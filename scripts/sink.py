#!/usr/bin/env python3
"""Tiny local HTTP sink for Maestro runs.

The assert scripts POST their findings here so the renderer can surface
the actual backend values (message_id, metrics, campaign) in the report,
instead of just a pass/fail tick.

Usage:
    sink.py <out_jsonl> [--port 0] [--port-file <path>]

Each POST is appended to <out_jsonl> as one JSON line, with the server's
receive timestamp merged in as `received_at_ms`.
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import TCPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            data = {"_raw": raw.decode(errors="replace")}
        data["received_at_ms"] = int(time.time() * 1000)
        data["path"] = self.path
        with open(self.server.out_path, "a") as f:
            f.write(json.dumps(data) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"sink ok\n")

    def log_message(self, *_):
        return


class LoopbackHTTPServer(HTTPServer):
    """HTTP server that binds without reverse-resolving the loopback address.

    HTTPServer.server_bind calls socket.getfqdn after binding. That lookup can
    block indefinitely on hosted macOS runners even though this process only
    needs a loopback listener. TCPServer performs the same socket bind without
    the unrelated hostname lookup.
    """

    def server_bind(self):
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    args = ap.parse_args()

    open(args.out, "w").close()  # truncate
    print(f"sink binding to 127.0.0.1:{args.port}", file=sys.stderr, flush=True)
    srv = LoopbackHTTPServer(("127.0.0.1", args.port), Handler)
    srv.out_path = args.out
    if args.port_file:
        Path(args.port_file).write_text(str(srv.server_port))
    print(f"sink bound to 127.0.0.1:{srv.server_port}", file=sys.stderr, flush=True)
    print(f"sink listening on 127.0.0.1:{srv.server_port} -> {args.out}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
