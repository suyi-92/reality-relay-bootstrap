#!/usr/bin/env bash
# 安装并配置 fail2ban 的 sshd jail。
set -Eeuo pipefail
PHASE_NAME="fail2ban"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
  info "ENABLE_FAIL2BAN=false，跳过 fail2ban。"
  exit 0
fi

backup_path /etc/fail2ban || true
apt_install fail2ban

if is_dry_run; then
  log "DRY-RUN: mkdir -p /etc/fail2ban/jail.d"
else
  mkdir -p /etc/fail2ban/jail.d
fi
write_root_file /etc/fail2ban/jail.d/sshd.local 0644 <<EOF
# Managed by reality-relay-bootstrap.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
backend = systemd
usedns = no

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

if ! is_dry_run; then
  fail2ban-client -t 2>&1 | tee -a "$LOG_FILE"
  systemctl enable --now fail2ban 2>&1 | tee -a "$LOG_FILE"
  systemctl restart fail2ban 2>&1 | tee -a "$LOG_FILE"
  systemctl status fail2ban --no-pager 2>&1 | tee -a "$LOG_FILE" || true
  fail2ban-client status 2>&1 | tee -a "$LOG_FILE" || true
  fail2ban-client status sshd 2>&1 | tee -a "$LOG_FILE" || true
else
  log "DRY-RUN: fail2ban-client -t && systemctl restart fail2ban"
fi
