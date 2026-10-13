#!/usr/bin/env python3
"""Safely wire node-admin settings into an existing DamageBDD dashboard.

The host files are deliberately edited in the *local checkout*, rather than
shipped as guessed diffs: their latest versions were not in the source snapshot.
Only these three existing files are touched:
    apps/damage/src/damage_app.erl
    apps/damage/src/damage_sup.erl
    apps/damage/priv/templates/ui/dashboard/page_shell.mustache

Usage:
  python3 scripts/integrate_damage_node_settings.py --check
  python3 scripts/integrate_damage_node_settings.py --apply
"""
from __future__ import annotations

import argparse
import difflib
import os
from pathlib import Path
import re
import sys
import tempfile

APP_FILE = 'apps/damage/src/damage_app.erl'
SUP_FILE = 'apps/damage/src/damage_sup.erl'
SHELL_FILE = 'apps/damage/priv/templates/ui/dashboard/page_shell.mustache'

NAV_SCRIPT = '<script src="/static/js/damage-node-settings-nav.js" defer></script>'
CHILD_SPEC = '''#{
            id => damage_settings,
            start => {damage_settings, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [damage_settings]
        }'''


class IntegrationError(Exception):
    pass


def rewrite_app(src: str) -> str:
    # Bootstrap before children which read application env.
    if 'damage_settings:bootstrap()' not in src:
        anchor = re.search(r'(?m)^([ \t]*)damage_sup:start_link\(\)', src)
        if not anchor:
            raise IntegrationError('damage_app.erl: cannot locate damage_sup:start_link() in start/2')
        indent = anchor.group(1)
        src = src[:anchor.start()] + indent + 'ok = damage_settings:bootstrap(),\n' + src[anchor.start():]

    # Route registration via the app's existing Trails discovery path.
    begin = re.search(r'\bget_trails\s*\(\s*\)\s*->', src)
    if not begin:
        raise IntegrationError('damage_app.erl: cannot locate get_trails/0')
    tail = src[begin.end():]
    end_match = re.search(r'\btrails:trails\s*\(\s*Handlers\s*\)', tail)
    if not end_match:
        raise IntegrationError('damage_app.erl: get_trails/0 is not using a Handlers list')
    handlers = tail[:end_match.start()]
    if not re.search(r'\bdamage_settings_http\b', handlers):
        anchor = re.search(r'\bdamage_dashboard\s*,', handlers)
        if not anchor:
            raise IntegrationError('damage_app.erl: cannot locate damage_dashboard in handler list')
        handlers = handlers[:anchor.start()] + 'damage_settings_http,\n        ' + handlers[anchor.start():]
        tail = handlers + tail[end_match.start():]
        src = src[:begin.end()] + tail
    return src


def rewrite_sup(src: str) -> str:
    if re.search(r'\bid\s*=>\s*damage_settings\b', src):
        return src
    anchor = re.search(r'(?m)^(?P<indent>[ \t]*)(Core|Children|CoreChildren|ChildSpecs)\s*=\s*\[', src)
    if not anchor:
        raise IntegrationError('damage_sup.erl: cannot locate Core/Children supervisor list')
    indent = anchor.group('indent')
    child = CHILD_SPEC.replace('\n', '\n' + indent + '    ')
    # Insert before dependent children and preserve the surrounding list.
    pos = anchor.end()
    return src[:pos] + '\n' + indent + '    ' + child + ',' + src[pos:]


def rewrite_shell(src: str) -> str:
    if NAV_SCRIPT in src:
        return src
    closing = re.search(r'(?im)^[ \t]*</body\s*>', src)
    if not closing:
        raise IntegrationError('page_shell.mustache: cannot locate a closing </body> tag')
    indent = re.match(r'[ \t]*', closing.group()).group()
    return src[:closing.start()] + indent + NAV_SCRIPT + '\n' + src[closing.start():]


def propose(root: Path) -> dict[Path, tuple[str, str]]:
    updates = {}
    for name, transform in [
        (APP_FILE, rewrite_app),
        (SUP_FILE, rewrite_sup),
        (SHELL_FILE, rewrite_shell),
    ]:
        path = root / name
        if not path.is_file():
            raise IntegrationError(f'missing required dashboard integration file: {name}')
        original = path.read_text(encoding='utf-8')
        updated = transform(original)
        updates[path] = (original, updated)
    return updates


def show_diff(root: Path, changes: dict[Path, tuple[str, str]]) -> None:
    for path, (before, after) in changes.items():
        if before == after:
            continue
        relative = path.relative_to(root).as_posix()
        print(''.join(difflib.unified_diff(
            before.splitlines(keepends=True), after.splitlines(keepends=True),
            fromfile=f'a/{relative}', tofile=f'b/{relative}', n=3)), end='')


def atomic_write(path: Path, content: str) -> None:
    mode = path.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                     prefix=f'.{path.name}.', delete=False) as handle:
        temp = Path(handle.name)
        try:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temp.unlink(missing_ok=True)
            raise
    try:
        temp.chmod(mode)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def integrate(root: Path, apply: bool) -> int:
    changes = propose(root)  # Validate ALL three files before touching any.
    dirty = [(path, before, after) for path, (before, after) in changes.items()
             if before != after]
    if not dirty:
        print('Node settings routing, supervision and dashboard navigation are already integrated.')
        return 0
    if not apply:
        show_diff(root, changes)
        print(f'\n{len(dirty)} host file(s) need changes. Run with --apply to write them.')
        return 0
    completed: list[tuple[Path, str]] = []
    try:
        for path, before, after in dirty:
            atomic_write(path, after)
            completed.append((path, before))
            print(f'Updated {path.relative_to(root)}')
    except Exception:
        for path, before in reversed(completed):
            try:
                atomic_write(path, before)
            except OSError:
                print(f'Rollback failed: {path}', file=sys.stderr)
        raise
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true', help='Print proposed unified diffs without writing')
    mode.add_argument('--apply', action='store_true', help='Apply only the three validated host edits')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        return integrate(root, apply=args.apply)
    except IntegrationError as exc:
        print(f'Integration aborted without edits: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
