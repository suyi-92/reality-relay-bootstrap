#!/usr/bin/env python3
"""Ensure Cloudflare DNS records for a custom Reality domain."""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE = "https://api.cloudflare.com/client/v4"


class CloudflareError(SystemExit):
    pass


def load_generator(path: Path):
    spec = importlib.util.spec_from_file_location("gen", path)
    gen = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(gen)
    return gen


def read_cloudflare_token(env: Dict[str, str]) -> str:
    token = env.get("CLOUDFLARE_API_TOKEN", "").strip()
    if token:
        return token
    credentials = Path(env.get("CLOUDFLARE_API_TOKEN_FILE", ""))
    if credentials.exists():
        for raw in credentials.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\s*dns_cloudflare_api_token\s*=\s*(.+?)\s*$", raw)
            if match:
                return match.group(1).strip()
    raise CloudflareError("缺少 Cloudflare API token：请设置 CLOUDFLARE_API_TOKEN 或准备 CLOUDFLARE_API_TOKEN_FILE。")


def cf_request(token: str, method: str, path: str, *, query: Optional[Dict[str, str]] = None, data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    url = API_BASE + path
    if query:
        url += "?" + urlencode(query)
    body = None if data is None else json.dumps(data).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    request = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8"))
        except Exception:
            payload = {"success": False, "errors": [{"message": str(exc)}]}
        raise CloudflareError(format_cf_errors(payload, f"Cloudflare API {method} {path} 失败，HTTP {exc.code}")) from exc
    except (OSError, URLError) as exc:
        raise CloudflareError(f"Cloudflare API 请求失败：{exc}") from exc
    if not payload.get("success"):
        raise CloudflareError(format_cf_errors(payload, f"Cloudflare API {method} {path} 返回失败"))
    return payload


def format_cf_errors(payload: Dict[str, Any], prefix: str) -> str:
    errors = payload.get("errors") or []
    messages = []
    for item in errors:
        code = item.get("code")
        message = item.get("message") or item
        messages.append(f"{code}: {message}" if code else str(message))
    return prefix + ("：" + "；".join(messages) if messages else "")


def find_zone(token: str, zone_name: str) -> Optional[Dict[str, Any]]:
    payload = cf_request(token, "GET", "/zones", query={"name": zone_name, "per_page": "1"})
    result = payload.get("result") or []
    return result[0] if result else None


def create_zone(token: str, account_id: str, zone_name: str) -> Dict[str, Any]:
    payload = cf_request(
        token,
        "POST",
        "/zones",
        data={
            "account": {"id": account_id},
            "name": zone_name,
            "type": "full",
        },
    )
    return payload["result"]


def desired_records(env: Dict[str, str]) -> List[Tuple[str, str]]:
    records: List[Tuple[str, str]] = []
    ipv4 = env.get("SERVER_IP_IPV4", "").strip()
    ipv6 = env.get("SERVER_IP_IPV6", "").strip()
    if ipv4:
        records.append(("A", ipv4))
    if ipv6:
        records.append(("AAAA", ipv6))
    if not records:
        raise CloudflareError("SERVER_IP_IPV4 和 SERVER_IP_IPV6 至少需要一个，用于创建 Cloudflare A/AAAA 记录。")
    return records


def record_payload(env: Dict[str, str], record_type: str, content: str) -> Dict[str, Any]:
    return {
        "type": record_type,
        "name": env["CUSTOM_DOMAIN"],
        "content": content,
        "ttl": int(env["CLOUDFLARE_DNS_TTL"]),
        "proxied": False,
        "comment": env["SERVER_ALIAS"],
    }


def list_records(token: str, zone_id: str, record_type: str, name: str) -> List[Dict[str, Any]]:
    payload = cf_request(token, "GET", f"/zones/{zone_id}/dns_records", query={"type": record_type, "name": name, "per_page": "100"})
    return payload.get("result") or []


def upsert_record(token: str, zone_id: str, env: Dict[str, str], record_type: str, content: str) -> str:
    records = list_records(token, zone_id, record_type, env["CUSTOM_DOMAIN"])
    payload = record_payload(env, record_type, content)
    if records:
        exact = next((record for record in records if record.get("content") == content), None)
        target = exact or records[0]
        if not exact and env["CLOUDFLARE_DNS_OVERWRITE_EXISTING"] != "true":
            current = ", ".join(record.get("content", "") for record in records)
            raise CloudflareError(f"{record_type} {env['CUSTOM_DOMAIN']} 已存在且内容不是 {content}：{current}；如确认覆盖，设置 CLOUDFLARE_DNS_OVERWRITE_EXISTING=true。")
        cf_request(token, "PATCH", f"/zones/{zone_id}/dns_records/{target['id']}", data=payload)
        return "updated"
    cf_request(token, "POST", f"/zones/{zone_id}/dns_records", data=payload)
    return "created"


def print_zone_guidance(zone: Dict[str, Any]) -> None:
    status = zone.get("status", "unknown")
    nameservers = zone.get("name_servers") or []
    print(f"Cloudflare zone：{zone.get('name')} status={status}")
    if status != "active" and nameservers:
        print("请到域名注册商处把 NS 改成 Cloudflare 分配的 nameserver：")
        for item in nameservers:
            print(f"  - {item}")


def dry_run_summary(env: Dict[str, str]) -> None:
    print("DRY-RUN: 将检查/准备 Cloudflare DNS：")
    print(f"  zone: {env['CLOUDFLARE_ZONE_NAME']}")
    print(f"  record: {env['CUSTOM_DOMAIN']}")
    for record_type, content in desired_records(env):
        print(f"  {record_type}: {content} proxied=false ttl={env['CLOUDFLARE_DNS_TTL']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-env", required=True)
    parser.add_argument("--generator", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    gen = load_generator(Path(args.generator))
    env_path = Path(args.config_env).resolve()
    env = gen.defaults(gen.parse_env_file(env_path))
    gen.validate_env(env)

    if env["ENABLE_CUSTOM_DOMAIN"] != "true":
        print("ENABLE_CUSTOM_DOMAIN=false，跳过 Cloudflare DNS 准备。")
        return 0
    if env["CLOUDFLARE_ENSURE_DNS_RECORDS"] != "true":
        print("CLOUDFLARE_ENSURE_DNS_RECORDS=false，跳过 Cloudflare DNS 记录创建。")
        return 0
    if args.dry_run:
        dry_run_summary(env)
        return 0

    token = read_cloudflare_token(env)
    zone = find_zone(token, env["CLOUDFLARE_ZONE_NAME"])
    if not zone:
        if env["CLOUDFLARE_CREATE_ZONE"] == "true":
            zone = create_zone(token, env["CLOUDFLARE_ACCOUNT_ID"], env["CLOUDFLARE_ZONE_NAME"])
        else:
            raise CloudflareError(
                f"Cloudflare 账号中找不到 zone：{env['CLOUDFLARE_ZONE_NAME']}。请先在 Cloudflare 添加域名并把注册商 NS 改到 Cloudflare，或设置 CLOUDFLARE_CREATE_ZONE=true + CLOUDFLARE_ACCOUNT_ID。"
            )

    print_zone_guidance(zone)
    zone_id = zone["id"]
    for record_type, content in desired_records(env):
        action = upsert_record(token, zone_id, env, record_type, content)
        print(f"{action}: {record_type} {env['CUSTOM_DOMAIN']} -> {content} proxied=false")
    if env.get("CLOUDFLARE_REQUIRE_ACTIVE_ZONE", "true") == "true" and zone.get("status") != "active":
        raise CloudflareError("Cloudflare zone 尚未 active。请先到域名注册商把 NS 改成 Cloudflare 分配的 nameserver，并等待 Cloudflare 显示 active 后再继续申请证书。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CloudflareError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
