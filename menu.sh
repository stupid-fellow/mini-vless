#!/bin/bash

# ==================================================
# 1. 全局配置
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

RV_SCRIPT="/root/rv.sh"

# ==================================================
# 2. 核心功能：写入 rv.sh (这是实际执行安装的脚本)
# ==================================================
write_rv_script() {
# 注意：下面的 'EOF' 必须保持原样，不要改动
cat > "$RV_SCRIPT" <<'EOF'
#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================
# VLESS Reality Vision (内核脚本)
# =========================

ENV_FILE="/root/reality_vision.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
REYM_DEFAULT="www.tesla.com"

# --- 系统检测 ---
check_sys() {
    if [ -f /etc/alpine-release ]; then
        RELEASE="alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        RELEASE="debian" 
    elif command -v yum >/dev/null 2>&1; then
        RELEASE="centos"
    else
        RELEASE="unknown"
    fi
}

# --- 安装依赖 ---
install_deps() {
    check_sys
    echo "正在为 $RELEASE 系统安装依赖..."
    case "$RELEASE" in
        alpine)
            apk update
            apk add --no-cache bash curl unzip openssl ca-certificates iproute2 coreutils libc6-compat
            ;;
        debian)
            apt-get update -y
            apt-get install -y curl unzip openssl ca-certificates iproute2
            ;;
        centos)
            yum update -y
            yum install -y curl unzip openssl ca-certificates iproute2
            ;;
    esac
}

# --- 下载 Xray ---
install_xray() {
    echo "下载 Xray 内核..."
    mkdir -p /usr/local/bin /usr/local/etc/xray
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOWNLOAD_ARCH="64" ;;
        aarch64) DOWNLOAD_ARCH="arm64-v8a" ;;
        *) echo "不支持架构: $ARCH"; exit 1 ;;
    esac
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${DOWNLOAD_ARCH}.zip"
    unzip -qo /tmp/xray.zip -d /usr/local/bin
    chmod +x "$XRAY_BIN"
    rm -f /tmp/xray.zip
}

# --- 生成配置 ---
gen_config() {
    UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
    # 接收外部传入的端口
    if [[ -n "${vlpt:-}" ]]; then
        PORT="$vlpt"
    else
        PORT="$(shuf -i 10000-65535 -n 1)"
    fi
    
    KEYS="$($XRAY_BIN x25519)"
    PRIVATE_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/PrivateKey|Private key/ {print $2}')"
    PUBLIC_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/Password|Public key/ {print $2}')"
    SHORT_ID="$(openssl rand -hex 4)"
    SNI="${reym:-$REYM_DEFAULT}"

    cat > "$XRAY_CONF" <<JSON
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
JSON
    # 防火墙尝试放行
    if command -v ufw >/dev/null 2>&1; then ufw allow "$PORT"/tcp; fi
    if command -v iptables >/dev/null 2>&1; then iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT; fi

    cat > "$ENV_FILE" <<ENV
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ip.sb)
PORT=$PORT
UUID=$UUID
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
ENV
    chmod 600 "$ENV_FILE"
}

# --- 服务管理 ---
setup_service() {
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/xray.service <<ServiceEOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF}
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
ServiceEOF
        systemctl daemon-reload; systemctl enable xray >/dev/null 2>&1; systemctl restart xray
    elif [ -f /sbin/openrc-run ]; then
        cat > /etc/init.d/xray <<InitEOF
#!/sbin/openrc-run
name="Xray"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONF}"
command_background=true
pidfile="/run/xray.pid"
InitEOF
        chmod +x /etc/init.d/xray
        rc-update add xray default; rc-service xray restart
    else
        $XRAY_BIN run -c $XRAY_CONF &
    fi
}

cmd_install() {
    install_deps; install_xray; gen_config; setup_service
}

