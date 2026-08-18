#!/bin/bash
set -e

REPO="mrpompy/v2panel-releases"
BIN_NAME="v2panel-agent"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/v2panel-agent.service"
CLI_FILE="/usr/local/bin/v2panel"
STATE_DIR="/var/lib/v2panel-agent"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}==> V2Panel Agent Installer${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash install-agent.sh"
  exit 1
fi

# Stop service before replacing binary (avoid "Text file busy" error)
if systemctl is-active --quiet v2panel-agent 2>/dev/null; then
  echo -e "${CYAN}==> Stopping existing agent...${NC}"
  systemctl stop v2panel-agent
fi

# Use GitHub's /latest/download/ redirect (stable, no API parsing needed)
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"
echo -e "${CYAN}==> Downloading agent...${NC}"
# Download to temp file first, then move (atomic replace)
TMP_BIN=$(mktemp)
curl -fL "$DOWNLOAD_URL" -o "$TMP_BIN" || {
  echo "ERROR: Download failed from ${DOWNLOAD_URL}"
  rm -f "$TMP_BIN"
  exit 1
}
mv "$TMP_BIN" "${INSTALL_DIR}/v2panel-agent"
chmod +x "${INSTALL_DIR}/v2panel-agent"
echo -e "${GREEN}✓ Binary installed to ${INSTALL_DIR}/v2panel-agent${NC}"

# Generate token if service doesn't exist yet
if [ -f "$SERVICE_FILE" ]; then
  # Keep existing token
  AGENT_TOKEN=$(grep -oP '(?<=AGENT_TOKEN=)[^\s]+' "$SERVICE_FILE" || true)
  AGENT_PORT=$(grep -oP '(?<=AGENT_PORT=)\d+' "$SERVICE_FILE" || true)
  BACKEND_URL=$(grep -oP '(?<=BACKEND_URL=)[^\s]+' "$SERVICE_FILE" || true)
  NODE_ID=$(grep -oP '(?<=NODE_ID=)\d+' "$SERVICE_FILE" || true)
  VMESS_NODE_ID=$(grep -oP '(?<=VMESS_NODE_ID=)\d+' "$SERVICE_FILE" || true)
  HY2_NODE_ID=$(grep -oP '(?<=HY2_NODE_ID=)\d+' "$SERVICE_FILE" || true)
  REALITY_NODE_ID=$(grep -oP '(?<=REALITY_NODE_ID=)\d+' "$SERVICE_FILE" || true)
fi

if [ -z "$AGENT_TOKEN" ]; then
  AGENT_TOKEN=$(openssl rand -hex 32)
  echo -e "${GREEN}✓ Generated new token${NC}"
fi
AGENT_PORT=${AGENT_PORT:-9191}

# Preserve the Hysteria2 traffic API secret across upgrades.
if [ -f "$SERVICE_FILE" ]; then
  HY2_STATS_SECRET=$(grep -oP '(?<=HY2_STATS_SECRET=)[^\s]+' "$SERVICE_FILE" || true)
fi
if [ -z "$HY2_STATS_SECRET" ]; then
  HY2_STATS_SECRET=$(openssl rand -hex 32)
  echo -e "${GREEN}✓ Generated Hysteria2 stats secret${NC}"
fi

install -d -m 700 "$STATE_DIR"

# Detect V2Ray config path
V2RAY_CONFIG="/etc/v2ray/config.json"
if [ ! -f "$V2RAY_CONFIG" ]; then
  V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
fi
if [ ! -f "$V2RAY_CONFIG" ]; then
  echo -e "${YELLOW}⚠ V2Ray config not found, defaulting to /etc/v2ray/config.json${NC}"
  V2RAY_CONFIG="/etc/v2ray/config.json"
fi

# Write systemd service
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=V2Panel Node Agent
After=network.target

[Service]
Environment=AGENT_TOKEN=${AGENT_TOKEN}
Environment=AGENT_PORT=${AGENT_PORT}
Environment=BACKEND_URL=${BACKEND_URL}
Environment=NODE_ID=${NODE_ID}
Environment=VMESS_NODE_ID=${VMESS_NODE_ID}
Environment=HY2_NODE_ID=${HY2_NODE_ID}
Environment=REALITY_NODE_ID=${REALITY_NODE_ID}
Environment=V2RAY_CONFIG=${V2RAY_CONFIG}
Environment=HY2_AUTH_ADDR=127.0.0.1:9192
Environment=HY2_USER_STORE=${STATE_DIR}/hysteria2-users.json
Environment=HY2_STATS_URL=http://127.0.0.1:9999
Environment=HY2_STATS_SECRET=${HY2_STATS_SECRET}
Environment=XRAY_CONFIG=/usr/local/etc/xray/config.json
Environment=XRAY_SERVICE=xray
Environment=XRAY_BINARY=/usr/local/bin/xray
Environment=XRAY_API_ADDR=127.0.0.1:10085
ExecStart=/usr/local/bin/v2panel-agent
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable v2panel-agent
systemctl restart v2panel-agent
echo -e "${GREEN}✓ Service started${NC}"

# Install v2panel management CLI
cat > "$CLI_FILE" << 'CLIPEOF'
#!/bin/bash
SERVICE_FILE="/etc/systemd/system/v2panel-agent.service"
get_env() {
  grep -oP "(?<=Environment=$1=)[^\\s]+" "$SERVICE_FILE" 2>/dev/null || true
}
set_env() {
  sed -i "/^Environment=$1=/d" "$SERVICE_FILE"
  sed -i "/^\[Service\]/a Environment=$1=$2" "$SERVICE_FILE"
}
show_node_ids() {
  VMESS=$(get_env VMESS_NODE_ID); [ -n "$VMESS" ] || VMESS=$(get_env NODE_ID)
  HY2=$(get_env HY2_NODE_ID)
  REALITY=$(get_env REALITY_NODE_ID)
  echo "vmess:         ${VMESS:-未设置}"
  echo "hysteria2:     ${HY2:-未设置}"
  echo "vless-reality: ${REALITY:-未设置}"
}
case "$1" in
  token)
    grep -oP '(?<=AGENT_TOKEN=)[^\s]+' "$SERVICE_FILE"
    ;;
  status)
    systemctl status v2panel-agent --no-pager
    ;;
  start)
    systemctl start v2panel-agent && echo "Started"
    ;;
  stop)
    systemctl stop v2panel-agent && echo "Stopped"
    ;;
  restart)
    systemctl restart v2panel-agent && echo "Restarted"
    ;;
  log)
    journalctl -u v2panel-agent -f --no-pager
    ;;
  ip)
    curl -s ifconfig.me
    echo
    ;;
  port)
    if [ -z "$2" ]; then
      grep -oP '(?<=AGENT_PORT=)\d+' "$SERVICE_FILE"
    else
      sed -i "s/AGENT_PORT=[0-9]*/AGENT_PORT=$2/" "$SERVICE_FILE"
      systemctl daemon-reload
      systemctl restart v2panel-agent
      echo "Port changed to $2, agent restarted"
      echo "Agent URL: http://$(curl -s ifconfig.me 2>/dev/null):$2"
    fi
    ;;
  token-reset)
    NEW_TOKEN=$(openssl rand -hex 32)
    sed -i "s/AGENT_TOKEN=.*/AGENT_TOKEN=${NEW_TOKEN}/" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart v2panel-agent
    echo "New token: ${NEW_TOKEN}"
    ;;
  info)
    TOKEN=$(grep -oP '(?<=AGENT_TOKEN=)[^\s]+' "$SERVICE_FILE")
    PORT=$(grep -oP '(?<=AGENT_PORT=)\d+' "$SERVICE_FILE")
    BACKEND=$(get_env BACKEND_URL); BACKEND=${BACKEND:-未设置}
    IP=$(curl -s ifconfig.me 2>/dev/null)
    echo "Agent URL:  http://${IP}:${PORT}"
    echo "Token:      ${TOKEN}"
    echo "Backend:    ${BACKEND}"
    echo "Node IDs:"
    show_node_ids | sed 's/^/  /'
    echo "Status:     $(systemctl is-active v2panel-agent)"
    echo "Protocols:  vmess, hysteria2, vless-reality"
    ;;
  hy2-stats-secret)
    grep -oP '(?<=HY2_STATS_SECRET=)[^\s]+' "$SERVICE_FILE"
    ;;
  backend)
    if [ -z "$2" ]; then
      VALUE=$(get_env BACKEND_URL); echo "${VALUE:-未设置}"
    else
      set_env BACKEND_URL "$2"
      systemctl daemon-reload && systemctl restart v2panel-agent
      echo "Backend set to: $2"
    fi
    ;;
  node-id)
    if [ -z "$2" ]; then
      show_node_ids
    elif [ -z "$3" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
      set_env VMESS_NODE_ID "$2"
      systemctl daemon-reload && systemctl restart v2panel-agent
      echo "vmess Node ID set to: $2"
    else
      if ! [[ "$3" =~ ^[0-9]+$ ]]; then
        echo "Node ID must be a non-negative integer"
        exit 1
      fi
      case "$2" in
        vmess) ENV_KEY=VMESS_NODE_ID ;;
        hysteria2|hy2) ENV_KEY=HY2_NODE_ID ;;
        vless-reality|reality) ENV_KEY=REALITY_NODE_ID ;;
        *) echo "Protocol must be vmess, hysteria2, or vless-reality"; exit 1 ;;
      esac
      set_env "$ENV_KEY" "$3"
      systemctl daemon-reload && systemctl restart v2panel-agent
      echo "$2 Node ID set to: $3"
    fi
    ;;
  *)
    echo "v2panel commands:"
    echo "  info              — Agent URL + Token + Backend + 状态"
    echo "  token             — 显示 Token"
    echo "  token-reset       — 重置 Token"
    echo "  port              — 查看当前端口"
    echo "  port N            — 修改端口为 N"
    echo "  backend           — 查看管理后台地址"
    echo "  backend <URL>     — 设置管理后台地址"
    echo "  node-id                         — 查看各协议节点 ID"
    echo "  node-id <protocol> <N>          — 设置协议节点 ID"
    echo "  node-id <N>                     — 设置 VMess 节点 ID（兼容）"
    echo "  hy2-stats-secret  — 显示 HY2 流量 API Secret"
    echo "  status            — systemd 服务状态"
    echo "  start             — 启动"
    echo "  stop              — 停止"
    echo "  restart           — 重启"
    echo "  log               — 实时日志 (Ctrl+C 退出)"
    echo "  ip                — 显示公网 IP"
    ;;
