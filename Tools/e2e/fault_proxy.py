#!/usr/bin/env python3
"""A tiny forwarding proxy for the real-hub end-to-end test. It passes every
request to the real hub unchanged, except the paths named with --break, which
answer 200 with a body that is not JSON. Standard library only.

Usage: fault_proxy.py --listen PORT --upstream PORT --break /api/usage/accounts
The proxy never logs headers, so the hub token stays out of the output.
"""
import argparse
import http.client
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
       "proxy-authorization", "proxy-authenticate", "content-length"}


class Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(upstream, broken):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *args):
            pass

        def handle_any(self):
            path = self.path.split("?", 1)[0]
            if path in broken:
                body = b"<<this is not json>>"
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            length = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP | {"host"}}
            conn = http.client.HTTPConnection("127.0.0.1", upstream, timeout=3600)
            try:
                conn.request(self.command, self.path, body=data, headers=headers)
                resp = conn.getresponse()
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in HOP:
                        self.send_header(k, v)
                self.send_header("Connection", "close")
                self.end_headers()
                while True:
                    chunk = resp.read1(4096) if hasattr(resp, "read1") else resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except OSError:
                try:
                    self.send_error(502)
                except OSError:
                    pass
            finally:
                conn.close()

        do_GET = do_POST = do_PUT = do_DELETE = handle_any

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, required=True)
    parser.add_argument("--upstream", type=int, required=True)
    parser.add_argument("--break", dest="broken", action="append", default=[])
    args = parser.parse_args()
    server = Server(("127.0.0.1", args.listen), make_handler(args.upstream, set(args.broken)))
    print("proxy on %d, upstream %d, broken paths %s" % (args.listen, args.upstream, sorted(args.broken)), flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
