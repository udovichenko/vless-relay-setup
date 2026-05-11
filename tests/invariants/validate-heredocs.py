#!/usr/bin/env python3
"""Validate that heredoc blocks in shell scripts produce syntactically valid
JSON / YAML / systemd-unit content after shell variable expansion.

Substitutes `$VAR`, `${VAR}`, `$(cmd)` with `0` (a token that's valid in all
target syntaxes), then runs a type-specific parser. Reports the heredoc's
file:line on failure.

Skipped types: Caddyfile, HTML, plain text, INI-like (sysctl/fail2ban) —
no built-in parser without external binaries.
"""
import json
import re
import sys
from pathlib import Path

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SHELL_FILES = sorted(
    list((REPO_ROOT / 'scripts' / 'lib').glob('*.sh'))
    + list((REPO_ROOT / 'scripts').glob('*.sh'))
)

HEREDOC_RE = re.compile(
    r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n(.*?)\n[ \t]*\1\s*$",
    re.MULTILINE | re.DOTALL,
)


def expand_shell(text: str) -> str:
    """Substitute shell expansions with neutral token `0`."""
    text = re.sub(r'\$\([^)]*\)', '0', text)
    text = re.sub(r'\$\{[^}]+\}', '0', text)
    text = re.sub(r'\$[A-Za-z_][A-Za-z0-9_]*', '0', text)
    return text


def classify(body: str):
    stripped = body.lstrip()
    # JSON: '{' followed by quoted key, or empty object '{}'
    if stripped.startswith('{'):
        rest = stripped[1:].lstrip()
        if rest.startswith('"') or rest.startswith('}'):
            return 'json'
        # else: Caddyfile-like with bare directives — skip
        return None
    if stripped.startswith('['):
        # JSON array vs INI section header
        rest = stripped[1:].lstrip()
        if rest and rest[0] in '"0123456789-{[]tfn':
            return 'json'
        return None
    if re.search(r'^\s*\[(Unit|Service|Install|Socket|Timer|Path|Mount)\]\s*$',
                 body, re.MULTILINE):
        return 'systemd'
    # YAML guess: at least two top-level keys like "name:" followed by content
    yaml_keys = re.findall(r'^[a-z][a-z0-9_-]*:\s*\S', body, re.MULTILINE)
    if len(yaml_keys) >= 2:
        return 'yaml'
    return None


def validate_json(body: str):
    try:
        json.loads(body)
        return None
    except json.JSONDecodeError as e:
        return f"JSON: {e.msg} at line {e.lineno}, col {e.colno}"


def validate_yaml(body: str):
    if not HAS_YAML:
        return None  # silent skip when PyYAML missing
    try:
        yaml.safe_load(body)
        return None
    except yaml.YAMLError as e:
        return f"YAML: {e}"


def validate_systemd(body: str):
    section_re = re.compile(r'^\[[A-Z][A-Za-z]+\]\s*$')
    kv_re = re.compile(r'^[A-Za-z][A-Za-z0-9-]*=')
    saw_section = False
    for idx, line in enumerate(body.split('\n'), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or stripped.startswith(';'):
            continue
        if section_re.match(stripped):
            saw_section = True
            continue
        if not saw_section:
            return f"systemd: content before any [Section] at body line {idx}"
        if not kv_re.match(stripped):
            return f"systemd: line {idx} not key=value or [Section]: {stripped!r}"
    if not saw_section:
        return "systemd: no [Section] headers found"
    return None


def line_of_offset(text: str, offset: int) -> int:
    return text.count('\n', 0, offset) + 1


def main():
    errors = []
    for path in SHELL_FILES:
        try:
            content = path.read_text()
        except OSError:
            continue
        for m in HEREDOC_RE.finditer(content):
            marker = m.group(1)
            body = m.group(2)
            expanded = expand_shell(body)
            kind = classify(expanded)
            if kind is None:
                continue
            if kind == 'json':
                err = validate_json(expanded)
            elif kind == 'yaml':
                err = validate_yaml(expanded)
            elif kind == 'systemd':
                err = validate_systemd(expanded)
            else:
                continue
            if err:
                line = line_of_offset(content, m.start())
                rel = path.relative_to(REPO_ROOT)
                errors.append((str(rel), line, marker, kind, err))

    if errors:
        print("validate-heredocs: errors found:", file=sys.stderr)
        for rel, line, marker, kind, msg in errors:
            print(f"  {rel}:{line} heredoc <<{marker}> ({kind}) — {msg}",
                  file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
