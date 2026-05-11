#!/usr/bin/env python3
"""Verify VLESS and Hysteria URL templates in shell scripts produce well-formed
URLs after shell variable expansion.

Substitutes `$VAR` / `${VAR}` with dummy values matched by name hints
(uuid → fake UUID, port → 443, domain/sni/host → example.com, ip → 203.0.113.1).
Checks:
  • scheme matches vless / hysteria2
  • UUID-shaped username present
  • host:port (or host:port,range) follows @
  • query string after '?' contains required keys
"""
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SHELL_FILES = sorted(
    list((REPO_ROOT / 'scripts').glob('*.sh'))
    + list((REPO_ROOT / 'scripts' / 'lib').glob('*.sh'))
)

DUMMY_UUID = '00000000-0000-0000-0000-000000000000'
DUMMY_PORT = '443'
DUMMY_DOMAIN = 'example.com'
DUMMY_IP = '203.0.113.1'

VAR_RE = re.compile(r'\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)')


def resolve_var(name: str) -> str:
    base = re.split(r'[:/]', name, 1)[0].lower()
    if 'uuid' in base:
        return DUMMY_UUID
    if 'port' in base:
        return DUMMY_PORT
    if 'ip' in base:
        return DUMMY_IP
    if any(k in base for k in ('domain', 'sni', 'host')):
        return DUMMY_DOMAIN
    return 'x'


def substitute(text: str) -> str:
    def replace(m):
        return resolve_var(m.group(1) or m.group(2))
    return VAR_RE.sub(replace, text)


# Find URL assignments in shell: `var="vless://..."` or `var="hysteria2://..."`
URL_LINE_RE = re.compile(
    r'(?:vless|hysteria2)://[^"\'`\s]+',
)

VLESS_RE = re.compile(
    r'^vless://'
    r'[0-9a-fA-F-]{8,}'      # UUID-ish
    r'@'
    r'[A-Za-z0-9.-]+'        # host
    r':[0-9]+'               # port
    r'(?:[,/?#].*)?$'        # optional rest
)

HYSTERIA_RE = re.compile(
    r'^hysteria2://'
    r'[0-9a-fA-F-]{8,}'
    r'@'
    r'[A-Za-z0-9.-]+'
    r':[0-9]+(?:,[0-9-]+)?'  # port, optionally followed by ,port-end
    r'/?\?[^#]+'             # query
    r'(?:#.*)?$'
)


def parse_query_keys(url: str) -> set:
    if '?' not in url:
        return set()
    qs = url.split('?', 1)[1].split('#', 1)[0]
    keys = set()
    for part in qs.split('&'):
        if '=' in part:
            keys.add(part.split('=', 1)[0])
        elif part:
            keys.add(part)
    return keys


def main():
    errors = []
    seen = 0

    for path in SHELL_FILES:
        try:
            content = path.read_text()
        except OSError:
            continue
        rel = path.relative_to(REPO_ROOT)
        for line_no, line in enumerate(content.split('\n'), start=1):
            for m in URL_LINE_RE.finditer(line):
                raw = m.group(0)
                # strip trailing closing-quote artifacts the regex may include
                raw = raw.rstrip('"\'`')
                expanded = substitute(raw)
                seen += 1
                if expanded.startswith('vless://'):
                    if not VLESS_RE.match(expanded):
                        errors.append(
                            f"{rel}:{line_no} VLESS structure invalid after expansion: {expanded}"
                        )
                        continue
                    keys = parse_query_keys(expanded)
                    required = {'type', 'security'}
                    missing = required - keys
                    if missing:
                        errors.append(
                            f"{rel}:{line_no} VLESS missing required query keys "
                            f"{sorted(missing)}: {expanded}"
                        )
                elif expanded.startswith('hysteria2://'):
                    if not HYSTERIA_RE.match(expanded):
                        errors.append(
                            f"{rel}:{line_no} Hysteria structure invalid after expansion: {expanded}"
                        )
                        continue
                    keys = parse_query_keys(expanded)
                    required = {'obfs'}
                    missing = required - keys
                    if missing:
                        errors.append(
                            f"{rel}:{line_no} Hysteria missing required query keys "
                            f"{sorted(missing)}: {expanded}"
                        )

    if errors:
        print(f"validate-urls: {len(errors)} issue(s) in {seen} URL(s):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
