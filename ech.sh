#!/bin/sh

REPO_OWNER="byJoey"
REPO_NAME="ech-wk"
BIN_PATH="/usr/bin/ech-workers"
CONF_FILE="/etc/ech-workers.conf"
TMP_DIR="/tmp/ech-workers"

# 默认配置
DEFAULT_BEST_IP="joeyblog.net"
DEFAULT_SERVER_ADDR="echo.example.com:443"
DEFAULT_LISTEN_ADDR="0.0.0.0:30001"
DEFAULT_TOKEN=""
DEFAULT_DNS="https://dns.alidns.com/dns-query"
DEFAULT_ECH_DOMAIN="cloudflare-ech.com"
DEFAULT_ROUTING="global"

# --- 系统检测 ---
check_sys() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        INIT_TYPE="procd"
        INIT_FILE="/etc/init.d/ech-workers"
    elif command -v systemctl >/dev/null 2>&1; then
        OS_TYPE="linux_systemd"
        INIT_TYPE="systemd"
        INIT_FILE="/etc/systemd/system/ech-workers.service"
    else
        OS_TYPE="linux_generic"
        INIT_TYPE="unknown"
        INIT_FILE=""
    fi
}

# --- 依赖安装 (略) ---
install_pkg() {
    local pkg=$1
    command -v "$pkg" >/dev/null 2>&1 && return 0

    echo "正在安装 $pkg ..."
    if [ "$OS_TYPE" = "openwrt" ]; then
        opkg update && opkg install "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    elif command -v apk >/dev/null 2>&1; then
        apk add "$pkg"
    else
        echo "无法自动安装 $pkg，请手动安装。"
        return 1
    fi
}

# 基础环境检查 (略)
check_env() {
    install_pkg wget
    install_pkg tar
    if [ "$OS_TYPE" != "openwrt" ]; then
        install_pkg ca-certificates
    fi
}

# 获取当前架构 (略)
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

# 安全的下载函数 (略)
download_file() {
    local url="$1"
    local output="$2"
    
    if wget --help 2>&1 | grep -q "busybox"; then
        wget --no-check-certificate -q -O "$output" "$url"
    else
        wget --no-check-certificate -q -O "$output" "$url"
    fi
    
    if [ $? -ne 0 ] && command -v curl >/dev/null 2>&1; then
        echo "wget 下载失败，尝试使用 curl..."
        curl -L -k -s -o "$output" "$url"
    fi
}

# 获取下载链接 (略)
get_latest_release_url() {
    echo "正在获取版本信息..." >&2
    
    api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    
    api_response_file="$TMP_DIR/api_response.json"
    mkdir -p "$TMP_DIR"
    
    wget --no-check-certificate -q -O - "$api_url" > "$api_response_file"
    
    if [ ! -s "$api_response_file" ]; then
        echo "获取 API 失败，尝试 curl..." >&2
        if command -v curl >/dev/null 2>&1; then
            curl -L -k -s "$api_url" > "$api_response_file"
        fi
    fi

    if [ ! -s "$api_response_file" ]; then
        echo "无法获取版本信息，请检查网络连接。" >&2
        rm -f "$api_response_file"
        return 1
    fi

    json_content=$(cat "$api_response_file")
    rm -f "$api_response_file"

    ARCH=$(get_arch)
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        echo "错误: 不支持的系统架构: $ARCH" >&2
        return 1
    fi
    
    echo "检测到系统: $OS_TYPE, 架构: $ARCH" >&2

    download_url=""
    
    if [ "$OS_TYPE" = "openwrt" ]; then
        download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}-softrouter[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
    else
        download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}.tar.gz[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
    fi

    if [ -z "$download_url" ]; then
        echo "首选版本未找到，尝试备用版本..." >&2
        if [ "$OS_TYPE" = "openwrt" ]; then
            download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}.tar.gz[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
        else
            download_url=$(echo "$json_content" | grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}-softrouter[^\"]*\"" | sed 's/.*"\(https.*\)".*/\1/' | head -n 1)
        fi
    fi

    if [ -z "$download_url" ]; then
        echo "未找到适合架构 ($ARCH) 的下载链接" >&2
        return 1
    fi

    echo "$download_url"
}

