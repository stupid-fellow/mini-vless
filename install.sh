#!/bin/bash

# ==================================================
# 变量定义
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
RV_SCRIPT="/root/rv.sh"

# ==================================================
# 1. 核心功能：显示节点信息
#    (这个函数既用于安装后立刻显示，也写入 rv.sh 供日后查询)
# ==================================================
print_info() {
    # 重新获取配置信息，确保数据准确
    if [ -f "$XRAY_CONFIG" ]; then
        LOCAL_UUID=$(grep "id" $XRAY_CONFIG | awk -F '"' '{print $4}')
        LOCAL_PORT=$(grep "port" $XRAY_CONFIG | head -n 1 | tr -cd '[0-9]')
        # 获取公网IP
        LOCAL_IP=$(curl -s4m8 ip.sb)
        if [ -z "$LOCAL_IP" ]; then LOCAL_IP=$(curl -s4m8 ifconfig.me); fi

        # 拼接 VLESS 链接
        # 格式: vless://UUID@IP:PORT?encryption=none&security=none&type=tcp&headerType=none#VPS-Node
        VLESS_LINK="vless://${LOCAL_UUID}@${LOCAL_IP}:${LOCAL_PORT}?encryption=none&security=none&type=tcp&headerType=none#VPS-Node"

        echo -e ""
        echo -e "------------------------------------------------"
        echo -e "          ${GREEN}VLESS 安装成功 - 节点信息${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e " 地址 (IP)   : ${GREEN}${LOCAL_IP}${PLAIN}"
        echo -e " 端口 (Port) : ${GREEN}${LOCAL_PORT}${PLAIN}"
        echo -e " UUID        : ${GREEN}${LOCAL_UUID}${PLAIN}"
        echo -e " 传输协议    : ${GREEN}TCP${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e " ${YELLOW}>>> VLESS 链接 (复制下方内容):${PLAIN}"
        echo -e "${GREEN}${VLESS_LINK}${PLAIN}"
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}错误：无法读取配置文件，安装可能未完成。${PLAIN}"
    fi
}

# ==================================================
# 2. 生成 /root/rv.sh (方便日后查看)
# ==================================================
generate_rv_script() {
    cat > "$RV_SCRIPT" <<EOF
#!/bin/bash
# 引用主脚本中的显示函数逻辑的简化版
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'
CONFIG="/usr/local/etc/xray/config.json"

if [ ! -f "\$CONFIG" ]; then echo "未安装服务"; exit 1; fi

ID=\$(grep "id" \$CONFIG | awk -F '"' '{print \$4}')
PORT=\$(grep "port" \$CONFIG | head -n 1 | tr -cd '[0-9]')
IP=\$(curl -s4m8 ip.sb)
LINK="vless://\${ID}@\${IP}:\${PORT}?encryption=none&security=none&type=tcp&headerType=none#VPS-Node"

case "\$1" in
    info)
        echo -e "------------------------------------------------"
        echo -e " 地址: \${GREEN}\${IP}\${PLAIN}"
        echo -e " 端口: \${GREEN}\${PORT}\${PLAIN}"
        echo -e " UUID: \${GREEN}\${ID}\${PLAIN}"
        echo -e "------------------------------------------------"
        echo -e "\${GREEN}\${LINK}\${PLAIN}"
        ;;
    *) echo "使用: bash rv.sh info" ;;
esac
EOF
    chmod +x "$RV_SCRIPT"
}

# ==================================================
# 3. 安装流程
# ==================================================
install_vless() {
    echo -e "${GREEN}>>> 开始安装依赖...${PLAIN}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget curl unzip >/dev/null 2>&1

    echo -e "${GREEN}>>> 下载 Xray 内核...${PLAIN}"
    mkdir -p /usr/local/bin /usr/local/etc/xray
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DOWNLOAD_ARCH="64" ;;
        aarch64) DOWNLOAD_ARCH="arm64-v8a" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
    
    # 官方下载链接
    wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${DOWNLOAD_ARCH}.zip"
    unzip -qo /tmp/xray.zip -d /usr/local/bin
    rm -f /tmp/xray.zip
    chmod +x /usr/local/bin/xray

    echo -e "${GREEN}>>> 生成配置...${PLAIN}"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PORT=$(shuf -i 10000-60000 -n 1)

    # 写入配置文件
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "tcp" }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    # 写入 Systemd 服务
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 启动
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    
    # 生成日后用的脚本
    generate_rv_script

    # 【关键】这里直接调用函数显示，不再依赖文件是否生成成功，确保你看到结果
    print_info
}

# ==================================================
# 4. 卸载流程
# ==================================================
uninstall_vless() {
    echo -e "${YELLOW}>>> 正在卸载...${PLAIN}"
    systemctl stop xray
    systemctl disable xray >/dev/null 2>&1
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service
    rm -f "$RV_SCRIPT"
    systemctl daemon-reload
    echo -e "${GREEN}>>> 卸载完成。${PLAIN}"
}

# ==================================================
# 5. 菜单
# ==================================================
show_menu() {
    clear
    echo -e "=================================="
    echo -e "    ${GREEN}VLESS 一键安装脚本${PLAIN}"
    echo -e "=================================="
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS (自动显示节点)"
    echo -e "  ${GREEN}2.${PLAIN} 卸载 VLESS"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "=================================="
    read -p " 请输入选择 [0-2]: " num

    case "$num" in
        1) install_vless ;;
        2) uninstall_vless ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${PLAIN}"; sleep 1; show_menu ;;
    esac
}

# 必须 root 运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行！${PLAIN}"
else
    show_menu
fi
