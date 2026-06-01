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

请保留当前 SSH 窗口，另开一个新的 Windows PowerShell 测试 admin key 登录：
$(for host in $(server_hosts); do
  printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
done)

登录成功后在新窗口执行：
  whoami
  sudo whoami

确认输出为：
  $ADMIN_USER
  root

确认后再执行最终加固：
  sudo CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
EOF
