#!/usr/bin/env bash
# 一键交互式安装入口：下载/定位项目、生成默认配置，并按安全阶段执行部署。
set -Eeuo pipefail

clear_screen() {
  if [[ -t 1 ]]; then
    if command -v clear >/dev/null 2>&1; then
      clear 2>/dev/null || printf '\033[2J\033[H'
    else
      printf '\033[2J\033[H'
    fi
  fi
}

clear_screen

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

banner() {
  clear_screen
  printf '%b\n' "${CYAN}${BOLD}"
  cat <<'BANNER'
╭────────────────────────────────────────────────╮
│            Reality Relay Bootstrap             │
│              One-click installer               │
│        Server, SSH key, and relay exits        │
╰────────────────────────────────────────────────╯
BANNER
  printf '%b' "${RESET}"
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
  local prompt="$1" _default_value="${2:-yes}" value suffix="Y/n"
  while true; do
    printf '%b' "${BOLD}${prompt}${RESET} ${DIM}[${suffix}]${RESET}: " >"$INPUT_TTY"
    IFS= read -r value <"$INPUT_TTY" || true
    [[ -z "$value" ]] && return 0
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
  local keys_file="$1" index=1 key
  : >"$keys_file"

  line
  printf '%b\n' "${CYAN}${BOLD}管理员 SSH 公钥${RESET}"
  printf '%b\n' "${DIM}可以填写多个 ADMIN_PUBKEY；留空回车结束。${RESET}"
  while true; do
    key="$(read_default "ADMIN_PUBKEY #${index}" "")"
    if [[ -n "$key" ]]; then
      printf '%s\n' "$key" >>"$keys_file"
    elif (( index > 1 )); then
      break
    else
      die "ADMIN_PUBKEY 不能为空；请至少粘贴一个本地 SSH 公钥。"
    fi

    index=$((index + 1))
  done

  [[ -s "$keys_file" ]] || die "ADMIN_PUBKEY 不能为空；请至少粘贴一个本地 SSH 公钥。"
}

read_bool_value() {
  local prompt="$1" default_value="$2" value
  while true; do
    value="$(read_default "$prompt" "$default_value")"
    case "$value" in
      true|false) printf '%s\n' "$value"; return 0 ;;
      y|Y|yes|YES|Yes) printf 'true\n'; return 0 ;;
      n|N|no|NO|No) printf 'false\n'; return 0 ;;
      *) warn "$prompt 必须是 true 或 false。" ;;
    esac
  done
}

url_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

normalize_subscription_target() {
  local raw="${1:-VLESS_REALITY}" lower compact
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  compact="$(printf '%s' "$lower" | tr -d ' _-')"
  case "$compact" in
    vless|vlessreality|reality) printf 'VLESS_REALITY\n' ;;
    mihomo|clash|clashmeta) printf 'ClashMeta\n' ;;
    v2ray|v2rayn|v2rayng) printf 'V2Ray\n' ;;
    quantumultx|quanx|quantumult|qx) printf 'QX\n' ;;
    shadowrocket) printf 'ShadowRocket\n' ;;
    *) return 1 ;;
  esac
}

read_subscription_target() {
  local prompt="$1" default_value="$2" value target
  while true; do
    value="$(read_default "$prompt" "$default_value")"
    if target="$(normalize_subscription_target "$value")"; then
      printf '%s\n' "$target"
      return 0
    fi
    warn "$prompt 支持：VLESS_REALITY、ClashMeta、V2Ray、QX、ShadowRocket。"
  done
}

subscription_target_label() {
  case "$1" in
    VLESS_REALITY) printf 'VLESS Reality\n' ;;
    ClashMeta) printf 'ClashMeta\n' ;;
    V2Ray) printf 'V2Ray\n' ;;
    QX) printf 'QX\n' ;;
    ShadowRocket) printf 'ShadowRocket\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

subscription_token() {
  local token_path="/etc/reality-relay-bootstrap/vless-uuid.txt"
  if [[ -r "$token_path" ]]; then
    tr -d '\r\n' < "$token_path"
  else
    printf '<token>'
  fi
}

