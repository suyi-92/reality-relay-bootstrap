#!/usr/bin/env bash
# 可选自有域名：Cloudflare DNS-01 证书 + 本机 Nginx TLS fallback。
set -Eeuo pipefail
PHASE_NAME="custom-domain"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if ! custom_domain_enabled; then
  info "ENABLE_CUSTOM_DOMAIN=false，跳过自有域名和 Nginx fallback 配置。"
  exit 0
fi

apt_install ca-certificates curl nginx certbot python3-certbot-dns-cloudflare openssl

backup_path "$CLOUDFLARE_API_TOKEN_FILE" || true
backup_path "$NGINX_FALLBACK_CONF" || true
backup_path /etc/nginx/nginx.conf || true
[[ -d /etc/nginx/sites-enabled ]] && backup_path /etc/nginx/sites-enabled || true

ensure_cloudflare_credentials() {
  local dir
  dir="$(dirname "$CLOUDFLARE_API_TOKEN_FILE")"
  if is_dry_run; then
    if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
      log "DRY-RUN: write Cloudflare DNS API token credentials to $CLOUDFLARE_API_TOKEN_FILE"
    else
      log "DRY-RUN: use existing Cloudflare credentials file $CLOUDFLARE_API_TOKEN_FILE"
    fi
    return 0
  fi

  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
    umask 077
    printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" >"$CLOUDFLARE_API_TOKEN_FILE"
  fi
  [[ -s "$CLOUDFLARE_API_TOKEN_FILE" ]] || die "找不到 Cloudflare credentials：请设置 CLOUDFLARE_API_TOKEN 或准备 $CLOUDFLARE_API_TOKEN_FILE"
  chmod 600 "$CLOUDFLARE_API_TOKEN_FILE"
}

request_certificate() {
  local certbot_args
  certbot_args=(
    certonly
    --non-interactive
    --agree-tos
    --email "$LE_EMAIL"
    --dns-cloudflare
    --dns-cloudflare-credentials "$CLOUDFLARE_API_TOKEN_FILE"
    --dns-cloudflare-propagation-seconds "$CLOUDFLARE_DNS_PROPAGATION_SECONDS"
    --cert-name "$CUSTOM_DOMAIN"
    -d "$CUSTOM_DOMAIN"
    --keep-until-expiring
  )
  if [[ "$LE_STAGING" == "true" ]]; then
    certbot_args+=(--staging)
  fi
  run certbot "${certbot_args[@]}"
}

write_fallback_site() {
  run mkdir -p "$NGINX_FALLBACK_ROOT"
  write_root_file "$NGINX_FALLBACK_ROOT/index.html" 0644 <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Digital Notes</title>
  <style>
    body {
      max-width: 760px;
      margin: 60px auto;
      padding: 0 20px;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.6;
      color: #222;
    }

    h1 {
      font-size: 32px;
    }

    .muted {
      color: #666;
    }
  </style>
</head>
<body>
  <main>
    <h1>Digital Notes</h1>
    <p class="muted">A small collection of technical notes, references, and project updates.</p>

    <h2>About</h2>
    <p>This site hosts lightweight static pages and public notes.</p>

    <h2>Status</h2>
    <p>All services are running normally.</p>
  </main>
</body>
</html>
EOF

  write_root_file "$NGINX_FALLBACK_ROOT/robots.txt" 0644 <<'EOF'
User-agent: *
Allow: /
EOF

  write_root_file "$NGINX_FALLBACK_ROOT/favicon.ico" 0644 <<'EOF'
EOF
}

