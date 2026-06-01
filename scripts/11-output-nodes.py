#!/usr/bin/env python3
"""Generate VLESS+Reality node text and Clash/Mihomo YAML."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, List


def load_generator(path: Path):
    spec = importlib.util.spec_from_file_location("gen", path)
    gen = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(gen)
    return gen


def q(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


def yaml_bool(value: bool) -> str:
    return "true" if value else "false"


def get_server_ip(env: Dict[str, str]) -> str:
    if env.get("SERVER_IP", "").strip():
        return env["SERVER_IP"].strip()
    try:
        proc = subprocess.run(
            ["curl", "-4", "-fsS", "--max-time", "10", "https://ifconfig.me"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        ip = proc.stdout.strip()
        if ip:
            return ip
    except Exception:
        pass
    raise SystemExit("SERVER_IP 为空且无法自动获取公网 IP；请在 config.env 填写 SERVER_IP。")


def build_nodes(env: Dict[str, str], rows: List[Dict[str, Any]], gen) -> List[Dict[str, Any]]:
    uuid = gen.read_vless_uuid(env)
    public_key = gen.read_reality_public_key(env)
    short_id = gen.read_reality_short_id(env)
    server = get_server_ip(env)
    alpn = [item.strip() for item in env["CLIENT_ALPN"].split(",") if item.strip()]
    udp = gen.as_bool(env, "CLIENT_UDP")

    nodes = []
    for item in gen.node_list(env, rows):
        node: Dict[str, Any] = {
            "name": item["name"],
            "type": "vless",
            "server": server,
            "port": int(item["port"]),
            "uuid": uuid,
            "tls": True,
            "servername": env["REALITY_SERVER_NAME"],
            "client-fingerprint": env["CLIENT_FINGERPRINT"],
            "reality-opts": {
                "public-key": public_key,
                "short-id": short_id,
            },
            "udp": udp,
            "alpn": alpn,
            "kind": item.get("kind", ""),
        }
        if env.get("VLESS_FLOW", ""):
            node["flow"] = env["VLESS_FLOW"]
        nodes.append(node)
    return nodes


def node_to_text(node: Dict[str, Any]) -> str:
    alpn = ",".join(node["alpn"])
    lines = [
        f"name={node['name']}",
        "type=vless",
        f"server={node['server']}",
        f"port={node['port']}",
        f"uuid={node['uuid']}",
    ]
    if node.get("flow"):
        lines.append(f"flow={node['flow']}")
    lines.extend(
        [
            "tls=true",
            f"servername={node['servername']}",
            f"client-fingerprint={node['client-fingerprint']}",
            f"reality-public-key={node['reality-opts']['public-key']}",
            f"reality-short-id={node['reality-opts']['short-id']}",
            f"udp={str(node['udp']).lower()}",
            f"alpn={alpn}",
        ]
    )
    return "\n".join(lines) + "\n"


def build_clash_yaml(env: Dict[str, str], nodes: List[Dict[str, Any]]) -> str:
    names = [node["name"] for node in nodes]
    ipv6_enabled = env["PROXY_IP_VERSION"] in {"ipv6", "dual"}
    lines = [
        f"mixed-port: {env['CLASH_MIXED_PORT']}",
        "allow-lan: false",
        "mode: rule",
        "log-level: info",
        f"ipv6: {yaml_bool(ipv6_enabled)}",
        "",
        "proxies:",
    ]
    for node in nodes:
        lines.extend(
            [
                f"  - name: {q(node['name'])}",
                "    type: vless",
                f"    server: {q(node['server'])}",
                f"    port: {node['port']}",
                f"    uuid: {q(node['uuid'])}",
            ]
        )
        if node.get("flow"):
            lines.append(f"    flow: {q(node['flow'])}")
        lines.extend(
            [
                "    tls: true",
                f"    servername: {q(node['servername'])}",
                f"    client-fingerprint: {q(node['client-fingerprint'])}",
                f"    udp: {yaml_bool(node['udp'])}",
                "    reality-opts:",
                f"      public-key: {q(node['reality-opts']['public-key'])}",
                f"      short-id: {q(node['reality-opts']['short-id'])}",
                "    alpn:",
            ]
        )
        for item in node["alpn"]:
            lines.append(f"      - {q(item)}")
        lines.append("")
    lines.extend(
        [
            "proxy-groups:",
            "  - name: PROXY",
            "    type: select",
            "    proxies:",
        ]
    )
    for name in names:
        lines.append(f"      - {q(name)}")
    lines.extend(["      - DIRECT", "", "rules:", "  - MATCH,PROXY", ""])
    return "\n".join(lines)


def mask(value: str) -> str:
    if len(value) <= 8:
        return "***"
    return value[:4] + "..." + value[-4:]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config-env", required=True)
    ap.add_argument("--generator", required=True)
    ap.add_argument("--nodes-out", default="/root/reality-relay-bootstrap-nodes.txt")
    ap.add_argument("--clash-out", default="/root/reality-relay-bootstrap-clash.yaml")
    args = ap.parse_args()

    env_path = Path(args.config_env).resolve()
    gen = load_generator(Path(args.generator))
    env = gen.defaults(gen.parse_env_file(env_path))
    gen.validate_env(env)
    rows = gen.load_rows(env, env_path.parent, allow_empty=True)
    nodes = build_nodes(env, rows, gen)

    nodes_text = "\n---\n".join(node_to_text(node) for node in nodes) + "\n"
    clash_yaml = build_clash_yaml(env, nodes)

    for out, text in [(args.nodes_out, nodes_text), (args.clash_out, clash_yaml)]:
        path = Path(out)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)

    print(f"已生成节点文件：{args.nodes_out}")
    print(f"已生成 Clash/Mihomo 文件：{args.clash_out}")
    print("控制台脱敏摘要：")
    for node in nodes:
        print(
            f"  {node['name']}: {node['server']}:{node['port']} "
            f"servername={node['servername']} uuid={mask(node['uuid'])} "
            f"reality-public-key={mask(node['reality-opts']['public-key'])} "
            f"short-id={mask(node['reality-opts']['short-id'])} udp={str(node['udp']).lower()}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
