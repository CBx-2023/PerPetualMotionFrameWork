# pmf-init 修复回归测试设计 Spec

> 日期：2026-06-14
> 状态：已批准
> 关联文档：
> - [pmf-init 设计 Spec](file:///home/cbx/Projects/PerPetualMotionFrameWork/docs/superpowers/specs/2026-06-14-setup-script-design.md)
> - [pmf-init 真机测试设计 Spec](file:///home/cbx/Projects/PerPetualMotionFrameWork/docs/superpowers/specs/2026-06-14-real-machine-test-design.md)

## 目标

在远程主机 `test2` 上对 `pmf-init.sh` 脚本在 `pmf-init-fixes` (FIX-01~05) 中所做的修复进行回归测试。通过三轮特定测试用例，录制终端日志并生成结构化回归分析报告，验证所有重大 Bug 已闭环且无新引入问题。

## 目标主机与环境

| 项目 | 值 |
|------|-----|
| SSH 别名 | `test2` |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| 内核 | 6.6.87.2-microsoft-standard-WSL2 |
| 执行身份 | 非 root 用户 (用于验证 `npm_global_cmd_prefix` 追加 sudo 功能) |
| 代理配置 | 确保设置有 `http_proxy` / `https_proxy` (验证 `sudo -E` 保留代理功能) |

---

## 恢复与清理脚本 (R-CLEAN)

在测试执行前、以及轮次之间恢复干净状态，在 `test2` 执行：

```bash
# 卸载 npm 全局工具
npm uninstall -g @openai/codex @anthropic-ai/claude-code @google/agy 2>/dev/null || true

# 移除 agy 独立安装
sudo rm -f /usr/local/bin/agy ~/.local/bin/agy 2>/dev/null || true

# 卸载 uv 与 graphifyy
uv self uninstall 2>/dev/null || rm -f ~/.local/bin/uv ~/.local/bin/uvx 2>/dev/null || true
uv tool uninstall graphifyy 2>/dev/null || true

# 清理配置与 skill 目录
rm -rf ~/.codex/ ~/.gemini/ ~/.claude/ ~/.agents/

# 清理生成的文件报告（保留 logs/）
rm -rf ~/pmf-test/docs/ ~/pmf-test/issues/ ~/pmf-test/.mission/
rm -f ~/pmf-test/AGENTS.md ~/pmf-test/pmf-init-report-*.md
```

---

## 回归测试用例

为避免与上一轮实机测试的 R1-R3 轮次混淆，本轮测试命名为 **R4**、**R5** 和 **R6**。

### 轮次 R4：自动部署回归测试 (`--yes` 模式，无 API Key)

* **目的**：验证修复后在干净环境下的全自动安装、`sudo -E` 代理保留、APT 缓存校验、以及无密钥时 Graphify 的自动跳过。
* **执行步骤**：
  1. 登录 `test2`，运行清理脚本。
  2. 执行自动部署并录制日志：
     ```bash
     script -q -c "./pmf-init.sh --yes 2>&1 | tee logs/r4_clean.txt" logs/r4_raw.txt
     ```
* **回归校验矩阵**：
  * **FIX-01 (APT Update)**：终端日志中 `apt-get update` 是否在首次安装前自动触发，且**仅执行了一次**。所有 apt 相关命令是否都包含 `sudo -E`。
  * **FIX-02 (npm sudo)**：以非 root 身份运行时，对于系统全局 npm 包安装，是否检测到写权限不足并**正确自动前置了 `sudo`**。
  * **FIX-03 (agy 安装)**：`agy` 并非通过 npm 安装，而是显示使用 `curl -fsSL https://antigravity.google/cli/install.sh | bash` 执行安装，且 `tier4_check_cmds` 中检测成功。
  * **FIX-04 (API Key)**：由于无任何大模型 API Key 环境变量，检测后是否**自动静默跳过了 `graphify .`**（应输出 `⏭️ graphify-out/: 用户跳过 (--yes 模式, 无 API Key)`），未发生重试和卡顿。

### 轮次 R5：交互式安装与跳过格式回归测试 (带 Dummy API Key)

* **目的**：验证在有 API Key 时 `graphify` 的交互式行为，以及手动跳过时的日志输出和报告生成是否完全兼容。
* **执行步骤**：
  1. 登录 `test2`，仅清理 graphify 目录及 `~/.agents/` 目录。
  2. 设置 Dummy API Key：
     ```bash
     export GEMINI_API_KEY="dummy_key_123"
     ```
  3. 执行脚本，手动选择跳过部分组件（输入 `n` 或 `s`），其余接受：
     ```bash
     # 示例交互混合输入
     ./pmf-init.sh
     ```
* **回归校验矩阵**：
  * **FIX-04 (API Key 交互警告)**：进入 `graphify` 时，是否提示检测到 API 密钥，发出警告，并询问是否强行运行。
  * **FIX-05 (跳过日志)**：所有被选择跳过的组件在终端的输出日志格式是否为 `⏭️ [component]: 用户跳过`。
  * **报告生成 (Skip 兼容)**：检查 Phase 7 生成的 HTML/Markdown 报告文件，被跳过的组件是否准确呈现在跳过报表区域，格式是否完好。

### 轮次 R6：二次运行免重复安装测试

* **目的**：验证所有工具已正确安装并处于最新版时，脚本的快速检测和零冗余安装。
* **执行步骤**：
  1. 保留 R5 的环境。
  2. 直接二次交互式执行脚本并同意全部默认检测：
     ```bash
     ./pmf-init.sh
     ```
* **回归校验矩阵**：
  * 各组件是否状态被检测为最新并快速通过。
  * 最终 Phase 7 生成的统计报告表格是否全部为 ✅ OK。

---

## 日志回收与分析报告

回归测试结束后，拉回测试机日志：
```bash
# 本地执行
mkdir -p docs/testing/2026-06-14-real-machine/
scp test2:~/pmf-test/logs/r*_clean.txt docs/testing/2026-06-14-real-machine/
scp test2:~/pmf-test/pmf-init-report-*.md docs/testing/2026-06-14-real-machine/ 2>/dev/null || true
```

生成最终的结构化回归分析报告：`docs/testing/2026-06-14-real-machine/regression-report.md`，对 FIX-01 到 FIX-05 的闭环进行明确的 PASS/FAIL 判决。
