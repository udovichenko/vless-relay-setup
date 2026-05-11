#!/usr/bin/env python3
"""Verify orchestration scripts source the libs they call.

Catches the v1.9.2-class bug: adding a call to a `scripts/lib/<x>.sh`
function without sourcing `lib/<x>.sh` from the caller.

Modes:
  • No CLI args: read a Claude Code hook JSON payload from stdin and check
    the file at `.tool_input.file_path`.
  • CLI args: each argument is a file path to check; report all issues
    across all files, exit 2 if any.
"""
import glob
import json
import os
import re
import sys
from typing import List, Tuple


ORCHESTRATION_RE = re.compile(
    r'^(setup(-exit|-relay)?|update-(exit|relay)|uninstall|selfcheck|vpn)(\.sh)?$'
)


def collect_lib_funcs(lib_dir: str) -> dict:
    """Return {func_name: lib_filename} from all *.sh in lib_dir."""
    func_lib = {}
    func_def_paren = re.compile(r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)', re.MULTILINE)
    func_def_kw = re.compile(r'^function\s+([a-zA-Z_][a-zA-Z0-9_]*)', re.MULTILINE)
    for lib_path in sorted(glob.glob(os.path.join(lib_dir, '*.sh'))):
        lib_name = os.path.basename(lib_path)
        try:
            with open(lib_path) as f:
                content = f.read()
        except OSError:
            continue
        for m in func_def_paren.finditer(content):
            func_lib[m.group(1)] = lib_name
        for m in func_def_kw.finditer(content):
            func_lib[m.group(1)] = lib_name
    return func_lib


def check_one(file_path: str) -> List[Tuple[str, str]]:
    """Return list of (function_name, missing_lib_name) for one orchestration file.

    Returns [] when the file is not an orchestration script or has no issues.
    """
    if not os.path.isfile(file_path):
        return []

    parent_dir = os.path.basename(os.path.dirname(os.path.abspath(file_path)))
    if parent_dir != 'scripts':
        return []
    if not ORCHESTRATION_RE.match(os.path.basename(file_path)):
        return []

    scripts_dir = os.path.dirname(os.path.abspath(file_path))
    lib_dir = os.path.join(scripts_dir, 'lib')
    if not os.path.isdir(lib_dir):
        return []

    func_lib = collect_lib_funcs(lib_dir)
    if not func_lib:
        return []

    try:
        with open(file_path) as f:
            edited = f.read()
    except OSError:
        return []

    # Drop line comments only (keep strings so we can read source paths)
    no_comments = re.sub(r'#.*', '', edited)

    # Sourced libs (extract before stripping strings — paths live inside quotes)
    sourced = set()
    for m in re.finditer(r'source\s+\S*?lib/([a-zA-Z0-9_.-]+\.sh)', no_comments):
        sourced.add(m.group(1))

    # Strip string literals so name lookups don't match text inside strings
    cleaned = re.sub(r"'[^']*'", '', no_comments)
    cleaned = re.sub(r'"[^"]*"', '', cleaned)

    issues = []
    for func, lib in sorted(func_lib.items()):
        if re.search(r'\b' + re.escape(func) + r'\b', cleaned):
            if lib not in sourced:
                issues.append((func, lib))
    return issues


def main():
    args = sys.argv[1:]

    if args:
        any_issue = False
        for file_path in args:
            issues = check_one(file_path)
            if issues:
                any_issue = True
                print(f"lib-imports-check: missing sources in {file_path}:", file=sys.stderr)
                for func, lib in issues:
                    print(f"  function '{func}' is called but 'lib/{lib}' is not sourced", file=sys.stderr)
        sys.exit(2 if any_issue else 0)

    # Hook mode: read JSON from stdin
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)
    file_path = data.get('tool_input', {}).get('file_path', '')
    if not file_path:
        sys.exit(0)
    issues = check_one(file_path)
    if issues:
        print(f"lib-imports-check: missing sources in {file_path}:", file=sys.stderr)
        for func, lib in issues:
            print(f"  function '{func}' is called but 'lib/{lib}' is not sourced", file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