write_nginx_site() {
  local conf_dir subscription_block enabled_name
  conf_dir="$(dirname "$NGINX_FALLBACK_CONF")"
  run mkdir -p "$conf_dir"

  subscription_block=""
  if [[ "$ENABLE_SUBSCRIPTION_SERVER" == "true" ]]; then
    subscription_block="$(cat <<EOF

  location /sub/ {
    proxy_pass http://127.0.0.1:$SUBSCRIPTION_LISTEN_PORT;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
EOF
)"
  fi

  write_root_file "$NGINX_FALLBACK_CONF" 0644 <<EOF
# Managed by reality-relay-bootstrap.
# Public tcp/443 is handled by sing-box Reality; ordinary TLS is forwarded here.
server {
  listen $NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT ssl http2;
  server_name $CUSTOM_DOMAIN;

  ssl_certificate /etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$CUSTOM_DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:RRBFallbackSSL:10m;
  ssl_session_timeout 1d;

  root $NGINX_FALLBACK_ROOT;
  index index.html;

  location = /healthz {
    access_log off;
    default_type text/plain;
    return 200 "ok\n";
  }
$subscription_block

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
EOF

  if [[ -d /etc/nginx/sites-enabled ]]; then
    enabled_name="/etc/nginx/sites-enabled/$(basename "$NGINX_FALLBACK_CONF")"
    if is_dry_run; then
      log "DRY-RUN: ln -sf $NGINX_FALLBACK_CONF $enabled_name"
    else
      ln -sf "$NGINX_FALLBACK_CONF" "$enabled_name"
    fi
  fi
}

write_renew_hook() {
  local hook="/etc/letsencrypt/renewal-hooks/deploy/reality-relay-bootstrap-nginx.sh"
  run mkdir -p "$(dirname "$hook")"
  write_root_file "$hook" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
EOF
}

reload_nginx() {
  run nginx -t
  if is_dry_run; then
    log "DRY-RUN: systemctl enable nginx && systemctl reload nginx || systemctl restart nginx"
  else
    systemctl enable nginx >>"$LOG_FILE" 2>&1 || true
    systemctl reload nginx >>"$LOG_FILE" 2>&1 || systemctl restart nginx >>"$LOG_FILE" 2>&1
    systemctl is-active --quiet nginx && info "Nginx fallback 已运行：$NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT" || die "Nginx 未运行"
  fi
}

verify_fallback() {
  local resolve_arg base_url body robots health
  if is_dry_run; then
    log "DRY-RUN: verify local Nginx fallback TLS on $NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT"
    log "DRY-RUN: verify fallback site content through https://$CUSTOM_DOMAIN:$NGINX_FALLBACK_PORT/"
    return 0
  fi
  wait_for_port_listener "$NGINX_FALLBACK_PORT" 15 || die "Nginx fallback 未监听端口：$NGINX_FALLBACK_PORT"
  timeout 10 openssl s_client -brief -connect "$NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT" -servername "$CUSTOM_DOMAIN" </dev/null >>"$LOG_FILE" 2>&1 \
    || die "本机 Nginx fallback TLS 验证失败：$NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT"

  resolve_arg="$CUSTOM_DOMAIN:$NGINX_FALLBACK_PORT:$NGINX_FALLBACK_HOST"
  base_url="https://$CUSTOM_DOMAIN:$NGINX_FALLBACK_PORT"

  body="$(timeout 10 curl --noproxy '*' -fsS --resolve "$resolve_arg" "$base_url/" 2>>"$LOG_FILE" || true)"
  [[ "$body" == *"<title>Digital Notes</title>"* ]] || die "Nginx fallback 首页内容验证失败：$base_url/"

  robots="$(timeout 10 curl --noproxy '*' -fsS --resolve "$resolve_arg" "$base_url/robots.txt" 2>>"$LOG_FILE" || true)"
  [[ "$robots" == *"User-agent: *"* && "$robots" == *"Allow: /"* ]] || die "Nginx fallback robots.txt 验证失败：$base_url/robots.txt"

  health="$(timeout 10 curl --noproxy '*' -fsS --resolve "$resolve_arg" "$base_url/healthz" 2>>"$LOG_FILE" || true)"
  [[ "$health" == "ok" ]] || die "Nginx fallback healthz 验证失败：$base_url/healthz"

  info "Nginx fallback 静态站点正常：$base_url/"
}

ensure_cloudflare_credentials
request_certificate
write_fallback_site
write_nginx_site
write_renew_hook
reload_nginx
verify_fallback

cat <<EOF

自有域名 fallback 已配置：

  DNS:      Cloudflare DNS 灰云，$CUSTOM_DOMAIN 指向本机公网 IP
  Public:   tcp/443 -> sing-box Reality
  Fallback: $NGINX_FALLBACK_HOST:$NGINX_FALLBACK_PORT -> Nginx TLS
  Cert:     /etc/letsencrypt/live/$CUSTOM_DOMAIN/fullchain.pem

请确认 Cloudflare 记录为 DNS only / 灰云，服务商安全组放行 tcp/443。
EOF
