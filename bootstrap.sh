#!/usr/bin/env bash
# our-server-bootstrap 总入口。所有危险步骤都拆成阶段执行，避免一次性锁机。
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$PROJECT_DIR/scripts"
export OBS_PROJECT_DIR="$PROJECT_DIR"

PHASE=""
OBS_CONFIG_FILE="$PROJECT_DIR/config.env"
OBS_DRY_RUN="false"
OBS_YES="false"
export OBS_CONFIG_FILE OBS_DRY_RUN OBS_YES

usage() {
  cat <<'EOF'
Usage: sudo bash bootstrap.sh --phase <phase> [--config config.env] [--dry-run] [--yes]

Phases:
  preflight       检测系统、配置和 SSH 基础条件
  ssh-phase1      创建 admin/SFTP 用户，只开启公钥登录，不禁 root/密码
  ssh-final       二阶段 SSH 最终加固；必须 CONFIRM_ADMIN_KEY_LOGIN=yes
  fail2ban        安装并配置 fail2ban
  singbox         安装 sing-box、生成 VLESS+Reality 多入口配置并重启
  firewall        安装/配置 UFW，只开放 SSH、443 和 CSV 实际端口
  validate        验证 SSH、fail2ban、UFW、sing-box、监听端口和家宽代理
  output-nodes    生成 /root/our-singbox-nodes.txt 与 /root/our-singbox-clash.yaml
  rollback        回滚 SSH 加固、sing-box 配置；可选处理 UFW
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:-}"; shift 2 ;;
    --config) OBS_CONFIG_FILE="${2:-}"; export OBS_CONFIG_FILE; shift 2 ;;
    --dry-run) OBS_DRY_RUN="true"; export OBS_DRY_RUN; shift ;;
    --yes|-y) OBS_YES="true"; export OBS_YES; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$PHASE" ]] || { usage >&2; exit 2; }

run_phase() {
  local script="$1"
  shift || true
  bash "$SCRIPT_DIR/$script" "$@"
}

case "$PHASE" in
  preflight) run_phase 01-preflight.sh ;;
  ssh-phase1)
    run_phase 02-create-admin.sh
    run_phase 03-ssh-hardening-phase1.sh
    ;;
  ssh-final) run_phase 04-ssh-hardening-final.sh ;;
  fail2ban) run_phase 05-install-fail2ban.sh ;;
  singbox)
    run_phase 07-install-singbox.sh
    python3 "$SCRIPT_DIR/08-generate-singbox-config.py" --config-env "$OBS_CONFIG_FILE" --write
    run_phase 10-validate.sh --singbox-only --skip-proxy-tests --restart-singbox
    run_phase 11-output-nodes-wrapper.sh
    ;;
  firewall) run_phase 09-apply-firewall.sh ;;
  validate) run_phase 10-validate.sh ;;
  output-nodes) run_phase 11-output-nodes-wrapper.sh ;;
  rollback) run_phase 12-rollback.sh ;;
  *) echo "Unknown phase: $PHASE" >&2; usage >&2; exit 2 ;;
esac
