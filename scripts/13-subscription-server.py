#!/usr/bin/env python3
"""Serve IPv4-only subscriptions on IPv4 and dual-stack subscriptions on IPv6."""
from __future__ import annotations

import argparse
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import List, Tuple
from urllib.parse import urlsplit


class IPv6HTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def build_handler(root: Path, mode: str):
    files = {
        "/clash.yaml": ("clash.yaml", "text/yaml; charset=utf-8"),
        "/nodes.txt": ("nodes.txt", "text/plain; charset=utf-8"),
    }

    class SubscriptionHandler(BaseHTTPRequestHandler):
        server_version = "RRBSubscription/1.0"

        def log_message(self, format: str, *args) -> None:  # noqa: A002
            return

        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            if path == "/":
                self.send_body(200, b"subscription files: /clash.yaml /nodes.txt\n", "text/plain; charset=utf-8")
                return
            if path not in files:
                self.send_body(404, b"not found\n", "text/plain; charset=utf-8")
                return
            name, content_type = files[path]
            try:
                body = (root / mode / name).read_bytes()
            except OSError:
                self.send_body(503, b"subscription not ready\n", "text/plain; charset=utf-8")
                return
            self.send_body(200, body, content_type)

        def send_body(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    return SubscriptionHandler


def serve(server: ThreadingHTTPServer) -> None:
    server.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--ipv4", choices=["true", "false"], default="true")
    parser.add_argument("--ipv6", choices=["true", "false"], default="false")
    args = parser.parse_args()

    servers: List[Tuple[str, ThreadingHTTPServer]] = []
    if args.ipv4 == "true":
        servers.append(("ipv4", ThreadingHTTPServer(("0.0.0.0", args.port), build_handler(args.root, "ipv4"))))
    if args.ipv6 == "true":
        servers.append(("ipv6", IPv6HTTPServer(("::", args.port), build_handler(args.root, "dual"))))
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
