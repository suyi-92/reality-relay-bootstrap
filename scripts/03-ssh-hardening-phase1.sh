#!/usr/bin/env bash
# SSH Phase1：只保证公钥登录开启；绝不禁 root/密码。
set -Eeuo pipefail
PHASE_NAME="ssh-phase1"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

backup_path /etc/ssh/sshd_config
[[ -d /etc/ssh/sshd_config.d ]] && backup_path /etc/ssh/sshd_config.d
ensure_sshd_dropin_include

if [[ -f /etc/ssh/sshd_config.d/00-reality-relay-bootstrap-hardening.conf ]]; then
  if is_dry_run; then
    log "DRY-RUN: remove old final hardening drop-in before phase1"
  else
    rm -f /etc/ssh/sshd_config.d/00-reality-relay-bootstrap-hardening.conf
  fi
fi

write_root_file /etc/ssh/sshd_config.d/00-reality-relay-bootstrap-phase1.conf 0644 <<'EOF'
# Managed by reality-relay-bootstrap phase1.
# Phase1 only enables public key authentication. It intentionally does NOT
# disable root login or password login. Final hardening is a separate phase.
PubkeyAuthentication yes
EOF

test_sshd_config
reload_ssh

cat <<EOF

SSH phase1 已完成；当前仍未禁用 root/密码登录。

请保留当前 SSH 窗口，另开一个新的 Windows PowerShell 测试 root key 登录：
$(if [[ -n "$(server_ipv4_hosts)" ]]; then
  printf 'IPv4:\n'
  for host in $(server_ipv4_hosts); do
    printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
  done
  printf '\n'
fi)
$(if [[ -n "$(server_ipv6_hosts)" ]]; then
  printf '\nIPv6:\n'
  for host in $(server_ipv6_hosts); do
    printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
  done
  printf '\n'
fi)
$(if [[ -z "$(server_ipv4_hosts)" && -z "$(server_ipv6_hosts)" ]]; then
  for host in $(server_hosts); do
    printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
  done
  printf '\n'
fi)

登录成功后在新窗口执行：
  whoami

确认输出为：
  root

确认后再执行最终加固：
  sudo CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
EOF
