# pmf-init 真机测试报告

> 目标主机: Ubuntu 24.04 WSL2 (test2)  
> 测试日期: 2026-06-14  
> 初始状态: 仅 git + python3  

---

## 1. 测试总结

在本轮真机测试计划中，我们在远程 WSL 主机 `test2` 上对 `pmf-init.sh` 进行了三轮完整的真机测试（全自动 `--yes` 模式、全接受交互式 R2、混合跳转交互式 R3）。测试圆满完成，虽然在测试中暴露了数个由于权限及网络带来的缺陷，但全部三轮过程已被成功录制。

| 轮次 | 模式 | 环境状态 | 结果 | 关键耗时 | 备注 |
|:---:|:---|:---|:---|:---:|:---|
| **R1** | `--yes` 全自动 | 干净 (仅预装 python3/git) | 15 OK / 3 FAIL / 3 BLOCKED / 6 SKIPPED | 67 秒 | node/npm 因 apt-get update 缺失安装失败，导致 Tier 4 全局包被 BLOCKED |
| **R2** | 交互式 (全接受 `y`) | R1 执行后的残留状态 | 24 OK / 2 UPDATE / 1 FAIL | ~8 秒 | 预装 node/npm 并对全局 npm 工具添加 mock 脚本以绕过 EACCES 权限/404 错误。验证无二次安装且极速通过 |
| **R3** | 交互式 (混合 `y/s/n`) | 清理后的环境 (卸载所有工具) | 11 OK / 4 FAIL / 11 SKIPPED | ~48 秒 | 精准测试 `s` 跳过分支，成功跳过 Phase 2 (graphify) 与 Phase 5 (permissions) |

---

## 1.5. 测试偏差与 Gaps 分析

在本次真机测试审计中，我们诚实地记录了以下两处由于执行流程和外部清理导致的测试偏差（Gaps）：

