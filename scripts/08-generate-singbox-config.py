#!/usr/bin/env python3
"""
Generate /etc/sing-box/config.json from config.env and home-proxies.csv.

Security notes:
- Inbound protocol is VLESS + Reality.
- This script never prints VLESS UUID, Reality private key, or home proxy passwords.
- CSV is parsed with Python's csv module, so quoted commas are supported.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

TAG_RE = re.compile(r"^[A-Za-z0-9_-]+$")
DOMAIN_RE = re.compile(r"^[A-Za-z0-9._-]+$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SHORT_ID_RE = re.compile(r"^[0-9a-fA-F]{0,16}$")
REQUIRED_COLUMNS = {
    "tag",
    "listen_port",
    "type",
    "server",
    "server_port",
    "username",
    "password",
    "network",
}

AI_DOMAINS = [
    "browser-intake-datadoghq.com",
    "chat.openai.com.cdn.cloudflare.net",
    "openai-api.arkoselabs.com",
    "openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
    "openaicomproductionae4b.blob.core.windows.net",
    "production-openaicom-storage.azureedge.net",
    "static.cloudflareinsights.com",
    "cdn.usefathom.com",
    "ai.google.dev",
    "alkalimakersuite-pa.clients6.google.com",
    "generativelanguage.googleapis.com",
    "makersuite.google.com",
    "copilot.microsoft.com",
]

AI_DOMAIN_SUFFIXES = [
    "perplexity.ai",
    "pplx.ai",
    "ai.com",
    "chatgpt.com",
    "chatgpt.livekit.cloud",
    "oaistatic.com",
    "oaiusercontent.com",
    "openai.com",
    "openaiapi-site.azureedge.net",
    "openaicom.imgix.net",
    "host.livekit.cloud",
    "turn.livekit.cloud",
    "anthropic.com",
    "claude.ai",
    "claude.com",
    "bard.google.com",
    "deepmind.com",
    "deepmind.google",
    "gemini.google.com",
    "generativeai.google",
    "proactivebackend-pa.googleapis.com",
    "aisandbox-pa.googleapis.com",
    "robinfrontend-pa.googleapis.com",
    "x.ai",
    "grok.com",
    "chorus.sh",
]

AI_DOMAIN_KEYWORDS = ["openai"]

AI_IP_CIDRS = [
    "24.199.123.28/32",
    "64.23.132.171/32",
]


class ConfigError(SystemExit):
    pass


def project_dir() -> Path:
    return Path(__file__).resolve().parents[1]


def parse_env_file(path: Path) -> Dict[str, str]:
    if not path.exists():
        raise ConfigError(f"找不到配置文件：{path}")
    env: Dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            continue
        if value:
            try:
                parts = shlex.split(value, comments=False, posix=True)
                env[key] = parts[0] if parts else ""
            except ValueError:
                env[key] = value.strip("'\"")
        else:
            env[key] = ""
    return env


def defaults(env: Dict[str, str]) -> Dict[str, str]:
    merged = dict(env)
    state_dir = merged.get("RRB_STATE_DIR") or "/etc/reality-relay-bootstrap"
    d = {
        "SERVER_ALIAS": "my-vps",
        "SERVER_IP": "",
        "SSH_PORT": "22",
        "INITIAL_USER": "root",
        "ADMIN_USER": "admin",
        "ADMIN_PUBKEY": "",
        "ADMIN_PUBKEYS": "",
        "ENABLE_SFTP_USER": "false",
        "SFTP_USER": "sftpuser",
        "USE_233BOY_INSTALLER": "false",
        "INSTALL_SINGBOX_METHOD": "apt",
        "PROXY_PROTOCOL": "vless-reality",
        "MODE_443": "direct",
        "DIRECT_PORT": "443",
        "HOME_PORT_START": "51043",
        "HOME_PORT_END": "51060",
        "ENABLE_UFW": "true",
        "ENABLE_FAIL2BAN": "true",
        "ENABLE_IPV6_LISTEN": "false",
        "CSV_PATH": "./home-proxies.csv",
        "RRB_STATE_DIR": state_dir,
        "SINGBOX_CONFIG_PATH": "/etc/sing-box/config.json",
        "VLESS_UUID_PATH": f"{state_dir}/vless-uuid.txt",
        "VLESS_FLOW": "xtls-rprx-vision",
        "REALITY_PRIVATE_KEY_PATH": f"{state_dir}/reality-private.key",
        "REALITY_PUBLIC_KEY_PATH": f"{state_dir}/reality-public.key",
        "REALITY_SHORT_ID_PATH": f"{state_dir}/reality-short-id.txt",
        "REALITY_SERVER_NAME": "www.microsoft.com",
        "REALITY_HANDSHAKE_SERVER": "www.microsoft.com",
        "REALITY_HANDSHAKE_PORT": "443",
        "REALITY_MAX_TIME_DIFFERENCE": "1m",
        "SMART_AI_HOME_TAG": "",
        "REJECT_CN_PRIVATE": "true",
        "CLIENT_FINGERPRINT": "chrome",
        "CLIENT_UDP": "false",
        "CLIENT_ALPN": "h2,http/1.1",
        "CLASH_MIXED_PORT": "7890",
    }
    for k, v in d.items():
        merged.setdefault(k, v)

    default_state_dir = "/etc/reality-relay-bootstrap"
    if merged["RRB_STATE_DIR"] != default_state_dir:
        default_paths = {
            "VLESS_UUID_PATH": "vless-uuid.txt",
            "REALITY_PRIVATE_KEY_PATH": "reality-private.key",
            "REALITY_PUBLIC_KEY_PATH": "reality-public.key",
            "REALITY_SHORT_ID_PATH": "reality-short-id.txt",
        }
        for key, filename in default_paths.items():
            if merged.get(key) == f"{default_state_dir}/{filename}":
                merged[key] = f"{merged['RRB_STATE_DIR']}/{filename}"
    return merged


def as_bool(env: Dict[str, str], key: str) -> bool:
    value = env.get(key, "").lower()
    if value not in {"true", "false"}:
        raise ConfigError(f"{key} 必须是 true 或 false，当前：{env.get(key)}")
    return value == "true"


def as_port(env: Dict[str, str], key: str) -> int:
    value = env.get(key, "")
    if not value.isdigit():
        raise ConfigError(f"{key} 必须是数字端口，当前：{value}")
    port = int(value)
    if not 1 <= port <= 65535:
        raise ConfigError(f"{key} 超出端口范围 1-65535：{port}")
    return port


def resolve_path(env: Dict[str, str], key: str, base: Path) -> Path:
    value = env[key]
    p = Path(value)
    if not p.is_absolute():
        p = base / value.lstrip("./")
    return p


def validate_env(env: Dict[str, str]) -> None:
    as_port(env, "SSH_PORT")
    direct_port = as_port(env, "DIRECT_PORT")
    start = as_port(env, "HOME_PORT_START")
    end = as_port(env, "HOME_PORT_END")
    as_port(env, "REALITY_HANDSHAKE_PORT")
    if start > end:
        raise ConfigError("HOME_PORT_START 不能大于 HOME_PORT_END")
    if env["PROXY_PROTOCOL"] != "vless-reality":
        raise ConfigError("PROXY_PROTOCOL 当前只支持 vless-reality")
    if env["MODE_443"] not in {"direct", "smart"}:
        raise ConfigError("MODE_443 只能是 direct 或 smart")
    if not env["SERVER_ALIAS"].strip():
        raise ConfigError("SERVER_ALIAS 不能为空；它会作为 443 节点名称")
    if env["INSTALL_SINGBOX_METHOD"] not in {"apt", "233boy"}:
        raise ConfigError("INSTALL_SINGBOX_METHOD 只能是 apt 或 233boy")
    if env.get("VLESS_FLOW", "") not in {"", "xtls-rprx-vision"}:
        raise ConfigError("VLESS_FLOW 目前建议为空或 xtls-rprx-vision")
    for key in ["REALITY_SERVER_NAME", "REALITY_HANDSHAKE_SERVER"]:
        if not DOMAIN_RE.match(env[key]):
            raise ConfigError(f"{key} 不合法：{env[key]}")
    for key in [
        "ENABLE_SFTP_USER",
        "USE_233BOY_INSTALLER",
        "ENABLE_UFW",
        "ENABLE_FAIL2BAN",
        "ENABLE_IPV6_LISTEN",
        "REJECT_CN_PRIVATE",
        "CLIENT_UDP",
    ]:
        as_bool(env, key)
    if direct_port != 443:
        print(f"WARN: DIRECT_PORT={direct_port}，不是默认 443。", file=sys.stderr)
    if as_bool(env, "ENABLE_IPV6_LISTEN"):
        print("WARN: ENABLE_IPV6_LISTEN=true，将监听 ::，请确认 IPv6 暴露风险。", file=sys.stderr)


def iter_csv_lines(path: Path) -> Iterable[str]:
    for line in path.read_text(encoding="utf-8-sig").splitlines(True):
        if line.strip() and not line.lstrip().startswith("#"):
            yield line


def load_rows(env: Dict[str, str], base: Path, allow_empty: bool = True) -> List[Dict[str, Any]]:
    csv_path = resolve_path(env, "CSV_PATH", base)
    if not csv_path.exists():
        state_csv = Path(env["RRB_STATE_DIR"]) / "home-proxies.csv"
        if state_csv.exists():
            csv_path = state_csv
        else:
            raise ConfigError(f"找不到 CSV：{csv_path}")

    try:
        reader = csv.DictReader(iter_csv_lines(csv_path))
    except UnicodeDecodeError as exc:
        raise ConfigError(f"CSV 必须是 UTF-8：{exc}") from exc

    if not reader.fieldnames:
        if allow_empty:
            return []
        raise ConfigError("CSV 没有表头")

    missing = REQUIRED_COLUMNS - set(reader.fieldnames)
    if missing:
        raise ConfigError("CSV 表头缺少字段：" + ", ".join(sorted(missing)))

    direct_port = as_port(env, "DIRECT_PORT")
    start = as_port(env, "HOME_PORT_START")
    end = as_port(env, "HOME_PORT_END")
    used_tags = set()
    used_ports = {direct_port}
    rows: List[Dict[str, Any]] = []

    for lineno, row in enumerate(reader, start=2):
        normalized = {k: (v or "").strip() for k, v in row.items()}
        if not any(normalized.values()):
            continue

        tag = normalized["tag"]
        proto = normalized["type"].lower()
        network = (normalized.get("network") or "tcp").lower()

        if not TAG_RE.match(tag):
            raise ConfigError(f"第 {lineno} 行 tag 不合法：{tag}；只能用英文、数字、下划线、短横线")
        if tag in used_tags:
            raise ConfigError(f"第 {lineno} 行 tag 重复：{tag}")
        used_tags.add(tag)

        try:
            listen_port = int(normalized["listen_port"])
            server_port = int(normalized["server_port"])
        except ValueError as exc:
            raise ConfigError(f"第 {lineno} 行 listen_port/server_port 必须是数字") from exc

        if not (1 <= listen_port <= 65535 and 1 <= server_port <= 65535):
            raise ConfigError(f"第 {lineno} 行端口超出范围 1-65535")
        if listen_port == direct_port:
            raise ConfigError(f"第 {lineno} 行 listen_port 不能使用 {direct_port}；该端口保留给 443 入口")
        if listen_port in used_ports:
            raise ConfigError(f"第 {lineno} 行 listen_port 重复：{listen_port}")
        if not (start <= listen_port <= end):
            raise ConfigError(f"第 {lineno} 行 listen_port={listen_port} 不在 HOME_PORT_START/HOME_PORT_END 范围 {start}-{end}")
        used_ports.add(listen_port)

        if proto not in {"socks5", "socks", "http"}:
            raise ConfigError(f"第 {lineno} 行 type 只支持 socks5 或 http")
        if network not in {"tcp", "udp"}:
            raise ConfigError(f"第 {lineno} 行 network 只支持 tcp 或 udp")
        if proto == "http" and network == "udp":
            print(f"WARN: 第 {lineno} 行 {tag} 是 HTTP 代理，通常只支持 TCP；生成配置将不为 HTTP 出站设置 UDP。", file=sys.stderr)
        if not normalized["server"]:
            raise ConfigError(f"第 {lineno} 行 server 不能为空")

        rows.append(
            {
                "tag": tag,
                "listen_port": listen_port,
                "type": "socks5" if proto == "socks" else proto,
                "server": normalized["server"],
                "server_port": server_port,
                "username": normalized["username"],
                "password": normalized["password"],
                "network": network,
            }
        )

    if env["MODE_443"] == "smart" and not rows:
        raise ConfigError("MODE_443=smart 需要至少一行家宽代理，用于 AI 域名出口。")
    if not rows and not allow_empty:
        raise ConfigError("home-proxies.csv 没有任何家宽代理行。")
    return rows


def read_secret_file(path: str, label: str) -> str:
    p = Path(path)
    if not p.exists():
        raise ConfigError(f"找不到 {label} 文件：{p}；请先运行 sudo bash bootstrap.sh --phase singbox")
    value = p.read_text(encoding="utf-8").strip()
    if not value:
        raise ConfigError(f"{label} 文件为空：{p}")
    return value


def read_vless_uuid(env: Dict[str, str]) -> str:
    value = read_secret_file(env["VLESS_UUID_PATH"], "VLESS UUID")
    if not UUID_RE.match(value):
        raise ConfigError(f"VLESS UUID 格式不合法：{env['VLESS_UUID_PATH']}")
    return value


def read_reality_private_key(env: Dict[str, str]) -> str:
    return read_secret_file(env["REALITY_PRIVATE_KEY_PATH"], "Reality private key")


def read_reality_public_key(env: Dict[str, str]) -> str:
    return read_secret_file(env["REALITY_PUBLIC_KEY_PATH"], "Reality public key")


def read_reality_short_id(env: Dict[str, str]) -> str:
    value = read_secret_file(env["REALITY_SHORT_ID_PATH"], "Reality short-id")
    if not SHORT_ID_RE.match(value) or len(value) % 2 != 0:
        raise ConfigError("Reality short-id 必须是 0-16 位、偶数长度的十六进制字符串")
    return value.lower()


def build_vless_reality_inbound(tag: str, port: int, uuid: str, private_key: str, short_id: str, env: Dict[str, str]) -> Dict[str, Any]:
    listen = "::" if as_bool(env, "ENABLE_IPV6_LISTEN") else "0.0.0.0"
    user: Dict[str, Any] = {"name": env["ADMIN_USER"], "uuid": uuid}
    if env.get("VLESS_FLOW", ""):
        user["flow"] = env["VLESS_FLOW"]

    reality: Dict[str, Any] = {
        "enabled": True,
        "handshake": {
            "server": env["REALITY_HANDSHAKE_SERVER"],
            "server_port": as_port(env, "REALITY_HANDSHAKE_PORT"),
        },
        "private_key": private_key,
        "short_id": [short_id],
    }
    if env.get("REALITY_MAX_TIME_DIFFERENCE", ""):
        reality["max_time_difference"] = env["REALITY_MAX_TIME_DIFFERENCE"]

    return {
        "type": "vless",
        "tag": tag,
        "listen": listen,
        "listen_port": port,
        "users": [user],
        "tls": {
            "enabled": True,
            "server_name": env["REALITY_SERVER_NAME"],
            "reality": reality,
        },
    }


def build_home_outbound(row: Dict[str, Any]) -> Dict[str, Any]:
    tag = f"out-{row['tag']}"
    if row["type"] in {"socks", "socks5"}:
        outbound: Dict[str, Any] = {
            "type": "socks",
            "tag": tag,
            "server": row["server"],
            "server_port": row["server_port"],
            "version": "5",
            "network": row["network"],
            "domain_resolver": "dns-cloudflare",
        }
        if row["username"]:
            outbound["username"] = row["username"]
        if row["password"]:
            outbound["password"] = row["password"]
        return outbound

    outbound = {
        "type": "http",
        "tag": tag,
        "server": row["server"],
        "server_port": row["server_port"],
        "domain_resolver": "dns-cloudflare",
    }
    if row["username"]:
        outbound["username"] = row["username"]
    if row["password"]:
        outbound["password"] = row["password"]
    return outbound


def select_ai_outbound(env: Dict[str, str], rows: List[Dict[str, Any]]) -> Tuple[str, str]:
    requested = env.get("SMART_AI_HOME_TAG", "").strip()
    if requested:
        for row in rows:
            if row["tag"] == requested:
                return f"out-{row['tag']}", row["tag"]
        available = ", ".join(row["tag"] for row in rows)
        raise ConfigError(f"SMART_AI_HOME_TAG={requested} 不存在；可用 tag：{available}")
    if rows:
        first = rows[0]
        return f"out-{first['tag']}", first["tag"]
    return "direct", "direct"


def build_config(env: Dict[str, str], rows: List[Dict[str, Any]], uuid: str, private_key: str, short_id: str) -> Dict[str, Any]:
    direct_port = as_port(env, "DIRECT_PORT")
    direct_inbound_tag = "vless-direct-443" if env["MODE_443"] == "direct" else "vless-smart-443"

    inbounds = [build_vless_reality_inbound(direct_inbound_tag, direct_port, uuid, private_key, short_id, env)]
    for row in rows:
        inbounds.append(build_vless_reality_inbound(f"vless-{row['tag']}", row["listen_port"], uuid, private_key, short_id, env))

    outbounds: List[Dict[str, Any]] = [{"type": "direct", "tag": "direct"}]
    for row in rows:
        outbounds.append(build_home_outbound(row))
    outbounds.append({"type": "block", "tag": "block"})

    route_rules: List[Dict[str, Any]] = [
        {"action": "sniff", "timeout": "1s"},
        {"protocol": "dns", "action": "hijack-dns"},
    ]

    if env["MODE_443"] == "direct":
        route_rules.append({"inbound": direct_inbound_tag, "action": "route", "outbound": "direct"})

    if as_bool(env, "REJECT_CN_PRIVATE"):
        route_rules.extend(
            [
                {"ip_is_private": True, "action": "reject"},
                {"rule_set": ["geosite-cn", "geoip-cn"], "action": "reject"},
            ]
        )

    if env["MODE_443"] == "smart":
        ai_outbound_tag, _ = select_ai_outbound(env, rows)
        route_rules.append(
            {
                "inbound": direct_inbound_tag,
                "domain": AI_DOMAINS,
                "domain_suffix": AI_DOMAIN_SUFFIXES,
                "domain_keyword": AI_DOMAIN_KEYWORDS,
                "ip_cidr": AI_IP_CIDRS,
                "action": "route",
                "outbound": ai_outbound_tag,
            }
        )
        route_rules.append({"inbound": direct_inbound_tag, "action": "route", "outbound": "direct"})

    for row in rows:
        route_rules.append({"inbound": f"vless-{row['tag']}", "action": "route", "outbound": f"out-{row['tag']}"})

    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {
                    "type": "https",
                    "tag": "dns-cloudflare",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                },
                {
                    "type": "https",
                    "tag": "dns-google",
                    "server": "8.8.8.8",
                    "server_port": 443,
                    "path": "/dns-query",
                },
            ],
            "final": "dns-cloudflare",
            "strategy": "ipv4_only",
            "cache_capacity": 4096,
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": "dns-cloudflare",
            "rules": route_rules,
            "rule_set": [
                {
                    "type": "remote",
                    "tag": "geosite-cn",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                    "download_detour": "direct",
                    "update_interval": "24h",
                },
                {
                    "type": "remote",
                    "tag": "geoip-cn",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                    "download_detour": "direct",
                    "update_interval": "24h",
                },
            ],
            "final": "block",
        },
        "experimental": {"cache_file": {"enabled": True}},
    }


def port_list(env: Dict[str, str], rows: List[Dict[str, Any]]) -> List[int]:
    ports = [as_port(env, "DIRECT_PORT")]
    ports.extend(int(r["listen_port"]) for r in rows)
    return sorted(set(ports))


def node_list(env: Dict[str, str], rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    direct_port = as_port(env, "DIRECT_PORT")
    direct_name = env["SERVER_ALIAS"]
    nodes = [{"name": direct_name, "port": direct_port, "kind": env["MODE_443"]}]
    for row in rows:
        nodes.append(
            {
                "name": row["tag"],
                "port": row["listen_port"],
                "kind": "home",
                "home_tag": row["tag"],
            }
        )
    return nodes


def print_summary(env: Dict[str, str], rows: List[Dict[str, Any]]) -> None:
    print("配置检查通过。")
    print("入站协议：VLESS + Reality")
    print(f"443 模式：{env['MODE_443']}，端口：{env['DIRECT_PORT']}")
    print(f"Reality server_name：{env['REALITY_SERVER_NAME']}")
    print(f"Reality handshake：{env['REALITY_HANDSHAKE_SERVER']}:{env['REALITY_HANDSHAKE_PORT']}")
    if env["MODE_443"] == "smart":
        outbound, tag = select_ai_outbound(env, rows)
        print(f"Smart 443 AI 出口：{tag} ({outbound})")
    print("将开放端口：" + ", ".join(str(p) for p in port_list(env, rows)))
    if rows:
        print("家宽映射：")
        for row in rows:
            print(f"  {row['tag']} {row['listen_port']} -> {row['type']}://{row['server']}:{row['server_port']}")
    else:
        print("CSV 无家宽行；仅生成 443 入口。")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config-env", default=str(project_dir() / "config.env"))
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--print-ports", action="store_true")
    ap.add_argument("--print-nodes-json", action="store_true")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="only validate/write without printing the human summary")
    args = ap.parse_args()

    env_path = Path(args.config_env).resolve()
    base = env_path.parent if env_path.exists() else project_dir()
    env = defaults(parse_env_file(env_path))
    validate_env(env)
    rows = load_rows(env, base, allow_empty=True)

    if args.print_ports:
        for p in port_list(env, rows):
            print(p)
        return 0

    if args.print_nodes_json:
        print(json.dumps(node_list(env, rows), ensure_ascii=False))
        return 0

    if args.check_only:
        if not args.quiet:
            print_summary(env, rows)
        return 0

    if args.summary:
        print_summary(env, rows)
        return 0

    if args.write:
        if os.environ.get("RRB_DRY_RUN") == "true":
            print("DRY-RUN: 将生成 VLESS+Reality sing-box 配置，但不会写入文件。")
            print_summary(env, rows)
            return 0
        uuid = read_vless_uuid(env)
        private_key = read_reality_private_key(env)
        short_id = read_reality_short_id(env)
        config = build_config(env, rows, uuid, private_key, short_id)
        config_path = Path(env["SINGBOX_CONFIG_PATH"])
        config_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = config_path.with_name(config_path.name + ".tmp")
        tmp.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(config_path)
        os.chmod(config_path, 0o600)
        if not args.quiet:
            print(f"已生成 {config_path}")
            print_summary(env, rows)
        return 0

    ap.error("请指定 --check-only、--write、--print-ports、--print-nodes-json 或 --summary")
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
