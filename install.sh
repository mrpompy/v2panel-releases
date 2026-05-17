#!/bin/bash
set -e

REPO="mrpompy/v2panel-releases"
BIN_NAME="v2panel-agent"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/v2panel-agent.service"
CLI_FILE="/usr/local/bin/v2panel"

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
    IP=$(curl -s ifconfig.me 2>/dev/null)
    echo "Agent URL:  http://${IP}:${PORT}"
    echo "Token:      ${TOKEN}"
    echo "Status:     $(systemctl is-active v2panel-agent)"
    ;;
  *)
    echo "Usage: v2panel {info|token|token-reset|port [N]|status|start|stop|restart|log|ip}"
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
echo -e "    ${CYAN}v2panel info${NC}         — Agent URL + Token + 状态"
echo -e "    ${CYAN}v2panel token${NC}        — 显示 Token"
echo -e "    ${CYAN}v2panel token-reset${NC}  — 重置 Token"
echo -e "    ${CYAN}v2panel port${NC}         — 查看当前端口"
echo -e "    ${CYAN}v2panel port 9292${NC}    — 修改端口"
echo -e "    ${CYAN}v2panel status${NC}       — 服务状态"
echo -e "    ${CYAN}v2panel start${NC}        — 启动"
echo -e "    ${CYAN}v2panel stop${NC}         — 停止"
echo -e "    ${CYAN}v2panel restart${NC}      — 重启"
echo -e "    ${CYAN}v2panel log${NC}          — 实时日志"
echo -e "    ${CYAN}v2panel ip${NC}           — 公网 IP"
echo -e "${CYAN}========================================${NC}"
