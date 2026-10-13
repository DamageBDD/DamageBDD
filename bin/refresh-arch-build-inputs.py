#!/usr/bin/env python3
"""Refresh the Dockerfile and feature CIDs used by the failing Arch build.

Requires Python 3.9+ and an IPFS CLI connected to a running Kubo node.
Downloads the existing public build inputs, appends the native dependency
installation to the Dockerfile's final stage, and adds/pins BOTH revised files.
Does not execute Docker, run a feature, mint a release, or edit rebar.config.
Inspect Dockerfile.original and the generated diff before executing the feature.
"""
from __future__ import annotations

import argparse
import difflib
import re
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_FEATURE_CID = "Qme7xs1WZSScV8Y6U79rmteWxQVx6y7jHp3QByAsvapL4R"
# These are the two image names used by the supplied build feature.
BUILD_STEP = re.compile(
    r'(?m)^\s*When I build an image from Dockerfile at "([A-Za-z0-9]+)" '
    r'as tag "(damagebdd/arch-builder:(?:latest|aarch64))" with params "[^"\n]*"[ \t]*$'
)
RUN_STEP = re.compile(
    r'(?m)^[ \t]*Then I run docker image tagged '
    r'"(damagebdd/arch-builder:(?:latest|aarch64))"[ \t]*$'
)
SCRIPT_START = re.compile(r'(?m)^([ \t]+)set -eux[ \t]*$')
PREFLIGHT_MARKER = "[damagebdd] native-preflight-v1"
DOCKERFILE_MARKER = "# damagebdd:gtk-shumate-builder-v1"
DOCKERFILE_APPEND = """
# damagebdd:gtk-shumate-builder-v1
# This block installs into the final builder stage, not the host OS.
USER root
RUN pacman -Syu --noconfirm --needed pkgconf gtk4 libshumate \\
    && pkg-config --print-errors --exists gtk4 shumate-1.0 \\
    && pkg-config --cflags gtk4 shumate-1.0 >/dev/null \\
    && pkg-config --libs gtk4 shumate-1.0 >/dev/null
USER damage
WORKDIR /opt/workspace
"""
PREFLIGHT = """# Check the actual container before Git fetches or cleaning/building _build.
# Inline deliberately: this does not depend on a helper being committed/pushed.
echo '[damagebdd] native-preflight-v1: checking GTK4/Shumate'
command -v pkg-config >/dev/null 2>&1 || {
    echo '[damagebdd] pkg-config is missing from the builder image' >&2
    exit 1
}
for pc_module in gtk4 shumate-1.0; do
    if ! pkg-config --print-errors --exists "$pc_module"; then
        echo "[damagebdd] Missing $pc_module in the builder image; rebuild the revised Dockerfile." >&2
        exit 1
    fi
done
pkg-config --cflags gtk4 shumate-1.0 >/dev/null
pkg-config --libs gtk4 shumate-1.0 >/dev/null
pkg-config --modversion gtk4 shumate-1.0
"""


