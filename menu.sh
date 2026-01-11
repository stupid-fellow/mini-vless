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
# 2. 核心功能：写入 rv.sh (实际干活的脚本)
# ==================================================
write_rv_script() {
cat > "$RV_SCRIPT" <<'EOF'
#!/usr/bin/env bash
export LANG=en_US.UTF-8

# =========================
# VLESS Reality Vision (全系统兼容版)
# =========================

ENV_FILE="/root/reality_vision.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
REYM_DEFAULT="www.tesla.com"

# -------------------------
# 系统检测
# -------------------------
check_sys() {
    if [ -f /etc/alpine-release ]; then
        RELEASE="alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        RELEASE="debian" # Ubuntu/Debian/Kali
    elif command -v yum >/dev/null 2>&1; then
        RELEASE="centos" # CentOS/RedHat
    else
        RELEASE="unknown"
    fi
}

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

install_xray() {
    echo "下载 Xray 内核..."
    mkdir -p /usr/local/bin /usr/local/etc/xray
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOWNLOAD_ARCH="64" ;;
        aarch64) DOWNLOAD_ARCH="arm64-v8a" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac

    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${DOWNLOAD_ARCH}.zip"
    unzip -qo /tmp/xray.zip -d /usr/local/bin
    chmod +x "$XRAY_BIN"
    rm -f /tmp/xray.zip
}

# -------------------------
# 配置生成
# -------------------------
gen_config() {
    UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
    
    # 接收外部传入的端口变量 vlpt
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

    # 简单的防火墙放行
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

# -------------------------
# 服务管理 (Systemd + OpenRC)
# -------------------------
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
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
        systemctl restart xray
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
        rc-update add xray default
        rc-service xray restart
    else
        $XRAY_BIN run -c $XRAY_CONF &
    fi
}

cmd_install() {
    install_deps
    install_xray
    gen_config
    setup_service
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
        echo -e "\033[0;31m[错误
