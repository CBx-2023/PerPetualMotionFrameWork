#!/usr/bin/env bash
# pmf-init.sh — PerPetual Motion FrameWork 交互式环境配置脚本
# 用法: ./pmf-init.sh [--yes] [--force-permissions] [--help]
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
#  全局变量
# ═══════════════════════════════════════════════════════════════

YES_MODE=false
FORCE_PERMISSIONS=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
PKG_MGR=""
OS_TYPE=""

# 状态收集数组（Phase 7 用）
declare -A COMPONENT_STATUS=()
declare -A COMPONENT_VERSION=()

# 工具安装状态跟踪（跨阶段依赖）
declare -A TOOL_STATE=()

# apt-get update 状态缓存（每次脚本执行只跑一次）
APT_UPDATED=false

# 备份记录
declare -a BACKUP_RECORDS=()

# ═══════════════════════════════════════════════════════════════
#  CLI 参数解析
# ═══════════════════════════════════════════════════════════════

show_usage() {
    cat <<'EOF'
Usage: ./pmf-init.sh [OPTIONS]

PerPetual Motion FrameWork — 交互式环境配置脚本

Options:
  --yes                全自动模式（跳过所有确认，权限层仍需确认）
  --force-permissions  与 --yes 一起使用，权限层也自动修改
  --help               显示此帮助信息

Examples:
  ./pmf-init.sh                           # 交互模式
  ./pmf-init.sh --yes                     # 全自动（权限层仍需确认）
  ./pmf-init.sh --yes --force-permissions # 全自动（包括权限层）
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                YES_MODE=true
                shift
                ;;
            --force-permissions)
                FORCE_PERMISSIONS=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log ERROR "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  核心工具函数 (SPEC-01)
# ═══════════════════════════════════════════════════════════════

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local color=""
    local prefix=""
    case "$level" in
        INFO)  color="$GREEN";  prefix="✅" ;;
        WARN)  color="$YELLOW"; prefix="⚠️" ;;
        ERROR) color="$RED";    prefix="❌" ;;
        DEBUG) color="$CYAN";   prefix="🔍" ;;
        *)     color="$NC";     prefix="  " ;;
    esac
    echo -e "${color}${prefix} ${message}${NC}"
}

prompt_user() {
    local message="$1"
    local default="${2:-Y}"

    if [[ "$YES_MODE" == true ]]; then
        echo "yes"
        return
    fi

    local hint=""
    case "$default" in
        Y) hint="[Y/n/s]" ;;
        N) hint="[y/N/s]" ;;
        *) hint="[Y/n/s]" ;;
    esac

    echo -e "${BOLD}${message} ${hint}${NC}" >&2
    echo -e "  Y = yes    n = skip this item    s = skip entire phase" >&2
    local answer
    read -r answer
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) echo "yes" ;;
        s|skip) echo "skip_phase" ;;
        *) echo "no" ;;
    esac
}

backup_file() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local backup="${path}.bak.${TIMESTAMP}"
        if [[ ! -f "$backup" ]]; then
            cp "$path" "$backup"
            log INFO "备份: $path → $backup"
            BACKUP_RECORDS+=("$path → $backup")
        else
            log WARN "备份已存在: $backup"
        fi
    fi
}

refresh_path() {
    # 1. 清除命令 hash 缓存
    hash -r 2>/dev/null

    # 2. 将常见安装路径加入当前会话 PATH（如果不在的话）
    local paths_to_add=(
        "$HOME/.local/bin"
        "$HOME/.cargo/bin"
    )

    # npm global bin（安全获取）
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$npm_prefix" ]]; then
        paths_to_add+=("$npm_prefix/bin")
    fi

    # pip --user bin（安全获取）
    local pip_user_base
    pip_user_base="$(python3 -m site --user-base 2>/dev/null || true)"
    if [[ -n "$pip_user_base" ]]; then
        paths_to_add+=("$pip_user_base/bin")
    fi

    for p in "${paths_to_add[@]}"; do
        if [[ -d "$p" ]] && [[ ":$PATH:" != *":$p:"* ]]; then
            export PATH="$p:$PATH"
        fi
    done

    # 3. 重新提取 rc 文件中的 PATH 定义（最小副作用）
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]]; then
            eval "$(grep -E '^export PATH=|^PATH=' "$rc" 2>/dev/null || true)"
        fi
    done
}

phase_banner() {
    local phase_num="$1"
    local phase_name="$2"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Phase ${phase_num}/7: ${phase_name}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
#  检测与安装函数 (SPEC-02)
# ═══════════════════════════════════════════════════════════════

detect_os() {
    case "$(uname -s)" in
        Linux*)  OS_TYPE="linux" ;;
        Darwin*) OS_TYPE="macos" ;;
        *)       OS_TYPE="unknown" ;;
    esac

    # Linux 包管理器检测
    if [[ "$OS_TYPE" == "linux" ]]; then
        if command -v apt-get &>/dev/null; then PKG_MGR="apt"
        elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
        elif command -v pacman &>/dev/null; then PKG_MGR="pacman"
        fi
    fi
}

