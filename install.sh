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

# Get latest release URL
echo -e "${CYAN}==> Fetching latest release...${NC}"
DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep "browser_download_url.*${BIN_NAME}" \
  | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
  echo "ERROR: Could not find release binary. Check https://github.com/${REPO}/releases"
  exit 1
fi

echo -e "${CYAN}==> Downloading from: ${DOWNLOAD_URL}${NC}"
curl -L "$DOWNLOAD_URL" -o "${INSTALL_DIR}/v2panel-agent"
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
Environment=AGENT_PORT=9090
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
  *)
    echo "Usage: v2panel {token|status|start|stop|restart|log|ip}"
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
echo -e "  Agent URL:  ${YELLOW}http://$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):9090${NC}"
echo -e "  Token:      ${YELLOW}${AGENT_TOKEN}${NC}"
echo ""
echo -e "  Commands:"
echo -e "    ${CYAN}v2panel token${NC}    — show token"
echo -e "    ${CYAN}v2panel status${NC}   — service status"
echo -e "    ${CYAN}v2panel log${NC}      — live logs"
echo -e "    ${CYAN}v2panel restart${NC}  — restart agent"
echo -e "${CYAN}========================================${NC}"