cmd_info() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        echo -e ""
        echo -e "\033[0;32m=== VLESS Reality Vision 节点 ===\033[0m"
        echo -e "地址 (IP): ${SERVER_IP}"
        echo -e "端口 (Port): ${PORT}"
        echo -e "UUID: ${UUID}"
        echo -e "SNI: ${SNI}"
        echo -e "----------------------------------------"
        echo -e "链接:"
        echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Node-${PORT}"
        echo -e "----------------------------------------"
    else
        echo -e "\033[0;31m[错误] 配置文件不存在。\033[0m"
    fi
}

cmd_uninstall() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop xray; systemctl disable xray; rm -f /etc/systemd/system/xray.service
    elif [ -f /sbin/openrc-run ]; then
        rc-service xray stop; rc-update del xray; rm -f /etc/init.d/xray
    fi
    rm -rf /usr/local/bin/xray /usr/local/etc/xray "$ENV_FILE"
    echo "服务已卸载。"
}

case "$1" in
  install) cmd_install ;;
  info) cmd_info ;;
  uninstall) cmd_uninstall ;;
  *) echo "用法: bash rv.sh install|info|uninstall" ;;
esac
EOF
    # 下面的 EOF 必须顶格，不要有空格
    chmod +x "$RV_SCRIPT"
}

# ==================================================
# 3. 交互逻辑
# ==================================================
ask_port() {
    echo -e "-------------------------------------------"
    read -p "是否自定义端口? [y/N] (默认随机): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "请输入端口 (1-65535): " custom_port
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
                echo -e "${GREEN}已选择端口: $custom_port${PLAIN}"
                export vlpt="$custom_port"
                break
            else
                echo -e "${RED}输入无效，请输入 1-65535 之间的数字。${PLAIN}"
            fi
        done
    else
        echo -e "${GREEN}将使用随机高位端口。${PLAIN}"
        unset vlpt
    fi
    echo -e "-------------------------------------------"
}

# ==================================================
# 4. 菜单入口
# ==================================================
install_vless() {
    # 针对 Alpine 安装 bash
    if [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1; then
        apk update && apk add bash
    fi
    
    echo -e "${GREEN}>>> 初始化环境...${PLAIN}"
    write_rv_script
    ask_port
    
    echo -e "${GREEN}>>> 开始安装 (适配 Ubuntu/Alpine)...${PLAIN}"
    bash "$RV_SCRIPT" install
    
    echo -e "${GREEN}>>> 安装完成，获取节点信息...${PLAIN}"
    sleep 2
    bash "$RV_SCRIPT" info
}

view_info() {
    if [ -f "$RV_SCRIPT" ]; then
        bash "$RV_SCRIPT" info
    else
        echo -e "${RED}>>> 尚未安装服务。${PLAIN}"
    fi
    echo ""; read -p "按回车键返回菜单..."
    show_menu
}

uninstall_vless() {
    echo -e "${YELLOW}>>> 正在卸载...${PLAIN}"
    if [ -f "$RV_SCRIPT" ]; then
        bash "$RV_SCRIPT" uninstall; rm -f "$RV_SCRIPT"
    else
        echo "脚本不存在。"
    fi
}

show_menu() {
    clear
    echo -e "==========================================="
    echo -e "   ${GREEN}VLESS Vision (Ubuntu/Debian/Alpine)${PLAIN}"
    echo -e "==========================================="
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS + TCP + REALITY + Vision"
    echo -e "  ${GREEN}2.${PLAIN} 卸载 VLESS + TCP + REALITY + Vision"
    echo -e "  ${GREEN}3.${PLAIN} 显示 VLESS + TCP + REALITY + Vision"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "==========================================="
    read -p " 请输入选项 [0-3]: " num
    case "$num" in
        1) install_vless ;;
        2) uninstall_vless ;;
        3) view_info ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

if [ "$(id -u)" -ne 0 ]; then echo -e "${RED}请使用 root 运行！${PLAIN}"; exit 1; fi
show_menu
