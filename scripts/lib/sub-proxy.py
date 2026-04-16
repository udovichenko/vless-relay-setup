#!/usr/bin/env python3
"""Subscription proxy: fetches from 3X-UI and appends extra VPN links.

Appends CDN VLESS, Direct Exit, and Hysteria 2 links to subscriptions.
Browser requests (Accept: text/html) are passed through as-is so the
3X-UI subscription page with QR codes works normally.

App requests (no Accept: text/html) get extra links appended to the
base64-encoded subscription response.

Shadowrocket config endpoint: ?conf=ru (split routing, RU sites direct)
and ?conf=full (everything through VPN).
"""

import http.server
import urllib.request
import urllib.parse
import base64
import os
import sys

UPSTREAM = os.environ.get("SUB_UPSTREAM", "http://127.0.0.1:8443")
CDN_LINK = os.environ.get("CDN_VLESS_LINK", "")
CDN_LINK_ASYM = os.environ.get("CDN_VLESS_LINK_ASYM", "")
DIRECT_LINK = os.environ.get("DIRECT_VLESS_LINK", "")
HYSTERIA_LINK = os.environ.get("HYSTERIA_LINK", "")
LISTEN_PORT = int(os.environ.get("SUB_PROXY_PORT", "18443"))
CONF_DIR = os.environ.get("SR_CONF_DIR", "/etc/sub-proxy")

SR_TEMPLATES = {}


def load_sr_templates():
    """Load Shadowrocket .conf templates from CONF_DIR at startup."""
    for name in ("ru", "full"):
        path = os.path.join(CONF_DIR, f"sr-conf-{name}.conf")
        try:
            with open(path) as f:
                SR_TEMPLATES[name] = f.read()
        except FileNotFoundError:
            pass


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Shadowrocket config endpoints — served directly, no upstream call
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        conf_mode = query.get("conf", [None])[0]

        if conf_mode in SR_TEMPLATES:
            host = self.headers.get("Host", "localhost")
            update_url = f"https://{host}{self.path}"
            body = SR_TEMPLATES[conf_mode].format(update_url=update_url).encode()
            filenames = {"ru": "split-ru.conf", "full": "full-vpn.conf"}
            filename = filenames.get(conf_mode, f"{conf_mode}.conf")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        accept = self.headers.get("Accept", "")
        is_browser = "text/html" in accept

        try:
            headers = {
                "Host": self.headers.get("Host", "localhost"),
                "User-Agent": self.headers.get("User-Agent", ""),
                "Accept": accept,
            }
            req = urllib.request.Request(
                f"{UPSTREAM}{self.path}",
                headers=headers,
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read()
                ct = resp.headers.get("Content-Type", "text/plain")
        except Exception:
            self.send_error(502, "Upstream unavailable")
            return

        # Non-subscription content (HTML pages, CSS, JS, images) → pass through as-is
        is_html = b"<!DOCTYPE" in body[:100] or b"<html" in body[:100]
        is_sub = not is_browser and not is_html and "text/plain" in ct

        if not is_sub:
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Subscription response (base64) → append extra links
        extra_links = []
        if CDN_LINK_ASYM:
            extra_links.append(CDN_LINK_ASYM)
        if CDN_LINK:
            extra_links.append(CDN_LINK)
        if HYSTERIA_LINK:
            extra_links.append(HYSTERIA_LINK)
        if DIRECT_LINK:
            extra_links.append(DIRECT_LINK)
        if extra_links:
            try:
                decoded = base64.b64decode(body).decode("utf-8", errors="replace")
                combined = decoded.rstrip("\n") + "\n" + "\n".join(extra_links) + "\n"
                body = base64.b64encode(combined.encode()).rstrip(b"=")
            except Exception:
                pass  # non-base64 response, return as-is

        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def log_message(self, fmt, *args):
        pass  # silent


if __name__ == "__main__":
    load_sr_templates()
    if SR_TEMPLATES:
        print(f"sub-proxy: loaded Shadowrocket configs: {', '.join(SR_TEMPLATES)}")
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    print(f"sub-proxy listening on 127.0.0.1:{LISTEN_PORT} -> {UPSTREAM}")
    sys.stdout.flush()
    server.serve_forever()