# 安装二进制 (略)
ensure_binary() {
    if [ -x "$BIN_PATH" ]; then return 0; fi

    check_env
    URL=$(get_latest_release_url)
    if [ $? -ne 0 ]; then return 1; fi

    echo "下载地址: $URL"
    mkdir -p "$(dirname "$BIN_PATH")"
    mkdir -p "$TMP_DIR"

    echo "正在下载..."
    download_file "$URL" "$TMP_DIR/ech-workers.tar.gz"
    
    if [ ! -f "$TMP_DIR/ech-workers.tar.gz" ] || [ ! -s "$TMP_DIR/ech-workers.tar.gz" ]; then
        echo "下载失败，文件为空或不存在。"
        return 1
    fi

    echo "解压中..."
    tar -zxvf "$TMP_DIR/ech-workers.tar.gz" -C "$TMP_DIR" >/dev/null 2>&1

    EXTRACTED_BIN=$(find "$TMP_DIR" -type f -name "ech-workers" | head -n 1)
    
    if [ -n "$EXTRACTED_BIN" ]; then
        mv "$EXTRACTED_BIN" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        echo "安装成功: $BIN_PATH"
        rm -rf "$TMP_DIR"
    else
        echo "解压错误: 未找到二进制文件"
        return 1
    fi
}

# 确保配置存在 (略)
ensure_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        mkdir -p "$(dirname "$CONF_FILE")"
        cat >"$CONF_FILE" <<EOF
BEST_IP="$DEFAULT_BEST_IP"
SERVER_ADDR="$DEFAULT_SERVER_ADDR"
LISTEN_ADDR="$DEFAULT_LISTEN_ADDR"
TOKEN="$DEFAULT_TOKEN"
DNS="$DEFAULT_DNS"
ECH_DOMAIN="$DEFAULT_ECH_DOMAIN"
ROUTING="$DEFAULT_ROUTING"
EOF
    fi
}

# 确保服务配置 (已优化 Systemd 日志)
ensure_init() {
    ensure_conf

    if [ "$INIT_TYPE" = "procd" ]; then
        cat >"$INIT_FILE" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
BIN="/usr/bin/ech-workers"
CONF="/etc/ech-workers.conf"

start_service() {
    [ -x "$BIN" ] || return 1
    [ -f "$CONF" ] && . "$CONF"
    : "${DNS:=https://dns.alidns.com/dns-query}"
    : "${ECH_DOMAIN:=cloudflare-ech.com}"
    : "${ROUTING:=global}"

    procd_open_instance
    procd_set_param command $BIN -f "${SERVER_ADDR}" -l "${LISTEN_ADDR}" -token "${TOKEN}" -ip "${BEST_IP}" -dns "${DNS}" -ech "${ECH_DOMAIN}" -routing "${ROUTING}"
    
    procd_set_param respawn
    procd_set_param stderr 1    # 错误日志送往系统 log
    procd_set_param stdout 1    # 标准输出也送往系统 log
    procd_close_instance
}
EOF
        chmod +x "$INIT_FILE"
        /etc/init.d/ech-workers enable >/dev/null 2>&1

    elif [ "$INIT_TYPE" = "systemd" ]; then
        # 优化点：移除 LOG_FILE 定义和重定向，完全依赖 journald
        cat >"$INIT_FILE" <<EOF
[Unit]
Description=ECH Workers Service
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONF_FILE
# 优化点：移除文件重定向，ExecStart使用纯命令
ExecStart=$BIN_PATH -f \${SERVER_ADDR} -l \${LISTEN_ADDR} -token \${TOKEN} -ip \${BEST_IP} -dns \${DNS} -ech \${ECH_DOMAIN} -routing \${ROUTING}
# 优化点：强制将输出发送到 journald
StandardOutput=journal
StandardError=journal
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ech-workers >/dev/null 2>&1
    fi
}

# 服务控制 (略)
svc_restart() {
    if [ "$INIT_TYPE" = "procd" ]; then
        /etc/init.d/ech-workers stop >/dev/null 2>&1
        /etc/init.d/ech-workers start
    elif [ "$INIT_TYPE" = "systemd" ]; then
        systemctl restart ech-workers
    else
        # 此时非 procd 非 systemd，使用 nohup 启动，且不重定向文件，让其进入 /dev/null
        killall ech-workers 2>/dev/null
        nohup "$BIN_PATH" -f "$SERVER_ADDR" -l "$LISTEN_ADDR" -token "$TOKEN" -ip "$BEST_IP" -dns "$DNS" -ech "$ECH_DOMAIN" -routing "$ROUTING" >/dev/null 2>&1 &
    fi
}

svc_stop() {
    if [ "$INIT_TYPE" = "procd" ]; then
        /etc/init.d/ech-workers stop
    elif [ "$INIT_TYPE" = "systemd" ]; then
        systemctl stop ech-workers
    else
        killall ech-workers
    fi
}

