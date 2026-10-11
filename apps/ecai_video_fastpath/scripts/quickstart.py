#!/usr/bin/env python3
"""Create real synthetic MP4 locally, import, revise, verify with API.

Set ECAI_VIDEO_TOKEN and optionally ECAI_VIDEO_URL before running.
This needs no paid AI backend, no NFT wallet, and no IPFS node.
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import httpx

BASE = os.environ.get("ECAI_VIDEO_URL", "http://127.0.0.1:9011")
KEY = os.environ.get("ECAI_VIDEO_TOKEN")
if not KEY:
    raise SystemExit("Set ECAI_VIDEO_TOKEN first")

with httpx.Client(base_url=BASE, headers={"Authorization": "Bearer " + KEY}, timeout=180) as http:
    def call(method, path, **kwargs):
        response = http.request(method, path, **kwargs)
        response.raise_for_status()
        return response.json()

    project = call("POST", "/v1/projects", json={"title": "Demo Launch", "license": "customer-owned"})
    pid = project["id"]
    with tempfile.TemporaryDirectory() as tmp:
        sample = Path(tmp) / "demo.mp4"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=12", "-t", "2", "-c:v", "libx264",
                        "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(sample)], check=True)
        with sample.open("rb") as fh:
            original = call("POST", f"/v1/projects/{pid}/assets", files={"file": ("demo.mp4", fh, "video/mp4")})
    base = original["version"]["id"]
    meta = call("POST", f"/v1/projects/{pid}/versions",
                json={"parent_version_id": base, "operation": "metadata", "options": {"note": "Australian variant"}})
    caption = call("POST", f"/v1/projects/{pid}/versions",
                   json={"parent_version_id": base, "operation": "caption", "options": {"text": "AU SALE · OCT 2026"}})
    assert meta["output_sha256"] == original["asset_sha256"], "Metadata revision unexpectedly altered video"
    assert caption["output_sha256"] != original["asset_sha256"], "Caption did not alter video"
    proof = call("GET", f"/v1/versions/{caption['id']}/verify")
    assert proof["verified"], "ECAI verification failed"
    print(json.dumps({"project_id": pid, "original_version_id": base,
                      "metadata_version_id": meta["id"], "caption_version_id": caption["id"],
                      "original_video_sha256": original["asset_sha256"],
                      "metadata_reused_exact_bytes": True, "caption_verified": True,
                      "metrics": call("GET", f"/v1/projects/{pid}/value"),
                      "graph": call("GET", f"/v1/projects/{pid}/graph")}, indent=2))
