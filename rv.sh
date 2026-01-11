#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# =========================
# 自用最小脚本：VLESS TCP REALITY Vision (交互版)
# =========================

ENV_FILE="/root/reality_vision.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
SERVICE="xray"

REYM_DEFAULT="www.tesla.com"
PORT_MIN=10000
PORT_MAX=65535

is_root() { [[ "${EUID}" -eq 0 ]]; }
# 端口占用检测: 占用返回1，空闲返回0
is_port_free() { ss -lnt | awk '{print $4}' | grep -qE "[:.]$1$" && return 1 || return 0; }

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
  # 1. 优先检测环境变量 (兼容自动化一键安装)
  if [[ -n "${vlpt:-}" ]]; then
    PORT="$vlpt"
    echo "检测到环境变量，使用指定端口: $PORT"
    return
  fi

  # 2. 交互式询问
  echo "------------------------------------------------"
  read -r -p "请输入端口号 (留空则随机 $PORT_MIN-$PORT_MAX): " input_port
  
  if [[ -n "$input_port" ]]; then
    # 简单的数字范围正则判断
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
      PORT="$input_port"
      echo "使用自定义端口: $PORT"
    else
      PORT="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
      echo "输入无效，已自动切换为随机端口: $PORT"
    fi
  else
    PORT="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
    echo "未输入，使用随机端口: $PORT"
  fi

  # 3. 占用检测警告 (极简原则：只警告，不强制中断，防止判断失误)
  if ! is_port_free "$PORT"; then
    echo "⚠️  警告: 端口 $PORT 似乎已被占用，安装可能失败！"
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
  choose_port  # 这里调用更新后的端口选择函数
  gen_reality_keys

  SERVER_IP="$(curl -s https://api.ipify.org)"
  write_config

  systemctl enable xray >/dev/null
  systemctl restart xray

  save_env
  echo "------------------------------------------------"
  echo "安装完成，运行：bash rv.sh info"
}

cmd_info() {
  source "$ENV_FILE"
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#RV-Tesla-Vision"
}

cmd_uninstall() {
  systemctl stop xray || true
  systemctl disable xray || true
  rm -f "$XRAY_CONF" "$ENV_FILE"
  curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- remove
}

case "$1" in
  install) cmd_install ;;
  info) cmd_info ;;
  uninstall) cmd_uninstall ;;
  *) echo "用法: bash rv.sh install|info|uninstall" ;;
esac
