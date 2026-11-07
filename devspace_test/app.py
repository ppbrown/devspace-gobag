#!/usr/bin/env python3
"""Trivial web app, just enough to give devspace something to build and deploy.

Serves one page, title and body "dev demo". If the BODY_CONTENTS env var is
set, its value is appended to the body.
"""
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "8080"))


def render_page() -> bytes:
    body = "dev demo"
    extra = os.environ.get("BODY_CONTENTS")
    if extra:
        body = f"{body}<br>{extra}"
    html = f"""<!doctype html>
<html>
<head><title>dev demo</title></head>
<body>{body}</body>
</html>
"""
    return html.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        page = render_page()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    print(f"listening on :{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
