"""Customer-facing HTTP API. Authenticated multi-tenant fast-path video service.

Deployment runs as a separate sidecar, not as part of Cowboy's auth stack.
For a public service use TLS via a reverse proxy and a real subscription gateway.
"""
from __future__ import annotations

import asyncio
import hmac
import importlib.resources
import json
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

from .config import Settings
from .bridge_auth import verify as verify_bridge_token
from .media import MediaError
from .providers import Providers
from .store import Store, UserError


class ProjectIn(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    license: str = Field(default="all-rights-reserved", min_length=1, max_length=128)
    tags: list[str] = Field(default_factory=list, max_length=16)


class RevisionIn(BaseModel):
    parent_version_id: str
    operation: str
    options: dict = Field(default_factory=dict)


class GenerationIn(BaseModel):
    backend_id: str
    prompt: str = Field(min_length=1, max_length=3000)
    parameters: dict = Field(default_factory=dict)


class BackendConnectionIn(BaseModel):
    id: str = Field(min_length=1, max_length=48)
    kind: str = "http_sync"
    url: str = Field(min_length=8, max_length=1000)
    api_key: str = Field(min_length=8, max_length=2048)
    auth_scheme: str = "Bearer"
    download_hosts: list[str] = Field(default_factory=list, max_length=8)
    output_path: str = "video_url"
    defaults: dict = Field(default_factory=dict)
    allowed_parameters: list[str] = Field(default_factory=list)


class NftDraftIn(BaseModel):
    video_cid: str = Field(min_length=10, max_length=160)
    poster_cid: str | None = Field(default=None, min_length=10, max_length=160)


async def worker_loop(store: Store, providers: Providers, poll: float) -> None:
    while True:
        try:
            job = await asyncio.to_thread(store.claim_job)
            if job:
                await asyncio.to_thread(providers.process_job, job)
            else:
                await asyncio.sleep(poll)
        except asyncio.CancelledError:
            raise
        except Exception:  # A faulty job must never kill the entire queue.
            await asyncio.sleep(poll)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = (settings or Settings.from_env()).validate()
    store = Store(settings)
    providers = Providers(store)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        store.recover()
        task = asyncio.create_task(worker_loop(store, providers, settings.polling_seconds))
        yield
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    app = FastAPI(title="ECAI Video Fastpath", version="0.1.0", lifespan=lifespan)
    app.state.store = store

    def tenant(request: Request, authorization: str | None = Header(default=None)) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(401, "Bearer API key required", headers={"WWW-Authenticate": "Bearer"})
        key = authorization.removeprefix("Bearer ")
        if key.startswith("bridge1."):
            identity = verify_bridge_token(settings.bridge_secret, key, request.method, request.url.path)
            if identity is None:
                raise HTTPException(401, "Expired or invalid ECAI bridge signature")
            return identity
        for name, expected in settings.api_keys.items():
            if hmac.compare_digest(key, expected):
                return name
        raise HTTPException(401, "Invalid API key", headers={"WWW-Authenticate": "Bearer"})

    @app.exception_handler(UserError)
    async def handle_user_error(_request, exc: UserError):
        from fastapi.responses import JSONResponse
        msg = str(exc)
        return JSONResponse({"detail": msg}, status_code=404 if "not found" in msg else 400)

    @app.exception_handler(MediaError)
    async def handle_media_error(_request, exc: MediaError):
        from fastapi.responses import JSONResponse
        return JSONResponse({"detail": str(exc)}, status_code=422)

    @app.get("/health")
    def health():
        return {"status": "ok", "service": "ecai-video-fastpath", "version": "0.1.0"}

    @app.get("/studio", response_class=HTMLResponse)
    def studio():
        return importlib.resources.files("ecai_video_fastpath").joinpath("studio.html").read_text(encoding="utf-8")

    @app.get("/v1/public-key")
    def public_key():
        # Public endpoint on purpose; client must pin fingerprint from trusted out-of-band channel.
        return {"algorithm": "ECDSA-secp256k1-SHA256", "public_key_hex": store.signer.pub.hex(),
                "key_fingerprint_sha256": store.signer.fingerprint}

    @app.get("/v1/backends")
    def backends(t: str = Depends(tenant)):
        return store.list_backends(t)

    @app.get("/v1/backend-connection-policy")
    def connection_policy(t: str = Depends(tenant)):
        del t
        return {"enabled": bool(settings.allowed_connection_hosts and settings.backend_encryption_key),
                "approved_hosts": settings.allowed_connection_hosts,
                "requires_https": not settings.allow_private_connection_hosts}

    @app.post("/v1/backends", status_code=201)
    def connect_backend(req: BackendConnectionIn, t: str = Depends(tenant)):
        return store.connect_backend(t, req.id, req.kind, req.url, req.api_key,
                                     req.download_hosts, req.output_path, req.auth_scheme,
                                     req.defaults, req.allowed_parameters)

    @app.post("/v1/projects", status_code=201)
    def create_project(req: ProjectIn, t: str = Depends(tenant)):
        if any(len(tag) > 64 or not tag for tag in req.tags):
            raise HTTPException(422, "Tags must be 1..64 characters")
        return store.create_project(t, req.title, req.license, req.tags)

    @app.get("/v1/projects")
    def projects(t: str = Depends(tenant)):
        return store.list_projects(t)

    @app.get("/v1/projects/{project}")
    def project(project: str, t: str = Depends(tenant)):
        return store.project(t, project)

    @app.post("/v1/projects/{project}/assets", status_code=201)
    async def upload_asset(project: str, file: UploadFile = File(...), t: str = Depends(tenant)):
        if not (file.filename or "").lower().endswith(".mp4"):
            raise HTTPException(422, "Upload MP4 files only")
        temp = store.new_temp(t, project)
        try:
            size = 0
            with temp.open("wb") as out:
                while data := await file.read(1024 * 1024):
                    size += len(data)
                    if size > settings.max_upload_bytes:
                        raise HTTPException(413, "Upload exceeds configured limit")
                    out.write(data)
            sha, info = await asyncio.to_thread(store.ingest_temp, t, project, temp)
            version = await asyncio.to_thread(store.register_import, t, project, sha)
            return {"asset_sha256": sha, "media": info, "version": version}
        finally:
            temp.unlink(missing_ok=True)
            await file.close()

    @app.get("/v1/projects/{project}/versions")
    def versions(project: str, t: str = Depends(tenant)):
        return store.list_versions(t, project)

    @app.post("/v1/projects/{project}/versions", status_code=201)
    async def create_version(project: str, req: RevisionIn, t: str = Depends(tenant)):
        if len(json.dumps(req.options)) > 10000:
            raise HTTPException(422, "Options too large")
        return await asyncio.to_thread(store.create_revision, t, project, req.parent_version_id,
                                       req.operation, req.options)

    @app.get("/v1/projects/{project}/jobs")
    def list_project_jobs(project: str, t: str = Depends(tenant)):
        return store.list_jobs(t, project)

    @app.post("/v1/projects/{project}/generations", status_code=202)
    def generate(project: str, req: GenerationIn, t: str = Depends(tenant)):
        try:
            backend = store.backend_spec(t, req.backend_id)
        except UserError:
            raise HTTPException(422, "Unknown backend_id")
        allowed = set(backend.get("allowed_parameters", []))
        if set(req.parameters) - allowed:
            raise HTTPException(422, "Backend parameters require operator allowlisting")
        if len(json.dumps(req.parameters)) > 8000:
            raise HTTPException(422, "Backend parameters too large")
        # One active provider job per project by default: safer first-customer usage cap.
        with store.db() as conn:
            active = conn.execute("SELECT COUNT(*) FROM jobs WHERE tenant=? AND project=? AND "
                                  "state IN ('queued','submitting','awaiting_result','polling','downloading')",
                                  (t, project)).fetchone()[0]
        if active >= 1:
            raise HTTPException(429, "Project has an active generation; poll its status first")
        return store.create_job(t, project, req.backend_id, req.prompt, req.parameters)

    @app.get("/v1/jobs/{job_id}")
    def job(job_id: str, t: str = Depends(tenant)):
        return store.job(t, job_id)

    @app.post("/v1/jobs/{job_id}/retry")
    def retry(job_id: str, t: str = Depends(tenant)):
        return store.retry_job(t, job_id)

    @app.get("/v1/versions/{vid}")
    def version(vid: str, t: str = Depends(tenant)):
        return store.version(t, vid)

    @app.get("/v1/versions/{vid}/manifest")
    def manifest(vid: str, t: str = Depends(tenant)):
        return store.version(t, vid)["sealed_manifest"]

    @app.get("/v1/versions/{vid}/verify")
    def verify(vid: str, t: str = Depends(tenant)):
        return store.verify(t, vid)

    @app.get("/v1/versions/{vid}/video")
    def video(vid: str, t: str = Depends(tenant)):
        v = store.version(t, vid)
        path = store.asset_path(t, v["project_id"], v["output_sha256"])
        if not path.is_file():
            raise HTTPException(410, "Video bytes unavailable")
        return FileResponse(path, media_type="video/mp4", filename=f"ecai-{vid}.mp4")

    @app.get("/v1/projects/{project}/graph")
    def graph(project: str, t: str = Depends(tenant)):
        return store.graph(t, project)

    @app.get("/v1/projects/{project}/value")
    def value(project: str, t: str = Depends(tenant)):
        return store.metrics(t, project)

    @app.get("/v1/projects/{project}/search")
    def search(project: str, q: str = Query(min_length=1, max_length=100), t: str = Depends(tenant)):
        # Metadata/relationship search, not invented visual semantic inference.
        proj = store.project(t, project)
        needle = q.casefold()
        rows = store.list_versions(t, project)
        return {"q": q, "matches": [v for v in rows if needle in " ".join([
            proj["title"], proj["license"], " ".join(proj["tags"]), v["operation"],
            json.dumps(v["options"], ensure_ascii=False),
        ]).casefold()]}

    @app.post("/v1/versions/{vid}/nft-draft")
    def nft_draft(vid: str, req: NftDraftIn, t: str = Depends(tenant)):
        import re
        if not re.fullmatch(r"[a-zA-Z0-9]+", req.video_cid) or (req.poster_cid and not re.fullmatch(r"[a-zA-Z0-9]+", req.poster_cid)):
            raise HTTPException(422, "Invalid CID syntax")
        v = store.version(t, vid)
        verified = store.verify(t, vid)
        if not verified["verified"]:
            raise HTTPException(409, "Video integrity verification failed")
        m = v["sealed_manifest"]["manifest"]
        metadata = {
            "name": m["title"] + " / " + vid[:8],
            "description": "Versioned, integrity-verified ECAI video asset",
            "animation_url": "ipfs://" + req.video_cid,
            "properties": {"schema": m["schema"], "video_sha256": m["video_sha256"],
                           "version_id": vid, "license": m["license"],
                           "provenance_key_fingerprint": v["sealed_manifest"]["proof"]["key_fingerprint_sha256"]}
        }
        if req.poster_cid:
            metadata["image"] = "ipfs://" + req.poster_cid
        return {"metadata": metadata, "minted": False, "publication_verified": False,
                "warning": "Draft only: external CID content and legal rights MUST be checked before minting."}

    return app


# Production startup requires ECAI_VIDEO_KEYS; no insecure embedded default API key.
# Importing this module without keys is permitted for tests and docs via create_app().
app = create_app() if __name__ != "__main__" and (
    __import__("os").environ.get("ECAI_VIDEO_KEYS") or
    __import__("os").environ.get("ECAI_VIDEO_BRIDGE_SECRET")
) else None
