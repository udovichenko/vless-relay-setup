#!/usr/bin/env python3
"""Verify that every `{{PLACEHOLDER}}` in `scripts/lib/templates/*` is
substituted somewhere in code, and every `{{PLACEHOLDER}}` referenced in
code exists in some template.

Catches:
  • Added a placeholder to a template, forgot the substitution in code →
    final output ships with literal "{{NEW_FIELD}}".
  • Renamed a placeholder in code, forgot the template → substitution
    silently no-ops, template ships unfilled.
  • Typo in placeholder name → mismatch.
"""
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATE_DIR = REPO_ROOT / 'scripts' / 'lib' / 'templates'
# Code locations that perform placeholder substitution
CODE_FILES = [
    REPO_ROOT / 'scripts' / 'lib' / 'sub-proxy.py',
    REPO_ROOT / 'scripts' / 'lib' / 'caddy.sh',
    REPO_ROOT / 'scripts' / 'lib' / '3xui.sh',
]

PLACEHOLDER_RE = re.compile(r'\{\{([A-Z][A-Z0-9_]*)\}\}')


def find_placeholders(path: Path):
    try:
        text = path.read_text()
    except OSError:
        return set()
    return set(PLACEHOLDER_RE.findall(text))


def main():
    if not TEMPLATE_DIR.is_dir():
        print(f"validate-templates: template dir not found: {TEMPLATE_DIR}",
              file=sys.stderr)
        sys.exit(1)

    template_placeholders = {}
    for tpl in sorted(TEMPLATE_DIR.iterdir()):
        if tpl.is_file():
            ph = find_placeholders(tpl)
            if ph:
                template_placeholders[tpl] = ph

    code_placeholders = set()
    for code in CODE_FILES:
        if code.is_file():
            code_placeholders |= find_placeholders(code)

    errors = []

    for tpl, ph_set in template_placeholders.items():
        rel = tpl.relative_to(REPO_ROOT)
        for ph in sorted(ph_set):
            if ph not in code_placeholders:
                errors.append(
                    f"{rel}: {{{{{ph}}}}} appears in template but is not "
                    f"substituted in any of {[str(c.relative_to(REPO_ROOT)) for c in CODE_FILES]}"
                )

    all_template_ph = set().union(*template_placeholders.values()) if template_placeholders else set()
    for ph in sorted(code_placeholders):
        if ph not in all_template_ph:
            errors.append(
                f"code references {{{{{ph}}}}} but no template under "
                f"{TEMPLATE_DIR.relative_to(REPO_ROOT)} contains it"
            )

    if errors:
        print("validate-templates: placeholder mismatches:", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
