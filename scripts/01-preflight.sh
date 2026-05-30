#!/usr/bin/env bash
# 系统和配置预检查：不做危险加固。
set -Eeuo pipefail
PHASE_NAME="preflight"
source "${OBS_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

info "开始 preflight。日志：$LOG_FILE"

apt_install ca-certificates curl gnupg lsb-release openssl python3 sudo openssh-server iproute2

have systemctl || die "找不到 systemctl；本项目仅支持 systemd 环境。"
have ss || die "找不到 ss；请确认 iproute2 已安装。"

backup_path /etc/ssh/sshd_config
[[ -d /etc/ssh/sshd_config.d ]] && backup_path /etc/ssh/sshd_config.d

ensure_sshd_dropin_include
test_sshd_config

info "当前 SSH 服务名：$(ssh_service_name)"
info "配置中的 SSH_PORT=$SSH_PORT；防火墙阶段会先放行该端口。"

if [[ -z "$ADMIN_PUBKEY" && ! -s /root/.ssh/authorized_keys ]]; then
  die "ADMIN_PUBKEY 为空，且 /root/.ssh/authorized_keys 不存在或为空。请在 config.env 填入本地公钥。"
fi

if port_in_use_by_other "$DIRECT_PORT"; then
  die "DIRECT_PORT=$DIRECT_PORT 已被非 sing-box 进程占用。请停止占用服务或修改端口。"
fi

python3 "$SCRIPT_DIR/08-generate-singbox-config.py" --config-env "$OBS_CONFIG_FILE" --check-only

cat <<EOF

Preflight 通过。建议下一步：
  sudo bash bootstrap.sh --phase ssh-phase1

ssh-phase1 只会创建管理用户并开启公钥登录，不会禁用 root/密码。
EOF
