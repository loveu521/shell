#!/usr/bin/env bash
# ============================================================================
# YLShell 工具箱安装脚本 v3.1
# 极简版：直接下载main.sh，无验证，轻量快速
# ============================================================================

set -Eeuo pipefail
trap 'cleanup; echo -e "\n\033[31m✗ 安装被中断\033[0m"; exit 1' INT TERM ERR

# ============================================================================
# 配置部分
# ============================================================================
readonly SCRIPT_VERSION="3.1"
readonly MAIN_SCRIPT_URL="https://shell.yvlo.top/main.sh"
readonly FALLBACK_URLS=(
    "https://raw.githubusercontent.com/ylshell/main/main.sh"
    "https://cdn.jsdelivr.net/gh/ylshell/main/main.sh"
)

# 目录配置
readonly INSTALL_DIR="${YL_INSTALL_DIR:-$HOME/.ylshell}"
readonly BIN_DIR="${HOME}/.local/bin"
readonly LOG_FILE="${HOME}/.ylshell_install.log"

# 颜色定义
readonly COLOR_RESET="\033[0m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_BLUE="\033[34m"
readonly COLOR_CYAN="\033[36m"

# ============================================================================
# 输出函数
# ============================================================================
print_info() { echo -e "${COLOR_BLUE}ℹ${COLOR_RESET} $1"; }
print_success() { echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1"; }
print_warning() { echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $1"; }
print_error() { echo -e "${COLOR_RED}✗${COLOR_RESET} $1"; exit 1; }

print_header() {
    echo -e "\n${COLOR_CYAN}╔═══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_CYAN}║${COLOR_RESET} ${COLOR_BLUE}$1${COLOR_RESET}"
    echo -e "${COLOR_CYAN}╚═══════════════════════════════════════════════╝${COLOR_RESET}"
}

print_progress() {
    printf "\r${COLOR_CYAN}[下载中]${COLOR_RESET} %-50s" "$1..."
}

# ============================================================================
# 依赖检查
# ============================================================================
check_dependencies() {
    # 检查curl或wget
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        # 尝试安装curl
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y curl
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y curl
        elif command -v brew >/dev/null 2>&1; then
            brew install curl
        else
            print_error "需要 curl 或 wget，请手动安装"
        fi
    fi
    print_success "依赖检查通过"
}

# ============================================================================
# 下载函数（极简版）
# ============================================================================
download_file() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null 2>&1; then
        if curl -sSL --connect-timeout 20 "$url" -o "$output"; then
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --timeout=20 "$url" -O "$output"; then
            return 0
        fi
    fi
    
    return 1
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local retries=3
    
    for i in $(seq 1 $retries); do
        print_progress "尝试下载 ($i/$retries)"
        if download_file "$url" "$output"; then
            echo -e "\r${COLOR_GREEN}✓ 下载完成${COLOR_RESET} $(printf '%50s' ' ')"
            return 0
        fi
        sleep 1
    done
    
    return 1
}

# ============================================================================
# 安装主脚本
# ============================================================================
install_main_script() {
    print_header "安装主脚本"
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 尝试多个下载源
    local script_file="${INSTALL_DIR}/main.sh"
    
    # 先尝试主URL
    if download_with_retry "$MAIN_SCRIPT_URL" "$script_file"; then
        chmod +x "$script_file"
        print_success "主脚本安装完成"
        return 0
    fi
    
    # 尝试备用URL
    for url in "${FALLBACK_URLS[@]}"; do
        if download_with_retry "$url" "$script_file"; then
            chmod +x "$script_file"
            print_success "从备用源安装完成"
            return 0
        fi
    done
    
    print_error "所有下载源都失败"
}

# ============================================================================
# 创建命令别名
# ============================================================================
create_commands() {
    print_header "创建命令别名"
    
    local script_file="${INSTALL_DIR}/main.sh"
    
    # 确保bin目录存在
    mkdir -p "$BIN_DIR"
    
    # 创建命令别名
    local commands=("ylshell" "YLShell" "YLSHELL" "box" "shell" "Box" "Shell" "BOX" "SHELL")
    
    for cmd in "${commands[@]}"; do
        cat > "${BIN_DIR}/${cmd}" << EOF
#!/usr/bin/env bash
exec "${script_file}" "\$@"
EOF
        chmod +x "${BIN_DIR}/${cmd}"
        print_info "命令创建: $cmd"
    done
    
    print_success "命令别名创建完成"
}

# ============================================================================
# 配置环境
# ============================================================================
configure_environment() {
    print_header "配置环境"
    
    local need_update=0
    
    # 检查bashrc
    if ! grep -q "\.local/bin" "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        need_update=1
    fi
    
    # 检查zshrc
    if [ -f "$HOME/.zshrc" ] && ! grep -q "\.local/bin" "$HOME/.zshrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
        need_update=1
    fi
    
    if [ $need_update -eq 1 ]; then
        export PATH="$HOME/.local/bin:$PATH"
        print_warning "PATH已更新，新终端生效"
    else
        print_success "环境已配置"
    fi
}

# ============================================================================
# 创建修复脚本
# ============================================================================
create_fix_script() {
    cat > "${INSTALL_DIR}/fix.sh" << 'EOF'
#!/usr/bin/env bash
# YLShell 快速修复脚本

set -e

echo "开始修复..."
INSTALL_DIR="$HOME/.ylshell"
BIN_DIR="$HOME/.local/bin"

# 修复权限
chmod +x "$INSTALL_DIR/main.sh" 2>/dev/null || true

# 重新创建命令
mkdir -p "$BIN_DIR"
for cmd in ylshell yl ys box; do
    cat > "$BIN_DIR/$cmd" << EOL
#!/usr/bin/env bash
exec "$INSTALL_DIR/main.sh" "\$@"
EOL
    chmod +x "$BIN_DIR/$cmd"
done

echo "修复完成！"
EOF
    
    chmod +x "${INSTALL_DIR}/fix.sh"
    print_info "修复脚本已创建: fix.sh"
}

# ============================================================================
# 清理函数
# ============================================================================
cleanup() {
    rm -f "/tmp/ylshell_*" 2>/dev/null || true
}

# ============================================================================
# 显示结果
# ============================================================================
show_result() {
    print_header "安装完成"
    
    echo -e "${COLOR_BLUE}安装信息：${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}•${COLOR_RESET} 安装目录: $INSTALL_DIR"
    echo -e "  ${COLOR_GREEN}•${COLOR_RESET} 主脚本:   main.sh"
    echo -e "  ${COLOR_GREEN}•${COLOR_RESET} 命令目录: $BIN_DIR"
    
    echo -e "\n${COLOR_BLUE}使用方法：${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}ylshell${COLOR_RESET}    # 启动工具箱"
    echo -e "  ${COLOR_CYAN}YLShell${COLOR_RESET}         # 快捷命令"
    echo -e "  ${COLOR_CYAN}shell${COLOR_RESET}         # 快捷命令"
    echo -e "  ${COLOR_CYAN}box${COLOR_RESET}        # 快捷命令"
    
    echo -e "\n${COLOR_BLUE}故障排除：${COLOR_RESET}"
    echo -e "  命令找不到？运行: ${COLOR_YELLOW}source ~/.bashrc${COLOR_RESET}"
    echo -e "  快速修复: ${COLOR_YELLOW}$INSTALL_DIR/fix.sh${COLOR_RESET}"
    
    echo -e "\n${COLOR_GREEN}✓ 安装成功！输入 ylshell 开始使用。${COLOR_RESET}"
}

# ============================================================================
# 主安装流程
# ============================================================================
main_installation() {
    print_header "YLShell 工具箱安装程序 v${SCRIPT_VERSION}"
    
    # 检查依赖
    check_dependencies
    
    # 安装主脚本
    install_main_script
    
    # 创建命令别名
    create_commands
    
    # 配置环境
    configure_environment
    
    # 创建修复脚本
    create_fix_script
    
    # 显示结果
    show_result
    
    return 0
}

# ============================================================================
# 脚本入口
# ============================================================================
main() {
    # 显示欢迎信息
    echo -e "${COLOR_CYAN}"
    echo "    ██╗   ██╗██╗     ███████╗██╗  ██╗███████╗██╗     ██╗     "
    echo "    ╚██╗ ██╔╝██║     ██╔════╝██║  ██║██╔════╝██║     ██║     "
    echo "     ╚████╔╝ ██║     ███████╗███████║█████╗  ██║     ██║     "
    echo "      ╚██╔╝  ██║     ╚════██║██╔══██║██╔══╝  ██║     ██║     "
    echo "       ██║   ███████╗███████║██║  ██║███████╗███████╗███████╗"
    echo "       ╚═╝   ╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"
    echo -e "${COLOR_RESET}"
    echo -e "${COLOR_BLUE}             极简工具箱安装程序${COLOR_RESET}\n"
    
    # 检查是否直接运行
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        # 创建日志目录
        mkdir -p "$(dirname "$LOG_FILE")"
        
        # 确认安装
        read -rp "是否继续安装？(Y/n): " confirm
        confirm=${confirm:-Y}
        
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo "安装已取消"
            exit 0
        fi
        
        # 执行安装
        echo -e "\n开始安装...\n"
        if main_installation; then
            exit 0
        else
            print_error "安装失败"
        fi
    fi
}

# 执行主函数
main "$@"