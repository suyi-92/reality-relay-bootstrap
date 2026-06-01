#!/usr/bin/env bash
# 可选订阅端口：IPv4 入口返回 IPv4 节点，IPv6 入口返回双栈节点。
set -Eeuo pipefail
PHASE_NAME="subscription"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

SERVICE_NAME="reality-relay-subscription"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVER_INSTALL_DIR="/usr/local/lib/reality-relay-bootstrap"
SERVER_INSTALL_PATH="$SERVER_INSTALL_DIR/subscription-server.py"

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
  mkdir -p "$SUBSCRIPTION_DIR/ipv4" "$SUBSCRIPTION_DIR/dual" "$SERVER_INSTALL_DIR"
  chmod 700 "$SUBSCRIPTION_DIR" "$SUBSCRIPTION_DIR/ipv4" "$SUBSCRIPTION_DIR/dual"
  install -m 0755 -o root -g root "$SCRIPT_DIR/13-subscription-server.py" "$SERVER_INSTALL_PATH"
  if [[ -n "$SERVER_IP_IPV4" ]]; then
    python3 "$SCRIPT_DIR/11-output-nodes.py" \
      --config-env "$RRB_CONFIG_FILE" \
      --generator "$SCRIPT_DIR/08-generate-singbox-config.py" \
      --server-override "$SERVER_IP_IPV4" \
      --clash-ipv6 false \
      --nodes-out "$SUBSCRIPTION_DIR/ipv4/nodes.txt" \
      --clash-out "$SUBSCRIPTION_DIR/ipv4/clash.yaml"
    chmod 600 "$SUBSCRIPTION_DIR/ipv4/nodes.txt" "$SUBSCRIPTION_DIR/ipv4/clash.yaml"
  fi
  if [[ -n "$SERVER_IP_IPV6" ]]; then
    if [[ -n "$SERVER_IP_IPV4" ]]; then
      python3 "$SCRIPT_DIR/11-output-nodes.py" \
        --config-env "$RRB_CONFIG_FILE" \
        --generator "$SCRIPT_DIR/08-generate-singbox-config.py" \
        --server-override "$SERVER_IP_IPV4" \
        --name-suffix " IPv4" \
        --extra-server "$SERVER_IP_IPV6" \
        --extra-name-suffix " IPv6" \
        --clash-ipv6 true \
        --nodes-out "$SUBSCRIPTION_DIR/dual/nodes.txt" \
        --clash-out "$SUBSCRIPTION_DIR/dual/clash.yaml"
    else
      python3 "$SCRIPT_DIR/11-output-nodes.py" \
        --config-env "$RRB_CONFIG_FILE" \
        --generator "$SCRIPT_DIR/08-generate-singbox-config.py" \
        --server-override "$SERVER_IP_IPV6" \
        --clash-ipv6 true \
        --nodes-out "$SUBSCRIPTION_DIR/dual/nodes.txt" \
        --clash-out "$SUBSCRIPTION_DIR/dual/clash.yaml"
    fi
    chmod 600 "$SUBSCRIPTION_DIR/dual/nodes.txt" "$SUBSCRIPTION_DIR/dual/clash.yaml"
  fi
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
ExecStart=/usr/bin/python3 $SERVER_INSTALL_PATH --root $SUBSCRIPTION_DIR --port $SUBSCRIPTION_PORT --ipv4 $([[ -n "$SERVER_IP_IPV4" ]] && echo true || echo false) --ipv6 $([[ -n "$SERVER_IP_IPV6" ]] && echo true || echo false)
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

$(if [[ -n "$(server_ipv4_hosts)" ]]; then
  printf 'IPv4:\n'
  for host in $(server_ipv4_hosts); do
    h="$(url_host "$host")"
    printf '  Clash/Mihomo:  http://%s:%s/clash.yaml\n' "$h" "$SUBSCRIPTION_PORT"
    printf '  节点文本:      http://%s:%s/nodes.txt\n' "$h" "$SUBSCRIPTION_PORT"
  done
  printf '\n'
fi)
$(if [[ -n "$(server_ipv6_hosts)" ]]; then
  printf 'IPv6:\n'
  for host in $(server_ipv6_hosts); do
    h="$(url_host "$host")"
    printf '  Clash/Mihomo:  http://%s:%s/clash.yaml\n' "$h" "$SUBSCRIPTION_PORT"
    printf '  节点文本:      http://%s:%s/nodes.txt\n' "$h" "$SUBSCRIPTION_PORT"
  done
  printf '\n'
fi)
说明：IPv4 订阅只返回 IPv4 节点；IPv6 订阅返回 IPv4 + IPv6 双栈节点。

请确认 UFW 和服务商安全组放行 tcp/$SUBSCRIPTION_PORT。
EOF