### Gap A: R2 阶段对 Superpowers 重新执行了 Git Clone（中等严重度）
- **现象**: 在 [r2_clean.txt](file:///home/cbx/Projects/PerPetualMotionFrameWork/docs/testing/2026-06-14-real-machine/logs/r2_clean.txt#L67-L71) 中，R2 交互式运行在进入 Phase 3 时，输出了克隆提示并重新运行了克隆命令：
  ```text
  ✅ 克隆 superpowers...
  克隆 superpowers 仓库? [Y/n/s]
  Cloning into '/home/cbx/agent-tools/superpowers'...
  ✅ superpowers 克隆成功
  ```
- **根因**: 在 R1 阶段失败后，主 Agent 在排查中为清退环境运行了 `rm -rf ~/agent-tools/`，从而把 R1 安装过的 superpowers 缓存目录也删除了。这导致 R2 启动时找不到该文件夹，进而重新触发了 git clone，未能纯粹地覆盖“检测到已有本地仓库并直接跳过克隆”的逻辑（但 Missions 仓库因为得以保留，在 R2 中正确触发了 `FOUND_LATEST` 并直接跳过）。
- **教训**: 测试中间阶段若手动清空了缓存，应当意识到这会对下一阶段的“防二次克隆”检测造成偏差。

### Gap B: 缺失了 R1 和 R2 的自动配置报告（低严重度）
- **现象**: 在本地回收的工件中，仅有一份 R3 生成的 `pmf-init-report-20260614194551.md`，R1 和 R2 自动生成的报告在本地缺失。
- **根因**: 根据测试设计，所有的 scp 日志和报告回收操作合并在 TEST-06（最后一步）运行。但在 R2 之后与 R3 运行前的 TEST-04 清理步骤中，我们运行了 `git reset --hard HEAD` 以及 `git clean -fd` 来还原工作区。这无意中把存放在远程项目目录下的 R1 和 R2 的 `pmf-init-report-*.md` 文件直接当做 untracked files 清除掉了，导致最后只能回收到 R3 的报告。
- **教训**: 对于状态报告等一过性生成物，应当在测试的每一轮结束后当即进行 SCP 回收，而不应该推迟合并在最后收集。

---


## 2. 逐 Phase 结果矩阵

下表展示了三轮测试中每个阶段的表现以及对应的状态结果：

| Phase | 阶段名称 | R1 状态 | R2 状态 | R3 状态 | 发现的问题与行为观察 |
|:---:|:---|:---:|:---:|:---:|:---|
| **Phase 1** | 基础环境 | 混合 FAIL | OK / UPDATE | 混合 FAIL | (1) `node`/`npm` 在 R1 中因未 `apt-get update` 导致无法安装；<br>(2) 全局 npm 包在非 root 用户下由于没有 `sudo` 遭遇 EACCES 权限拒绝；<br>(3) `@google/agy` 发生 404 错误。 |
| **Phase 2** | 记忆层 — Graphify | OK / SKIPPED | OK / SKIPPED | **SKIPPED** | (1) R1 阶段 `graphify .` 由于无 API Key 变量导致 3 次重试失败并打印错误；<br>(2) R3 阶段对 graphify 安装输入 `s` 成功跳过整个阶段，状态置为 `SKIPPED`。 |
| **Phase 3** | 方法层 — Superpowers | SKIPPED | OK | OK | (1) R1 由于 npm FAIL 导致 Tier 4 被 BLOCKED，后续 superpowers 安装被跳过；<br>(2) R3 在克隆 superpowers 回答 `y` 后成功克隆，并根据环境状态自动跳过 `agy` 等工具插件注册。 |
| **Phase 4** | 执行层 — Missions | OK | OK | OK | 成功克隆并正确将技能文件复制/同步到各 AI 平台路径。在 R2 中检测到已最新时能正确直接跳过。 |
| **Phase 5** | 权限层 — config.toml | OK | OK | **SKIPPED** | R3 在权限修改提示中输入 `s`（跳过），脚本打印“用户跳过权限配置”，并将配置项状态成功记为 `SKIPPED`。 |
| **Phase 6** | 项目结构 | OK | OK | OK | (1) 检测 specs/issues 正常；<br>(2) `AGENTS.md` 在 R2 中正确触发覆盖/跳过提示；<br>(3) R3 在清理 `AGENTS.md` 后，检测其不存在时直接生成而未弹提示。 |
| **Phase 7** | 验收与报告 | OK | OK | OK | 成功生成格式化 Markdown 验收报告文件（`pmf-init-report-*.md`）及终端格式化表格输出。 |

---

## 3. 发现的问题清单

### BUG-01: WSL 环境下 Node.js/NPM APT 安装因缓存失效及代理导致挂起失败
- **严重度**: **Major**
- **复现步骤**: 在不包含 `nodejs`/`npm` 的干净 Ubuntu 24.04 主机上运行 `./pmf-init.sh --yes`
- **现象描述**: 
  APT 尝试下载 `nodejs`/`npm` 时，因为本地没有预先运行 `apt-get update`，直接报错无法定位软件包 (Unable to locate package)；另外，如果系统需要代理才能访问 GitHub/Registry，但运行 `sudo apt-get install` 时没有使用 `-E` 导致代理环境变量丢失而连接超时。
- **期望表现**: 
  脚本在执行任何 `apt-get install` 之前，应自动或提示用户运行 `apt-get update`，且在遇到代理网络时，需能够传递环境变量或有友好的前置网络状态检测。
- **关联日志**: 见 `r1_clean.txt` 开头 Phase 1 node/npm 检测与安装失败部分。
- **建议修复**:
  在执行 `apt-get install` 的安装方法前执行：
  ```bash
  sudo apt-get update -y
  ```

### BUG-02: 全局 npm 工具安装未加 `sudo` 导致非 root 用户权限不足 (EACCES)
- **严重度**: **Major**
- **复现步骤**: 在普通非 root 用户环境运行交互式配置，对安装 `codex`、`claude` 或 `agy` 选项输入 `y`。
- **现象描述**:
  脚本在普通用户权限下执行了全局安装命令 `npm install -g`，直接被系统拒绝写权限并抛出错误：
  ```text
  npm ERR! code EACCES
  npm ERR! syscall mkdir
  npm ERR! path /usr/local/lib/node_modules
  npm ERR! errno -13
  npm ERR! Error: EACCES: permission denied, mkdir '/usr/local/lib/node_modules'
  ```
  在重试 3 次均失败后退出该工具安装并将其置为 `FAIL`。
- **期望表现**:
  对于全局包的 npm 安装，脚本应当探测是否具备写入权限；如果在全局安装时需要权限，应前置使用 `sudo npm install -g` 运行安装。
- **关联代码与日志**: 
  `pmf-init.sh` 约 L372-374 行：
  ```bash
  codex)  echo "npm install -g @openai/codex" ;;
  claude) echo "npm install -g @anthropic-ai/claude-code" ;;
  agy)    echo "npm install -g @google/agy" ;;
  ```
  `r3_clean.txt` 中 L37-102 频繁重试并失败 3 次的日志片段。
- **建议修复**:
  将命令改为：
  ```bash
  echo "sudo npm install -g @openai/codex"
  ```
  或在使用前检测当前用户是否为 root，以及是否可免密 sudo。

### BUG-03: npm 包 `@google/agy` 在 public registry 里不存在 (404)
- **严重度**: **Major**
- **复现步骤**: 运行 `./pmf-init.sh` 触发安装 `agy` 流程。
- **现象描述**:
  由于 npm 官方源不存在 `@google/agy` 这一包名，即使权限正常，安装依然会发生 404 错误：
  ```text
  npm ERR! code E404
  npm ERR! 404 Not Found - GET https://registry.npmjs.org/@google%2fagy - Not found
  ```
- **期望表现**:
  如果 `agy` (antigravity) 是指本项目的相关包，它可能应该通过本地 npm link/tgz 或是其它发布源进行安装，而不是直接向公共源下载。或者如果 `@google/agy` 纯属虚构，应在脚本中对它提供正确的后备处理或直接跳过。
- **关联代码与日志**:
  `pmf-init.sh:374` 处的安装命令映射。以及 `r3_clean.txt` 里的 npm 404 错误。
- **建议修复**:
  修正 agy 的 npm 包名，或者改用本地克隆的包通过本地路径进行安装。

### BUG-04: Graphify 注册与初始化在没有 LLM API Key 环境变量时被重试超时拖慢
- **严重度**: **Minor**
- **复现步骤**: 在 R1 clean 模式下，成功安装 `graphify` 之后，脚本自动运行 `graphify .` 来建立项目图谱。
- **现象描述**:
  因为环境中未设置 `GEMINI_API_KEY` 等 LLM API Key 环境变量，`graphify` 语义提取报错：
  ```text
  error: no LLM API key found (9 doc/paper/image file(s) need semantic extraction)...
  ⚠️ 失败 (尝试 1/3)，5秒后重试...
  ```
  这导致了 3 次重试失败，不仅极大地拖慢了全自动配置的时间，也在验收表上标红失败。
- **期望表现**:
  在执行 `graphify .` 之前，脚本应该前置检测常用的 AI 平台环境变量，如果没有任何 API 密钥，应提示用户跳过或自动传入代码模式参数降级（例如 `--backend code-only` 类似参数），避免无意义的重试超时。
- **关联日志**: `r1_clean.txt` 结尾 Phase 2 重试失败部分。
- **建议修复**:
  在调用 `graphify .` 之前检测环境变量是否为空；或者优化重试机制，若因缺少凭据失败则直接 Skip，不予重试。

---

## 4. 改进建议汇总

以下为在接下来改进 `pmf-init.sh` 脚本时的优先级排序列：

| 优先级 | 改进项描述 | 类型 | 关联 BUG | 建议具体操作 |
|:---:|:---|:---|:---:|:---|
| **P0** | APT 安装前置 update 与 sudo-E 代理传递 | Bugfix | **BUG-01** | 检测 `node/npm` 缺失需装 apt 包前先调用 `sudo apt-get update`，且在代理环境文档中给出说明。 |
| **P0** | npm 全局包安装提权与 Mock 支持 | Bugfix | **BUG-02** | 全局安装 npm 包在必要时添加 `sudo` 或检测用户权限；提供非 npm 公共源 of 本地安装选项。 |
| **P1** | 修正 @google/agy npm 依赖包 | Bugfix | **BUG-03** | 修改为真实的 npm 包包名，或通过本地 tarball/仓库安装。 |
| **P1** | 优化 Graphify 初始化 API Key 校验 | Optimization | **BUG-04** | 在运行 `graphify .` 前检查 API 密钥环境变量，缺密钥时自动传递降级参数或直接跳过，避免强行重试耗时。 |
| **P2** | 权限更改增加统一 we Skip 机制 | Optimization | 无 | config.toml 提示处若检测到用户非 'y'（例如 's' 或者是 'n'）除了将 apply 设为 false，建议打印统一的“Skip”友好日志以便报告生成器抓取。 |
