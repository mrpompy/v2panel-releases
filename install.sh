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
fi

if [ -z "$AGENT_TOKEN" ]; then
  AGENT_TOKEN=$(openssl rand -hex 32)
  echo -e "${GREEN}✓ Generated new token${NC}"
fi

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
Environment=AGENT_PORT=9191
Environment=V2RAY_CONFIG=${V2RAY_CONFIG}
Environment=HY2_AUTH_ADDR=127.0.0.1:9192
Environment=HY2_USER_STORE=${STATE_DIR}/hysteria2-users.json
Environment=HY2_STATS_URL=http://127.0.0.1:9999
Environment=HY2_STATS_SECRET=${HY2_STATS_SECRET}
Environment=XRAY_CONFIG=/usr/local/etc/xray/config.json
Environment=XRAY_SERVICE=xray
Environment=XRAY_BINARY=/usr/local/bin/xray
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
    BACKEND=$(grep -oP '(?<=BACKEND_URL=)[^\s]+' "$SERVICE_FILE" 2>/dev/null || echo "未设置")
    NODE_ID=$(grep -oP '(?<=NODE_ID=)[^\s]+' "$SERVICE_FILE" 2>/dev/null || echo "未设置")
    IP=$(curl -s ifconfig.me 2>/dev/null)
    echo "Agent URL:  http://${IP}:${PORT}"
    echo "Token:      ${TOKEN}"
    echo "Backend:    ${BACKEND}"
    echo "Node ID:    ${NODE_ID}"
    echo "Status:     $(systemctl is-active v2panel-agent)"
    echo "Protocols:  vmess, hysteria2, vless-reality"
    ;;
  hy2-stats-secret)
    grep -oP '(?<=HY2_STATS_SECRET=)[^\s]+' "$SERVICE_FILE"
    ;;
  backend)
    if [ -z "$2" ]; then
      grep -oP '(?<=BACKEND_URL=)[^\s]+' "$SERVICE_FILE" 2>/dev/null || echo "未设置"
    else
      # Remove existing BACKEND_URL line if present, then add new one
      sed -i '/^Environment=BACKEND_URL=/d' "$SERVICE_FILE"
      sed -i "/^\[Service\]/a Environment=BACKEND_URL=$2" "$SERVICE_FILE"
      systemctl daemon-reload && systemctl restart v2panel-agent
      echo "Backend set to: $2"
    fi
    ;;
  node-id)
    if [ -z "$2" ]; then
      grep -oP '(?<=NODE_ID=)[^\s]+' "$SERVICE_FILE" 2>/dev/null || echo "未设置"
    else
      sed -i '/^Environment=NODE_ID=/d' "$SERVICE_FILE"
      sed -i "/^\[Service\]/a Environment=NODE_ID=$2" "$SERVICE_FILE"
      systemctl daemon-reload && systemctl restart v2panel-agent
      echo "Node ID set to: $2"
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
    echo "  node-id           — 查看节点 ID"
    echo "  node-id <N>       — 设置节点 ID"
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
echo -e "    ${CYAN}v2panel node-id <N>${NC}             — 设置节点 ID"
echo -e "    ${CYAN}v2panel hy2-stats-secret${NC}         — 显示 HY2 流量 API Secret"
echo -e "    ${CYAN}v2panel port [N]${NC}                — 查看/修改端口"
echo -e "    ${CYAN}v2panel token${NC}  ${CYAN}token-reset${NC}    — 查看/重置 Token"
echo -e "    ${CYAN}v2panel start${NC}  ${CYAN}stop${NC}  ${CYAN}restart${NC}   — 服务控制"
echo -e "    ${CYAN}v2panel log${NC}                     — 实时日志"
echo -e "${CYAN}========================================${NC}"
