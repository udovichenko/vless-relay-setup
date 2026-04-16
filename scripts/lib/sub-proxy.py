#!/usr/bin/env python3
"""Subscription proxy: fetches from 3X-UI and appends extra VPN links.

Appends CDN VLESS, Direct Exit, and Hysteria 2 links to subscriptions.
Browser requests (Accept: text/html) are passed through as-is so the
3X-UI subscription page with QR codes works normally.

App requests (no Accept: text/html) get extra links appended to the
base64-encoded subscription response.

Split routing:
- Shadowrocket Module: ?module=ru endpoint (.sgmodule file)
- Happ: routing HTTP header with deeplink (auto-import on subscription update)
- HTML page: inject download buttons for Shadowrocket module
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

SR_MODULE = ""
HAPP_ROUTING_HEADER = ""


def load_templates():
    """Load Shadowrocket module and Happ routing profile at startup."""
    global SR_MODULE, HAPP_ROUTING_HEADER

    # Shadowrocket module
    module_path = os.path.join(CONF_DIR, "sr-module-ru.sgmodule")
    try:
        with open(module_path) as f:
            SR_MODULE = f.read()
    except FileNotFoundError:
        pass

    # Happ routing profile → deeplink header
    happ_path = os.path.join(CONF_DIR, "happ-routing-ru.json")
    try:
        with open(happ_path) as f:
            profile = f.read()
        encoded = base64.b64encode(profile.encode()).decode()
        HAPP_ROUTING_HEADER = f"happ://routing/onadd/{encoded}"
    except FileNotFoundError:
        pass


HTML_SNIPPET = """\
<div style="margin:24px auto;max-width:600px;padding:16px 20px;background:#f0f4f8;
 border-radius:12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
 text-align:center">
 <div style="font-size:15px;font-weight:600;margin-bottom:8px;color:#1a1a1a">
  Split Routing</div>
 <div style="font-size:13px;color:#666;margin-bottom:14px">
  RU-сервисы напрямую, остальное через VPN</div>
 <div style="display:flex;gap:10px;justify-content:center;flex-wrap:wrap">
  <a href="https://{host}{base}?module=ru"
   style="display:inline-block;padding:10px 20px;background:#007aff;color:#fff;
   border-radius:8px;text-decoration:none;font-size:14px;font-weight:500">
   Shadowrocket Module</a>
 </div>
 <div style="font-size:11px;color:#999;margin-top:10px">
  Shadowrocket: Config → Modules → добавить URL выше<br>
  Happ: routing подключается автоматически через подписку</div>
</div>
"""


def _build_html_snippet(host, base):
    return HTML_SNIPPET.format(host=host, base=base).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        # Shadowrocket Module endpoint
        if query.get("module", [None])[0] == "ru" and SR_MODULE:
            body = SR_MODULE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition",
                             'attachment; filename="split-ru.sgmodule"')
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

        is_html = b"<!DOCTYPE" in body[:100] or b"<html" in body[:100]
        is_sub = not is_browser and not is_html and "text/plain" in ct

        # HTML page → inject split routing buttons
        if not is_sub:
            if is_html and SR_MODULE:
                host = self.headers.get("Host", "localhost")
                base = parsed.path
                snippet = _build_html_snippet(host, base)
                if b"</a-layout-content>" in body:
                    body = body.replace(
                        b"</a-layout-content>",
                        snippet + b"</a-layout-content>", 1)
                elif b"</body>" in body:
                    body = body.replace(b"</body>", snippet + b"</body>", 1)
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Subscription response (base64) → append extra links + Happ routing
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
                pass

        self.send_response(200)
        self.send_header("Content-Type", ct)
        if HAPP_ROUTING_HEADER:
            self.send_header("routing", HAPP_ROUTING_HEADER)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def log_message(self, fmt, *args):
        pass  # silent


if __name__ == "__main__":
    load_templates()
    loaded = []
    if SR_MODULE:
        loaded.append("Shadowrocket module")
    if HAPP_ROUTING_HEADER:
        loaded.append("Happ routing")
    if loaded:
        print(f"sub-proxy: loaded split routing: {', '.join(loaded)}")
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    print(f"sub-proxy listening on 127.0.0.1:{LISTEN_PORT} -> {UPSTREAM}")
    sys.stdout.flush()
    server.serve_forever()
