"""Bridge authentication regression and tenant-isolation tests."""
import time

from fastapi.testclient import TestClient

from ecai_video_fastpath.api import create_app
from ecai_video_fastpath.bridge_auth import sign, verify
from ecai_video_fastpath.config import Settings

SECRET = "super-long-test-secret-with-over-32-characters"


def auth(tenant: str, method: str, path: str):
    return {"Authorization": "Bearer " + sign(SECRET, tenant, method, path)}


def test_short_lived_method_path_bound_signature():
    now = int(time.time())
    token = sign(SECRET, "ecai_a123", "POST", "/v1/projects", now=now)
    assert verify(SECRET, token, "POST", "/v1/projects", now=now) == "ecai_a123"
    assert verify(SECRET, token, "GET", "/v1/projects", now=now) is None
    assert verify(SECRET, token, "POST", "/v1/backends", now=now) is None
    assert verify(SECRET, token, "POST", "/v1/projects", now=now + 61) is None
    assert verify("different-test-secret-which-is-long-enough", token, "POST", "/v1/projects", now=now) is None
    assert verify(SECRET, token[:-1] + ("0" if token[-1] != "0" else "1"), "POST", "/v1/projects", now=now) is None


def test_account_scoped_bridge_with_replay_rejection(tmp_path):
    settings = Settings(data_dir=tmp_path / "video", api_keys={}, bridge_secret=SECRET)
    with TestClient(create_app(settings)) as client:
        path = "/v1/projects"
        assert client.get(path).status_code == 401
        assert client.get(path, headers=auth("ecai_alice", "POST", path)).status_code == 401
        a = client.post(path, headers=auth("ecai_alice", "POST", path), json={"title": "Alice campaign"})
        assert a.status_code == 201, a.text
        b = client.post(path, headers=auth("ecai_bob", "POST", path), json={"title": "Bob campaign"})
        assert b.status_code == 201, b.text
        ra = client.get(path, headers=auth("ecai_alice", "GET", path))
        rb = client.get(path, headers=auth("ecai_bob", "GET", path))
        assert [x["id"] for x in ra.json()] == [a.json()["id"]]
        assert [x["id"] for x in rb.json()] == [b.json()["id"]]
        another = f"/v1/projects/{b.json()['id']}"
        assert client.get(another, headers=auth("ecai_alice", "GET", another)).status_code == 404


def test_persistent_job_listing_is_tenant_bound(tmp_path):
    settings = Settings(data_dir=tmp_path / "video", api_keys={}, bridge_secret=SECRET)
    with TestClient(create_app(settings)) as client:
        create_path = "/v1/projects"
        project_a = client.post(create_path, headers=auth("ecai_alice", "POST", create_path), json={"title": "Persisted job"}).json()["id"]
        jobs_path = f"/v1/projects/{project_a}/jobs"
        assert client.get(jobs_path, headers=auth("ecai_alice", "GET", jobs_path)).json() == []
        generate_path = f"/v1/projects/{project_a}/generations"
        created = client.post(generate_path, headers=auth("ecai_alice", "POST", generate_path),
                              json={"backend_id": "demo", "prompt": "Test video"})
        assert created.status_code == 202, created.text
        listing = client.get(jobs_path, headers=auth("ecai_alice", "GET", jobs_path))
        assert listing.status_code == 200
        assert len(listing.json()) == 1 and listing.json()[0]["id"] == created.json()["id"]
        assert "prompt" not in listing.json()[0] and "backend_input" not in listing.json()[0]
        assert client.get(jobs_path, headers=auth("ecai_bob", "GET", jobs_path)).status_code == 404