# 日志查看 (已优化 Systemd 逻辑)
svc_log() {
    echo "--- 实时日志 (Ctrl+C 退出) ---"
    if [ "$INIT_TYPE" = "procd" ]; then
        echo "（OpenWrt 系统日志，包含时间戳）"
        # 尝试使用 grep 过滤，如果失败则显示所有日志
        logread -f | grep -E "(ech-workers|\[ech-workers\])" || logread -f
    elif [ "$INIT_TYPE" = "systemd" ]; then
        echo "（Systemd Journal 日志）"
        # 优化点：不再尝试 tail 文件，直接使用 journalctl
        journalctl -u ech-workers -f
    else
        echo "未知初始化系统，无法实时查看日志"
    fi
}

# 暂停并等待按键 (略)
pause_key() {
    printf "\n===> 操作已完成，按回车键返回菜单..."
    read dummy
}

# 卸载功能 (已优化 Systemd 清理)
uninstall() {
    printf "确定要卸载吗？(y/n): "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        pause_key
        return
    fi

    echo "正在停止服务..."
    svc_stop

    echo "正在清理文件..."
    if [ "$INIT_TYPE" = "procd" ]; then
        /etc/init.d/ech-workers disable >/dev/null 2>&1
        rm -f "$INIT_FILE"
    elif [ "$INIT_TYPE" = "systemd" ]; then
        systemctl disable ech-workers >/dev/null 2>&1
        rm -f "$INIT_FILE"
        systemctl daemon-reload
        # 优化点：清理之前可能残留的日志文件
        rm -f "/tmp/ech-workers.log"
    fi

    rm -f "$BIN_PATH"
    rm -f "$CONF_FILE"
    rm -rf "$TMP_DIR"
    
    echo "卸载完成。"
    printf "\n按回车键退出..."
    read dummy
    exit 0
}

# 加载/保存配置 (略)
load_conf() { [ -f "$CONF_FILE" ] && . "$CONF_FILE"; }
save_conf() {
    cat >"$CONF_FILE" <<EOF
BEST_IP="${BEST_IP}"
SERVER_ADDR="${SERVER_ADDR}"
LISTEN_ADDR="${LISTEN_ADDR}"
TOKEN="${TOKEN}"
DNS="${DNS}"
ECH_DOMAIN="${ECH_DOMAIN}"
ROUTING="${ROUTING}"
EOF
}

# 菜单 (略)
show_menu() {
    while true; do
        clear
        ensure_conf
        load_conf
        
        STATUS="未运行"
        # 注意：此处 pgrep 依赖于进程名，不受日志记录方式变化影响
        if pgrep -f "ech-workers" >/dev/null; then STATUS="运行中"; fi
        
        ARCH_SHOW=$(get_arch)

        echo "=================================="
        echo "   ech-wk 管理脚本 "
        echo "   系统: $OS_TYPE ($INIT_TYPE)"
        echo "   架构: $ARCH_SHOW"
        echo "   状态: $STATUS"
        echo "=================================="
        echo "1. 设置 优选IP    [$BEST_IP]"
        echo "2. 设置 服务地址  [$SERVER_ADDR]"
        echo "3. 设置 监听地址  [$LISTEN_ADDR]"
        echo "4. 设置 Token     [${TOKEN:0:6}***]"
        echo "5. 设置 分流模式  [$ROUTING]"
        echo "----------------------------------"
        echo "6. 启动 / 重启服务"
        echo "7. 停止服务"
        echo "8. 查看实时日志"
        echo "9. 卸载程序"
        echo "0. 退出"
        echo "=================================="
        printf "请输入选项: "
        read -r choice

        case "$choice" in
            1) 
                printf "新优选IP: "; read -r BEST_IP; save_conf
                echo "配置已更新，正在重启服务..."
                svc_restart
                pause_key
                ;;
            2) 
                printf "新服务地址: "; read -r SERVER_ADDR; save_conf
                echo "配置已更新，正在重启服务..."
                svc_restart
                pause_key
                ;;
            3) 
                printf "新监听地址: "; read -r LISTEN_ADDR; save_conf
                echo "配置已更新，正在重启服务..."
                svc_restart
                pause_key
                ;;
            4) 
                printf "新Token: "; read -r TOKEN; save_conf
                echo "配置已更新，正在重启服务..."
                svc_restart
                pause_key
                ;;
            5) 
                echo "1) global (全局)  2) bypass_cn (绕过CN)"
                printf "选择: "; read -r r_mode
                [ "$r_mode" = "2" ] && ROUTING="bypass_cn" || ROUTING="global"
                save_conf 
                echo "配置已更新，正在重启服务..."
                svc_restart
                pause_key
                ;;
            6) 
                ensure_binary
                ensure_init
                svc_restart
                echo "服务已重启..."
                pause_key
                ;;
            7) 
                svc_stop
                echo "服务已停止"
                pause_key 
                ;;
            8) svc_log ;;
            9) uninstall ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# 入口
check_sys
show_menu