def ipfs(executable: str, *args: str) -> bytes:
    result = subprocess.run(
        [executable, "--timeout=120s", *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=130,
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"IPFS {args[0]} failed ({result.returncode}): {detail}")
    return result.stdout


def read_text(data: bytes, label: str) -> str:
    if not data or len(data) > 1024 * 1024 or b"\x00" in data:
        raise ValueError(f"{label} is empty, binary, or larger than 1 MiB")
    return data.decode("utf-8")


def add_file(executable: str, path: Path) -> str:
    cid = ipfs(executable, "add", "--cid-version=0", "--raw-leaves=false",
               "--pin=true", "-Q", str(path)).decode("ascii").strip()
    if not re.fullmatch(r"Qm[1-9A-HJ-NP-Za-km-z]{44}", cid):
        raise ValueError(f"IPFS did not return a single CIDv0 for {path.name}")
    return cid


def write_text(path: Path, text: str) -> None:
    # Exclusive creation prevents clobbering an earlier result.
    with path.open("x", encoding="utf-8", newline="") as stream:
        stream.write(text)


def rewrite_feature(feature: str, old_cid: str, new_cid: str,
                    tags: list[str]) -> str:
    rewritten = feature.replace(f'"{old_cid}"', f'"{new_cid}"')
    for tag in tags:
        arch = "aarch64" if tag.endswith(":aarch64") else "x86_64"
        new_tag = f"damagebdd/arch-builder:shumate-{new_cid}-{arch}"
        rewritten = rewritten.replace(f'"{tag}"', f'"{new_tag}"')
    # Replace the optional, checkout-dependent helper with an inline preflight.
    rewritten = re.sub(r"(?m)^[ \t]*sh bin/check-gtk-build-deps\.sh[ \t]*\n", "", rewritten)

    def inject(match: re.Match[str]) -> str:
        indent = match.group(1)
        block = "\n".join(indent + line if line else "" for line in PREFLIGHT.splitlines())
        return match.group(0) + "\n\n" + block + "\n"

    rewritten, count = SCRIPT_START.subn(inject, rewritten)
    if count != len(tags):
        raise ValueError("Cannot safely pair build steps with shell script starts")
    return rewritten


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="new output directory (must not already exist)")
    parser.add_argument("--feature-cid", default=DEFAULT_FEATURE_CID,
                        help="existing feature CID; defaults to the failing run's CID")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9]+", args.feature_cid):
            raise ValueError("Expected a bare feature CID, not a URL or IPFS path")
        executable = shutil.which("ipfs")
        if executable is None:
            raise RuntimeError("ipfs CLI is required; use the node that can retrieve the original build inputs")
        output = args.output.expanduser().absolute()
        if output.exists():
            raise ValueError(f"Refusing to overwrite {output}; choose a new output directory")

        feature_raw = ipfs(executable, "cat", args.feature_cid)
        feature = read_text(feature_raw, "Feature")
        matches = BUILD_STEP.findall(feature)
        tags = [tag for _, tag in matches]
        cids = {cid for cid, _ in matches}
        if not matches or len(cids) != 1 or len(tags) != len(set(tags)):
            raise ValueError("Expected one shared Dockerfile CID and unique known Arch builder tags")
        if sorted(RUN_STEP.findall(feature)) != sorted(tags):
            raise ValueError("Build/run image steps do not match the expected feature shape")
        if len(SCRIPT_START.findall(feature)) != len(tags):
            raise ValueError("Expected one 'set -eux' shell script per build scenario")
        if PREFLIGHT_MARKER in feature:
            raise ValueError("Feature already contains this refresh; select the original CID")
        old_docker_cid = next(iter(cids))
        docker_raw = ipfs(executable, "cat", old_docker_cid)
        docker = read_text(docker_raw, "Dockerfile")
        if not re.search(r"(?im)^[ \t]*FROM[ \t]+", docker):
            raise ValueError("Referenced Dockerfile has no FROM instruction")
        if re.search(r"(?im)^\s*#\s*escape\s*=\s*`", docker):
            raise ValueError("Backtick-escape Dockerfiles require manual integration")
        if DOCKERFILE_MARKER in docker:
            raise ValueError("Dockerfile already contains this block; inspect the image and pkg-config environment")

        # Validate all known input structure before adding either revised file.
        output.mkdir(parents=True, exist_ok=False)
        (output / "Dockerfile.original").write_bytes(docker_raw)
        (output / "feature.original").write_bytes(feature_raw)
        updated_docker = docker.rstrip() + "\n" + DOCKERFILE_APPEND
        write_text(output / "Dockerfile", updated_docker)
        new_docker_cid = add_file(executable, output / "Dockerfile")
        if new_docker_cid == old_docker_cid:
            raise ValueError("Dockerfile CID did not change")
        updated_feature = rewrite_feature(feature, old_docker_cid, new_docker_cid, tags)
        write_text(output / "docker_build_arch.feature", updated_feature)
        new_feature_cid = add_file(executable, output / "docker_build_arch.feature")
        if new_feature_cid == args.feature_cid:
            raise ValueError("Feature CID did not change")
        write_text(output / "DOCKERFILE_CID", new_docker_cid + "\n")
        write_text(output / "FEATURE_CID", new_feature_cid + "\n")
        diff = "".join(difflib.unified_diff(docker.splitlines(True), updated_docker.splitlines(True),
                                         fromfile="Dockerfile.original", tofile="Dockerfile"))
        diff += "".join(difflib.unified_diff(feature.splitlines(True), updated_feature.splitlines(True),
                                          fromfile="feature.original", tofile="docker_build_arch.feature"))
        write_text(output / "build-inputs.diff", diff)
        print(f"Output directory: {output}")
        print(f"Old Dockerfile CID: {old_docker_cid}")
        print(f"New Dockerfile CID: {new_docker_cid}")
        print(f"Old feature CID:    {args.feature_cid}")
        print(f"New feature CID:    {new_feature_cid}")
        print(f"Updated scenarios:  {len(tags)}")
        print("Review build-inputs.diff and Dockerfile.original before execution.")
        print("IPFS inputs were added and pinned locally; no image or release was built.")
        print("Submit docker_build_arch.feature or select the NEW feature CID, not the old one.")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"[damagebdd] refresh failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