public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}')"
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
  local project_dir="$1" server_alias="$2" server_ip_ipv4="$3" server_ip_ipv6="$4" ssh_port="$5" admin_user="$6" admin_pubkey="$7" direct_port="$8" enable_subscription_server="$9" subscription_port="${10}" subscription_target="${11}" reset_proxy_keys="${12}" home_port_start="${13}" home_port_end="${14}"
  local server_ip="$server_ip_ipv4"
  local proxy_ip_version="ipv4"
  local enable_ipv6_listen="false"
  [[ -n "$server_ip" ]] || server_ip="$server_ip_ipv6"
  if [[ -n "$server_ip_ipv4" && -n "$server_ip_ipv6" ]]; then
    proxy_ip_version="dual"
  elif [[ -z "$server_ip_ipv4" && -n "$server_ip_ipv6" ]]; then
    proxy_ip_version="ipv6"
  fi
  [[ -z "$server_ip_ipv6" ]] || enable_ipv6_listen="true"
  cat >"$project_dir/config.env" <<EOF_CONFIG
# Generated by install.sh. Sensitive values; do not publish.
SERVER_ALIAS=$(shell_quote "$server_alias")
SERVER_IP=$(shell_quote "$server_ip")
SERVER_IP_IPV4=$(shell_quote "$server_ip_ipv4")
SERVER_IP_IPV6=$(shell_quote "$server_ip_ipv6")
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
DIRECT_PORT=$(shell_quote "$direct_port")
HOME_PORT_START=$(shell_quote "$home_port_start")
HOME_PORT_END=$(shell_quote "$home_port_end")
ENABLE_UFW="true"
ENABLE_FAIL2BAN="true"
ENABLE_IPV6_LISTEN=$(shell_quote "$enable_ipv6_listen")

ADMIN_SUDO_NOPASSWD="true"
SFTP_PUBKEY=""
CSV_PATH="./home-proxies.csv"
UPSTREAM_NODES_PATH="./upstream-nodes.txt"
RRB_STATE_DIR="/etc/reality-relay-bootstrap"
SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"

PROXY_PROTOCOL="vless-reality"
PROXY_IP_VERSION=$(shell_quote "$proxy_ip_version")
RESET_PROXY_KEYS=$(shell_quote "$reset_proxy_keys")
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

ENABLE_SUBSCRIPTION_SERVER=$(shell_quote "$enable_subscription_server")
SUBSCRIPTION_PORT=$(shell_quote "$subscription_port")
SUBSCRIPTION_TARGET=$(shell_quote "$subscription_target")
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

write_upstream_nodes() {
  local project_dir="$1" rows_file="$2"
  {
    printf 'tag,listen_port,node_url\n'
    cat "$rows_file"
  } >"$project_dir/upstream-nodes.txt"
  chmod 600 "$project_dir/upstream-nodes.txt"
}

tag_from_upstream_url() {
  local url="$1" fallback="$2" tag=""
  if [[ "$url" == *"#"* ]]; then
    tag="${url##*#}"
  fi
  tag="$(printf '%s' "${tag:-$fallback}" | sed 's/%20/-/g; s/[^A-Za-z0-9_-]/-/g; s/^-*//; s/-*$//')"
  [[ -n "$tag" ]] || tag="$fallback"
  printf '%s\n' "$tag"
}

port_used_in_file() {
  local port="$1" file="$2"
  [[ -s "$file" ]] || return 1
  awk -F',' -v port="$port" 'NF >= 2 && $2 == port { found=1 } END { exit found ? 0 : 1 }' "$file"
}

next_available_relay_port() {
  local start="$1" end="$2" home_rows_file="$3" upstream_rows_file="$4" port
  for (( port=start; port<=end; port++ )); do
    port_used_in_file "$port" "$home_rows_file" && continue
    port_used_in_file "$port" "$upstream_rows_file" && continue
    printf '%s\n' "$port"
    return 0
  done
  die "HOME_PORT_START/HOME_PORT_END 范围内没有可用端口；请扩大端口范围。"
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
    collect_home_proxies_bulk "$rows_file" || warn "没有粘贴任何家宽代理行。"
  fi
  if [[ ! -s "$rows_file" ]]; then
    if read_yes_no "未添加家宽代理，是否跳过家宽代理配置？" yes; then
      return 0
    fi
    collect_home_proxies_one_by_one "$rows_file"
  fi
}

