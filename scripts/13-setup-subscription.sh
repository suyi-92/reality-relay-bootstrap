#!/usr/bin/env bash
# 可选订阅端口：用 python3 -m http.server 服务专用目录里的客户端配置文件。
set -Eeuo pipefail
PHASE_NAME="subscription"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

SERVICE_NAME="reality-relay-subscription"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "$ENABLE_SUBSCRIPTION_SERVER" != "true" ]]; then
  info "ENABLE_SUBSCRIPTION_SERVER=false，跳过订阅服务。"
  if ! is_dry_run && systemctl list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
    info "已停用订阅服务：$SERVICE_NAME"
  fi
  exit 0
fi

apt_install python3

if is_dry_run; then
  log "DRY-RUN: mkdir -p $SUBSCRIPTION_DIR"
  log "DRY-RUN: generate subscription files into $SUBSCRIPTION_DIR"
else
  mkdir -p "$SUBSCRIPTION_DIR"
  chmod 700 "$SUBSCRIPTION_DIR"
  python3 "$SCRIPT_DIR/11-output-nodes.py" \
    --config-env "$RRB_CONFIG_FILE" \
    --generator "$SCRIPT_DIR/08-generate-singbox-config.py" \
    --nodes-out "$SUBSCRIPTION_DIR/nodes.txt" \
    --clash-out "$SUBSCRIPTION_DIR/clash.yaml"
  printf 'subscription files are direct links only\n' > "$SUBSCRIPTION_DIR/index.html"
  chmod 600 "$SUBSCRIPTION_DIR/nodes.txt" "$SUBSCRIPTION_DIR/clash.yaml"
  chmod 644 "$SUBSCRIPTION_DIR/index.html"
fi

if is_dry_run; then
  log "DRY-RUN: write $SERVICE_FILE and systemctl enable --now $SERVICE_NAME"
else
  cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Reality Relay Bootstrap subscription file server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SUBSCRIPTION_DIR
ExecStart=/usr/bin/python3 -m http.server $SUBSCRIPTION_PORT --bind 0.0.0.0 --directory $SUBSCRIPTION_DIR
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >>"$LOG_FILE" 2>&1
  systemctl restart "$SERVICE_NAME" >>"$LOG_FILE" 2>&1
fi

cat <<EOF

订阅服务已配置：

  Clash/Mihomo:  http://${SERVER_IP:-服务器IP}:$SUBSCRIPTION_PORT/clash.yaml
  节点文本:      http://${SERVER_IP:-服务器IP}:$SUBSCRIPTION_PORT/nodes.txt

请确认 UFW 和服务商安全组放行 tcp/$SUBSCRIPTION_PORT。
EOF
