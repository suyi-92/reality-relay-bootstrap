#!/usr/bin/env bash
# 创建 admin 管理用户和可选 SFTP-only 用户，安装 SSH 公钥。
set -Eeuo pipefail
PHASE_NAME="create-admin"
source "${OBS_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

backup_path /etc/sudoers.d || true
apt_install sudo openssh-server

get_pubkey_for_admin() {
  if [[ -n "$ADMIN_PUBKEY" ]]; then
    printf '%s\n' "$ADMIN_PUBKEY"
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    cat /root/.ssh/authorized_keys
  else
    return 1
  fi
}

validate_pubkey_text() {
  local key_file="$1"
  awk 'NF && $1 !~ /^#/ { if ($1 !~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/) exit 1 }' "$key_file"
}

create_user_if_needed() {
  local user="$1" shell="$2"
  if id "$user" >/dev/null 2>&1; then
    info "用户已存在：$user"
    run usermod -s "$shell" "$user"
  else
    run useradd -m -s "$shell" "$user"
  fi
}

install_authorized_keys() {
  local user="$1" key_text="$2"
  local home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || die "无法获取 $user 的 home"
  if is_dry_run; then
    log "DRY-RUN: install authorized_keys for $user"
    return 0
  fi
  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$key_text" | awk 'NF && $1 !~ /^#/' > "$tmp"
  validate_pubkey_text "$tmp" || { rm -f "$tmp"; die "$user 的 SSH 公钥格式不正确"; }
  touch "$home/.ssh/authorized_keys"
  chown "$user:$user" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qxF "$line" "$home/.ssh/authorized_keys" || printf '%s\n' "$line" >> "$home/.ssh/authorized_keys"
  done < "$tmp"
  rm -f "$tmp"
  chown -R "$user:$user" "$home/.ssh"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"
  chmod go-w "$home" || true
}

admin_keys="$(get_pubkey_for_admin || true)"
[[ -n "$admin_keys" ]] || die "没有可用 ADMIN_PUBKEY，也无法从 /root/.ssh/authorized_keys 复制。"

create_user_if_needed "$ADMIN_USER" /bin/bash
run usermod -aG sudo "$ADMIN_USER"
run passwd -l "$ADMIN_USER" || true
install_authorized_keys "$ADMIN_USER" "$admin_keys"

if [[ "$ADMIN_SUDO_NOPASSWD" == "true" ]]; then
  write_root_file "/etc/sudoers.d/90-our-${ADMIN_USER}" 0440 <<EOF
# Managed by our-server-bootstrap. Admin password is locked; sudo uses key-protected SSH login.
${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  if ! is_dry_run; then
    visudo -cf "/etc/sudoers.d/90-our-${ADMIN_USER}" >/dev/null
  fi
fi

if [[ "$ENABLE_SFTP_USER" == "true" ]]; then
  NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"
  sftp_keys="${SFTP_PUBKEY:-$admin_keys}"
  create_user_if_needed "$SFTP_USER" "$NOLOGIN"
  run passwd -l "$SFTP_USER" || true
  install_authorized_keys "$SFTP_USER" "$sftp_keys"
  if is_dry_run; then
    log "DRY-RUN: create /sftp/${SFTP_USER}/upload chroot"
  else
    mkdir -p "/sftp/${SFTP_USER}/upload"
    chown root:root /sftp "/sftp/${SFTP_USER}"
    chmod 755 /sftp "/sftp/${SFTP_USER}"
    chown "${SFTP_USER}:${SFTP_USER}" "/sftp/${SFTP_USER}/upload"
    chmod 750 "/sftp/${SFTP_USER}/upload"
  fi
fi

cat <<EOF

用户准备完成：
  管理用户：$ADMIN_USER
  sudo NOPASSWD：$ADMIN_SUDO_NOPASSWD
  SFTP 用户：$ENABLE_SFTP_USER${ENABLE_SFTP_USER:+ ($SFTP_USER)}

下一步会写入 phase1 SSH drop-in，只开启公钥登录，不禁 root/密码。
EOF
