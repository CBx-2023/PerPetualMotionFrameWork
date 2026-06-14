# PerPetual Motion FrameWork

<p align="center">
  <strong>🔄 一键配置 AI Agent 四层协作架构</strong>
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> •
  <a href="#架构概览">架构概览</a> •
  <a href="#七阶段流程">七阶段流程</a> •
  <a href="#命令行参数">命令行参数</a> •
  <a href="https://cbx-2023.github.io/PerPetualMotionFrameWork/">📖 在线文档</a>
</p>

---

## 什么是 PerPetual Motion FrameWork？

PerPetual Motion FrameWork (PMF) 是一个 **AI Agent 协作框架**，通过四层架构将多个 AI 编程工具（Codex、Claude Code、AGY/Antigravity）统一为一个高效的开发工作流：

| 层 | 职责 | 组件 |
|---|---|---|
| **权限层** | 安全控制与审批策略 | Codex `config.toml` |
| **记忆层** | 代码库知识图谱 | Graphify CLI |
| **方法层** | 技能与方法论 | Superpowers Skills |
| **执行层** | 任务分解与闭环执行 | Missions Skills |

`pmf-init` 是框架的 **一键配置脚本**，可自动检测、安装、配置所有组件。

## 快速开始

### Linux / macOS

```bash
git clone https://github.com/CBx-2023/PerPetualMotionFrameWork.git
cd PerPetualMotionFrameWork
chmod +x pmf-init.sh
./pmf-init.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/CBx-2023/PerPetualMotionFrameWork.git
cd PerPetualMotionFrameWork
.\pmf-init.ps1
```

### 全自动模式

```bash
# Linux/macOS — 自动安装所有组件（权限层仍需确认）
./pmf-init.sh --yes

# Linux/macOS — 完全自动（包括权限修改）
./pmf-init.sh --yes --force-permissions

# Windows
.\pmf-init.ps1 -Yes
.\pmf-init.ps1 -Yes -ForcePermissions
```

## 架构概览

```
┌─────────────────────────────────────────────┐
│            PerPetual Motion FrameWork       │
├─────────┬─────────────┬────────────────────┤
│ Codex   │ Claude Code │ AGY (Antigravity)  │
├─────────┴─────────────┴────────────────────┤
│  Phase 5: 权限层 — config.toml 安全配置     │
├────────────────────────────────────────────┤
│  Phase 2: 记忆层 — Graphify 知识图谱        │
├────────────────────────────────────────────┤
│  Phase 3: 方法层 — Superpowers Skills       │
├────────────────────────────────────────────┤
│  Phase 4: 执行层 — Missions Skills          │
├────────────────────────────────────────────┤
│  Phase 1: 基础环境 — 9 工具依赖检测/安装     │
│  Phase 6: 项目结构 — 目录 + AGENTS.md       │
│  Phase 7: 验收 — 状态表 + 报告生成           │
└────────────────────────────────────────────┘
```

## 七阶段流程

### Phase 1: 基础环境

按 **四级依赖顺序** 检测和安装 9 个工具：

| Tier | 工具 | 最低版本 | 安装方式 |
|------|------|---------|---------|
| 1 | git | — | apt/dnf/pacman/brew/winget |
| 2 | python3 + pip | ≥ 3.10 | apt/brew/winget |
| 2 | node + npm | ≥ 20 | apt/brew/winget |
| 3 | uv | — | curl\|sh / winget |
| 4 | codex | — | npm install -g |
| 4 | claude | — | npm install -g |
| 4 | agy | — | npm install -g |

如果 Tier 2 (node/npm) 缺失且用户跳过，Tier 4 工具将被标记为 `BLOCKED(需要 npm)`。

### Phase 2: 记忆层 — Graphify

- 通过 `uv tool install "graphifyy[office,chinese]"` 安装 Graphify CLI
- 为每个已安装平台注册：`graphify install --platform codex/antigravity/claude`
- 可选：运行 `graphify .` 生成项目知识图谱

### Phase 3: 方法层 — Superpowers

- 克隆 [obra/superpowers](https://github.com/obra/superpowers) 到 `~/agent-tools/superpowers`
- AGY: `agy plugin install`
- Codex/Claude: 文件放置到 `~/.codex/skills/` 和 `~/.agents/skills/`（已有目录不覆盖）

### Phase 4: 执行层 — Missions

- 克隆 [flowing-water1/Missions](https://github.com/flowing-water1/Missions) 到 `~/agent-tools/Missions`
- 复制 6 个 mission 目录到三个平台的 skills 路径
- 仅复制 `mission*` 目录，不复制 README/LICENSE

### Phase 5: 权限层 — Codex config.toml

配置 Codex 的安全策略：

| 设置 | 目标值 | 说明 |
|------|--------|------|
| `approval_policy` | `never` | 免确认执行 |
| `sandbox_mode` | `danger-full-access` | 完全文件系统访问 |
| `multi_agent` | `true` | 多 Agent 协作 |

> ⚠️ **安全提示**：即使在 `--yes` 模式下，权限修改仍需手动确认（默认 N）。仅 `--yes --force-permissions` 会自动应用。

### Phase 6: 项目结构

- 创建目录：`docs/superpowers/specs/`、`issues/`、`.mission/`
- 生成 `AGENTS.md`（工具分工、工作流路由、硬门禁规则）
- 已有 AGENTS.md 提供三选一：覆盖/追加/跳过

### Phase 7: 验收

- 渲染格式化状态表（✅ OK / ⚠️ UPDATE / ❌ FAIL / 🚫 BLOCKED / ⏭️ SKIPPED）
- 生成 `pmf-init-report-YYYYMMDDHHmmss.md` 报告文件

## 命令行参数

### Bash (pmf-init.sh)

| 参数 | 说明 |
|------|------|
| `--yes` | 全自动模式，跳过所有确认（权限层除外） |
| `--force-permissions` | 与 `--yes` 配合，权限层也自动修改 |
| `--help` | 显示帮助信息 |

### PowerShell (pmf-init.ps1)

| 参数 | 说明 |
|------|------|
| `-Yes` | 全自动模式 |
| `-ForcePermissions` | 权限层自动修改 |
| `-Help` | 显示帮助信息 |

## 核心设计原则

- **先检测再行动** — 每个组件先 `detect` 状态，再决定 install/update/skip
- **用户可控** — 每步交互 Y/n/s，可跳过任何单项或整个阶段
- **安全底线** — 权限修改始终需要额外确认
- **不覆盖用户数据** — 已有 skill 目录不覆盖，AGENTS.md 提供选择
- **失败重试** — 网络操作重试 3 次，间隔递增（5s → 10s）
- **容错不中断** — 任何单项失败不终止脚本

## 项目结构

```
PerPetualMotionFrameWork/
├── pmf-init.sh              # Linux/macOS 配置脚本
├── pmf-init.ps1             # Windows 配置脚本
├── AGENTS.md                # Agent 协作规则（由脚本生成）
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-06-14-setup-script-design.md  # 设计文档
├── issues/                  # 任务 CSV 跟踪
└── .mission/                # Mission 运行时数据
```

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！
