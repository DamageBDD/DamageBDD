#!/usr/bin/env python3
"""Execute only the version guards extracted from the real build features.

No builds, downloads, package commands or chain/IPFS operations are executed.
The entire embedded build script is also syntax-checked with the chosen shell.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import textwrap

FEATURES = ("ubuntu", "mint", "arch")
CASES = (
    ("1.4.2", True),
    ("v1.4.2", True),
    ("1.4.2-rc.1+build.7", True),
    ("0", True),
    ("v" + "a" * 159, True),  # Exactly 160 characters is valid.
    ("v" + "a" * 160, False),  # Previously fell through despite set -e.
    ("latest", False),
    ("", False),
    ("-v1", False),
    (".v1", False),
    ("bad/version", False),
    ("bad version", False),
    ("bad:version", False),
    ("bad|version", False),
    ("bad\nversion", False),
    ("$(printf INJECTED)", False),
)
ACCEPTED = "guard-accepted\n"


def check_feature(root: Path, name: str, shell: str) -> int:
    path = root / "features" / "devops" / f"docker_build_{name}.feature"
    content = path.read_text(encoding="utf-8")
    blocks = re.split(r'(?m)^    """[ \t]*\n', content)
    if len(blocks) < 3:
        raise ValueError(f"{path}: could not locate embedded build script")
    script = textwrap.dedent(blocks[1])
    syntax = subprocess.run([shell, "-n"], input=script, text=True,
                            capture_output=True, timeout=5, check=False)
    if syntax.returncode:
        raise ValueError(f"{path}: shell syntax error: {syntax.stderr.strip()}")
    print(f"PASS: {name} embedded build script syntax")
    start = script.index('case "$RELEASE_VSN" in\n')
    end = script.index("rebar3 as prod pkg gen ", start)
    guard = script[start:end]
    failures = 0
    for version, expected in CASES:
        env = dict(os.environ, RELEASE_VSN=version, LC_ALL="C")
        result = subprocess.run([shell], input="set -eu\n" + guard +
                                "printf '%s\\n' guard-accepted\n", env=env,
                                text=True, capture_output=True, timeout=5, check=False)
        passed = ((result.returncode == 0 and result.stdout == ACCEPTED) if expected
                  else (result.returncode != 0 and ACCEPTED not in result.stdout))
        if not passed:
            failures += 1
            print(f"FAIL: {name} version={version!r} expected_accept={expected} "
                  f"exit={result.returncode} stdout={result.stdout!r} "
                  f"stderr={result.stderr!r}", file=sys.stderr)
    if not failures:
        print(f"PASS: {name} {len(CASES)} version-guard cases")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="Repository root (defaults to this script's parent directory)")
    parser.add_argument("--shell", default="sh", help="Shell executable to test (default: sh)")
    args = parser.parse_args()
    shell = shutil.which(args.shell)
    if shell is None:
        parser.error(f"Shell executable not found: {args.shell}")
    try:
        failures = sum(check_feature(args.root, name, shell) for name in FEATURES)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    if failures:
        print(f"FAIL: {failures} version-guard cases", file=sys.stderr)
        return 1
    print(f"PASS: {len(FEATURES) * len(CASES)} guard cases and "
          f"{len(FEATURES)} syntax checks using {shell}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
