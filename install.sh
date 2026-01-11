#!/bin/bash

# ==================================================
# 全局变量与配置
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

RV_SCRIPT="/root/rv.sh"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# ==================================================
# 辅助函数
# ==================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# ==================================================
# 核心功能：生成 /root/rv.sh 脚本
# ==================================================
# 这个函数会在本地创建 rv.sh，用于查看节点信息
create_rv_script() {
    cat > "$RV_SCRIPT" <<EOF
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'

# 获取配置信息
CONFIG_FILE="$XRAY_CONFIG"
if [ ! -f "\$CONFIG_FILE" ]; then
    echo -e "\${RED}未找到配置文件，请先安装服务。\${PLAIN}"
    exit 1
fi

# 简单的 JSON 解析 (利用 grep/awk，不依赖 jq 以保证兼容性)
UUID=\$(grep "id" \$CONFIG_FILE | awk -F '"' '{print \$4}')
PORT=\$(grep "port" \$CONFIG_FILE | head -n 1 | tr -cd '[0-9]')
IP=\$(curl -s4m8 ip.sb)

# VLESS 链接拼接
# 格式: vless://UUID@IP:PORT?encryption=none&security=none&type=tcp&headerType=none#VPS-Node
LINK="vless://\${UUID}@\${IP}:\${PORT}?encryption=none&security=none&type=tcp&headerType=none#VPS-Node"

show_info() {
    echo -e "------------------------------------------------"
    echo -e "       \${GREEN}VLESS 节点信息\${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "地址 (IP)  : \${GREEN}\${IP}\${PLAIN}"
    echo -e "端口 (Port): \${GREEN}\${PORT}\${PLAIN}"
    echo -e "UUID       : \${GREEN}\${UUID}\${PLAIN}"
    echo -e "传输协议   : \${GREEN}TCP\${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "VLESS 链接 (复制下方链接到客户端):"
    echo -e "\${GREEN}\${LINK}\${PLAIN}"
    echo -e "------------------------------------------------"
}

case "\$1" in
    info)
        show_info
        ;;
    *)
        echo "使用方法: bash rv.sh info"
        ;;
esac
EOF
    chmod +x "$RV_SCRIPT"
}

# ==================================================
# 核心功能：安装 VLESS
# ==================================================
install_vless() {
    echo -e "${GREEN}>>> 开始安装依赖...${PLAIN}"
    apt-get update -y
    apt-get install -y wget curl unzip

    echo -e "${GREEN}>>> 下载 Xray 内核...${PLAIN}"
    # 判断架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOWNLOAD_ARCH="64" ;;
        aarch64) DOWNLOAD_ARCH="arm64-v8a" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    # 创建目录
    mkdir -p /usr/local/bin /usr/local/etc/xray

    # 下载并解压官方内核
    wget -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${DOWNLOAD_ARCH}.zip"
    unzip -o /tmp/xray.zip -d /usr/local/bin
    rm -f /tmp/xray.zip
    chmod +x /usr/local/bin/xray

    echo -e "${GREEN}>>> 生成配置...${PLAIN}"
    # 生成随机 UUID 和 端口
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PORT=$(shuf -i 10000-60000 -n 1)

    # 写入 config.json (最简 VLESS-TCP 模式)
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    echo -e "${GREEN}>>> 配置 Systemd 服务...${PLAIN}"
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

    # 生成 rv.sh 管理脚本
    create_rv_script

    echo -e "${GREEN}>>> 安装完成！${PLAIN}"
    
    # 【关键需求】直接调用 rv.sh info 显示节点
    echo -e "${YELLOW}>>> 正在获取节点链接...${PLAIN}"
    if [ -f "$RV_SCRIPT" ]; then
        bash "$RV_SCRIPT" info
    fi
}

# ==================================================
# 核心功能：卸载
# ==================================================
uninstall_vless() {
    echo -e "${YELLOW}>>> 正在卸载 VLESS...${PLAIN}"
    systemctl stop xray
    systemctl disable xray
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    
    rm -rf /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    
    # 删除管理脚本
    rm -f "$RV_SCRIPT"
    
    echo -e "${GREEN}>>> 卸载完成，所有相关文件已清除。${PLAIN}"
}

# ==================================================
# 交互菜单
# ==================================================
show_menu() {
    check_root
    clear
    echo -e "=================================="
    echo -e "    ${GREEN}VLESS 极简安装脚本${PLAIN}"
    echo -e "=================================="
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS 服务 (自动显示节点)"
    echo -e "  ${GREEN}2.${PLAIN} 卸载该服务"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "=================================="
    read -p " 请输入选项 [0-2]: " num

    case "$num" in
        1) install_vless ;;
        2) uninstall_vless ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${PLAIN}"; sleep 1; show_menu ;;
    esac
}

# 运行菜单
show_menu
