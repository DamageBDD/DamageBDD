#!/usr/bin/env python3
"""Static audit of node-level OTP configuration names (never reads values into output).

Run from the repository root. The JSON is packaged under priv/config and is
used only to *describe* known keys in the node-admin dashboard. It does not
make any discovered key writable; the Erlang allowlist is authoritative.

Usage:
  python3 apps/damage/scripts/discover_node_settings.py
  python3 apps/damage/scripts/discover_node_settings.py --report /tmp/node-settings.csv
"""
import argparse
import csv
import json
import pathlib
import re
from collections import defaultdict

APPS = ('damage', 'ecai', 'nosternity', 'erm', 'bop')
GET_ENV = re.compile(r'\bapplication\s*:\s*get_env\s*\(\s*(damage|ecai|nosternity|erm|bop)\s*,\s*([a-z][a-z0-9_]*)\s*[,)]', re.M)
APP_SPEC = re.compile(r'(?m)^\s*spec\s*\(\s*([a-z][a-z0-9_]*)\s*\)\s*->')


def scrub_comments(src):
    # Only remove full-line comments; inline comments cannot introduce a get_env(
    return re.sub(r'(?m)^\s*%[^\n]*$', '', src)


def extract_app_keys(src, app):
    """Get tuple keys in first app stanza without serializing configuration values."""
    match = re.search(r'\{\s*' + re.escape(app) + r'\s*,\s*\[', src)
    if match is None:
        return []
    pos = match.end()
    depth = 1
    quoted = False
    comment = False
    escape = False
    keys = []
    while pos < len(src) and depth:
        char = src[pos]
        if char == '\n':
            comment = False
        if comment:
            pos += 1
            continue
        if char == '%' and not quoted:
            comment = True
            pos += 1
            continue
        if char == '"' and not escape:
            quoted = not quoted
        if not quoted:
            if char == '[':
                depth += 1
            elif char == ']':
                depth -= 1
            elif char == '{' and depth == 1:
                key = re.match(r'\{\s*([a-z][a-z0-9_]*)\s*,', src[pos:])
                if key:
                    keys.append(key.group(1))
        escape = char == '\\' and not escape
        pos += 1
    return keys


def scan(root, optional_configs=()):
    evidence = defaultdict(lambda: defaultdict(set))
    for source_app in APPS:
        src_dir = root / 'apps' / source_app / 'src'
        for path in sorted(src_dir.glob('**/*')):
            if path.suffix not in ('.erl', '.hrl') and not path.name.endswith('.app.src'):
                continue
            data = scrub_comments(path.read_text(encoding='utf-8', errors='replace'))
            for match in GET_ENV.finditer(data):
                referenced_app, key = match.groups()
                evidence[referenced_app][key].add(path.relative_to(root).as_posix() + ':' + str(data.count('\n', 0, match.start()) + 1))
            if path.name == 'nosternity_config.erl':
                for match in APP_SPEC.finditer(data):
                    evidence['nosternity'][match.group(1)].add(path.relative_to(root).as_posix() + ':' + str(data.count('\n', 0, match.start()) + 1))
    for config in optional_configs:
        path = pathlib.Path(config)
        if not path.is_file():
            continue
        raw = path.read_text(encoding='utf-8', errors='replace')
        for app in APPS:
            for key in extract_app_keys(raw, app):
                evidence[app][key].add(path.name + ':configuration-key')
    # Include previously supported schema keys even if their consumers have
    # been renamed. They remain explicitly validated, but source-only status
    # is visible in the evidence report for follow-up verification.
    schema = root / 'apps' / 'damage' / 'src' / 'damage_settings_schema.erl'
    if schema.is_file():
        content = schema.read_text(encoding='utf-8', errors='replace')
        for app in APPS:
            match = re.search(r'base_fields\(' + app + r'\)\s*->\s*\[(.*?)\n\s*\];', content, re.S)
            if match:
                for field in re.finditer(r'\?\w+\((\w+),', match.group(1)):
                    evidence[app][field.group(1)].add('apps/damage/src/damage_settings_schema.erl:allowlisted')
    # Also use top-level literal names from the .app.src {env,[]} stanza.
    for app in APPS:
        source = root / 'apps' / app / 'src' / (app + '.app.src')
        if source.exists():
            raw = source.read_text(encoding='utf-8', errors='replace')
            match = re.search(r'\{\s*env\s*,\s*\[', raw)
            if match:
                for key in extract_app_keys('{env,[' + raw[match.end():], 'env'):
                    evidence[app][key].add(source.relative_to(root).as_posix() + ':application-default')
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[3])
    parser.add_argument('--report', type=pathlib.Path, help='Optional names-only CSV of evidence')
    parser.add_argument('--config', type=pathlib.Path, action='append', default=[], help='Additional sys.config input, names only')
    args = parser.parse_args()
    root = args.root.resolve()
    configs = [root / 'config' / 'sys.config', root / 'config' / 'sys.config.sample', root / 'sys.config', root / 'sys.config.sample', *args.config]
    evidence = scan(root, configs)
    document = {app: sorted(evidence[app]) for app in APPS}
    output = root / 'apps' / 'damage' / 'priv' / 'config' / 'node-settings-catalog.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + '\n')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open('w', newline='') as target:
            writer = csv.writer(target)
            writer.writerow(('application', 'key', 'found_in'))
            for app in APPS:
                for key in document[app]:
                    writer.writerow((app, key, '; '.join(sorted(evidence[app][key]))))
    print('Catalog:', output)
    for app in APPS:
        print(f'{app}: {len(document[app])} discovered keys')

if __name__ == '__main__':
    main()