collect_upstream_nodes() {
  local rows_file="$1" home_rows_file="$2" port_start="$3" port_end="$4"
  local line_value any=false index=1
  : >"$rows_file"

  line
  printf '%b\n' "${CYAN}${BOLD}上游节点配置${RESET}"
  printf '%b\n' "${DIM}可选：把别人给你的 hysteria2://、普通 vless:// 或 VLESS Reality 节点接到新的入口端口。${RESET}"
  if ! read_yes_no "是否粘贴上游节点分享链接或 CSV？" no; then
    return 0
  fi

  printf '%b\n' "${DIM}每行一个节点链接，脚本会自动分配端口；也支持 CSV：tag,listen_port,node_url。空行结束。${RESET}"
  printf '%b\n' "${DIM}示例：hysteria2://password@1.2.3.4:443?alpn=h3&insecure=1#hy2${RESET}"
  while true; do
    printf '%b' "> " >"$INPUT_TTY"
    IFS= read -r line_value <"$INPUT_TTY" || true
    [[ -n "$line_value" ]] || break
    [[ "$line_value" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line_value" =~ ^[[:space:]]*tag[[:space:]]*,[[:space:]]*listen_port[[:space:]]*, ]]; then
      continue
    fi
    if [[ "$line_value" == *","* && "$line_value" =~ ^[^,]+,[0-9]+, ]]; then
      printf '%s\n' "$line_value" >>"$rows_file"
      any=true
      index=$((index + 1))
      continue
    fi
    case "$line_value" in
      hysteria2://*|hy2://*|vless://*)
        local tag port
        tag="$(tag_from_upstream_url "$line_value" "upstream-$(printf '%02d' "$index")")"
        port="$(next_available_relay_port "$port_start" "$port_end" "$home_rows_file" "$rows_file")"
        printf '%s,%s,%s\n' "$(csv_escape "$tag")" "$(csv_escape "$port")" "$(csv_escape "$line_value")" >>"$rows_file"
        any=true
        index=$((index + 1))
        ;;
      *)
        warn "暂不支持这一行；请粘贴 hysteria2://、vless://，或 tag,listen_port,node_url CSV。"
        ;;
    esac
  done
  [[ "$any" == "true" ]] || warn "未添加上游节点。"
}

run_install_flow() {
  local project_dir="$1" server_ip_ipv4="$2" server_ip_ipv6="$3" ssh_port="$4" admin_user="$5" enable_subscription_server="$6" subscription_port="$7" subscription_target="$8"
  cd "$project_dir"
  line
  printf '%b\n' "${GREEN}${BOLD}配置文件已生成：${RESET}"
  printf '  %s\n' "$project_dir/config.env" "$project_dir/home-proxies.csv" "$project_dir/upstream-nodes.txt"

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
  if [[ -n "$server_ip_ipv4" ]]; then
    printf 'IPv4:\n'
    printf '  ssh -p %q -o PreferredAuthentications=publickey -o PasswordAuthentication=no %q@%q\n' "$ssh_port" "$admin_user" "$server_ip_ipv4"
  fi
  if [[ -n "$server_ip_ipv6" ]]; then
    printf '\nIPv6:\n'
    printf '  ssh -p %q -o PreferredAuthentications=publickey -o PasswordAuthentication=no %q@%q\n' "$ssh_port" "$admin_user" "$server_ip_ipv6"
  fi
  printf '\n  whoami && sudo whoami\n\n'
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
  printf '%b\n' "${GREEN}${BOLD}部署完成。${RESET}"
  if [[ "$enable_subscription_server" == "true" ]]; then
    local token target_label target_path
    token="$(subscription_token)"
    target_label="$(subscription_target_label "$subscription_target")"
    target_path="/sub/${token}?target=${subscription_target}"
    printf '\n订阅链接：\n'
    if [[ -n "$server_ip_ipv4" ]]; then
      local h4
      h4="$(url_host "$server_ip_ipv4")"
      printf 'IPv4:\n'
      printf '  %s:  http://%s:%s%s\n' "$target_label" "$h4" "$subscription_port" "$target_path"
    fi
    if [[ -n "$server_ip_ipv6" ]]; then
      local h6
      h6="$(url_host "$server_ip_ipv6")"
      printf '\nIPv6:\n'
      printf '  %s:  http://%s:%s%s\n' "$target_label" "$h6" "$subscription_port" "$target_path"
    fi
    printf '\n说明：订阅内容按 SERVER_IP_IPV4/SERVER_IP_IPV6 生成；如果两者都填写，IPv4/IPv6 链接都返回同一份完整节点，IPv6 节点名称追加 -IPv6。\n'
    printf '如客户端无法导入 IPv6 字面量订阅地址，有 IPv4 时直接使用 IPv4 订阅地址即可。\n'
    printf '内置订阅服务是 HTTP；如需 HTTPS，请在外层接入带证书的反向代理。\n'
  else
    printf '\n订阅服务未启用。\n'
  fi
  printf '\n可选：如需在服务器本地生成节点文件，再执行：\n'
  printf '  sudo bash bootstrap.sh --phase output-nodes\n'
}

main() {
  banner
  local project_dir default_ip
  project_dir="$(ensure_project)"
  default_ip="$(public_ipv4)"

  line
  printf '%b\n' "${CYAN}${BOLD}基础信息${RESET}"
  local server_alias server_ip_ipv4 server_ip_ipv6 ssh_port admin_user admin_pubkey direct_port enable_subscription_server subscription_port subscription_target reset_proxy_keys home_port_start home_port_end
  server_alias="$(read_default "SERVER_ALIAS" "")"
  server_ip_ipv4="$(read_default "SERVER_IP_IPv4" "$default_ip")"
  server_ip_ipv6="$(read_default "SERVER_IP_IPv6" "")"
  ssh_port="$(read_default "SSH_PORT" "22")"
  admin_user="$(read_default "ADMIN_USER" "admin")"
  direct_port="$(read_default "DIRECT_PORT" "443")"

  line
  printf '%b\n' "${CYAN}${BOLD}节点订阅配置${RESET}"
  reset_proxy_keys="$(read_bool_value "RESET_PROXY_KEYS" "false")"
  enable_subscription_server="$(read_bool_value "ENABLE_SUBSCRIPTION_SERVER" "true")"
  subscription_port="51040"
  subscription_target="VLESS_REALITY"
  if [[ "$enable_subscription_server" == "true" ]]; then
    subscription_port="$(read_default "SUBSCRIPTION_PORT" "51040")"
    subscription_target="$(read_subscription_target "SUBSCRIPTION_TARGET" "VLESS_REALITY")"
  fi
  home_port_start="$(read_default "HOME_PORT_START" "51043")"
  home_port_end="$(read_default "HOME_PORT_END" "51060")"

  [[ -n "$server_alias" ]] || die "SERVER_ALIAS 不能为空。"
  [[ -n "$server_ip_ipv4" || -n "$server_ip_ipv6" ]] || die "SERVER_IP_IPv4 和 SERVER_IP_IPv6 至少填写一个。"

  ADMIN_KEYS_FILE="$(mktemp)"
  ROWS_FILE="$(mktemp)"
  UPSTREAM_ROWS_FILE="$(mktemp)"
  trap 'rm -f "${ADMIN_KEYS_FILE:-}" "${ROWS_FILE:-}" "${UPSTREAM_ROWS_FILE:-}"' EXIT
  ADMIN_USER="$admin_user" collect_admin_pubkeys "$ADMIN_KEYS_FILE"
  admin_pubkey="$(cat "$ADMIN_KEYS_FILE")"
  collect_home_proxies "$ROWS_FILE"
  collect_upstream_nodes "$UPSTREAM_ROWS_FILE" "$ROWS_FILE" "$home_port_start" "$home_port_end"

  write_config "$project_dir" "$server_alias" "$server_ip_ipv4" "$server_ip_ipv6" "$ssh_port" "$admin_user" "$admin_pubkey" "$direct_port" "$enable_subscription_server" "$subscription_port" "$subscription_target" "$reset_proxy_keys" "$home_port_start" "$home_port_end"
  write_home_proxies "$project_dir" "$ROWS_FILE"
  write_upstream_nodes "$project_dir" "$UPSTREAM_ROWS_FILE"
  run_install_flow "$project_dir" "$server_ip_ipv4" "$server_ip_ipv6" "$ssh_port" "$admin_user" "$enable_subscription_server" "$subscription_port" "$subscription_target"
}

main "$@"
