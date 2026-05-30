#!/usr/bin/env bash
# 配置 UFW：只开放 SSH、443/DIRECT_PORT 和 CSV 实际使用端口。
set -Eeuo pipefail
PHASE_NAME="firewall"
source "${OBS_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if [[ "$ENABLE_UFW" != "true" ]]; then
  info "ENABLE_UFW=false，跳过防火墙配置。"
  exit 0
fi

bash "$SCRIPT_DIR/06-install-ufw.sh"

mapfile -t PORTS < <(python3 "$SCRIPT_DIR/08-generate-singbox-config.py" --config-env "$OBS_CONFIG_FILE" --print-ports)
[[ "${#PORTS[@]}" -ge 1 ]] || die "未解析到 VLESS+Reality 端口。"

info "准备开放实际使用的 VLESS+Reality TCP 端口：${PORTS[*]}"
for port in "${PORTS[@]}"; do
  validate_port_value="$port"
  [[ "$validate_port_value" =~ ^[0-9]+$ ]] || die "端口不是数字：$port"
  run ufw allow "${port}/tcp" comment "our-server-bootstrap sing-box VLESS+Reality ${port}"
done


if is_dry_run; then
  log "DRY-RUN: ufw --force enable && ufw status verbose"
else
  ufw --force enable 2>&1 | tee -a "$LOG_FILE"
  ufw status verbose 2>&1 | tee -a "$LOG_FILE"
  ufw status numbered 2>&1 | tee -a "$LOG_FILE"
fi

cat <<EOF

UFW 已按最小端口开放。服务商安全组/云防火墙也必须手动放行：

  SSH:        tcp/$SSH_PORT
$(printf '  VLESS+Reality:     tcp/%s\n' "${PORTS[@]}")

不要无脑开放 ${HOME_PORT_START}:${HOME_PORT_END}，除非你确认所有端口都会使用。
启用 UFW 后请另开窗口测试 SSH：
  ssh -p $SSH_PORT ${ADMIN_USER}@${SERVER_IP:-服务器IP}
EOF
