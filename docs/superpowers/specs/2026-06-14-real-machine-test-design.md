# pmf-init 真机测试设计 Spec

> 日期：2026-06-14
> 状态：已批准
> 关联文档：[pmf-init 设计 Spec](file:///home/cbx/Projects/PerPetualMotionFrameWork/docs/superpowers/specs/2026-06-14-setup-script-design.md)

## 目标

在一台干净的远程主机上对 `pmf-init.sh` 进行三轮真机测试，记录完整终端日志并生成结构化分析报告，作为脚本改进的依据。

## 不在范围内

- 不测试 `pmf-init.ps1`（目标机为 Linux）
- 不修改脚本本身（只记录问题，不当场修复）
- 不测试 macOS / Windows 原生环境

## 目标主机

| 项目 | 值 |
|------|-----|
| SSH 别名 | `test2` |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| 内核 | 6.6.87.2-microsoft-standard-WSL2 |
| 已有工具 | git, python3 |
| 缺失工具 | pip, node, npm, uv, codex, claude, agy |
| skill 目录 | 全部不存在（~/.codex/, ~/.gemini/, ~/.claude/, ~/.agents/） |

## 代码来源

通过 GitHub 中转拉取：

```bash
ssh test2
git clone https://github.com/CBx-2023/PerPetualMotionFrameWork.git ~/pmf-test
cd ~/pmf-test
chmod +x pmf-init.sh
mkdir -p logs/
```

## 日志录制

每轮使用 `script` + `tee` 双重录制：

```bash
script -q -c "./pmf-init.sh --yes 2>&1 | tee logs/r1_clean.txt" logs/r1_raw.txt
```

- `rN_raw.txt`：含 ANSI 控制码的完整终端录制（可 `cat` 回放）
- `rN_clean.txt`：纯文本，供 Agent 分析

## 三轮测试

### R1：`--yes` 全自动（干净环境）

**目的**：验证完整安装链路端到端可用性。

```bash
script -q -c "./pmf-init.sh --yes 2>&1 | tee logs/r1_clean.txt" logs/r1_raw.txt
```

**关注点**：

| # | 检查项 |
|---|--------|
| 1 | 9 个工具的检测 → 安装 → PATH 刷新链路 |
| 2 | 梯队依赖门禁（npm 不存在时 Tier 4 是否 BLOCKED） |
| 3 | retry_command 重试机制是否正确触发、间隔是否为 5s/10s |
| 4 | Graphify git clone + uv tool install + 三平台注册 |
| 5 | Superpowers git clone + agy plugin install + 文件复制 |
| 6 | Missions git clone + mission* 目录复制到三平台 |
| 7 | config.toml 在 `--yes`（无 `--force-permissions`）时是否仍弹安全确认 |
| 8 | Phase 7 验收表渲染 + 报告文件生成 |
| 9 | 整体耗时 |

### R2：交互模式（R1 已安装的环境）

**目的**：验证"已存在检测"和"跳过"逻辑。

```bash
yes y | script -q -c "./pmf-init.sh 2>&1 | tee logs/r2_clean.txt" logs/r2_raw.txt
```

**关注点**：

| # | 检查项 |
|---|--------|
| 1 | 所有工具检测为 FOUND_LATEST，不重复安装 |
| 2 | skill 目录已存在时是否正确 SKIPPED |
| 3 | AGENTS.md 已存在时三选一提示是否出现 |
| 4 | config.toml 已是目标值时是否跳过修改 |
| 5 | 验收表应全部 ✅ OK |
| 6 | 整体耗时（应远快于 R1） |

### R2→R3 清理脚本

在 R2 和 R3 之间执行，恢复到接近干净状态：

```bash
# 卸载通过脚本安装的 npm 全局工具
npm uninstall -g @openai/codex @anthropic-ai/claude-code @google/agy 2>/dev/null || true

# 卸载 uv
uv self uninstall 2>/dev/null || rm -f ~/.local/bin/uv ~/.local/bin/uvx 2>/dev/null || true

# 卸载 graphifyy
uv tool uninstall graphifyy 2>/dev/null || true

# 清理 skill/plugin 目录
rm -rf ~/.codex/ ~/.gemini/ ~/.claude/ ~/.agents/

# 清理本地缓存仓库
rm -rf ~/agent-tools/

# 清理项目生成物（保留 logs/）
rm -rf ~/pmf-test/docs/ ~/pmf-test/issues/ ~/pmf-test/.mission/
rm -f ~/pmf-test/AGENTS.md ~/pmf-test/pmf-init-report-*.md

# 可选：卸载 node/npm（如果要测试完整安装链路）
# sudo apt remove -y nodejs npm
```

> 注：保留 git 和 python3（系统预装），保留 node/npm（apt 安装的不易干净卸载，且保留可测试 Tier 4 工具的独立安装能力）。

### R3：交互模式（清理后环境）

**目的**：验证交互提示和阶段跳过分支。

```bash
# 混合回答序列（需在 R1 后根据实际提示数量调整）
# 预期：接受大部分安装，跳过 Phase 2(graphify) 和 Phase 5(权限)
printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ns\ny\ny\ny\ns\ny\ny\n' | \
  script -q -c "./pmf-init.sh 2>&1 | tee logs/r3_clean.txt" logs/r3_raw.txt
```

**关注点**：

| # | 检查项 |
|---|--------|
| 1 | `s`（skip_phase）是否正确跳过整个阶段 |
| 2 | 被跳过的阶段在验收表中是否标记 ⏭️ SKIPPED |
| 3 | 跳过某阶段后后续阶段是否正常继续 |
| 4 | 报告"用户跳过项"部分是否正确列出 |
| 5 | `n`（跳过单项）是否正常工作 |

> **注意**：`printf` 序列是预估值。R1 跑完后根据实际交互提示数量和顺序调整。

## 日志回收

每轮结束后通过 SSH 将日志拉回本地：

```bash
# 在本地执行
mkdir -p docs/testing/2026-06-14-real-machine/
scp test2:~/pmf-test/logs/r*_clean.txt docs/testing/2026-06-14-real-machine/
# 也拉回脚本生成的验收报告
scp test2:~/pmf-test/pmf-init-report-*.md docs/testing/2026-06-14-real-machine/ 2>/dev/null || true
```

## 分析与报告

Agent 分析三轮日志后生成结构化测试报告：

```text
docs/testing/2026-06-14-real-machine/
├── r1_clean.txt          # R1 纯文本日志
├── r2_clean.txt          # R2 纯文本日志
├── r3_clean.txt          # R3 纯文本日志
├── pmf-init-report-*.md  # 脚本自身生成的验收报告（可能多份）
└── test-report.md        # Agent 生成的结构化分析报告
```

### 测试报告结构

```markdown
# pmf-init 真机测试报告

> 目标主机: Ubuntu 24.04 WSL2 (test2)
> 测试日期: 2026-06-14
> 初始状态: 仅 git + python3

## 测试总结

| 轮次 | 模式 | 环境状态 | 结果 | 耗时 |
|------|------|----------|------|------|
| R1 | --yes | 干净 | ? | ? |
| R2 | 交互(全y) | R1后 | ? | ? |
| R3 | 交互(混合) | 清理后 | ? | ? |

## 逐 Phase 结果矩阵

| Phase | 名称 | R1 | R2 | R3 | 发现的问题 |
|-------|------|----|----|----|-----------| 

## 发现的问题清单

### BUG-nn: [标题]
- **严重度**: critical / major / minor
- **复现**: 哪一轮、哪个 Phase
- **现象**: 实际输出
- **期望**: 应有表现
- **根因分析**: 代码中可能的原因
- **建议修复**: 改进方向 + 关联代码位置

## 改进建议汇总

按优先级排列，可直接作为下一轮改进 CSV 的输入：

| 优先级 | 改进项 | 类型 | 关联 BUG |
|--------|--------|------|----------|
```

## 验收标准

1. 三轮测试均完整执行（不因脚本崩溃而中断，或崩溃被记录为 BUG）
2. 每轮都有可读的纯文本日志保存到本地
3. 生成的测试报告包含逐 Phase 结果矩阵和所有发现的问题
4. 改进建议以可执行的格式列出，可直接转化为改进 CSV