retry_command() {
    local cmd="$1"
    local max_retries="${2:-3}"
    local delays=(5 10)
    local attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        if eval "$cmd"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_retries ]]; then
            local delay_idx=$((attempt - 1))
            if [[ $delay_idx -ge ${#delays[@]} ]]; then
                delay_idx=$(( ${#delays[@]} - 1 ))
            fi
            local wait_time="${delays[$delay_idx]}"
            log WARN "失败 (尝试 $attempt/$max_retries)，${wait_time}秒后重试..."
            sleep "$wait_time"
        fi
    done
    log ERROR "命令在 ${max_retries} 次尝试后失败: $cmd"
    return 1
}

detect_tool() {
    local name="$1"
    local detect_cmd="$2"
    local min_version="${3:-}"

    local version_output
    if ! version_output=$(eval "$detect_cmd" 2>&1); then
        echo "NOT_FOUND"
        return
    fi

    # 提取版本号（支持多种格式）
    local version
    version=$(echo "$version_output" | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true)
    if [[ -z "$version" ]]; then
        version=$(echo "$version_output" | grep -oP 'v?\K\d+[\.\d]*' | head -1 || true)
    fi

    if [[ -z "$version" ]]; then
        echo "FOUND_LATEST|unknown"
        return
    fi

    # 版本比较（如果有最低版本要求）
    if [[ -n "$min_version" ]]; then
        if version_lt "$version" "$min_version"; then
            echo "FOUND_UPDATABLE|$version"
            return
        fi
    fi

    echo "FOUND_LATEST|$version"
}

version_lt() {
    # 返回 0 如果 $1 < $2
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then
        return 1
    fi
    local IFS='.'
    local i v1_parts=($v1) v2_parts=($v2)
    for ((i=0; i<${#v2_parts[@]}; i++)); do
        local a="${v1_parts[$i]:-0}"
        local b="${v2_parts[$i]:-0}"
        if ((10#$a < 10#$b)); then
            return 0
        elif ((10#$a > 10#$b)); then
            return 1
        fi
    done
    return 1
}

detect_skill() {
    local name="$1"
    shift
    local paths=("$@")
    local results=()
    for path in "${paths[@]}"; do
        if [[ -d "$path/$name" ]] && [[ -f "$path/$name/SKILL.md" ]]; then
            results+=("FOUND")
        elif [[ -d "$path/$name" ]]; then
            results+=("UPDATABLE")
        else
            results+=("NOT_FOUND")
        fi
    done
    local IFS=','
    echo "${results[*]}"
}

# 确保 apt 包索引已更新（每次脚本执行只跑一次）
ensure_apt_updated() {
    if [[ "$APT_UPDATED" == true ]]; then
        return 0
    fi
    if [[ "$PKG_MGR" == "apt" ]]; then
        log INFO "更新 apt 包索引..."
        if sudo -E apt-get update -y; then
            APT_UPDATED=true
        else
            log WARN "apt-get update 失败，继续尝试安装..."
        fi
    fi
}

install_tool() {
    local name="$1"
    local method="$2"

    log INFO "安装 $name..."

    # 若安装命令使用 apt-get install，先确保包索引已更新
    if [[ "$method" == *"apt-get install"* ]]; then
        ensure_apt_updated
    fi

    if retry_command "$method" 3; then
        refresh_path
        log INFO "$name 安装成功"
        TOOL_STATE["$name"]="INSTALLED"
        return 0
    else
        log ERROR "$name 安装失败"
        TOOL_STATE["$name"]="FAILED"
        # agy 安装失败时提供手动安装指引
        if [[ "$name" == "agy" ]]; then
            log WARN "手动安装 agy: curl -fsSL https://antigravity.google/cli/install.sh | bash"
            log WARN "详情: https://antigravity.google"
        fi
        return 1
    fi
}

# 判断 npm 全局安装是否需要 sudo
# 返回 "sudo" 或 ""，供 get_install_cmd 拼接命令
npm_global_cmd_prefix() {
    # Root 用户不需要 sudo
    if [[ $EUID -eq 0 ]]; then
        echo ""
        return
    fi

    # 获取 npm 全局安装路径
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || echo "/usr/local")"

    # nvm 管理的 node：prefix 在 $HOME 下，不需要 sudo
    if [[ "$npm_prefix" == "$HOME"* ]]; then
        echo ""
        return
    fi

    # 检查用户是否有写权限
    if [[ -w "${npm_prefix}/lib/node_modules" ]] 2>/dev/null; then
        echo ""
        return
    fi

    # 需要 sudo —— 检查是否可用
    if command -v sudo &>/dev/null; then
        echo "sudo"
        return
    fi

    # sudo 不可用
    log WARN "npm 全局安装需要 root 权限但 sudo 不可用。"
    log WARN "  建议方案 1: 使用 nvm 管理 Node.js — https://github.com/nvm-sh/nvm"
    log WARN "  建议方案 2: 以 root 用户运行此脚本"
    echo ""
}

get_install_cmd() {
    local name="$1"
    case "$name" in
        git)
            case "$OS_TYPE" in
                linux)
                    case "$PKG_MGR" in
                        apt) echo "sudo -E apt-get install -y git" ;;
                        dnf) echo "sudo dnf install -y git" ;;
                        pacman) echo "sudo pacman -S --noconfirm git" ;;
                    esac
                    ;;
                macos) echo "brew install git" ;;
            esac
            ;;
        python3)
            case "$OS_TYPE" in
                linux)
                    case "$PKG_MGR" in
                        apt) echo "sudo -E apt-get install -y python3 python3-pip" ;;
                        dnf) echo "sudo dnf install -y python3 python3-pip" ;;
                        pacman) echo "sudo pacman -S --noconfirm python python-pip" ;;
                    esac
                    ;;
                macos) echo "brew install python@3.12" ;;
            esac
            ;;
        node)
            case "$OS_TYPE" in
                linux)
                    case "$PKG_MGR" in
                        apt) echo "sudo -E apt-get install -y nodejs npm" ;;
                        dnf) echo "sudo dnf install -y nodejs npm" ;;
                        pacman) echo "sudo pacman -S --noconfirm nodejs npm" ;;
                    esac
                    ;;
                macos) echo "brew install node" ;;
            esac
            ;;
        uv)
            case "$OS_TYPE" in
                linux) echo "curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
                macos) echo "brew install uv" ;;
            esac
            ;;
        codex)
            local _prefix
            _prefix=$(npm_global_cmd_prefix)
            echo "${_prefix:+$_prefix }npm install -g @openai/codex"
            ;;
        claude)
            local _prefix
            _prefix=$(npm_global_cmd_prefix)
            echo "${_prefix:+$_prefix }npm install -g @anthropic-ai/claude-code"
            ;;
        agy)
            # agy (Antigravity CLI) 是原生 Go 二进制，不是 npm 包
            case "$OS_TYPE" in
                linux|macos) echo "curl -fsSL https://antigravity.google/cli/install.sh | bash" ;;
                *) log WARN "agy 安装仅支持 Linux/macOS。请访问 https://antigravity.google 手动安装。" ;;
            esac
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  Phase 1: 基础环境 (SPEC-03)
# ═══════════════════════════════════════════════════════════════

