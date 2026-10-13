from __future__ import annotations

import copy
import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from ecai_video_fastpath.api import create_app
from ecai_video_fastpath.config import Settings
from ecai_video_fastpath.crypto import verify_seal
from ecai_video_fastpath.providers import ProviderError, check_url


@pytest.fixture
def video_bytes(tmp_path):
    p = tmp_path / "fixture.mp4"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
           "testsrc2=size=320x180:rate=12", "-t", "1.5", "-c:v", "libx264", "-preset", "ultrafast",
           "-pix_fmt", "yuv420p", str(p)]
    subprocess.run(cmd, check=True, timeout=30)
    return p.read_bytes()


@pytest.fixture
def settings(tmp_path):
    return Settings(data_dir=tmp_path / "store", api_keys={"alice": "alice-1234567890abcdef", "bob": "bob-1234567890abcdef"},
                    backends={"demo": {"kind": "demo"}}, polling_seconds=0.05)


def headers(tenant="alice"):
    return {"Authorization": f"Bearer {tenant}-1234567890abcdef"}


def project(c, tenant="alice"):
    r = c.post("/v1/projects", headers=headers(tenant), json={"title": "Launch", "license": "customer-owned", "tags": ["shoe", "ad"]})
    assert r.status_code == 201, r.text
    return r.json()["id"]


def upload(c, pid, blob, tenant="alice"):
    r = c.post(f"/v1/projects/{pid}/assets", headers=headers(tenant), files={"file": ("clip.mp4", blob, "video/mp4")})
    assert r.status_code == 201, r.text
    return r.json()


def wait_job(c, jid, tenant="alice"):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        r = c.get(f"/v1/jobs/{jid}", headers=headers(tenant))
        assert r.status_code == 200, r.text
        state = r.json()["state"]
        if state in ("completed", "failed", "needs_review"):
            return r.json()
        time.sleep(0.1)
    raise AssertionError("Job did not finish")


def test_import_change_shortcircuit_proof_and_graph(settings, video_bytes):
    app = create_app(settings)
    with TestClient(app) as c:
        assert c.get("/health").json()["status"] == "ok"
        assert c.get("/v1/projects").status_code == 401
        assert c.get("/v1/projects", headers={"Authorization": "Bearer no"}).status_code == 401
        pid = project(c)
        first = upload(c, pid, video_bytes)
        original_sha = first["asset_sha256"]
        base = first["version"]["id"]
        initial = c.get(f"/v1/versions/{base}/verify", headers=headers()).json()
        assert initial["verified"] is True
        signed = c.get(f"/v1/versions/{base}/manifest", headers=headers()).json()
        assert verify_seal(signed, expected_fingerprint=c.get("/v1/public-key").json()["key_fingerprint_sha256"])
        altered = copy.deepcopy(signed)
        altered["manifest"]["video_sha256"] = "0" * 64
        assert not verify_seal(altered)
        r = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                   json={"parent_version_id": base, "operation": "metadata", "options": {"note": "New AUD price"}})
        assert r.status_code == 201, r.text
        changed = r.json()
        assert changed["output_sha256"] == original_sha
        assert changed["sealed_manifest"]["manifest"]["processing"]["reused_exact_video_bytes"] is True
        assert changed["sealed_manifest"]["manifest"]["processing"]["provider_generation_skipped"] is True
        assert c.get(f"/v1/versions/{changed['id']}/verify", headers=headers()).json()["verified"]
        r2 = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                    json={"parent_version_id": base, "operation": "metadata", "options": {"note": "New AUD price"}})
        assert r2.json()["cache_hit"] is True
        assert r2.json()["id"] == changed["id"]
        assert c.get(f"/v1/versions/{changed['id']}/video", headers=headers()).content == video_bytes
        graph = c.get(f"/v1/projects/{pid}/graph", headers=headers()).json()
        assert {"from": base, "to": changed["id"], "relation": "derived_from"} in graph["edges"]
        value = c.get(f"/v1/projects/{pid}/value", headers=headers()).json()
        assert value["exact_media_reuse_revisions"] == 1
        assert value["external_provider_submissions"] == 0
        assert value["repeated_operations_served_from_cache"] == 1
        search = c.get(f"/v1/projects/{pid}/search?q=AUD", headers=headers()).json()
        assert any(v["id"] == changed["id"] for v in search["matches"])
        # NFT metadata is explicitly not a mint and doesn't attest to a CID's bytes.
        draft = c.post(f"/v1/versions/{changed['id']}/nft-draft", headers=headers(),
                       json={"video_cid": "bafy1234567890abcde"}).json()
        assert draft["minted"] is False and draft["publication_verified"] is False
        assert draft["metadata"]["properties"]["video_sha256"] == original_sha
        assert c.get(f"/v1/versions/{changed['id']}", headers=headers("bob")).status_code == 404
        assert c.get(f"/v1/projects/{pid}", headers=headers("bob")).status_code == 404
    # Data and signing identity survive restart.
    with TestClient(create_app(settings)) as c:
        assert c.get(f"/v1/versions/{changed['id']}/verify", headers=headers()).json()["verified"]
        assert c.get("/v1/public-key").json()["key_fingerprint_sha256"] == initial["trusted_signer_fingerprint"]


