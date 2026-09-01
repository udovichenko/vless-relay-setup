#!/usr/bin/env python3
"""Verify routing-header propagation and app/browser classification."""

import importlib.util
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "lib" / "sub-proxy.py"
SPEC = importlib.util.spec_from_file_location("sub_proxy", MODULE_PATH)
sub_proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sub_proxy)


class HeaderCollector:
    def __init__(self):
        self.headers = {}

    def send_header(self, name, value):
        self.headers[name] = value


def main():
    assert not sub_proxy.is_browser_request("*/*", "Happ/4.3.0")
    assert not sub_proxy.is_browser_request("text/html", "Incy/1.0")
    assert sub_proxy.is_browser_request("text/html", "Mozilla/5.0")

    collector = HeaderCollector()
    deeplink = "happ://routing/onadd/dGVzdA=="
    sub_proxy.forward_routing_headers(collector, "true", deeplink)
    assert collector.headers == {
        "Routing-Enable": "true",
        "Routing": deeplink,
    }

    print("test-sub-proxy-routing: ok")


if __name__ == "__main__":
    main()
