# pmf-init：交互式环境配置脚本设计 Spec

> 日期：2026-06-14
> 状态：待批准
> 关联文档：[PerPetual Motion FrameWork 第二版](file:///home/cbx/Projects/PerPetualMotionFrameWork/docs/PerPetual%20Motion%20FrameWork%E7%AC%AC%E4%BA%8C%E7%89%88.md)

## 目标

为 PerPetual Motion FrameWork 第二版定义的四层架构（权限层、记忆层、方法层、执行层）提供一键式交互配置脚本 `pmf-init`。脚本从基础环境检测开始，逐层安装/更新所需组件，最后进行完整验收并输出报告。

## 核心原则

- **先检测再行动**：每个组件先 detect 状态，再决定 install / update / skip
- **用户可控**：每步交互询问 Y/n/s，用户可跳过任何单项或整个阶段
- **`--yes` 全自动**：传入 `--yes` 跳过所有确认并自动更新已有组件
- **安全底线**：权限层修改即使在 `--yes` 模式下仍需确认（除非 `--force-permissions`）
- **不覆盖用户数据**：已有 skill 目录不覆盖，已有 AGENTS.md 提供三选一
- **失败重试**：网络/安装操作失败后重试 3 次，间隔递增（5s → 10s）
- **容错不中断**：任何单项失败不终止脚本，记录状态继续执行

## 文件结构

```text
PerPetualMotionFrameWork/
├── pmf-init.sh            # Linux/macOS 主脚本（Bash）
├── pmf-init.ps1           # Windows 主脚本（PowerShell）
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-06-14-setup-script-design.md   # 本文件
```

两个脚本逻辑完全对称，只是语法不同。单文件分发，不拆分子脚本。

## 命令行接口

```bash
# Linux / macOS
chmod +x pmf-init.sh
./pmf-init.sh                           # 交互模式
./pmf-init.sh --yes                     # 全自动（权限层仍需确认）
./pmf-init.sh --yes --force-permissions # 全自动（包括权限层）

# Windows PowerShell
.\pmf-init.ps1
.\pmf-init.ps1 -Yes
.\pmf-init.ps1 -Yes -ForcePermissions
```

## 执行阶段总览

| 阶段 | 名称 | 内容 |
|---|---|---|
| Phase 1 | 基础环境 | git, python3, pip, node, npm/npx, uv, codex, claude, agy |
| Phase 2 | 记忆层 | Graphify（graphifyy via uv + 多平台 skill 放置） |
| Phase 3 | 方法层 | Superpowers（各平台专用安装方式） |
| Phase 4 | 执行层 | Missions（各平台 skill 放置） |
| Phase 5 | 权限层 | Codex config.toml（approval_policy, sandbox_mode, multi_agent） |
| Phase 6 | 项目结构 | docs/superpowers/specs/, issues/, .mission/, AGENTS.md |
| Phase 7 | 验收 | 终端状态表 + 报告文件 |

## 核心函数

```text
detect_tool(name, command)      → FOUND_LATEST(version) | FOUND_UPDATABLE(current, latest) | NOT_FOUND
detect_skill(name, paths[])     → 每路径返回 FOUND | NOT_FOUND | UPDATABLE
prompt_user(message, default)   → yes | no | skip_phase
retry_command(command, retries) → SUCCESS | FAIL(reason)   # max 3 次，间隔 5s/10s
install_tool(name, method)      → SUCCESS | FAIL(reason)
refresh_path()                  → 刷新 PATH + 清除 hash 缓存
backup_file(path)               → 带时间戳备份
log(level, message)             → 终端彩色输出 + 写入报告缓冲
```

## Shell PATH 刷新策略

安装工具后当前 shell 可能无法立即找到新命令，原因：
1. 安装器修改了 `~/.bashrc` / `~/.zshrc` / `~/.profile` 但当前会话未 source
2. Bash/Zsh 的 hash 表缓存了旧的命令位置
3. 不同工具安装到不同路径（`~/.local/bin`、npm global bin、`~/.cargo/bin` 等）

### `refresh_path()` 函数设计

每次 `install_tool()` 成功后自动调用 `refresh_path()`：

#### Bash (Linux/macOS)

```bash
refresh_path() {
    # 1. 清除命令 hash 缓存
    hash -r 2>/dev/null

    # 2. 将常见安装路径加入当前会话 PATH（如果不在的话）
    local paths_to_add=(
        "$HOME/.local/bin"                          # pip, uv, pipx
        "$HOME/.cargo/bin"                          # cargo/uv installer
        "$(npm config get prefix 2>/dev/null)/bin"  # npm global
        "$(python3 -m site --user-base 2>/dev/null)/bin"  # pip --user
    )
    for p in "${paths_to_add[@]}"; do
        if [ -d "$p" ] && [[ ":$PATH:" != *":$p:"* ]]; then
            export PATH="$p:$PATH"
        fi
    done

    # 3. 重新 source profile（仅在需要时，避免副作用）
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ]; then
            # 仅提取 PATH 相关行，避免 source 整个文件带来副作用
            eval "$(grep -E '^export PATH=|^PATH=' "$rc" 2>/dev/null)"
        fi
    done
}
```

#### PowerShell (Windows)

```powershell
function Refresh-Path {
    # 1. 从注册表重新读取系统和用户 PATH
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$userPath;$machinePath"

    # 2. 追加常见安装路径
    $extraPaths = @(
        "$env:APPDATA\Python\Python3*\Scripts"     # pip on Windows
        "$env:APPDATA\npm"                          # npm global
        "$env:USERPROFILE\.local\bin"               # uv
        "$env:USERPROFILE\.cargo\bin"               # cargo/uv installer
    )
    foreach ($p in $extraPaths) {
        $resolved = Resolve-Path $p -ErrorAction SilentlyContinue
        if ($resolved -and $env:Path -notlike "*$resolved*") {
            $env:Path = "$resolved;$env:Path"
        }
    }
}
```

### 调用时机

| 时机 | 行为 |
|---|---|
| 脚本启动时 | 调用一次 `refresh_path()`，确保已有工具可被检测 |
| 每次 `install_tool()` 成功后 | 自动调用 `refresh_path()`，确保后续阶段能找到新装工具 |
| 每个 Phase 开始时 | 调用一次 `refresh_path()`，兜底防止遗漏 |

### 降级处理

如果 `refresh_path()` 后仍然找不到刚安装的命令：

```text
  ✅ uv installed successfully
  ⚠ uv not found in PATH after refresh
  
  Trying known paths:
    ~/.local/bin/uv ... FOUND
  
  Using full path: /home/user/.local/bin/uv
```

脚本内部对"刚安装但 PATH 可能未生效"的工具，使用**全路径 fallback**：先尝试命令名，失败则尝试已知的完整路径。

## 交互模型

### 阶段入口

```text
═══════════════════════════════════════
  Phase 2/7: 记忆层 — Graphify
═══════════════════════════════════════

  Detecting graphify... NOT FOUND

  Install graphifyy via uv? [Y/n/s]
    Y = install    n = skip this item    s = skip entire phase
```

### 组件状态与行为矩阵

| 检测结果 | 正常模式 | --yes 模式 |
|---|---|---|
| `NOT_FOUND` | 询问安装 | 自动安装 |
| `FOUND_UPDATABLE` | 跳过，记录到报告"可更新项" | 自动更新 |
| `FOUND_LATEST` | 跳过，✅ 标记 | 跳过，✅ 标记 |

### 重试机制

所有涉及网络/安装的操作使用 `retry_command` 包装：

| 次数 | 行为 |
|---|---|
| 第 1 次失败 | 等待 5 秒，自动重试 |
| 第 2 次失败 | 等待 10 秒，自动重试 |
| 第 3 次失败 | 记录 FAIL，输出错误原因，继续下一项 |

适用范围：`apt install`、`brew install`、`winget install`、`npm install`、`uv tool install`、`git clone`、`git pull`、`agy plugin install`。纯本地操作（文件复制、目录创建）不重试，失败即记录。

---

## Phase 1：基础环境

### 9 个工具

安装顺序有依赖约束：

```text
第一梯队（无依赖）：  git
第二梯队（系统级）：  python3 + pip, node + npm/npx
第三梯队（依赖 pip）：uv
第四梯队（依赖 npm）：codex, claude, agy
```

如果 node/npm 检测失败且用户跳过安装，第四梯队三个工具自动标记为 `BLOCKED(需要 npm)`。

### 检测命令

| 工具 | 检测命令 | 版本更新检测 |
|---|---|---|
| git | `git --version` | 交给系统包管理器判断 |
| python3 | `python3 --version` 或 `python --version` | 对比主版本 ≥ 3.10 |
| pip | `pip3 --version` 或 `pip --version` | 随 python 检测 |
| node | `node --version` | 对比 LTS 版本号（≥ 20） |
| npm / npx | `npm --version` | 随 node 检测 |
| uv | `uv --version` | `uv self update --dry-run` 或版本比对 |
| codex | `codex --version` | `npm outdated -g @openai/codex` |
| claude | `claude --version` | `npm outdated -g @anthropic-ai/claude-code` |
| agy | `agy --version` | `npm outdated -g @google/agy` |

### 平台安装方法矩阵

| 工具 | Linux (apt/dnf) | macOS (brew) | Windows (PowerShell) |
|---|---|---|---|
| git | `apt install git` | `brew install git` | `winget install Git.Git` |
| python3 | `apt install python3 python3-pip` | `brew install python@3.12` | `winget install Python.Python.3.12` |
| node+npm | `apt install nodejs npm` 或 nvm | `brew install node` | `winget install OpenJS.NodeJS.LTS` |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | `brew install uv` | `winget install astral-sh.uv` |
| codex | `npm install -g @openai/codex` | 同左 | 同左 |
| claude | `npm install -g @anthropic-ai/claude-code` | 同左 | 同左 |
| agy | `npm install -g @google/agy` | 同左 | 同左 |

### Linux 包管理器自动检测

```bash
if command -v apt-get &>/dev/null; then PKG_MGR="apt"
elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
elif command -v pacman &>/dev/null; then PKG_MGR="pacman"
fi
```

### 容错

- node/npm 全局安装权限不足时提示使用 `sudo` 或 nvm
- 网络不通时提示用户检查网络，记录 blocker

---

## Phase 2：记忆层 — Graphify

### 安装 Graphify CLI

```text
检测：graphify --version
安装：uv tool install "graphifyy[office,chinese]"
更新：uv tool upgrade graphifyy
```

**依赖门禁**：Phase 1 中 uv 未安装且用户跳过 → 标记 `BLOCKED(需要 uv)`。

### 多平台 Skill 注册（经 CLI 实际验证）

`graphify install --platform <name>` 命令**确实存在**，支持 22 个平台：

```text
graphify install [--project] [--platform P|P]
支持平台: claude, codex, opencode, kilo, aider, copilot, claw, droid,
          trae, trae-cn, hermes, kiro, pi, codebuddy, antigravity,
          antigravity-windows, windows, kimi, amp, devin, gemini, cursor
```

该命令会自动将平台适配的 SKILL.md + references/ 放到各平台的正确路径。

#### 三个主要平台的注册命令和实际行为（经实测验证）

| 命令 | skill 安装到 | 额外操作 |
|---|---|---|
| `graphify install --platform codex` | `~/.codex/skills/graphify/SKILL.md` + `references/` | 无 |
| `graphify install --platform antigravity` | `~/.gemini/config/skills/graphify/SKILL.md` + `references/` | 无 |
| `graphify install --platform claude` | `~/.claude/skills/graphify/SKILL.md` + `references/` | 自动创建 `~/.claude/CLAUDE.md` |

> 注：`graphify claude install`（子命令形式）也存在，功能是向项目 CLAUDE.md 写入 `## graphify` 段落。
> 与 `graphify install --platform claude`（flag 形式）作用不同：前者是项目级集成，后者是全局 skill 安装。

脚本中 Phase 2 的注册流程：

```text
1. 安装 graphifyy CLI（uv tool install）
2. 对每个已安装的平台工具，运行对应注册命令：
   - codex 已安装  → graphify install --platform codex
   - agy 已安装    → graphify install --platform antigravity
   - claude 已安装 → graphify install --platform claude
3. 可选：运行 graphify claude install 做项目级集成
```

#### 各平台 SKILL.md 差异（自动处理，无需手动）

| 差异 | Codex 版本 | AGY/Gemini 版本 |
|---|---|---|
| 多 Agent 调度 | `spawn_agent` / `wait_agent` / `close_agent` API | 通用 Agent tool + `subagent_type="general-purpose"` |
| 结果传递 | 内存中返回（无 CHUNK_PATH） | 磁盘文件（CHUNK_PATH） |
| 前提条件 | `config.toml` 中 `multi_agent = true` | 无 |

这些差异由 `graphify install --platform` 自动处理，脚本无需手动区分版本。

### 项目级图谱

| graphify-out/ 状态 | 正常模式 | --yes 模式 |
|---|---|---|
| 不存在 | 询问是否运行 `graphify .` | 自动生成 |
| 已存在 | 记录到报告"可更新项" | 自动重新生成 |

---

## Phase 3：方法层 — Superpowers

```text
仓库源：https://github.com/obra/superpowers.git
本地缓存：~/agent-tools/superpowers
```

### 各平台安装方式（经调研确认）

三个平台的安装机制完全不同：

#### AGY（有专用 CLI）

AGY 有完整的插件管理命令：

```bash
# 从本地克隆的目录安装（已验证的工作流程）
git clone https://github.com/obra/superpowers.git ~/agent-tools/superpowers
agy plugin install ~/agent-tools/superpowers

# 验证
agy plugin list
```

`agy plugin install` 会：
- 读取目录中的 `plugin.json`
- 将 skills 复制到 `~/.gemini/config/plugins/superpowers/skills/`
- 将 hooks 复制到 `~/.gemini/config/plugins/superpowers/hooks.json`
- 记录安装元数据

**检测**：`agy plugin list` 输出中是否包含 `superpowers`
**更新**：`git -C ~/agent-tools/superpowers pull` → `agy plugin install ~/agent-tools/superpowers`

#### Codex（文件放置）

Codex 没有插件命令，通过文件放置安装：

```bash
cp -R ~/agent-tools/superpowers/skills/* ~/.codex/skills/
```

**检测**：`~/.codex/skills/brainstorming/SKILL.md` 是否存在
**更新**：git pull 后重新复制（不覆盖已有目录）

#### Claude Code（文件放置 + CLAUDE.md）

Claude Code **没有插件市场或 `/plugins` 命令**（经调研确认）。其扩展机制为：
- `CLAUDE.md`（系统指令）
- `.claude/commands/`（自定义命令）
- `settings.json`（hooks）
- MCP servers

安装 Superpowers skills：

```bash
# 复制 skills 到全局命令目录
mkdir -p ~/.claude/commands
# 或复制到通用 skills 路径（与 Codex 共享）
cp -R ~/agent-tools/superpowers/skills/* ~/.agents/skills/
```

**检测**：`~/.agents/skills/brainstorming/SKILL.md` 是否存在

### 更新检测

对 `~/agent-tools/superpowers` 使用 `git -C fetch && git -C log HEAD..origin/main --oneline` 检查远端是否有新提交。

### 安装流程汇总

```text
1. ~/agent-tools/superpowers 不存在 → git clone
   已存在 → 检测远端更新
2. 远端有更新：
   - 正常模式 → 记录到报告"可更新项"
   - --yes 模式 → git pull 后按各平台方式重新安装
3. 各平台分别安装：
   - AGY: agy plugin install ~/agent-tools/superpowers
   - Codex: cp skills/* → ~/.codex/skills/
   - Claude Code: cp skills/* → ~/.agents/skills/
4. 已存在的 skill 目录不覆盖（跳过并记录 SKIPPED）
```

---

## Phase 4：执行层 — Missions

```text
仓库源：https://github.com/flowing-water1/Missions.git
本地缓存：~/agent-tools/Missions
```

### 检测的 6 个目录

```text
mission/
mission-doc-route/
mission-approved-doc/
mission-csv-execute/
mission-long-task/
mission-recovery/
```

### 各平台安装方式

Missions 仓库没有 `plugin.json`，不能直接用 `agy plugin install`。采用 skill 文件放置方式：

| 平台 | 目标路径 | 方式 |
|---|---|---|
| AGY | `~/.gemini/config/skills/mission*/` | 复制 `mission*` 目录到 `~/.gemini/config/skills/` |
| Codex | `~/.codex/skills/mission*/` | 复制到 `~/.codex/skills/` |
| Claude Code | `~/.agents/skills/mission*/` | 复制到 `~/.agents/skills/` |

### 复制规则

- 只复制 `mission*` 匹配的目录
- 不复制 README.md、LICENSE 等无关文件
- 已存在的 skill 目录不覆盖（跳过并记录 SKIPPED）

### 更新检测

与 Phase 3 相同：`git -C fetch` 检查远端更新。

---

## Phase 5：权限层 — Codex config.toml

### 配置文件路径

| 平台 | 路径 |
|---|---|
| Linux / macOS | `~/.codex/config.toml` |
| Windows | `%USERPROFILE%\.codex\config.toml` |

### 检测的三个键

| 键 | 目标值 |
|---|---|
| `approval_policy` | `"never"` |
| `sandbox_mode` | `"danger-full-access"` |
| `[features].multi_agent` | `true` |

### 安全交互

```text
⚠ WARNING: 以下修改会降低 Codex 安全限制

Current approval_policy = "on-request"  →  Target: "never"
Current sandbox_mode    = "workspace-write" →  Target: "danger-full-access"

This means Codex will execute commands without approval
and have full access to your filesystem and network.

Only use in git-managed workspaces without production secrets.

Apply permission changes? [y/N]     ← 默认 N（拒绝）
```

### flag 行为

| flag 组合 | 行为 |
|---|---|
| 无 flag | 逐项询问，默认 N |
| `--yes` | 仍弹一次安全确认，默认 N |
| `--yes --force-permissions` | 跳过确认，直接修改 |

### 写入规则

- 修改前自动创建 `config.toml.bak.YYYYMMDDHHmmss`
- 逐键更新/追加，不整文件覆盖，保留用户已有的其他配置

---

## Phase 6：项目结构

### 目录创建

在项目根目录创建（已存在则跳过，不清空）：

```text
docs/superpowers/specs/
issues/
.mission/
```

### AGENTS.md 处理

| 状态 | 正常模式 | --yes 模式 |
|---|---|---|
| 不存在 | 生成默认模板 | 生成默认模板 |
| 已存在 | 提示三选一：[1]覆盖 [2]追加 [3]跳过 | 默认跳过 |

### 默认 AGENTS.md 模板

```markdown
# 项目 Agent 规则

## 工具分工
- 讨论、需求澄清、spec 设计：首选 Claude/AGY（Opus 4.6）+ Superpowers + Missions
- 降级讨论：Codex + Superpowers + Missions
- 长时间执行：Codex `/goal @issues/*.csv`
- 方法层：仅使用 Superpowers

## 工作流路由
- 简单查询/审查：直接回答
- 复杂任务：先 spec → mission 转 CSV → /goal 执行
- 中断恢复：$mission continue
- 代码库理解：优先查 Graphify

## 硬门禁
- 不虚构验证证据
- 低等级证据不包装为高等级结论
- 变更后必须运行验证并写明结果
- 不写入密钥，不运行破坏性命令

## 长任务完成定义
- 四状态闭环：dev_state + review_initial + review_regression + git_state
- REVIEW 行对齐原始目标
- 无法验证项必须记录 validation_gap 和 risk
```

---

## Phase 7：验收

### 终端状态表

```text
═══════════════════════════════════════════════════════════════
  Phase 7/7: 验收
═══════════════════════════════════════════════════════════════

  ┌─────────────┬──────────────────────┬──────────┬───────────┐
  │ Layer       │ Component            │ Status   │ Version   │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 基础环境     │ git                  │ ✅ OK    │ 2.43.0    │
  │             │ python3              │ ✅ OK    │ 3.12.4    │
  │             │ pip                  │ ✅ OK    │ 24.1      │
  │             │ node                 │ ✅ OK    │ 20.15.0   │
  │             │ npm                  │ ✅ OK    │ 10.8.1    │
  │             │ uv                   │ ✅ OK    │ 0.7.12    │
  │             │ codex                │ ✅ OK    │ 1.2.3     │
  │             │ claude               │ ⚠️ UPDATE │ 1.0→1.2   │
  │             │ agy                  │ ✅ OK    │ 0.5.0     │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 记忆层       │ graphify             │ ✅ OK    │ 0.8.3     │
  │             │ graphify→codex       │ ✅ OK    │ skill     │
  │             │ graphify→agy         │ ✅ OK    │ skill     │
  │             │ graphify→claude      │ ✅ OK    │ CLAUDE.md │
  │             │ graphify-out/        │ ✅ EXISTS │           │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 方法层       │ superpowers→agy      │ ✅ OK    │ plugin    │
  │             │ superpowers→codex    │ ✅ OK    │ 14 skills │
  │             │ superpowers→claude   │ ✅ OK    │ 14 skills │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 执行层       │ missions→agy         │ ✅ OK    │ 6 dirs    │
  │             │ missions→codex       │ ✅ OK    │ 6 dirs    │
  │             │ missions→claude      │ ✅ OK    │ 6 dirs    │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 权限层       │ approval_policy      │ ✅ never │           │
  │             │ sandbox_mode         │ ✅ full  │           │
  │             │ multi_agent          │ ✅ true  │           │
  ├─────────────┼──────────────────────┼──────────┼───────────┤
  │ 项目结构     │ docs/superpowers/    │ ✅ OK    │           │
  │             │ issues/              │ ✅ OK    │           │
  │             │ .mission/            │ ✅ OK    │           │
  │             │ AGENTS.md            │ ✅ OK    │           │
  └─────────────┴──────────────────────┴──────────┴───────────┘

  Summary: 24 OK / 1 UPDATE / 0 FAIL / 0 BLOCKED

  ⚠ 可更新项：
    claude: 当前 1.0.0 → 最新 1.2.0
    运行 npm update -g @anthropic-ai/claude-code 更新

  ✅ 环境就绪！请重启 Claude Code / AGY / Codex 使新配置生效。
```

### 状态类型

| 状态 | 符号 | 含义 |
|---|---|---|
| `OK` | ✅ | 已安装且为最新 |
| `UPDATE` | ⚠️ | 已安装但有更新可用 |
| `FAIL` | ❌ | 安装失败（3 次重试后） |
| `BLOCKED` | 🚫 | 依赖项缺失，无法安装 |
| `SKIPPED` | ⏭️ | 用户主动跳过 |

### 验收检测细节

| 组件 | 验收方式 |
|---|---|
| 基础工具 | `command --version` 获取版本号 |
| graphify CLI | `graphify --version` |
| graphify→codex | `~/.codex/skills/graphify/SKILL.md` 是否存在 |
| graphify→agy | `~/.gemini/config/skills/graphify/SKILL.md` 是否存在 |
| graphify→claude | `graphify claude install` 成功 或 CLAUDE.md 含 `## graphify` |
| graphify-out/ | 检查 `graph.html`、`GRAPH_REPORT.md`、`graph.json` 三个文件 |
| superpowers→agy | `agy plugin list` 包含 superpowers |
| superpowers→codex | 统计 `~/.codex/skills/` 下含 `SKILL.md` 的 superpowers 目录数 |
| superpowers→claude | 统计 `~/.agents/skills/` 下含 `SKILL.md` 的 superpowers 目录数 |
| missions→各平台 | 检查 6 个 `mission*` 目录是否存在于各 skills 路径 |
| config.toml | 解析并输出三个键的实际值 |
| AGENTS.md | 检查文件存在且字节数 > 0 |

### 报告文件

生成到项目根目录：`pmf-init-report-YYYYMMDDHHmmss.md`

```markdown
# PerPetual Motion FrameWork 环境配置报告

> 生成时间: YYYY-MM-DD HH:mm:ss
> 平台: [OS / arch / distro]
> 模式: 交互式 | --yes | --yes --force-permissions

## 状态总览
| 层 | 组件 | 状态 | 版本 | 备注 |

## 可更新项
- [组件]: [当前版本] → [最新版本] ([更新命令])

## 失败项
- [组件]: [错误原因] (重试 3 次后失败)

## 被阻塞项
- [组件]: 需要 [依赖项]

## 用户跳过项
- [组件]: 用户选择跳过

## 备份记录
- [原路径] → [备份路径]

## 下一步
1. 重启 Claude Code / AGY / Codex
2. 确认 skills 可触发：hello → $mission continue
3. 运行 graphify . 建立/刷新图谱
4. 开始讨论需求：首选 Claude/AGY，降级 Codex
```

---

## 调研发现记录

以下是在 spec 编写过程中通过实际调研和 CLI 验证发现的事实：

### Graphify 注册（经 CLI 实测验证）

| 命令 | 实际情况 |
|---|---|
| `graphify install --platform codex` | ✅ 存在，skill 安装到 `~/.codex/skills/graphify/` |
| `graphify install --platform antigravity` | ✅ 存在，skill 安装到 `~/.gemini/config/skills/graphify/` |
| `graphify install --platform claude` | ✅ 存在，skill 安装到 `~/.claude/skills/graphify/` + 创建 CLAUDE.md |
| `graphify claude install` | ✅ 存在（子命令形式），向项目 CLAUDE.md 写入 `## graphify` 段落 |
| 支持平台总数 | 22 个（claude, codex, antigravity, gemini, cursor 等） |

> 注：第一版文档中的 `graphify codex install` 子命令形式不存在，正确写法是 `graphify install --platform codex`（flag 形式）。

### Claude Code 插件

| 文档描述 | 实际情况 |
|---|---|
| `/plugins` 命令 | ❌ 不存在，Claude Code 没有插件市场 |
| 插件系统 | 通过 CLAUDE.md + .claude/commands/ + settings.json hooks + MCP |

### AGY 插件

| 文档描述 | 实际情况 |
|---|---|
| 手动复制到 `~/.gemini/config/plugins/` | ✅ 可行但非最佳 |
| `agy plugin install <dir>` | ✅ 最佳方式，有完整 CLI |
| `agy plugin list/enable/disable/uninstall` | ✅ 完整生命周期管理 |

---

## 不在范围内

- 不安装 addyosmani/agent-skills
- 不管理 API key / SSH key / 生产凭证
- 不删除用户已有文件
- 不提供 GUI 界面
- 不管理多项目并行配置（本脚本为单项目维度）
