#!/usr/bin/env bash
# 一键交互式安装入口：下载/定位项目、生成默认配置，并按安全阶段执行部署。
set -Eeuo pipefail

REPO_URL="${RRB_REPO_URL:-https://github.com/suyi-92/reality-relay-bootstrap.git}"
INSTALL_DIR="${RRB_INSTALL_DIR:-/opt/reality-relay-bootstrap}"
DEFAULT_BRANCH="${RRB_BRANCH:-main}"
RUN_PHASES="${RRB_RUN_PHASES:-true}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: 请使用 root 运行，例如：sudo bash install.sh" >&2
  exit 1
fi

if [[ -n "${RRB_INPUT_TTY:-}" ]]; then
  INPUT_TTY="$RRB_INPUT_TTY"
elif [[ -r /dev/tty ]]; then
  INPUT_TTY="/dev/tty"
elif [[ -t 0 ]]; then
  INPUT_TTY="/dev/stdin"
else
  echo "ERROR: 需要交互式终端来填写配置。" >&2
  exit 1
fi

BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
RESET=$'\033[0m'

line() { printf '%b\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"; }
info() { printf '%b\n' "${BLUE}INFO${RESET} $*" >&2; }
warn() { printf '%b\n' "${YELLOW}WARN${RESET} $*" >&2; }
die() { printf '%b\n' "${RED}ERROR${RESET} $*" >&2; exit 1; }

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

banner() {
  clear_screen
  printf '%b\n' "${CYAN}${BOLD}Reality Relay Bootstrap 一键安装${RESET}"
  printf '%b\n' "${CYAN}只填写服务器身份、SSH 管理员公钥和家宽代理，其余用默认值${RESET}"
  line
}

read_default() {
  local prompt="$1" default_value="$2" value
  if [[ -n "$default_value" ]]; then
    if [[ "$INPUT_TTY" == "/dev/tty" ]]; then
      IFS= read -e -i "$default_value" -r -p "${prompt}: " value <"$INPUT_TTY" || true
    else
      printf '%b' "${BOLD}${prompt}${RESET} ${DIM}[默认: ${default_value}]${RESET}: " >"$INPUT_TTY"
      IFS= read -r value <"$INPUT_TTY" || true
      value="${value:-$default_value}"
    fi
  else
    printf '%b' "${BOLD}${prompt}${RESET}: " >"$INPUT_TTY"
    IFS= read -r value <"$INPUT_TTY" || true
  fi
  printf '%s\n' "$value"
}

read_secret_default() {
  local prompt="$1" default_value="$2" value
  if [[ -n "$default_value" ]]; then
    printf '%b' "${BOLD}${prompt}${RESET} ${DIM}[默认: 已填入，可直接回车]${RESET}: " >"$INPUT_TTY"
  else
    printf '%b' "${BOLD}${prompt}${RESET}: " >"$INPUT_TTY"
  fi
  stty -echo <"$INPUT_TTY" 2>/dev/null || true
  IFS= read -r value <"$INPUT_TTY" || true
  stty echo <"$INPUT_TTY" 2>/dev/null || true
  printf '\n' >"$INPUT_TTY"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$value"
  fi
}

read_yes_no() {
  local prompt="$1" default_value="$2" value suffix
  if [[ "$default_value" == "yes" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  while true; do
    printf '%b' "${BOLD}${prompt}${RESET} ${DIM}[${suffix}]${RESET}: " >"$INPUT_TTY"
    IFS= read -r value <"$INPUT_TTY" || true
    value="${value:-$default_value}"
    case "$value" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "请输入 yes 或 no。" ;;
    esac
  done
}

shell_quote() {
  printf '%q' "$1"
}

csv_escape() {
  local value="$1"
  if [[ "$value" == *","* || "$value" == *"\""* || "$value" == *$'\n'* ]]; then
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

default_authorized_keys() {
  awk 'NF && $1 !~ /^#/ { print }' /root/.ssh/authorized_keys 2>/dev/null || true
}

collect_admin_pubkeys() {
  local keys_file="$1" index=1 key default_key
  local default_keys=()
  : >"$keys_file"
  if [[ -s /root/.ssh/authorized_keys ]]; then
    mapfile -t default_keys < <(default_authorized_keys)
  fi

  line
  printf '%b\n' "${CYAN}${BOLD}管理员 SSH 公钥${RESET}"
  printf '%b\n' "${DIM}可以填写多个 ADMIN_PUBKEY；每个公钥会写入 ${ADMIN_USER:-admin} 的 authorized_keys。${RESET}"
  while true; do
    default_key=""
    if (( index <= ${#default_keys[@]} )); then
      default_key="${default_keys[$((index - 1))]}"
    elif (( index > 1 )) && ! read_yes_no "是否继续添加第 ${index} 个 ADMIN_PUBKEY？" no; then
      break
    fi

    key="$(read_default "ADMIN_PUBKEY #${index}" "$default_key")"
    if [[ -n "$key" ]]; then
      printf '%s\n' "$key" >>"$keys_file"
    elif (( index == 1 )); then
      die "ADMIN_PUBKEY 不能为空；请至少粘贴一个本地 SSH 公钥。"
    fi

    index=$((index + 1))
  done

  [[ -s "$keys_file" ]] || die "ADMIN_PUBKEY 不能为空；请至少粘贴一个本地 SSH 公钥。"
}

public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s\n' "$ip"
}

ensure_project() {
  local self_dir
  self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  if [[ -n "$self_dir" && -f "$self_dir/bootstrap.sh" && -f "$self_dir/config.example.env" ]]; then
    printf '%s\n' "$self_dir"
    return 0
  fi

  info "当前是一键远程执行模式，将项目安装到：$INSTALL_DIR"
  if ! command -v git >/dev/null 2>&1; then
    info "安装 git/curl 基础依赖。"
    local apt_log="/tmp/reality-relay-bootstrap-install-apt.log"
    apt-get update -y >"$apt_log" 2>&1 || { tail -n 40 "$apt_log" >&2 || true; die "apt-get update 失败。"; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates >>"$apt_log" 2>&1 || { tail -n 60 "$apt_log" >&2 || true; die "安装 git/curl 失败。"; }
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "检测到已有项目目录，拉取最新代码。"
    git -C "$INSTALL_DIR" fetch --all --prune >&2
    git -C "$INSTALL_DIR" checkout "$DEFAULT_BRANCH" >&2
    git -C "$INSTALL_DIR" pull --ff-only >&2
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --branch "$DEFAULT_BRANCH" "$REPO_URL" "$INSTALL_DIR" >&2
  fi
  printf '%s\n' "$INSTALL_DIR"
}

write_config() {
  local project_dir="$1" server_alias="$2" server_ip="$3" ssh_port="$4" admin_user="$5" admin_pubkey="$6"
  cat >"$project_dir/config.env" <<EOF_CONFIG
# Generated by install.sh. Sensitive values; do not publish.
SERVER_ALIAS=$(shell_quote "$server_alias")
SERVER_IP=$(shell_quote "$server_ip")
SSH_PORT=$(shell_quote "$ssh_port")
INITIAL_USER="root"
ADMIN_USER=$(shell_quote "$admin_user")
ADMIN_PUBKEY=$(shell_quote "$admin_pubkey")
ADMIN_PUBKEYS=""
ENABLE_SFTP_USER="false"
SFTP_USER="sftpuser"
USE_233BOY_INSTALLER="false"
INSTALL_SINGBOX_METHOD="apt"
MODE_443="direct"
DIRECT_PORT="443"
HOME_PORT_START="51043"
HOME_PORT_END="51060"
ENABLE_UFW="true"
ENABLE_FAIL2BAN="true"
ENABLE_IPV6_LISTEN="false"

ADMIN_SUDO_NOPASSWD="true"
SFTP_PUBKEY=""
CSV_PATH="./home-proxies.csv"
RRB_STATE_DIR="/etc/reality-relay-bootstrap"
SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"

PROXY_PROTOCOL="vless-reality"
PROXY_IP_VERSION="ipv4"
VLESS_UUID_PATH="/etc/reality-relay-bootstrap/vless-uuid.txt"
VLESS_FLOW="xtls-rprx-vision"
REALITY_PRIVATE_KEY_PATH="/etc/reality-relay-bootstrap/reality-private.key"
REALITY_PUBLIC_KEY_PATH="/etc/reality-relay-bootstrap/reality-public.key"
REALITY_SHORT_ID_PATH="/etc/reality-relay-bootstrap/reality-short-id.txt"
REALITY_SERVER_NAME="www.microsoft.com"
REALITY_HANDSHAKE_SERVER="www.microsoft.com"
REALITY_HANDSHAKE_PORT="443"
REALITY_MAX_TIME_DIFFERENCE="1m"

SMART_AI_HOME_TAG=""
REJECT_CN_PRIVATE="true"

CLIENT_FINGERPRINT="chrome"
CLIENT_UDP="false"
CLIENT_ALPN="h2,http/1.1"
CLASH_MIXED_PORT="7890"

ENABLE_SUBSCRIPTION_SERVER="false"
SUBSCRIPTION_PORT="51080"
SUBSCRIPTION_DIR="/etc/reality-relay-bootstrap/subscription"
EOF_CONFIG
  chmod 600 "$project_dir/config.env"
}

write_home_proxies() {
  local project_dir="$1" rows_file="$2"
  {
    printf 'tag,listen_port,type,server,server_port,username,password,network\n'
    cat "$rows_file"
  } >"$project_dir/home-proxies.csv"
  chmod 600 "$project_dir/home-proxies.csv"
}

collect_home_proxies_bulk() {
  local rows_file="$1" line_value any=false
  printf '%b\n' "${DIM}可直接粘贴多行 CSV，字段为：tag,listen_port,type,server,server_port,username,password,network${RESET}"
  printf '%b\n' "${DIM}支持带表头；粘贴完成后输入空行结束。密码可留空，例如：home-01,51043,socks5,1.2.3.4,1080,,secret,tcp${RESET}"
  while true; do
    printf '%b' "> " >"$INPUT_TTY"
    IFS= read -r line_value <"$INPUT_TTY" || true
    [[ -n "$line_value" ]] || break
    [[ "$line_value" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line_value" =~ ^[[:space:]]*tag[[:space:]]*,[[:space:]]*listen_port[[:space:]]*, ]]; then
      continue
    fi
    printf '%s\n' "$line_value" >>"$rows_file"
    any=true
  done
  [[ "$any" == "true" ]]
}

collect_home_proxies_one_by_one() {
  local rows_file="$1" index=1
  while read_yes_no "是否添加第 ${index} 个家宽代理出口？" "$([[ $index -eq 1 ]] && echo yes || echo no)"; do
    local tag listen_port type server server_port username password network
    tag="$(read_default "  tag" "home-$(printf '%02d' "$index")")"
    listen_port="$(read_default "  listen_port" "$((51042 + index))")"
    type="$(read_default "  type (socks5/http)" "socks5")"
    server="$(read_default "  server" "")"
    server_port="$(read_default "  server_port" "1080")"
    username="$(read_default "  username" "")"
    password="$(read_secret_default "  password" "")"
    network="$(read_default "  network" "tcp")"
    [[ -n "$server" ]] || die "家宽代理 server 不能为空；如没有代理，请重新运行并选择不添加。"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$tag")" \
      "$(csv_escape "$listen_port")" \
      "$(csv_escape "$type")" \
      "$(csv_escape "$server")" \
      "$(csv_escape "$server_port")" \
      "$(csv_escape "$username")" \
      "$(csv_escape "$password")" \
      "$(csv_escape "$network")" >>"$rows_file"
    index=$((index + 1))
  done
}

collect_home_proxies() {
  local rows_file="$1"
  : >"$rows_file"
  line
  printf '%b\n' "${CYAN}${BOLD}家宽代理配置${RESET}"
  printf '%b\n' "${DIM}每一行会生成一个 VLESS+Reality 入口端口；如暂时没有家宽代理，可以不添加。${RESET}"
  if read_yes_no "是否一次性粘贴多行家宽代理 CSV？" no; then
    collect_home_proxies_bulk "$rows_file" || warn "没有粘贴任何家宽代理行，将继续逐个输入。"
  fi
  if [[ ! -s "$rows_file" ]]; then
    collect_home_proxies_one_by_one "$rows_file"
  fi
}

run_install_flow() {
  local project_dir="$1" server_ip="$2" ssh_port="$3" admin_user="$4"
  cd "$project_dir"
  line
  printf '%b\n' "${GREEN}${BOLD}配置文件已生成：${RESET}"
  printf '  %s\n' "$project_dir/config.env" "$project_dir/home-proxies.csv"

  if [[ "$RUN_PHASES" != "true" ]]; then
    warn "RRB_RUN_PHASES=$RUN_PHASES，仅生成配置，不执行部署阶段。"
    return 0
  fi

  line
  printf '%b\n' "${CYAN}${BOLD}开始分阶段部署${RESET}"
  bash bootstrap.sh --phase preflight
  bash bootstrap.sh --phase ssh-phase1

  line
  printf '%b\n' "${YELLOW}${BOLD}安全确认：不要关闭当前 SSH 窗口。${RESET}"
  printf '请另开一个终端，确认下面命令可以通过公钥登录并 sudo 成功：\n\n'
  printf '  ssh -p %q -o PreferredAuthentications=publickey -o PasswordAuthentication=no %q@%q\n' "$ssh_port" "$admin_user" "$server_ip"
  printf '  whoami && sudo whoami\n\n'
  printf '确认输出包含 %q 和 root 后，再回到这里继续。\n' "$admin_user"
  if read_yes_no "我已确认 admin 公钥登录和 sudo 正常，继续 SSH final 加固？" no; then
    CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
  else
    warn "已暂停在 ssh-phase1。之后可手动执行：sudo CONFIRM_ADMIN_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final"
    return 0
  fi

  bash bootstrap.sh --phase fail2ban
  bash bootstrap.sh --phase singbox
  bash bootstrap.sh --phase firewall
  bash bootstrap.sh --phase validate

  line
  printf '%b\n' "${GREEN}${BOLD}部署完成。节点文件：${RESET}"
  printf '  sudo cat /root/reality-relay-bootstrap-nodes.txt\n'
  printf '  sudo cat /root/reality-relay-bootstrap-clash.yaml\n'
}

main() {
  banner
  local project_dir default_ip
  project_dir="$(ensure_project)"
  default_ip="$(public_ipv4)"

  line
  printf '%b\n' "${CYAN}${BOLD}基础信息${RESET}"
  local server_alias server_ip ssh_port admin_user admin_pubkey
  server_alias="$(read_default "SERVER_ALIAS" "my-vps")"
  server_ip="$(read_default "SERVER_IP" "$default_ip")"
  ssh_port="$(read_default "SSH_PORT" "22")"
  admin_user="$(read_default "ADMIN_USER" "admin")"

  [[ -n "$server_ip" ]] || die "SERVER_IP 不能为空。"

  ADMIN_KEYS_FILE="$(mktemp)"
  ROWS_FILE="$(mktemp)"
  trap 'rm -f "${ADMIN_KEYS_FILE:-}" "${ROWS_FILE:-}"' EXIT
  ADMIN_USER="$admin_user" collect_admin_pubkeys "$ADMIN_KEYS_FILE"
  admin_pubkey="$(cat "$ADMIN_KEYS_FILE")"
  collect_home_proxies "$ROWS_FILE"

  write_config "$project_dir" "$server_alias" "$server_ip" "$ssh_port" "$admin_user" "$admin_pubkey"
  write_home_proxies "$project_dir" "$ROWS_FILE"
  run_install_flow "$project_dir" "$server_ip" "$ssh_port" "$admin_user"
}

main "$@"