def test_caption_local_render_and_trim(settings, video_bytes):
    with TestClient(create_app(settings)) as c:
        pid = project(c)
        base = upload(c, pid, video_bytes)["version"]["id"]
        response = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                          json={"parent_version_id": base, "operation": "caption", "options": {"text": "Sale: 20% / It's live"}})
        assert response.status_code == 201, response.text
        v = response.json()
        assert v["output_sha256"] != v["source_sha256"]
        assert c.get(f"/v1/versions/{v['id']}/verify", headers=headers()).json()["verified"]
        assert v["sealed_manifest"]["manifest"]["processing"]["provider_generation_skipped"]
        assert not v["sealed_manifest"]["manifest"]["processing"]["media_render_skipped"]
        trim = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                      json={"parent_version_id": v["id"], "operation": "trim",
                            "options": {"start_seconds": 0.2, "end_seconds": 0.9}})
        assert trim.status_code == 201, trim.text
        assert c.get(f"/v1/versions/{trim.json()['id']}/verify", headers=headers()).json()["verified"]
        assert c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                      json={"parent_version_id": v["id"], "operation": "trim",
                            "options": {"start_seconds": 1.5, "end_seconds": 600}}).status_code == 400
        # On-disk tampering must be detected, even if signature is still valid.
        sha = trim.json()["output_sha256"]
        p = c.app.state.store.asset_path("alice", pid, sha)
        with p.open("ab") as f:
            f.write(b"tamper")
        assert c.get(f"/v1/versions/{trim.json()['id']}/verify", headers=headers()).json()["bytes_match_sha256"] is False


def test_demo_job_and_restart_safe_recovery(settings):
    with TestClient(create_app(settings)) as c:
        pid = project(c)
        job = c.post(f"/v1/projects/{pid}/generations", headers=headers(),
                     json={"backend_id": "demo", "prompt": "sample movement"})
        assert job.status_code == 202, job.text
        completed = wait_job(c, job.json()["id"])
        assert completed["state"] == "completed", completed
        assert c.get(f"/v1/versions/{completed['version_id']}/verify", headers=headers()).json()["verified"]
        metrics = c.get(f"/v1/projects/{pid}/value", headers=headers()).json()
        assert metrics["external_provider_submissions"] == 0
        assert c.post(f"/v1/jobs/{job.json()['id']}/retry", headers=headers()).status_code == 400
    store = create_app(settings).state.store
    jid = store.create_job("alice", pid, "demo", "uncommitted submit", {})["id"]
    store.update_job(jid, "submitting")
    store.recover()
    assert store.job("alice", jid)["state"] == "needs_review"
    assert store.retry_job("alice", jid)["state"] == "queued"


def test_customer_http_backend(settings, video_bytes):
    class BackendHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(length))
            assert body["prompt"] == "customer model video"
            doc = json.dumps({"video": {"url": f"http://127.0.0.1:{self.server.server_port}/video.mp4"}}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(doc))); self.end_headers(); self.wfile.write(doc)
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(video_bytes))); self.end_headers(); self.wfile.write(video_bytes)
        def log_message(self, *_args):
            pass
    srv = ThreadingHTTPServer(("127.0.0.1", 0), BackendHandler)
    thr = threading.Thread(target=srv.serve_forever, daemon=True)
    thr.start()
    try:
        settings.backends["customer"] = {"kind": "http_sync", "url": f"http://127.0.0.1:{srv.server_port}/generate",
                                         "download_hosts": ["127.0.0.1"], "allow_private_network": True,
                                         "output_path": "video.url"}
        with TestClient(create_app(settings)) as c:
            pid = project(c)
            request = c.post(f"/v1/projects/{pid}/generations", headers=headers(),
                             json={"backend_id": "customer", "prompt": "customer model video"})
            assert request.status_code == 202, request.text
            completed = wait_job(c, request.json()["id"])
            assert completed["state"] == "completed", completed
            assert c.get(f"/v1/versions/{completed['version_id']}/verify", headers=headers()).json()["verified"]
            m = c.get(f"/v1/projects/{pid}/value", headers=headers()).json()
            assert m["external_provider_submissions"] == 1
            # Now apply a change: no further upstream API call.
            revision = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                              json={"parent_version_id": completed["version_id"], "operation": "metadata",
                                    "options": {"note": "market AUS"}})
            assert revision.status_code == 201
            assert c.get(f"/v1/projects/{pid}/value", headers=headers()).json()["external_provider_submissions"] == 1
    finally:
        srv.shutdown()
        srv.server_close()
        thr.join(1)


