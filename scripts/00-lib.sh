#!/usr/bin/env bash
# 公共库：日志、配置加载、校验、备份、执行封装。
set -Eeuo pipefail

OBS_PROJECT_DIR="${OBS_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
OBS_CONFIG_FILE="${OBS_CONFIG_FILE:-$OBS_PROJECT_DIR/config.env}"
OBS_DRY_RUN="${OBS_DRY_RUN:-false}"
OBS_YES="${OBS_YES:-false}"
SCRIPT_DIR="$OBS_PROJECT_DIR/scripts"
LOG_FILE="/var/log/our-server-bootstrap.log"
BACKUP_ROOT="/root/our-server-bootstrap-backups"
PHASE_NAME="${PHASE_NAME:-manual}"
BACKUP_DIR="${BACKUP_DIR:-}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  LOG_FILE="/tmp/our-server-bootstrap.log"
  BACKUP_ROOT="/tmp/our-server-bootstrap-backups"
fi

trap 'rc=$?; echo "[ERROR] line=${LINENO} cmd=${BASH_COMMAND} rc=${rc}" >&2; exit $rc' ERR

_ts() { date '+%F %T'; }
log() { printf '[%s] %s\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

is_dry_run() { [[ "$OBS_DRY_RUN" == "true" ]]; }
require_root() { [[ $EUID -eq 0 ]] || die "必须以 root 运行：sudo bash bootstrap.sh ..."; }

run() {
  if is_dry_run; then
    log "DRY-RUN: $*"
  else
    log "+ $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

user_home() {
  local user="$1" entry home
  entry="$(getent passwd "$user" || true)"
  if [[ -n "$entry" ]]; then
    local _name _passwd _uid _gid _gecos _shell
    IFS=: read -r _name _passwd _uid _gid _gecos home _shell <<<"$entry"
    [[ -n "$home" ]] || die "无法获取 $user 的 home"
    printf '%s\n' "$home"
    return 0
  fi

  if is_dry_run; then
    printf '/home/%s\n' "$user"
    return 0
  fi

  die "用户不存在，无法获取 home：$user"
}

apt_install() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  if is_dry_run; then
    log "DRY-RUN: apt-get update && apt-get install -y $*"
  else
    apt-get update -y 2>&1 | tee -a "$LOG_FILE"
    apt-get install -y "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

load_config() {
  [[ -f "$OBS_CONFIG_FILE" ]] || die "找不到配置文件：$OBS_CONFIG_FILE；请先 cp config.example.env config.env"
  set -a
  # shellcheck disable=SC1090
  source "$OBS_CONFIG_FILE"
  set +a

  : "${SERVER_ALIAS:=my-vps}"
  : "${SERVER_IP:=}"
  : "${SSH_PORT:=22}"
  : "${INITIAL_USER:=root}"
  : "${ADMIN_USER:=admin}"
  : "${ADMIN_PUBKEY:=}"
  : "${ENABLE_SFTP_USER:=false}"
  : "${SFTP_USER:=sftpuser}"
  : "${SFTP_PUBKEY:=}"
  : "${USE_233BOY_INSTALLER:=false}"
  : "${INSTALL_SINGBOX_METHOD:=apt}"
  : "${PROXY_PROTOCOL:=vless-reality}"
  : "${MODE_443:=direct}"
  : "${DIRECT_PORT:=443}"
  : "${HOME_PORT_START:=51043}"
  : "${HOME_PORT_END:=51060}"
  : "${ENABLE_UFW:=true}"
  : "${ENABLE_FAIL2BAN:=true}"
  : "${ENABLE_IPV6_LISTEN:=false}"
  : "${ADMIN_SUDO_NOPASSWD:=true}"
  : "${CSV_PATH:=./home-proxies.csv}"
  : "${OUR_STATE_DIR:=/etc/our-singbox}"
  : "${SINGBOX_CONFIG_PATH:=/etc/sing-box/config.json}"
  : "${VLESS_UUID_PATH:=/etc/our-singbox/vless-uuid.txt}"
  : "${VLESS_FLOW:=xtls-rprx-vision}"
  : "${REALITY_PRIVATE_KEY_PATH:=/etc/our-singbox/reality-private.key}"
  : "${REALITY_PUBLIC_KEY_PATH:=/etc/our-singbox/reality-public.key}"
  : "${REALITY_SHORT_ID_PATH:=/etc/our-singbox/reality-short-id.txt}"
  : "${REALITY_SERVER_NAME:=www.microsoft.com}"
  : "${REALITY_HANDSHAKE_SERVER:=www.microsoft.com}"
  : "${REALITY_HANDSHAKE_PORT:=443}"
  : "${REALITY_MAX_TIME_DIFFERENCE:=1m}"
  : "${SMART_AI_HOME_TAG:=}"
  : "${REJECT_CN_PRIVATE:=true}"
  : "${CLIENT_FINGERPRINT:=chrome}"
  : "${CLIENT_UDP:=false}"
  : "${CLIENT_ALPN:=h2,http/1.1}"
  : "${CLASH_MIXED_PORT:=7890}"

  validate_config_basics
  resolve_csv_path
}

validate_bool() {
  local name="$1" value="${!1}"
  case "$value" in true|false) ;; *) die "$name 必须是 true 或 false，当前：$value" ;; esac
}