esac
CLIPEOF
chmod +x "$CLI_FILE"
echo -e "${GREEN}✓ v2panel CLI installed${NC}"

# Summary
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  V2Panel Agent installed successfully!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "  Agent URL:  ${YELLOW}http://$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):9191${NC}"
echo -e "  Token:      ${YELLOW}${AGENT_TOKEN}${NC}"
echo ""
echo -e "  Commands:"
echo -e "    ${CYAN}v2panel info${NC}                   — 查看全部配置"
echo -e "    ${CYAN}v2panel backend <URL>${NC}           — 设置管理后台地址"
echo -e "    ${CYAN}v2panel node-id <protocol> <N>${NC}  — 设置协议节点 ID"
echo -e "    ${CYAN}v2panel hy2-stats-secret${NC}         — 显示 HY2 流量 API Secret"
echo -e "    ${CYAN}v2panel port [N]${NC}                — 查看/修改端口"
echo -e "    ${CYAN}v2panel token${NC}  ${CYAN}token-reset${NC}    — 查看/重置 Token"
echo -e "    ${CYAN}v2panel start${NC}  ${CYAN}stop${NC}  ${CYAN}restart${NC}   — 服务控制"
echo -e "    ${CYAN}v2panel log${NC}                     — 实时日志"
echo -e "${CYAN}========================================${NC}"