phase1_base_environment() {
    phase_banner 1 "基础环境"
    refresh_path

    local npm_available=true

    # ── Tier 1: git ──
    log INFO "检测 git..."
    local git_result
    git_result=$(detect_tool "git" "git --version")
    local git_status="${git_result%%|*}"
    local git_version="${git_result#*|}"

    case "$git_status" in
        FOUND_LATEST)
            log INFO "git $git_version ✅"
            COMPONENT_STATUS["git"]="OK"
            COMPONENT_VERSION["git"]="$git_version"
            ;;
        FOUND_UPDATABLE)
            log WARN "git $git_version 可更新"
            COMPONENT_STATUS["git"]="UPDATE"
            COMPONENT_VERSION["git"]="$git_version"
            ;;
        NOT_FOUND)
            log WARN "git 未找到"
            local answer
            answer=$(prompt_user "安装 git?")
            if [[ "$answer" == "yes" ]]; then
                local cmd
                cmd=$(get_install_cmd "git")
                if [[ -n "$cmd" ]] && install_tool "git" "$cmd"; then
                    git_result=$(detect_tool "git" "git --version")
                    git_version="${git_result#*|}"
                    COMPONENT_STATUS["git"]="OK"
                    COMPONENT_VERSION["git"]="$git_version"
                else
                    COMPONENT_STATUS["git"]="FAIL"
                    COMPONENT_VERSION["git"]=""
                fi
            elif [[ "$answer" == "skip_phase" ]]; then
                COMPONENT_STATUS["git"]="SKIPPED"
                COMPONENT_VERSION["git"]=""
                return
            else
                COMPONENT_STATUS["git"]="SKIPPED"
                COMPONENT_VERSION["git"]=""
            fi
            ;;
    esac

    # ── Tier 2: python3 + pip ──
    log INFO "检测 python3..."
    local py_result
    py_result=$(detect_tool "python3" "python3 --version" "3.10")
    local py_status="${py_result%%|*}"
    local py_version="${py_result#*|}"

    # 如果 python3 不存在，尝试 python
    if [[ "$py_status" == "NOT_FOUND" ]]; then
        py_result=$(detect_tool "python3" "python --version" "3.10")
        py_status="${py_result%%|*}"
        py_version="${py_result#*|}"
    fi

    case "$py_status" in
        FOUND_LATEST)
            log INFO "python3 $py_version ✅"
            COMPONENT_STATUS["python3"]="OK"
            COMPONENT_VERSION["python3"]="$py_version"
            ;;
        FOUND_UPDATABLE)
            log WARN "python3 $py_version (需要 ≥3.10)"
            COMPONENT_STATUS["python3"]="UPDATE"
            COMPONENT_VERSION["python3"]="$py_version"
            if [[ "$YES_MODE" == true ]]; then
                local cmd
                cmd=$(get_install_cmd "python3")
                if [[ -n "$cmd" ]]; then
                    install_tool "python3" "$cmd" || true
                    py_result=$(detect_tool "python3" "python3 --version" "3.10")
                    py_version="${py_result#*|}"
                    COMPONENT_STATUS["python3"]="OK"
                    COMPONENT_VERSION["python3"]="$py_version"
                fi
            fi
            ;;
        NOT_FOUND)
            log WARN "python3 未找到"
            local answer
            answer=$(prompt_user "安装 python3?")
            if [[ "$answer" == "yes" ]]; then
                local cmd
                cmd=$(get_install_cmd "python3")
                if [[ -n "$cmd" ]] && install_tool "python3" "$cmd"; then
                    py_result=$(detect_tool "python3" "python3 --version" "3.10")
                    py_version="${py_result#*|}"
                    COMPONENT_STATUS["python3"]="OK"
                    COMPONENT_VERSION["python3"]="$py_version"
                else
                    COMPONENT_STATUS["python3"]="FAIL"
                    COMPONENT_VERSION["python3"]=""
                fi
            elif [[ "$answer" == "skip_phase" ]]; then
                COMPONENT_STATUS["python3"]="SKIPPED"
                COMPONENT_VERSION["python3"]=""
                COMPONENT_STATUS["pip"]="SKIPPED"
                COMPONENT_VERSION["pip"]=""
                return
            else
                COMPONENT_STATUS["python3"]="SKIPPED"
                COMPONENT_VERSION["python3"]=""
            fi
            ;;
    esac

    # pip
    log INFO "检测 pip..."
    local pip_result
    pip_result=$(detect_tool "pip" "pip3 --version")
    local pip_status="${pip_result%%|*}"
    local pip_version="${pip_result#*|}"
    if [[ "$pip_status" == "NOT_FOUND" ]]; then
        pip_result=$(detect_tool "pip" "pip --version")
        pip_status="${pip_result%%|*}"
        pip_version="${pip_result#*|}"
    fi

    case "$pip_status" in
        FOUND_LATEST|FOUND_UPDATABLE)
            log INFO "pip $pip_version ✅"
            COMPONENT_STATUS["pip"]="OK"
            COMPONENT_VERSION["pip"]="$pip_version"
            ;;
        NOT_FOUND)
            log WARN "pip 未找到 (随 python3 安装)"
            COMPONENT_STATUS["pip"]="FAIL"
            COMPONENT_VERSION["pip"]=""
            ;;
    esac

    # ── Tier 2: node + npm ──
    log INFO "检测 node..."
    local node_result
    node_result=$(detect_tool "node" "node --version" "20")
    local node_status="${node_result%%|*}"
    local node_version="${node_result#*|}"

    case "$node_status" in
        FOUND_LATEST)
            log INFO "node $node_version ✅"
            COMPONENT_STATUS["node"]="OK"
            COMPONENT_VERSION["node"]="$node_version"
            ;;
        FOUND_UPDATABLE)
            log WARN "node $node_version (需要 ≥20)"
            COMPONENT_STATUS["node"]="UPDATE"
            COMPONENT_VERSION["node"]="$node_version"
            if [[ "$YES_MODE" == true ]]; then
                local cmd
                cmd=$(get_install_cmd "node")
                if [[ -n "$cmd" ]]; then
                    install_tool "node" "$cmd" || true
                    node_result=$(detect_tool "node" "node --version" "20")
                    node_status="${node_result%%|*}"
                    node_version="${node_result#*|}"
                    if [[ "$node_status" == "FOUND_LATEST" ]]; then
                        COMPONENT_STATUS["node"]="OK"
                    fi
                    COMPONENT_VERSION["node"]="$node_version"
                fi
            fi
            ;;
        NOT_FOUND)
            log WARN "node 未找到"
            local answer
            answer=$(prompt_user "安装 node + npm?")
            if [[ "$answer" == "yes" ]]; then
                local cmd
                cmd=$(get_install_cmd "node")
                if [[ -n "$cmd" ]] && install_tool "node" "$cmd"; then
                    node_result=$(detect_tool "node" "node --version" "20")
                    node_version="${node_result#*|}"
                    COMPONENT_STATUS["node"]="OK"
                    COMPONENT_VERSION["node"]="$node_version"
                else
                    COMPONENT_STATUS["node"]="FAIL"
                    COMPONENT_VERSION["node"]=""
                    npm_available=false
                fi
            elif [[ "$answer" == "skip_phase" ]]; then
                COMPONENT_STATUS["node"]="SKIPPED"
                COMPONENT_VERSION["node"]=""
                COMPONENT_STATUS["npm"]="SKIPPED"
                COMPONENT_VERSION["npm"]=""
                npm_available=false
                # Tier 4 blocked
                for t in codex claude agy; do
                    COMPONENT_STATUS["$t"]="BLOCKED"
                    COMPONENT_VERSION["$t"]=""
                done
                return
            else
                COMPONENT_STATUS["node"]="SKIPPED"
                COMPONENT_VERSION["node"]=""
                npm_available=false
            fi
            ;;
    esac

    # npm
    log INFO "检测 npm..."
    local npm_result
    npm_result=$(detect_tool "npm" "npm --version")
    local npm_status="${npm_result%%|*}"
    local npm_version="${npm_result#*|}"

    case "$npm_status" in
        FOUND_LATEST|FOUND_UPDATABLE)
            log INFO "npm $npm_version ✅"
            COMPONENT_STATUS["npm"]="OK"
            COMPONENT_VERSION["npm"]="$npm_version"
            ;;
        NOT_FOUND)
            log WARN "npm 未找到"
            COMPONENT_STATUS["npm"]="FAIL"
            COMPONENT_VERSION["npm"]=""
            npm_available=false
            ;;
    esac

    # ── Tier 3: uv (depends on pip) ──
    log INFO "检测 uv..."
    local uv_result
    uv_result=$(detect_tool "uv" "uv --version")
    local uv_status="${uv_result%%|*}"
    local uv_version="${uv_result#*|}"

    case "$uv_status" in
        FOUND_LATEST)
            log INFO "uv $uv_version ✅"
            COMPONENT_STATUS["uv"]="OK"
            COMPONENT_VERSION["uv"]="$uv_version"
            TOOL_STATE["uv"]="AVAILABLE"
            ;;
        FOUND_UPDATABLE)
            log WARN "uv $uv_version 可更新"
            COMPONENT_STATUS["uv"]="UPDATE"
            COMPONENT_VERSION["uv"]="$uv_version"
            TOOL_STATE["uv"]="AVAILABLE"
            ;;
        NOT_FOUND)
            log WARN "uv 未找到"
            local answer
            answer=$(prompt_user "安装 uv?")
            if [[ "$answer" == "yes" ]]; then
                local cmd
                cmd=$(get_install_cmd "uv")
                if [[ -n "$cmd" ]] && install_tool "uv" "$cmd"; then
                    uv_result=$(detect_tool "uv" "uv --version")
                    uv_version="${uv_result#*|}"
                    COMPONENT_STATUS["uv"]="OK"
                    COMPONENT_VERSION["uv"]="$uv_version"
                    TOOL_STATE["uv"]="AVAILABLE"
                else
                    COMPONENT_STATUS["uv"]="FAIL"
                    COMPONENT_VERSION["uv"]=""
                    TOOL_STATE["uv"]="MISSING"
                fi
            elif [[ "$answer" == "skip_phase" ]]; then
                COMPONENT_STATUS["uv"]="SKIPPED"
                COMPONENT_VERSION["uv"]=""
                TOOL_STATE["uv"]="MISSING"
                # codex/claude/agy still proceed if npm available
                return
            else
                COMPONENT_STATUS["uv"]="SKIPPED"
                COMPONENT_VERSION["uv"]=""
                TOOL_STATE["uv"]="MISSING"
            fi
            ;;
    esac

    # ── Tier 4: codex, claude, agy (depend on npm) ──
    if [[ "$npm_available" == false ]]; then
        log WARN "npm 不可用，Tier 4 工具标记为 BLOCKED(需要 npm)"
        for t in codex claude agy; do
            COMPONENT_STATUS["$t"]="BLOCKED"
            COMPONENT_VERSION["$t"]=""
            TOOL_STATE["$t"]="MISSING"
        done
        return
    fi

    local tier4_tools=("codex" "claude" "agy")
    local tier4_cmds=("codex --version" "claude --version" "agy --version")
    local tier4_check_cmds=("npm outdated -g @openai/codex" "npm outdated -g @anthropic-ai/claude-code" "agy --version")

    for i in "${!tier4_tools[@]}"; do
        local t="${tier4_tools[$i]}"
        local detect_cmd="${tier4_cmds[$i]}"

        log INFO "检测 $t..."
        local t_result
        t_result=$(detect_tool "$t" "$detect_cmd")
        local t_status="${t_result%%|*}"
        local t_version="${t_result#*|}"

        case "$t_status" in
            FOUND_LATEST)
                log INFO "$t $t_version ✅"
                COMPONENT_STATUS["$t"]="OK"
                COMPONENT_VERSION["$t"]="$t_version"
                TOOL_STATE["$t"]="AVAILABLE"
                ;;
            FOUND_UPDATABLE)
                log WARN "$t $t_version 可更新"
                COMPONENT_STATUS["$t"]="UPDATE"
                COMPONENT_VERSION["$t"]="$t_version"
                TOOL_STATE["$t"]="AVAILABLE"
                if [[ "$YES_MODE" == true ]]; then
                    local cmd
                    cmd=$(get_install_cmd "$t")
                    if [[ -n "$cmd" ]]; then
                        install_tool "$t" "$cmd" || true
                    fi
                fi
                ;;
            NOT_FOUND)
                log WARN "$t 未找到"
                local answer
                answer=$(prompt_user "安装 $t?")
                if [[ "$answer" == "yes" ]]; then
                    local cmd
                    cmd=$(get_install_cmd "$t")
                    if [[ -n "$cmd" ]] && install_tool "$t" "$cmd"; then
                        t_result=$(detect_tool "$t" "$detect_cmd")
                        t_version="${t_result#*|}"
                        COMPONENT_STATUS["$t"]="OK"
                        COMPONENT_VERSION["$t"]="$t_version"
                        TOOL_STATE["$t"]="AVAILABLE"
                    else
                        COMPONENT_STATUS["$t"]="FAIL"
                        COMPONENT_VERSION["$t"]=""
                        TOOL_STATE["$t"]="MISSING"
                    fi
                elif [[ "$answer" == "skip_phase" ]]; then
                    COMPONENT_STATUS["$t"]="SKIPPED"
                    COMPONENT_VERSION["$t"]=""
                    TOOL_STATE["$t"]="MISSING"
                    # Skip remaining tier 4
                    for j in $(seq $((i+1)) $((${#tier4_tools[@]}-1))); do
                        COMPONENT_STATUS["${tier4_tools[$j]}"]="SKIPPED"
                        COMPONENT_VERSION["${tier4_tools[$j]}"]=""
                        TOOL_STATE["${tier4_tools[$j]}"]="MISSING"
                    done
                    return
                else
                    COMPONENT_STATUS["$t"]="SKIPPED"
                    COMPONENT_VERSION["$t"]=""
                    TOOL_STATE["$t"]="MISSING"
                fi
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  Phase 2: 记忆层 — Graphify (SPEC-04)
# ═══════════════════════════════════════════════════════════════

phase2_graphify() {
    phase_banner 2 "记忆层 — Graphify"
    refresh_path

    # 检查 uv 依赖
    if [[ "${TOOL_STATE[uv]:-MISSING}" != "AVAILABLE" ]]; then
        log WARN "graphify 标记为 BLOCKED(需要 uv)"
        COMPONENT_STATUS["graphify"]="BLOCKED"
        COMPONENT_VERSION["graphify"]=""
        for sub in "graphify→codex" "graphify→agy" "graphify→claude" "graphify-out/"; do
            COMPONENT_STATUS["$sub"]="BLOCKED"
            COMPONENT_VERSION["$sub"]=""
        done
        return
    fi

    # 检测 graphify CLI
    log INFO "检测 graphify..."
    local gf_result
    gf_result=$(detect_tool "graphify" "graphify --version")
    local gf_status="${gf_result%%|*}"
    local gf_version="${gf_result#*|}"

    case "$gf_status" in
        FOUND_LATEST)
            log INFO "graphify $gf_version ✅"
            COMPONENT_STATUS["graphify"]="OK"
            COMPONENT_VERSION["graphify"]="$gf_version"
            ;;
        FOUND_UPDATABLE)
            log WARN "graphify $gf_version 可更新"
            COMPONENT_STATUS["graphify"]="UPDATE"
            COMPONENT_VERSION["graphify"]="$gf_version"
            if [[ "$YES_MODE" == true ]]; then
                retry_command "uv tool upgrade graphifyy" 3 || true
                gf_result=$(detect_tool "graphify" "graphify --version")
                gf_version="${gf_result#*|}"
                COMPONENT_STATUS["graphify"]="OK"
                COMPONENT_VERSION["graphify"]="$gf_version"
            fi
            ;;
        NOT_FOUND)
            log WARN "graphify 未找到"
            local answer
            answer=$(prompt_user "安装 graphifyy via uv?")
            if [[ "$answer" == "yes" ]]; then
                if install_tool "graphify" "uv tool install 'graphifyy[office,chinese]'"; then
                    gf_result=$(detect_tool "graphify" "graphify --version")
                    gf_version="${gf_result#*|}"
                    COMPONENT_STATUS["graphify"]="OK"
                    COMPONENT_VERSION["graphify"]="$gf_version"
                else
                    COMPONENT_STATUS["graphify"]="FAIL"
                    COMPONENT_VERSION["graphify"]=""
                fi
            elif [[ "$answer" == "skip_phase" ]]; then
                COMPONENT_STATUS["graphify"]="SKIPPED"
                COMPONENT_VERSION["graphify"]=""
                for sub in "graphify→codex" "graphify→agy" "graphify→claude" "graphify-out/"; do
                    COMPONENT_STATUS["$sub"]="SKIPPED"
                    COMPONENT_VERSION["$sub"]=""
                done
                return
            else
                COMPONENT_STATUS["graphify"]="SKIPPED"
                COMPONENT_VERSION["graphify"]=""
                for sub in "graphify→codex" "graphify→agy" "graphify→claude" "graphify-out/"; do
                    COMPONENT_STATUS["$sub"]="SKIPPED"
                    COMPONENT_VERSION["$sub"]=""
                done
                return
            fi
            ;;
    esac

    # 如果 graphify 不可用，跳过注册
    if [[ "${COMPONENT_STATUS[graphify]}" != "OK" && "${COMPONENT_STATUS[graphify]}" != "UPDATE" ]]; then
        for sub in "graphify→codex" "graphify→agy" "graphify→claude" "graphify-out/"; do
            COMPONENT_STATUS["$sub"]="BLOCKED"
            COMPONENT_VERSION["$sub"]=""
        done
        return
    fi

    # 注册到各平台
    # codex
    if [[ "${TOOL_STATE[codex]:-MISSING}" == "AVAILABLE" ]]; then
        log INFO "注册 graphify → codex..."
        if retry_command "graphify install --platform codex" 3; then
            COMPONENT_STATUS["graphify→codex"]="OK"
            COMPONENT_VERSION["graphify→codex"]="skill"
        else
            COMPONENT_STATUS["graphify→codex"]="FAIL"
            COMPONENT_VERSION["graphify→codex"]=""
        fi
    else
        log WARN "codex 不可用，跳过 graphify→codex 注册"
        COMPONENT_STATUS["graphify→codex"]="SKIPPED"
        COMPONENT_VERSION["graphify→codex"]=""
    fi

    # agy → antigravity
    if [[ "${TOOL_STATE[agy]:-MISSING}" == "AVAILABLE" ]]; then
        log INFO "注册 graphify → agy (antigravity)..."
        if retry_command "graphify install --platform antigravity" 3; then
            COMPONENT_STATUS["graphify→agy"]="OK"
            COMPONENT_VERSION["graphify→agy"]="skill"
        else
            COMPONENT_STATUS["graphify→agy"]="FAIL"
            COMPONENT_VERSION["graphify→agy"]=""
        fi
    else
        log WARN "agy 不可用，跳过 graphify→agy 注册"
        COMPONENT_STATUS["graphify→agy"]="SKIPPED"
        COMPONENT_VERSION["graphify→agy"]=""
    fi

    # claude
    if [[ "${TOOL_STATE[claude]:-MISSING}" == "AVAILABLE" ]]; then
        log INFO "注册 graphify → claude..."
        if retry_command "graphify install --platform claude" 3; then
            COMPONENT_STATUS["graphify→claude"]="OK"
            COMPONENT_VERSION["graphify→claude"]="skill"
        else
            COMPONENT_STATUS["graphify→claude"]="FAIL"
            COMPONENT_VERSION["graphify→claude"]=""
        fi
    else
        log WARN "claude 不可用，跳过 graphify→claude 注册"
        COMPONENT_STATUS["graphify→claude"]="SKIPPED"
        COMPONENT_VERSION["graphify→claude"]=""
    fi

    # 项目级图谱
    if [[ -d "$SCRIPT_DIR/graphify-out" ]]; then
        if [[ "$YES_MODE" == true ]]; then
            log INFO "graphify-out/ 已存在，重新生成项目图谱..."
            (cd "$SCRIPT_DIR" && retry_command "graphify ." 3) || true
            COMPONENT_STATUS["graphify-out/"]="OK"
        else
            log INFO "graphify-out/ 已存在 (可更新)"
            COMPONENT_STATUS["graphify-out/"]="UPDATE"
        fi
        COMPONENT_VERSION["graphify-out/"]=""
    else
        local answer
        answer=$(prompt_user "生成项目图谱 (graphify .)?")
        if [[ "$answer" == "yes" ]]; then
            log INFO "生成项目图谱..."
            if (cd "$SCRIPT_DIR" && retry_command "graphify ." 3); then
                COMPONENT_STATUS["graphify-out/"]="OK"
                COMPONENT_VERSION["graphify-out/"]=""
            else
                COMPONENT_STATUS["graphify-out/"]="FAIL"
                COMPONENT_VERSION["graphify-out/"]=""
            fi
        else
            COMPONENT_STATUS["graphify-out/"]="SKIPPED"
            COMPONENT_VERSION["graphify-out/"]=""
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Phase 3: 方法层 — Superpowers (SPEC-05)
# ═══════════════════════════════════════════════════════════════

phase3_superpowers() {
    phase_banner 3 "方法层 — Superpowers"
    refresh_path

    local repo_url="https://github.com/obra/superpowers.git"
    local local_path="$HOME/agent-tools/superpowers"
    local needs_install=false

    # Clone or detect updates
    if [[ ! -d "$local_path" ]]; then
        log INFO "克隆 superpowers..."
        local answer
        answer=$(prompt_user "克隆 superpowers 仓库?")
        if [[ "$answer" == "yes" ]]; then
            mkdir -p "$HOME/agent-tools"
            if retry_command "git clone '$repo_url' '$local_path'" 3; then
                log INFO "superpowers 克隆成功"
                needs_install=true
            else
                log ERROR "superpowers 克隆失败"
                for sub in "superpowers→agy" "superpowers→codex" "superpowers→claude"; do
                    COMPONENT_STATUS["$sub"]="FAIL"
                    COMPONENT_VERSION["$sub"]=""
                done
                return
            fi
        elif [[ "$answer" == "skip_phase" ]]; then
            for sub in "superpowers→agy" "superpowers→codex" "superpowers→claude"; do
                COMPONENT_STATUS["$sub"]="SKIPPED"
                COMPONENT_VERSION["$sub"]=""
            done
            return
        else
            for sub in "superpowers→agy" "superpowers→codex" "superpowers→claude"; do
                COMPONENT_STATUS["$sub"]="SKIPPED"
                COMPONENT_VERSION["$sub"]=""
            done
            return
        fi
    else
        log INFO "superpowers 已存在，检查更新..."
        git -C "$local_path" fetch 2>/dev/null || true
        local updates
        updates=$(git -C "$local_path" log HEAD..origin/main --oneline 2>/dev/null || true)
        if [[ -n "$updates" ]]; then
            if [[ "$YES_MODE" == true ]]; then
                log INFO "拉取更新..."
                git -C "$local_path" pull || true
                needs_install=true
            else
                log WARN "远端有更新: $updates"
                log INFO "运行 'git -C $local_path pull' 手动更新"
            fi
        else
            log INFO "superpowers 已是最新"
        fi
        needs_install=true
    fi

    # AGY 安装
    if [[ "${TOOL_STATE[agy]:-MISSING}" == "AVAILABLE" ]]; then
        log INFO "安装 superpowers → agy..."
        if retry_command "agy plugin install '$local_path'" 3; then
            COMPONENT_STATUS["superpowers→agy"]="OK"
            COMPONENT_VERSION["superpowers→agy"]="plugin"
        else
            COMPONENT_STATUS["superpowers→agy"]="FAIL"
            COMPONENT_VERSION["superpowers→agy"]=""
        fi
    else
        log WARN "agy 不可用，跳过 superpowers→agy"
        COMPONENT_STATUS["superpowers→agy"]="SKIPPED"
        COMPONENT_VERSION["superpowers→agy"]=""
    fi

    # Codex 安装（文件放置）
    if [[ "${TOOL_STATE[codex]:-MISSING}" == "AVAILABLE" || -d "$HOME/.codex" ]]; then
        log INFO "安装 superpowers → codex..."
        local codex_skills="$HOME/.codex/skills"
        mkdir -p "$codex_skills"
        local count=0
        if [[ -d "$local_path/skills" ]]; then
            for skill_dir in "$local_path/skills"/*/; do
                local skill_name
                skill_name=$(basename "$skill_dir")
                if [[ -d "$codex_skills/$skill_name" ]]; then
                    log INFO "  SKIPPED: $skill_name (已存在)"
                else
                    cp -R "$skill_dir" "$codex_skills/"
                    count=$((count + 1))
                fi
            done
        fi
        COMPONENT_STATUS["superpowers→codex"]="OK"
        COMPONENT_VERSION["superpowers→codex"]="${count} skills"
    else
        log WARN "codex 不可用，跳过 superpowers→codex"
        COMPONENT_STATUS["superpowers→codex"]="SKIPPED"
        COMPONENT_VERSION["superpowers→codex"]=""
    fi

    # Claude 安装（文件放置）
    if [[ "${TOOL_STATE[claude]:-MISSING}" == "AVAILABLE" || -d "$HOME/.agents" ]]; then
        log INFO "安装 superpowers → claude..."
        local claude_skills="$HOME/.agents/skills"
        mkdir -p "$claude_skills"
        local count=0
        if [[ -d "$local_path/skills" ]]; then
            for skill_dir in "$local_path/skills"/*/; do
                local skill_name
                skill_name=$(basename "$skill_dir")
                if [[ -d "$claude_skills/$skill_name" ]]; then
                    log INFO "  SKIPPED: $skill_name (已存在)"
                else
                    cp -R "$skill_dir" "$claude_skills/"
                    count=$((count + 1))
                fi
            done
        fi
        COMPONENT_STATUS["superpowers→claude"]="OK"
        COMPONENT_VERSION["superpowers→claude"]="${count} skills"
    else
        log WARN "claude 不可用，跳过 superpowers→claude"
        COMPONENT_STATUS["superpowers→claude"]="SKIPPED"
        COMPONENT_VERSION["superpowers→claude"]=""
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Phase 4: 执行层 — Missions (SPEC-06)
# ═══════════════════════════════════════════════════════════════

phase4_missions() {
    phase_banner 4 "执行层 — Missions"
    refresh_path

    local repo_url="https://github.com/flowing-water1/Missions.git"
    local local_path="$HOME/agent-tools/Missions"
    local mission_dirs=("mission" "mission-doc-route" "mission-approved-doc" "mission-csv-execute" "mission-long-task" "mission-recovery")

    # Clone or detect updates
    if [[ ! -d "$local_path" ]]; then
        log INFO "克隆 Missions..."
        local answer
        answer=$(prompt_user "克隆 Missions 仓库?")
        if [[ "$answer" == "yes" ]]; then
            mkdir -p "$HOME/agent-tools"
            if retry_command "git clone '$repo_url' '$local_path'" 3; then
                log INFO "Missions 克隆成功"
            else
                log ERROR "Missions 克隆失败"
                for sub in "missions→agy" "missions→codex" "missions→claude"; do
                    COMPONENT_STATUS["$sub"]="FAIL"
                    COMPONENT_VERSION["$sub"]=""
                done
                return
            fi
        elif [[ "$answer" == "skip_phase" ]]; then
            for sub in "missions→agy" "missions→codex" "missions→claude"; do
                COMPONENT_STATUS["$sub"]="SKIPPED"
                COMPONENT_VERSION["$sub"]=""
            done
            return
        else
            for sub in "missions→agy" "missions→codex" "missions→claude"; do
                COMPONENT_STATUS["$sub"]="SKIPPED"
                COMPONENT_VERSION["$sub"]=""
            done
            return
        fi
    else
        log INFO "Missions 已存在，检查更新..."
        git -C "$local_path" fetch 2>/dev/null || true
        local updates
        updates=$(git -C "$local_path" log HEAD..origin/main --oneline 2>/dev/null || true)
        if [[ -n "$updates" ]]; then
            if [[ "$YES_MODE" == true ]]; then
                log INFO "拉取更新..."
                git -C "$local_path" pull || true
            else
                log WARN "远端有更新: $updates"
                log INFO "运行 'git -C $local_path pull' 手动更新"
            fi
        else
            log INFO "Missions 已是最新"
        fi
    fi

    # 安装到各平台
    local platforms_targets=(
        "agy|$HOME/.gemini/config/skills"
        "codex|$HOME/.codex/skills"
        "claude|$HOME/.agents/skills"
    )

    for pt in "${platforms_targets[@]}"; do
        local platform="${pt%%|*}"
        local target="${pt#*|}"
        local label="missions→$platform"

        log INFO "安装 missions → $platform..."
        mkdir -p "$target"
        local installed=0
        local skipped=0

        for mdir in "${mission_dirs[@]}"; do
            if [[ -d "$local_path/$mdir" ]]; then
                if [[ -d "$target/$mdir" ]]; then
                    log INFO "  SKIPPED: $mdir (已存在)"
                    skipped=$((skipped + 1))
                else
                    cp -R "$local_path/$mdir" "$target/"
                    installed=$((installed + 1))
                fi
            else
                log WARN "  未找到: $local_path/$mdir"
            fi
        done

        local total=$((installed + skipped))
        COMPONENT_STATUS["$label"]="OK"
        COMPONENT_VERSION["$label"]="${total} dirs"
        log INFO "  $label: ${installed} 新安装, ${skipped} 已存在"
    done
}

# ═══════════════════════════════════════════════════════════════
#  Phase 5: 权限层 — Codex config.toml (SPEC-07)
# ═══════════════════════════════════════════════════════════════

phase5_permissions() {
    phase_banner 5 "权限层 — Codex config.toml"
    refresh_path

    local config_path="$HOME/.codex/config.toml"
    mkdir -p "$(dirname "$config_path")"

    # 读取当前值
    local current_approval="" current_sandbox="" current_multi_agent=""
    if [[ -f "$config_path" ]]; then
        current_approval=$(grep -E '^approval_policy\s*=' "$config_path" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d ' ' || true)
        current_sandbox=$(grep -E '^sandbox_mode\s*=' "$config_path" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d ' ' || true)
        current_multi_agent=$(grep -E '^\s*multi_agent\s*=' "$config_path" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' ' || true)
    fi

    local target_approval="never"
    local target_sandbox="danger-full-access"
    local target_multi_agent="true"

    # 检查哪些需要改
    local changes_needed=false
    if [[ "$current_approval" != "$target_approval" ]]; then changes_needed=true; fi
    if [[ "$current_sandbox" != "$target_sandbox" ]]; then changes_needed=true; fi
    if [[ "$current_multi_agent" != "$target_multi_agent" ]]; then changes_needed=true; fi

    if [[ "$changes_needed" == false ]]; then
        log INFO "所有权限配置已是目标值"
        COMPONENT_STATUS["approval_policy"]="OK"
        COMPONENT_VERSION["approval_policy"]=""
        COMPONENT_STATUS["sandbox_mode"]="OK"
        COMPONENT_VERSION["sandbox_mode"]=""
        COMPONENT_STATUS["multi_agent"]="OK"
        COMPONENT_VERSION["multi_agent"]=""
        return
    fi

    # 安全警告
    echo ""
    echo -e "${RED}${BOLD}⚠ WARNING: 以下修改会降低 Codex 安全限制${NC}"
    echo ""
    if [[ "$current_approval" != "$target_approval" ]]; then
        echo -e "  Current approval_policy = \"${current_approval:-<unset>}\"  →  Target: \"$target_approval\""
    fi
    if [[ "$current_sandbox" != "$target_sandbox" ]]; then
        echo -e "  Current sandbox_mode    = \"${current_sandbox:-<unset>}\"  →  Target: \"$target_sandbox\""
    fi
    if [[ "$current_multi_agent" != "$target_multi_agent" ]]; then
        echo -e "  Current multi_agent     = ${current_multi_agent:-<unset>}  →  Target: $target_multi_agent"
    fi
    echo ""
    echo -e "  This means Codex will execute commands without approval"
    echo -e "  and have full access to your filesystem and network."
    echo ""
    echo -e "  ${YELLOW}Only use in git-managed workspaces without production secrets.${NC}"
    echo ""

    # 确认逻辑
    local apply=false
    if [[ "$YES_MODE" == true && "$FORCE_PERMISSIONS" == true ]]; then
        log INFO "强制权限模式，跳过确认"
        apply=true
    elif [[ "$YES_MODE" == true ]]; then
        # --yes 模式仍需一次安全确认，默认 N
        echo -e "${BOLD}Apply permission changes? [y/N]${NC}"
        local answer
        read -r answer
        answer="${answer:-N}"
        if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
            apply=true
        fi
    else
        echo -e "${BOLD}Apply permission changes? [y/N]${NC}"
        local answer
        read -r answer
        answer="${answer:-N}"
        if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
            apply=true
        fi
    fi

    if [[ "$apply" == true ]]; then
        # 备份
        backup_file "$config_path"

        # 创建或更新 config.toml
        if [[ ! -f "$config_path" ]]; then
            cat > "$config_path" <<TOML
approval_policy = "$target_approval"
sandbox_mode = "$target_sandbox"

[features]
multi_agent = $target_multi_agent
TOML
        else
            # 逐键更新（保留其他配置）
            local tmpfile
            tmpfile=$(mktemp)
            cp "$config_path" "$tmpfile"

            # approval_policy
            if grep -qE '^approval_policy\s*=' "$tmpfile"; then
                sed -i "s/^approval_policy\s*=.*/approval_policy = \"$target_approval\"/" "$tmpfile"
            else
                echo "approval_policy = \"$target_approval\"" >> "$tmpfile"
            fi

            # sandbox_mode
            if grep -qE '^sandbox_mode\s*=' "$tmpfile"; then
                sed -i "s/^sandbox_mode\s*=.*/sandbox_mode = \"$target_sandbox\"/" "$tmpfile"
            else
                echo "sandbox_mode = \"$target_sandbox\"" >> "$tmpfile"
            fi

            # multi_agent under [features]
            if grep -qE '^\s*multi_agent\s*=' "$tmpfile"; then
                sed -i "s/^\(\s*\)multi_agent\s*=.*/\1multi_agent = $target_multi_agent/" "$tmpfile"
            else
                if grep -qE '^\[features\]' "$tmpfile"; then
                    sed -i "/^\[features\]/a multi_agent = $target_multi_agent" "$tmpfile"
                else
                    echo -e "\n[features]\nmulti_agent = $target_multi_agent" >> "$tmpfile"
                fi
            fi

            mv "$tmpfile" "$config_path"
        fi

        log INFO "权限配置已更新"
        COMPONENT_STATUS["approval_policy"]="OK"
        COMPONENT_VERSION["approval_policy"]=""
        COMPONENT_STATUS["sandbox_mode"]="OK"
        COMPONENT_VERSION["sandbox_mode"]=""
        COMPONENT_STATUS["multi_agent"]="OK"
        COMPONENT_VERSION["multi_agent"]=""
    else
        log WARN "用户跳过权限配置"
        COMPONENT_STATUS["approval_policy"]="SKIPPED"
        COMPONENT_VERSION["approval_policy"]=""
        COMPONENT_STATUS["sandbox_mode"]="SKIPPED"
        COMPONENT_VERSION["sandbox_mode"]=""
        COMPONENT_STATUS["multi_agent"]="SKIPPED"
        COMPONENT_VERSION["multi_agent"]=""
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Phase 6: 项目结构 (SPEC-08)
# ═══════════════════════════════════════════════════════════════

phase6_project_structure() {
    phase_banner 6 "项目结构"

    # 创建目录
    local dirs=("docs/superpowers/specs" "issues" ".mission")
    for d in "${dirs[@]}"; do
        local full_path="$SCRIPT_DIR/$d"
        if [[ -d "$full_path" ]]; then
            log INFO "$d/ 已存在 ✅"
        else
            mkdir -p "$full_path"
            log INFO "$d/ 已创建"
        fi
        COMPONENT_STATUS["$d/"]="OK"
        COMPONENT_VERSION["$d/"]=""
    done

    # AGENTS.md
    local agents_path="$SCRIPT_DIR/AGENTS.md"
    if [[ -f "$agents_path" ]]; then
        if [[ "$YES_MODE" == true ]]; then
            log INFO "AGENTS.md 已存在，--yes 模式默认跳过"
            COMPONENT_STATUS["AGENTS.md"]="OK"
            COMPONENT_VERSION["AGENTS.md"]=""
        else
            echo ""
            echo -e "${BOLD}AGENTS.md 已存在，如何处理？${NC}"
            echo "  [1] 覆盖"
            echo "  [2] 追加"
            echo "  [3] 跳过"
            echo ""
            echo -e "${BOLD}选择 [1/2/3]:${NC}"
            local choice
            read -r choice
            case "$choice" in
                1)
                    backup_file "$agents_path"
                    generate_agents_md "$agents_path"
                    log INFO "AGENTS.md 已覆盖"
                    ;;
                2)
                    echo "" >> "$agents_path"
                    echo "---" >> "$agents_path"
                    echo "" >> "$agents_path"
                    generate_agents_md_content >> "$agents_path"
                    log INFO "AGENTS.md 已追加"
                    ;;
                3|*)
                    log INFO "AGENTS.md 跳过"
                    ;;
            esac
            COMPONENT_STATUS["AGENTS.md"]="OK"
            COMPONENT_VERSION["AGENTS.md"]=""
        fi
    else
        generate_agents_md "$agents_path"
        log INFO "AGENTS.md 已生成"
        COMPONENT_STATUS["AGENTS.md"]="OK"
        COMPONENT_VERSION["AGENTS.md"]=""
    fi
}

generate_agents_md_content() {
    cat <<'AGENTS'
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
AGENTS
}

generate_agents_md() {
    local path="$1"
    generate_agents_md_content > "$path"
}

# ═══════════════════════════════════════════════════════════════
#  Phase 7: 验收 (SPEC-09)
# ═══════════════════════════════════════════════════════════════

phase7_validation() {
    phase_banner 7 "验收"

    # 构建表格数据
    local layers=(
        "基础环境|git|node|npm|python3|pip|uv|codex|claude|agy"
        "记忆层|graphify|graphify→codex|graphify→agy|graphify→claude|graphify-out/"
        "方法层|superpowers→agy|superpowers→codex|superpowers→claude"
        "执行层|missions→agy|missions→codex|missions→claude"
        "权限层|approval_policy|sandbox_mode|multi_agent"
        "项目结构|docs/superpowers/specs/|issues/|.mission/|AGENTS.md"
    )

    # 统计
    local ok_count=0 update_count=0 fail_count=0 blocked_count=0 skipped_count=0

    # 状态符号映射
    status_symbol() {
        case "$1" in
            OK)      echo "✅ OK" ;;
            UPDATE)  echo "⚠️ UPDATE" ;;
            FAIL)    echo "❌ FAIL" ;;
            BLOCKED) echo "🚫 BLOCKED" ;;
            SKIPPED) echo "⏭️ SKIPPED" ;;
            *)       echo "? $1" ;;
        esac
    }

    # 渲染表格
    echo "  ┌─────────────┬──────────────────────┬──────────────┬───────────┐"
    echo "  │ Layer       │ Component            │ Status       │ Version   │"
    echo "  ├─────────────┼──────────────────────┼──────────────┼───────────┤"

    local first_layer=true
    for layer_data in "${layers[@]}"; do
        local IFS='|'
        local parts=($layer_data)
        local layer_name="${parts[0]}"

        if [[ "$first_layer" == false ]]; then
            echo "  ├─────────────┼──────────────────────┼──────────────┼───────────┤"
        fi
        first_layer=false

        local first_in_layer=true
        for ((i=1; i<${#parts[@]}; i++)); do
            local comp="${parts[$i]}"
            local status="${COMPONENT_STATUS[$comp]:-SKIPPED}"
            local version="${COMPONENT_VERSION[$comp]:-}"
            local sym
            sym=$(status_symbol "$status")

            # 计数
            case "$status" in
                OK)      ok_count=$((ok_count + 1)) ;;
                UPDATE)  update_count=$((update_count + 1)) ;;
                FAIL)    fail_count=$((fail_count + 1)) ;;
                BLOCKED) blocked_count=$((blocked_count + 1)) ;;
                SKIPPED) skipped_count=$((skipped_count + 1)) ;;
            esac

            local layer_col=""
            if [[ "$first_in_layer" == true ]]; then
                layer_col="$layer_name"
                first_in_layer=false
            fi

            printf "  │ %-11s │ %-20s │ %-12s │ %-9s │\n" \
                "$layer_col" "$comp" "$sym" "$version"
        done
    done

    echo "  └─────────────┴──────────────────────┴──────────────┴───────────┘"
    echo ""
    echo -e "  ${BOLD}Summary: ${ok_count} OK / ${update_count} UPDATE / ${fail_count} FAIL / ${blocked_count} BLOCKED / ${skipped_count} SKIPPED${NC}"
    echo ""

    # 可更新项
    if [[ $update_count -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠ 可更新项：${NC}"
        for comp in "${!COMPONENT_STATUS[@]}"; do
            if [[ "${COMPONENT_STATUS[$comp]}" == "UPDATE" ]]; then
                echo "    $comp: 当前 ${COMPONENT_VERSION[$comp]}"
            fi
        done
        echo ""
    fi

    # 失败项
    if [[ $fail_count -gt 0 ]]; then
        echo -e "  ${RED}❌ 失败项：${NC}"
        for comp in "${!COMPONENT_STATUS[@]}"; do
            if [[ "${COMPONENT_STATUS[$comp]}" == "FAIL" ]]; then
                echo "    $comp"
            fi
        done
        echo ""
    fi

    # 报告文件
    generate_report

    if [[ $fail_count -eq 0 && $blocked_count -eq 0 ]]; then
        echo -e "  ${GREEN}✅ 环境就绪！请重启 Claude Code / AGY / Codex 使新配置生效。${NC}"
    fi
}

generate_report() {
    local report_file="$SCRIPT_DIR/pmf-init-report-${TIMESTAMP}.md"
    local os_info
    os_info="$(uname -s)/$(uname -m)"
    if [[ -f /etc/os-release ]]; then
        os_info="$os_info/$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo 'unknown')"
    fi

    local mode="交互式"
    if [[ "$YES_MODE" == true && "$FORCE_PERMISSIONS" == true ]]; then
        mode="--yes --force-permissions"
    elif [[ "$YES_MODE" == true ]]; then
        mode="--yes"
    fi

    cat > "$report_file" <<REPORT
# PerPetual Motion FrameWork 环境配置报告

> 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
> 平台: $os_info
> 模式: $mode

## 状态总览

| 层 | 组件 | 状态 | 版本 | 备注 |
|---|---|---|---|---|
REPORT

    # 遍历所有组件写入报告
    local layers=(
        "基础环境|git|node|npm|python3|pip|uv|codex|claude|agy"
        "记忆层|graphify|graphify→codex|graphify→agy|graphify→claude|graphify-out/"
        "方法层|superpowers→agy|superpowers→codex|superpowers→claude"
        "执行层|missions→agy|missions→codex|missions→claude"
        "权限层|approval_policy|sandbox_mode|multi_agent"
        "项目结构|docs/superpowers/specs/|issues/|.mission/|AGENTS.md"
    )

    for layer_data in "${layers[@]}"; do
        local IFS='|'
        local parts=($layer_data)
        local layer_name="${parts[0]}"
        for ((i=1; i<${#parts[@]}; i++)); do
            local comp="${parts[$i]}"
            local status="${COMPONENT_STATUS[$comp]:-SKIPPED}"
            local version="${COMPONENT_VERSION[$comp]:-}"
            echo "| $layer_name | $comp | $status | $version | |" >> "$report_file"
        done
    done

    # 可更新项
    echo "" >> "$report_file"
    echo "## 可更新项" >> "$report_file"
    local has_updates=false
    for comp in "${!COMPONENT_STATUS[@]}"; do
        if [[ "${COMPONENT_STATUS[$comp]}" == "UPDATE" ]]; then
            echo "- $comp: ${COMPONENT_VERSION[$comp]}" >> "$report_file"
            has_updates=true
        fi
    done
    if [[ "$has_updates" == false ]]; then
        echo "无" >> "$report_file"
    fi

    # 失败项
    echo "" >> "$report_file"
    echo "## 失败项" >> "$report_file"
    local has_fails=false
    for comp in "${!COMPONENT_STATUS[@]}"; do
        if [[ "${COMPONENT_STATUS[$comp]}" == "FAIL" ]]; then
            echo "- $comp (重试 3 次后失败)" >> "$report_file"
            has_fails=true
        fi
    done
    if [[ "$has_fails" == false ]]; then
        echo "无" >> "$report_file"
    fi

    # 被阻塞项
    echo "" >> "$report_file"
    echo "## 被阻塞项" >> "$report_file"
    local has_blocked=false
    for comp in "${!COMPONENT_STATUS[@]}"; do
        if [[ "${COMPONENT_STATUS[$comp]}" == "BLOCKED" ]]; then
            echo "- $comp" >> "$report_file"
            has_blocked=true
        fi
    done
    if [[ "$has_blocked" == false ]]; then
        echo "无" >> "$report_file"
    fi

    # 用户跳过项
    echo "" >> "$report_file"
    echo "## 用户跳过项" >> "$report_file"
    local has_skipped=false
    for comp in "${!COMPONENT_STATUS[@]}"; do
        if [[ "${COMPONENT_STATUS[$comp]}" == "SKIPPED" ]]; then
            echo "- $comp" >> "$report_file"
            has_skipped=true
        fi
    done
    if [[ "$has_skipped" == false ]]; then
        echo "无" >> "$report_file"
    fi

    # 备份记录
    echo "" >> "$report_file"
    echo "## 备份记录" >> "$report_file"
    if [[ ${#BACKUP_RECORDS[@]} -gt 0 ]]; then
        for rec in "${BACKUP_RECORDS[@]}"; do
            echo "- $rec" >> "$report_file"
        done
    else
        echo "无" >> "$report_file"
    fi

    # 下一步
    cat >> "$report_file" <<'NEXT'

## 下一步
1. 重启 Claude Code / AGY / Codex
2. 确认 skills 可触发：hello → $mission continue
3. 运行 graphify . 建立/刷新图谱
4. 开始讨论需求：首选 Claude/AGY，降级 Codex
NEXT

    log INFO "报告已生成: $report_file"
}

# ═══════════════════════════════════════════════════════════════
#  主执行流
# ═══════════════════════════════════════════════════════════════

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  PerPetual Motion FrameWork — 环境配置          ║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_os
    refresh_path

    phase1_base_environment
    phase2_graphify
    phase3_superpowers
    phase4_missions
    phase5_permissions
    phase6_project_structure
    phase7_validation
}

main "$@"
