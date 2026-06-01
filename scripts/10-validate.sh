#!/usr/bin/env bash
# 验证 SSH、fail2ban、UFW、sing-box、监听端口和家宽代理可用性。
set -Eeuo pipefail
PHASE_NAME="validate"
source "${RRB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

SINGBOX_ONLY="false"
SKIP_PROXY_TESTS="false"
RESTART_SINGBOX="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --singbox-only) SINGBOX_ONLY="true"; shift ;;
    --skip-proxy-tests) SKIP_PROXY_TESTS="true"; shift ;;
    --restart-singbox) RESTART_SINGBOX="true"; shift ;;
    *) die "validate 参数不支持：$1" ;;
  esac
done

if [[ "$SINGBOX_ONLY" != "true" ]]; then
  info "检查 sshd 配置语法。"
  test_sshd_config

  if ! is_dry_run; then
    info "检查 sshd -T 最终生效值。"
    "$(sshd_bin)" -T -C "user=${ADMIN_USER},host=localhost,addr=127.0.0.1" \
      | grep -Ei '^(permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|authenticationmethods|permitemptypasswords|allowusers|maxauthtries|x11forwarding|allowagentforwarding|allowtcpforwarding|permittunnel|gatewayports)\b' \
      | tee -a "$LOG_FILE"
  fi

  if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then
    info "检查 fail2ban。"
    if ! is_dry_run; then
      fail2ban-client -t 2>&1 | tee -a "$LOG_FILE"
      systemctl is-active --quiet fail2ban || die "fail2ban 未运行"
      info "fail2ban 服务运行中。"
      fail2ban-client status sshd 2>&1 | tee -a "$LOG_FILE" || true
    fi
  fi

  if [[ "$ENABLE_UFW" == "true" ]]; then
    info "检查 UFW。"
    if ! is_dry_run; then
      ufw status verbose 2>&1 | tee -a "$LOG_FILE"
    fi
  fi
fi

info "检查 sing-box 配置语法。"
python3 "$SCRIPT_DIR/08-generate-singbox-config.py" --config-env "$RRB_CONFIG_FILE" --check-only --quiet
singbox_check "$SINGBOX_CONFIG_PATH"

if [[ "$RESTART_SINGBOX" == "true" ]]; then
  if is_dry_run; then
    info "DRY-RUN: sing-box check 未实际执行；不会重启 sing-box，只展示将执行的命令。"
  else
    info "sing-box check 已通过，重启 sing-box。"
  fi
  restart_singbox
fi

if is_dry_run; then
  info "DRY-RUN: 跳过 sing-box systemd 状态、监听端口和家宽代理实测。"
else
  info "检查 sing-box systemd 状态。"
  systemctl is-active --quiet sing-box || die "sing-box 未运行"
  info "sing-box 服务运行中。"
fi

mapfile -t PORTS < <(python3 "$SCRIPT_DIR/08-generate-singbox-config.py" --config-env "$RRB_CONFIG_FILE" --print-ports)
if is_dry_run; then
  info "DRY-RUN: 实际运行后应监听端口：${PORTS[*]}"
else
  info "检查监听端口：${PORTS[*]}"
fi
if ! is_dry_run; then
  for port in "${PORTS[@]}"; do
    if wait_for_port_listener "$port" 15; then
      info "端口监听正常：$port"
    else
      diagnose_singbox_listeners
      die "未发现监听端口：$port；已等待 15 秒，详见上方 sing-box 状态和日志。"
    fi
  done
fi

if [[ "$ENABLE_SUBSCRIPTION_SERVER" == "true" && "$SINGBOX_ONLY" != "true" ]]; then
  if is_dry_run; then
    info "DRY-RUN: 实际运行后应检查订阅服务端口：$SUBSCRIPTION_PORT"
  else
    info "检查订阅服务。"
    systemctl is-active --quiet reality-relay-subscription || die "订阅服务未运行"
    wait_for_port_listener "$SUBSCRIPTION_PORT" 15 || die "订阅服务未监听端口：$SUBSCRIPTION_PORT"
    info "订阅服务端口正常：$SUBSCRIPTION_PORT"
  fi
fi

if [[ "$SKIP_PROXY_TESTS" != "true" ]]; then
  info "测试每个家宽代理本身是否可用；不会把代理密码写入日志。"
  if ! is_dry_run; then
    python3 - "$RRB_CONFIG_FILE" "$SCRIPT_DIR/08-generate-singbox-config.py" <<'PY'
import importlib.util
import subprocess
import sys
from pathlib import Path

env_path = Path(sys.argv[1]).resolve()
gen_path = Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("gen", gen_path)
gen = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(gen)

base = env_path.parent
env = gen.defaults(gen.parse_env_file(env_path))
rows = gen.load_rows(env, base, allow_empty=True)
if not rows:
    print("没有家宽代理行，跳过代理本身测试。")
    raise SystemExit(0)

for row in rows:
    proto = "socks5h" if row["type"] in {"socks", "socks5"} else "http"
    proxy = f"{proto}://{row['server']}:{row['server_port']}"
    cmd = [
        "curl",
        "--silent",
        "--show-error",
        "--max-time",
        "20",
        "--proxy",
        proxy,
        "https://ifconfig.me",
    ]
    if row["username"] or row["password"]:
        cmd[7:7] = ["--proxy-user", f"{row['username']}:{row['password']}"]
    print(f"测试 {row['tag']} ({row['type']}://{row['server']}:{row['server_port']}) ...", flush=True)
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        print(proc.stderr.strip() or proc.stdout.strip(), file=sys.stderr)
        raise SystemExit(f"家宽代理测试失败：{row['tag']}")
    print(f"  出口 IP: {proc.stdout.strip()[:80]}")
PY
  fi
fi

cat <<EOF

验证完成。Windows PowerShell 建议继续测试：

$(for host in $(server_hosts); do
  for port in "${PORTS[@]}"; do
    printf '  Test-NetConnection %s -Port %s\n' "$host" "$port"
  done
done)

$(for host in $(server_hosts); do
  printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
  printf '  ssh -p %s root@%s\n' "$SSH_PORT" "$host"
  printf '  ssh -p %s -o PubkeyAuthentication=no -o PreferredAuthentications=password %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$host"
done)
EOF