validate_port() {
  local name="$1" value="${!1}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字端口，当前：$value"
  (( value >= 1 && value <= 65535 )) || die "$name 超出端口范围 1-65535：$value"
}

validate_user_name() {
  local name="$1" value="${!1}"
  [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "$name 用户名不合法：$value"
}

validate_config_basics() {
  validate_port SSH_PORT
  validate_port DIRECT_PORT
  validate_port HOME_PORT_START
  validate_port HOME_PORT_END
  validate_bool ENABLE_SFTP_USER
  validate_bool USE_233BOY_INSTALLER
  validate_bool ENABLE_UFW
  validate_bool ENABLE_FAIL2BAN
  validate_bool ENABLE_IPV6_LISTEN
  validate_bool ADMIN_SUDO_NOPASSWD
  validate_bool REJECT_CN_PRIVATE
  validate_bool CLIENT_UDP
  validate_user_name ADMIN_USER
  validate_user_name SFTP_USER
  (( HOME_PORT_START <= HOME_PORT_END )) || die "HOME_PORT_START 不能大于 HOME_PORT_END"
  [[ "$MODE_443" == "direct" || "$MODE_443" == "smart" ]] || die "MODE_443 只能是 direct 或 smart"
  [[ "$INSTALL_SINGBOX_METHOD" == "apt" || "$INSTALL_SINGBOX_METHOD" == "233boy" ]] || die "INSTALL_SINGBOX_METHOD 只能是 apt 或 233boy"
  [[ "$PROXY_PROTOCOL" == "vless-reality" ]] || die "PROXY_PROTOCOL 当前只支持 vless-reality"
  validate_port REALITY_HANDSHAKE_PORT
  [[ "$VLESS_FLOW" == "" || "$VLESS_FLOW" == "xtls-rprx-vision" ]] || die "VLESS_FLOW 目前建议为空或 xtls-rprx-vision，当前：$VLESS_FLOW"
  [[ "$REALITY_SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "REALITY_SERVER_NAME 不合法：$REALITY_SERVER_NAME"
  [[ "$REALITY_HANDSHAKE_SERVER" =~ ^[A-Za-z0-9._-]+$ ]] || die "REALITY_HANDSHAKE_SERVER 不合法：$REALITY_HANDSHAKE_SERVER"
  if [[ "$DIRECT_PORT" != "443" ]]; then
    warn "DIRECT_PORT 当前不是 443：$DIRECT_PORT；请确认客户端和安全组同步。"
  fi
  if [[ "$ENABLE_IPV6_LISTEN" == "true" ]]; then
    warn "ENABLE_IPV6_LISTEN=true 会让 VLESS+Reality 监听 ::，请确认服务商 IPv6 安全组和 UFW v6 规则。"
  fi
}

resolve_csv_path() {
  if [[ "$CSV_PATH" != /* ]]; then
    CSV_PATH="$OBS_PROJECT_DIR/${CSV_PATH#./}"
  fi
  export CSV_PATH
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  local os_id="${ID:-}" ver="${VERSION_ID:-}"
  case "$os_id:$ver" in
    ubuntu:22.04|ubuntu:24.04|debian:13|debian:13.*)
      info "系统受支持：$PRETTY_NAME"
      ;;
    *)
      die "当前系统不在默认支持范围：${PRETTY_NAME:-unknown}。本项目优先支持 Ubuntu 22.04/24.04 和 Debian 13，为防锁机已停止。"
      ;;
  esac
}

init_backup_dir() {
  [[ -n "$BACKUP_DIR" ]] && return 0
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_DIR="$BACKUP_ROOT/backup-${stamp}-${PHASE_NAME}"
  if is_dry_run; then
    log "DRY-RUN: mkdir -p $BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR" 2>/dev/null || true
    printf 'phase=%s\ndate=%s\nconfig=%s\n' "$PHASE_NAME" "$(_ts)" "$OBS_CONFIG_FILE" > "$BACKUP_DIR/MANIFEST.txt"
  fi
  export BACKUP_DIR
}

backup_path() {
  local path="$1"
  [[ -e "$path" ]] || { info "备份跳过，不存在：$path"; return 0; }
  init_backup_dir
  local rel="${path#/}"
  local dest="$BACKUP_DIR/$rel"
  if is_dry_run; then
    log "DRY-RUN: cp -a $path $dest"
  else
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
    log "已备份：$path -> $dest"
  fi
}

ssh_service_name() {
  local units
  units="$(systemctl list-unit-files 2>/dev/null || true)"
  if grep -q '^ssh\.service' <<<"$units"; then
    echo ssh
  elif grep -q '^sshd\.service' <<<"$units"; then
    echo sshd
  elif systemctl status ssh >/dev/null 2>&1; then
    echo ssh
  else
    echo sshd
  fi
}

sshd_bin() {
  if [[ -x /usr/sbin/sshd ]]; then
    echo /usr/sbin/sshd
  else
    command -v sshd || true
  fi
}

test_sshd_config() {
  local bin
  bin="$(sshd_bin)"
  [[ -n "$bin" ]] || die "找不到 sshd；请安装 openssh-server"
  run "$bin" -t
}

reload_ssh() {
  local svc
  svc="$(ssh_service_name)"
  if is_dry_run; then
    log "DRY-RUN: systemctl reload $svc || systemctl restart $svc"
  else
    systemctl reload "$svc" 2>&1 | tee -a "$LOG_FILE" || systemctl restart "$svc" 2>&1 | tee -a "$LOG_FILE"
    systemctl status "$svc" --no-pager 2>&1 | tee -a "$LOG_FILE" || true
  fi
}

ensure_sshd_dropin_include() {
  local conf="/etc/ssh/sshd_config"
  [[ -f "$conf" ]] || die "找不到 $conf"
  if is_dry_run; then
    log "DRY-RUN: mkdir -p /etc/ssh/sshd_config.d"
  else
    mkdir -p /etc/ssh/sshd_config.d
  fi
  local include_line first_match
  include_line="$(grep -nE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf\b' "$conf" | head -n1 | cut -d: -f1 || true)"
  first_match="$(grep -nE '^\s*Match\b' "$conf" | head -n1 | cut -d: -f1 || true)"
  if [[ -n "$include_line" ]]; then
    if [[ -n "$first_match" && "$include_line" -gt "$first_match" ]]; then
      die "$conf 的 Include 出现在 Match 块之后，不适合自动写入早期 drop-in。请先手动整理 sshd_config。"
    fi
    info "已检测到 sshd drop-in Include：line $include_line"
    return 0
  fi
  warn "$conf 未发现 /etc/ssh/sshd_config.d/*.conf Include，将在文件开头安全插入。"
  backup_path "$conf"
  if is_dry_run; then
    log "DRY-RUN: prepend Include to $conf"
  else
    local tmp
    tmp="$(mktemp)"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$tmp"
    cat "$conf" >> "$tmp"
    cat "$tmp" > "$conf"
    rm -f "$tmp"
  fi
}

singbox_bin() {
  if [[ -x /etc/sing-box/bin/sing-box ]]; then
    echo /etc/sing-box/bin/sing-box
  elif command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
  else
    true
  fi
}

singbox_check() {
  local bin config
  config="${1:-$SINGBOX_CONFIG_PATH}"
  bin="$(singbox_bin)"
  if [[ -z "$bin" ]]; then
    if is_dry_run; then
      log "DRY-RUN: sing-box check -c $config"
      return 0
    fi
    die "找不到 sing-box 可执行文件"
  fi
  run "$bin" check -c "$config"
}

restart_singbox() {
  if is_dry_run; then
    log "DRY-RUN: systemctl enable --now sing-box && systemctl restart sing-box"
  else
    systemctl enable sing-box 2>&1 | tee -a "$LOG_FILE" || true
    systemctl restart sing-box 2>&1 | tee -a "$LOG_FILE"
    systemctl status sing-box --no-pager 2>&1 | tee -a "$LOG_FILE" || true
  fi
}

port_line_matches() {
  local port="$1" line p
  while read -r line; do
    [[ -z "$line" ]] && continue
    p="$(awk '{print $4}' <<<"$line")"
    p="${p##*:}"
    [[ "$p" == "$port" ]] && { printf '%s\n' "$line"; return 0; }
  done < <(ss -H -ltnp 2>/dev/null || ss -H -ltn 2>/dev/null || true)
  return 1
}

port_in_use_by_other() {
  local port="$1" lines
  lines="$(port_line_matches "$port" || true)"
  [[ -z "$lines" ]] && return 1
  if grep -qi 'sing-box' <<<"$lines"; then
    return 1
  fi
  printf '%s\n' "$lines" >&2
  return 0
}

write_root_file() {
  local path="$1" mode="$2"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if is_dry_run; then
    log "DRY-RUN: install -m $mode $path"
    rm -f "$tmp"
  else
    install -m "$mode" -o root -g root "$tmp" "$path"
    rm -f "$tmp"
  fi
}