def test_url_allowlist_and_invalid_media(settings):
    for url in ("http://169.254.169.254/latest/meta-data/", "https://evil.example/video.mp4",
                "file:///etc/passwd", "https://127.0.0.1/x"):
        with pytest.raises(ProviderError):
            check_url(url, ["trusted.example", "127.0.0.1"])
    with TestClient(create_app(settings)) as c:
        pid = project(c)
        bad = c.post(f"/v1/projects/{pid}/assets", headers=headers(),
                                          files={"file": ("clip.mp4", b"not really a video", "video/mp4")})
        assert bad.status_code == 422


def test_customer_self_service_backend_key_encrypted_and_tenant_scoped(settings, video_bytes):
    from cryptography.fernet import Fernet
    settings.allowed_connection_hosts = ["127.0.0.1"]
    settings.allow_private_connection_hosts = True  # Test-only; production disallows private origins.
    settings.backend_encryption_key = Fernet.generate_key().decode("ascii")
    secret = "sk_customer_super_secret_123"

    class BackendHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.headers.get("Authorization") == "Bearer " + secret
            n = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(n))
            assert body["seconds"] == 5
            assert body["prompt"] == "my prompt"
            data = json.dumps({"video_url": f"http://127.0.0.1:{self.server.server_port}/output.mp4"}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Length", str(len(video_bytes)))
            self.end_headers(); self.wfile.write(video_bytes)
        def log_message(self, *_args):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), BackendHandler)
    th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
    try:
        with TestClient(create_app(settings)) as c:
            resp = c.post("/v1/backends", headers=headers(), json={
                "id": "my_vendor", "kind": "http_sync", "url": f"http://127.0.0.1:{srv.server_port}/generate",
                "api_key": secret, "download_hosts": ["127.0.0.1"],
                "defaults": {"seconds": 5}, "output_path": "video_url"})
            assert resp.status_code == 201, resp.text
            assert secret not in str(resp.json())
            assert any(b["id"] == "my_vendor" for b in c.get("/v1/backends", headers=headers()).json())
            assert not any(b["id"] == "my_vendor" for b in c.get("/v1/backends", headers=headers("bob")).json())
            assert secret.encode() not in settings.data_dir.joinpath("fastpath.sqlite3").read_bytes()
            pid = project(c)
            generated = c.post(f"/v1/projects/{pid}/generations", headers=headers(),
                               json={"backend_id": "my_vendor", "prompt": "my prompt"})
            assert generated.status_code == 202, generated.text
            completed = wait_job(c, generated.json()["id"])
            assert completed["state"] == "completed", completed
            assert c.get(f"/v1/versions/{completed['version_id']}/verify", headers=headers()).json()["verified"]
            assert c.post(f"/v1/projects/{pid}/generations", headers=headers(),
                          json={"backend_id": "my_vendor", "prompt": "x", "parameters": {"seconds": 100}}).status_code == 422
    finally:
        srv.shutdown(); srv.server_close(); th.join(1)


def test_signed_parent_commitment_detects_db_rewrite(settings, video_bytes):
    with TestClient(create_app(settings)) as c:
        pid = project(c)
        root = upload(c, pid, video_bytes)["version"]["id"]
        child_resp = c.post(f"/v1/projects/{pid}/versions", headers=headers(),
                            json={"parent_version_id": root, "operation": "metadata", "options": {"note": "variant"}})
        child = child_resp.json()["id"]
        assert c.get(f"/v1/versions/{child}/verify", headers=headers()).json()["lineage_valid"] is True
        st = c.app.state.store
        with st.db() as conn:
            row = conn.execute("SELECT sealed_manifest FROM versions WHERE id=?", (root,)).fetchone()
            parent = json.loads(row["sealed_manifest"])
            parent["manifest"]["title"] = "tampered parent"
            conn.execute("UPDATE versions SET sealed_manifest=? WHERE id=?", (json.dumps(parent), root))
        result = c.get(f"/v1/versions/{child}/verify", headers=headers()).json()
        assert result["lineage_valid"] is False and result["verified"] is False
