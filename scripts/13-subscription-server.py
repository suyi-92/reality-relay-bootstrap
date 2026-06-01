#!/usr/bin/env python3
"""Serve token-protected subscription files on IPv4 and/or IPv6."""
from __future__ import annotations

import argparse
import re
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Tuple
from urllib.parse import parse_qs, unquote, urlsplit


TARGET_FILES: Dict[str, Tuple[str, str]] = {
    "ClashMeta": ("clashmeta.yaml", "text/yaml; charset=utf-8"),
    "V2Ray": ("v2ray.txt", "text/plain; charset=utf-8"),
    "QX": ("qx.txt", "text/plain; charset=utf-8"),
    "ShadowRocket": ("shadowrocket.txt", "text/plain; charset=utf-8"),
}


class ReusableHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class IPv6HTTPServer(ReusableHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def normalize_target(value: str) -> str:
    compact = re.sub(r"[\s_-]+", "", (value or "ClashMeta").lower())
    aliases = {
        "mihomo": "ClashMeta",
        "clash": "ClashMeta",
        "clashmeta": "ClashMeta",
        "v2ray": "V2Ray",
        "v2rayn": "V2Ray",
        "v2rayng": "V2Ray",
        "qx": "QX",
        "quanx": "QX",
        "quantumult": "QX",
        "quantumultx": "QX",
        "shadowrocket": "ShadowRocket",
    }
    return aliases.get(compact, compact)


def read_token(token_file: Path) -> str:
    try:
        return token_file.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def split_token_and_target(raw_tail: str, query: str, default_target: str) -> Tuple[str, str]:
    token = raw_tail
    path_target = ""
    if "/" in token:
        token, path_target = token.split("/", 1)
    if "&" in raw_tail:
        token, rest = raw_tail.split("&", 1)
        for part in rest.split("&"):
            key, sep, value = part.partition("=")
            if sep and key == "target":
                path_target = value
                break
    qs = parse_qs(query, keep_blank_values=True)
    query_target = (qs.get("target") or [""])[0]
    return unquote(token), normalize_target(unquote(query_target or path_target or default_target))


def build_handler(root: Path, token_file: Path, default_target: str):
    class SubscriptionHandler(BaseHTTPRequestHandler):
        server_version = "RRBSubscription/2.0"

        def log_message(self, format: str, *args) -> None:  # noqa: A002
            return

        def do_GET(self) -> None:
            split = urlsplit(self.path)
            if split.path == "/":
                self.send_body(200, b"subscription path: /sub/<token>/ClashMeta\n", "text/plain; charset=utf-8")
                return
            if not split.path.startswith("/sub/"):
                self.send_body(404, b"not found\n", "text/plain; charset=utf-8")
                return

            request_token, target = split_token_and_target(split.path[len("/sub/") :], split.query, default_target)
            expected_token = read_token(token_file)
            if not expected_token:
                self.send_body(503, b"subscription token not ready\n", "text/plain; charset=utf-8")
                return
            if request_token != expected_token:
                self.send_body(403, b"forbidden\n", "text/plain; charset=utf-8")
                return
            if target not in TARGET_FILES:
                self.send_body(400, b"unsupported target\n", "text/plain; charset=utf-8")
                return

            name, content_type = TARGET_FILES[target]
            try:
                body = (root / "all" / name).read_bytes()
            except OSError:
                self.send_body(404, b"target subscription not generated\n", "text/plain; charset=utf-8")
                return
            self.send_body(200, body, content_type)

        def do_OPTIONS(self) -> None:
            self.send_response(204)
            self.send_common_headers(0, "text/plain; charset=utf-8")
            self.end_headers()

        def send_body(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_common_headers(len(body), content_type)
            self.end_headers()
            self.wfile.write(body)

        def send_common_headers(self, body_len: int, content_type: str) -> None:
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(body_len))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "*")

    return SubscriptionHandler


def serve(server: ThreadingHTTPServer) -> None:
    server.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--ipv4", choices=["true", "false"], default="true")
    parser.add_argument("--ipv6", choices=["true", "false"], default="false")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--default-target", default="ClashMeta")
    args = parser.parse_args()

    default_target = normalize_target(args.default_target)
    if default_target not in TARGET_FILES:
        raise SystemExit(f"unsupported default target: {args.default_target}")

    handler = build_handler(args.root, args.token_file, default_target)
    servers: List[Tuple[str, ThreadingHTTPServer]] = []
    if args.ipv4 == "true":
        servers.append(("ipv4", ReusableHTTPServer(("0.0.0.0", args.port), handler)))
    if args.ipv6 == "true":
        servers.append(("ipv6", IPv6HTTPServer(("::", args.port), handler)))
    if not servers:
        raise SystemExit("at least one of --ipv4 or --ipv6 must be true")

    threads = []
    for _, server in servers:
        thread = threading.Thread(target=serve, args=(server,), daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
