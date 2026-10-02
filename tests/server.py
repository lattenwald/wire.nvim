import base64
import http.server
import json
import sys
import threading
import time

LOG = sys.argv[1]
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": [[k, v] for k, v in self.headers.items()],
            "body": base64.b64encode(body).decode(),
        }
        with lock, open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
        if self.path == "/hang":
            threading.Event().wait()
        if self.path.startswith("/sleep/"):
            time.sleep(int(self.path[len("/sleep/") :]) / 1000)
        if self.path == "/head10":
            self.send_response(200)
            self.send_header("Content-Length", "10")
            self.end_headers()
            return
        if self.path == "/server-timing":
            self.send_response(200)
            self.send_header("Server-Timing", 'db;dur=53;desc="a, \\"b\\"; c"')
            self.send_header("Server-Timing", "app;dur=120.5, cache;desc=hit")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        status = int(self.path[len("/status/") :]) if self.path.startswith("/status/") else 200
        out = json.dumps(entry).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_any

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_address[1], flush=True)
server.serve_forever()
