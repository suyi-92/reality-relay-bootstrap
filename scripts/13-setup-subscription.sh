#!/usr/bin/env bash
# 可选订阅端口：按已填写的服务器地址生成一份 token 保护的订阅。
set -Eeuo pipefail
PHASE_NAME="subscription"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

SERVICE_NAME="reality-relay-subscription"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVER_INSTALL_DIR="/usr/local/lib/reality-relay-bootstrap"
SERVER_INSTALL_PATH="$SERVER_INSTALL_DIR/subscription-server.py"

subscription_target_file() {
  case "$SUBSCRIPTION_TARGET" in
    ClashMeta) printf 'clashmeta.yaml\n' ;;
    *) die "SUBSCRIPTION_TARGET 不支持：$SUBSCRIPTION_TARGET" ;;
  esac
}

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
  mkdir -p "$SUBSCRIPTION_DIR/all" "$SERVER_INSTALL_DIR"
  chmod 700 "$SUBSCRIPTION_DIR" "$SUBSCRIPTION_DIR/all"
  install -m 0755 -o root -g root "$SCRIPT_DIR/13-subscription-server.py" "$SERVER_INSTALL_PATH"

  rm -f "$SUBSCRIPTION_DIR/all/"*.yaml "$SUBSCRIPTION_DIR/all/"*.txt

  target_file="$(subscription_target_file)"
  args=(
    python3 "$SCRIPT_DIR/11-output-nodes.py"
    --config-env "$RRB_CONFIG_FILE"
    --generator "$SCRIPT_DIR/08-generate-singbox-config.py"
    --nodes-out "$SUBSCRIPTION_DIR/all/nodes.txt"
    --clash-out "$SUBSCRIPTION_DIR/all/clash.yaml"
    --subscription-target "$SUBSCRIPTION_TARGET"
    --subscription-out "$SUBSCRIPTION_DIR/all/$target_file"
    --skip-node-files
    --quiet
  )
  if [[ -n "$SERVER_IP_IPV4" && -n "$SERVER_IP_IPV6" ]]; then
    args+=(
      --server-override "$SERVER_IP_IPV4"
      --extra-server "$SERVER_IP_IPV6"
      --extra-name-suffix=-IPv6
      --clash-ipv6 true
    )
  elif [[ -n "$SERVER_IP_IPV4" ]]; then
    args+=(--server-override "$SERVER_IP_IPV4" --clash-ipv6 false)
  elif [[ -n "$SERVER_IP_IPV6" ]]; then
    args+=(--server-override "$SERVER_IP_IPV6" --name-suffix=-IPv6 --clash-ipv6 true)
  else
    die "SERVER_IP_IPV4 和 SERVER_IP_IPV6 至少需要填写一个。"
  fi
  "${args[@]}"
  chmod 600 "$SUBSCRIPTION_DIR/all/"*
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
ExecStart=/usr/bin/python3 $SERVER_INSTALL_PATH --root $SUBSCRIPTION_DIR --port $SUBSCRIPTION_PORT --ipv4 $([[ -n "$SERVER_IP_IPV4" ]] && echo true || echo false) --ipv6 $([[ -n "$SERVER_IP_IPV6" ]] && echo true || echo false) --token-file $VLESS_UUID_PATH --default-target $SUBSCRIPTION_TARGET
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

token="$(subscription_token)"
target_label="$(subscription_target_label "$SUBSCRIPTION_TARGET")"
target_path="/sub/${token}?target=ClashMeta"

cat <<EOF

订阅服务已配置：

$(if [[ -n "${SUBSCRIPTION_BASE_URL:-}" ]]; then
  base="${SUBSCRIPTION_BASE_URL%/}"
  printf '  %s:  %s%s\n' "$target_label" "$base" "$target_path"
elif [[ -n "$(server_ipv4_hosts)" ]]; then
  printf 'IPv4:\n'
  for host in $(server_ipv4_hosts); do
    h="$(url_host "$host")"
    printf '  %s:  http://%s:%s%s\n' "$target_label" "$h" "$SUBSCRIPTION_PORT" "$target_path"
  done
fi)
$(if [[ -z "${SUBSCRIPTION_BASE_URL:-}" && -n "$(server_ipv6_hosts)" ]]; then
  printf '\nIPv6:\n'
  for host in $(server_ipv6_hosts); do
    h="$(url_host "$host")"
    printf '  %s:  http://%s:%s%s\n' "$target_label" "$h" "$SUBSCRIPTION_PORT" "$target_path"
  done
fi)

说明：订阅内容按 SERVER_IP_IPV4/SERVER_IP_IPV6 生成；如果两者都填写，IPv4/IPv6 链接都返回同一份完整节点，IPv6 节点名称追加 -IPv6。
如客户端无法导入 IPv6 字面量订阅地址，有 IPv4 时直接使用 IPv4 订阅地址即可。
内置订阅服务是 HTTP；如需 HTTPS，请在外层接入带证书的反向代理。

请确认 UFW 和服务商安全组放行 tcp/$SUBSCRIPTION_PORT。
EOF
