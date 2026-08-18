# V2Panel Agent

One-line installer for the [V2Panel](https://github.com/mrpompy/v2ray-panel) multi-protocol node agent.

Supported drivers: VMess, Hysteria2 HTTP Auth, and VLESS REALITY.

## Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/mrpompy/v2panel-releases/main/install.sh)
```

## Commands after install

```bash
v2panel info              # URL, token, status, and protocols
v2panel token             # show agent token
v2panel hy2-stats-secret  # show Hysteria2 traffic API secret
v2panel backend <URL>     # set panel URL for traffic reports
v2panel node-id           # show all protocol node IDs
v2panel node-id hysteria2 <N>
v2panel node-id vless-reality <N>
v2panel status            # service status
v2panel log               # live logs
v2panel restart           # restart agent
v2panel ip                # show server public IP
```

The installer keeps the existing Agent Token and Hysteria2 stats secret on upgrades. Hysteria2 still needs to be manually switched to HTTP Auth after panel users have been synchronized; see the main repository's `docs/hy2-reality-agent.md`.
