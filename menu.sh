#!/bin/bash

# ==================================================
# 颜色定义
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

RV_SCRIPT="/root/rv.sh"

# ==================================================
# 核心：写入 rv.sh 逻辑 (完全基于你提供的代码)
# ==================================================
write_rv_script() {
cat > "$RV_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# =========================
# 自用最小脚本：VLESS TCP REALITY Vision
# =========================

ENV_FILE="/root/reality_vision.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

REYM_DEFAULT="www.tesla.com"
PORT_MIN=10000
PORT_MAX=65535

is_root() { [[ "${EUID}" -eq 0 ]]; }

install_deps() {
  apt-get update -y >/dev/null
  apt-get install -y curl unzip openssl ca-certificates iproute2 >/dev/null
}

install_xray() {
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) >/dev/null
}

gen_uuid() {
  UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
}

choose_port() {
  if [[ -n "${vlpt:-}" ]]; then
    PORT="$vlpt"
  else
    PORT="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
  fi
}

gen_reality_keys() {
  local KEYS
  KEYS="$("$XRAY_BIN" x25519)"
  PRIVATE_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/PrivateKey|Private key/ {print $2}')"
  PUBLIC_KEY="$(echo "$KEYS" | awk -F'[: ]+' '/Password|Public key/ {print $2}')"
  SHORT_ID="$(openssl rand -hex 4)"
}

write_config() {
mkdir -p /usr/local/etc/xray
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
}

save_env() {
cat > "$ENV_FILE" <<ENV
SERVER_IP=$SERVER_IP
PORT=$PORT
UUID=$UUID
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
ENV
chmod 600 "$ENV_FILE"
}

cmd_install() {
  is_root || exit 1
  install_deps
  install_xray

  SNI="${reym:-$REYM_DEFAULT}"
  gen_uuid
  choose_port
  gen_reality_keys

  # 获取IP，增加备用源防止超时
  SERVER_IP="$(curl -s https://api.ipify.org || curl -s https://ip.sb)"
  write_config

  systemctl enable xray >/dev/null
  systemctl restart xray

  save_env
}

cmd_info() {
  if [ -f "$ENV_FILE" ]; then
      source "$ENV_FILE"
      echo -e ""
      echo -e "\033[0;32m=== VLESS Reality Vision 节点信息 ===\033[0m"
      echo -e "地址 (IP): ${SERVER_IP}"
      echo -e "端口 (Port): ${PORT}"
      echo -e "UUID: ${UUID}"
      echo -e "SNI: ${SNI}"
      echo -e "----------------------------------------"
      echo -e "\033[0;33m链接:\033[0m"
      echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#RV-Vision"
      echo -e "----------------------------------------"
  else
      echo -e "\033[0;31m未找到配置文件，请先安装。\033[0m"
  fi
}

cmd_uninstall() {
  systemctl stop xray || true
  systemctl disable xray || true
  rm -f "$XRAY_CONF" "$ENV_FILE"
  # 调用官方脚本卸载
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove >/dev/null
  echo "Xray 服务已卸载。"
}

case "$1" in
  install) cmd_install ;;
  info) cmd_info ;;
  uninstall) cmd_uninstall ;;
  *) echo "用法: bash rv.sh install|info|uninstall" ;;
esac
EOF
    chmod +x "$RV_SCRIPT"
}

# ==================================================
# 交互菜单功能
# ==================================================

install_vless() {
    echo -e "${GREEN}>>> 正在写入核心脚本...${PLAIN}"
    write_rv_script
    
    echo -e "${GREEN}>>> 开始安装 VLESS Reality Vision...${PLAIN}"
    # 调用生成的脚本进行安装
    bash "$RV_SCRIPT" install
    
    echo -e "${GREEN}>>> 安装完成！正在获取节点信息...${PLAIN}"
    sleep 1
    
    # 【核心需求】直接执行 info
    bash "$RV_SCRIPT" info
}

uninstall_vless() {
    echo -e "${YELLOW}>>> 正在卸载服务...${PLAIN}"
    if [ -f "$RV_SCRIPT" ]; then
        bash "$RV_SCRIPT" uninstall
        rm -f "$RV_SCRIPT"
        echo -e "${GREEN}>>> 卸载完成，脚本已清理。${PLAIN}"
    else
        echo -e "${RED}>>> 未找到安装脚本，可能尚未安装。${PLAIN}"
    fi
}

show_menu() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi

    clear
    echo -e "==========================================="
    echo -e "   ${GREEN}VLESS Reality Vision 管理脚本${PLAIN}"
    echo -e "==========================================="
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS 服务 (自动显示节点)"
    echo -e "  ${GREEN}2.${PLAIN} 卸载该服务"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "==========================================="
    read -p " 请输入选项 [0-2]: " num

    case "$num" in
        1) install_vless ;;
        2) uninstall_vless ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${PLAIN}"; sleep 1; show_menu ;;
    esac
}

# 启动菜单
show_menu
