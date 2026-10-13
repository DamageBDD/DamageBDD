"""SQLite persistence + tenant-separated content-addressed MP4 store."""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .config import Settings
from .crypto import Signer, canonical, digest_file, sha256, verify_seal
from .media import MediaError, probe, render_variant


def utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def uid() -> str:
    return uuid.uuid4().hex


class UserError(ValueError):
    pass


class Store:
    def __init__(self, settings: Settings):
        self.settings = settings.validate()
        self.root = settings.data_dir
        self.root.mkdir(parents=True, exist_ok=True)
        self.signer = Signer(self.root / "signing")
        self.db_path = self.root / "fastpath.sqlite3"
        self.lock = threading.RLock()
        with self.db() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS projects (
                    tenant TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
                    license TEXT NOT NULL, tags TEXT NOT NULL, created_at TEXT NOT NULL,
                    PRIMARY KEY(tenant, id)
                );
                CREATE TABLE IF NOT EXISTS assets (
                    tenant TEXT NOT NULL, project TEXT NOT NULL, sha TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL, media_info TEXT NOT NULL,
                    created_at TEXT NOT NULL, PRIMARY KEY(tenant, project, sha),
                    FOREIGN KEY(tenant, project) REFERENCES projects(tenant, id)
                );
                CREATE TABLE IF NOT EXISTS versions (
                    tenant TEXT NOT NULL, project TEXT NOT NULL, id TEXT NOT NULL,
                    parent TEXT, source_sha TEXT NOT NULL, output_sha TEXT NOT NULL,
                    operation TEXT NOT NULL, operation_data TEXT NOT NULL,
                    fingerprint TEXT NOT NULL, sealed_manifest TEXT NOT NULL,
                    created_at TEXT NOT NULL, PRIMARY KEY(tenant, id),
                    UNIQUE(tenant, project, fingerprint)
                );
                CREATE TABLE IF NOT EXISTS connections (
                    tenant TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
                    url TEXT NOT NULL, download_hosts TEXT NOT NULL,
                    output_path TEXT NOT NULL, auth_scheme TEXT NOT NULL,
                    defaults TEXT NOT NULL, allowed_parameters TEXT NOT NULL, encrypted_token TEXT NOT NULL, created_at TEXT NOT NULL,
                    PRIMARY KEY(tenant, id)
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, tenant TEXT NOT NULL, project TEXT NOT NULL,
                    backend TEXT NOT NULL, prompt TEXT NOT NULL, backend_input TEXT NOT NULL,
                    state TEXT NOT NULL, remote_id TEXT, result_url TEXT, media_url TEXT,
                    version_id TEXT, error TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                    next_check REAL NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, tenant TEXT NOT NULL,
                    project TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_jobs_ready ON jobs(state, next_check);
                CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_job ON jobs(tenant, project)
                WHERE state IN ('queued','submitting','awaiting_result','polling','downloading');
            """)

    @contextmanager
    def db(self):
        conn = sqlite3.connect(str(self.db_path), timeout=15, check_same_thread=False)
        try:
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA busy_timeout=15000")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("PRAGMA journal_mode=WAL")
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def project_dir(self, tenant: str, project: str) -> Path:
        # Tenant comes exclusively from operator config; project always generated uuid.
        return self.root / "tenants" / tenant / project

    def asset_path(self, tenant: str, project: str, sha: str) -> Path:
        return self.project_dir(tenant, project) / "objects" / sha[:2] / f"{sha}.mp4"

    def create_project(self, tenant: str, title: str, license_id: str, tags: list[str]) -> dict:
        pid = uid()
        row = {"id": pid, "title": title, "license": license_id, "tags": tags, "created_at": utc()}
        with self.db() as conn:
            conn.execute("INSERT INTO projects VALUES (?,?,?,?,?,?)",
                         (tenant, pid, title, license_id, json.dumps(tags), row["created_at"]))
            conn.commit()
        return row

    def project(self, tenant: str, project: str) -> dict:
        with self.db() as conn:
            row = conn.execute("SELECT * FROM projects WHERE tenant=? AND id=?", (tenant, project)).fetchone()
        if not row:
            raise UserError("Project not found")
        return {"id": row["id"], "title": row["title"], "license": row["license"],
                "tags": json.loads(row["tags"]), "created_at": row["created_at"]}

    def list_projects(self, tenant: str) -> list[dict]:
        with self.db() as conn:
            rows = conn.execute("SELECT * FROM projects WHERE tenant=? ORDER BY created_at DESC", (tenant,)).fetchall()
        return [{"id": r["id"], "title": r["title"], "license": r["license"],
                 "tags": json.loads(r["tags"]), "created_at": r["created_at"]} for r in rows]

    def new_temp(self, tenant: str, project: str) -> Path:
        self.project(tenant, project)
        dest = self.project_dir(tenant, project) / "tmp"
        dest.mkdir(parents=True, exist_ok=True)
        return dest / f"{uid()}.mp4"

    def ingest_temp(self, tenant: str, project: str, temp: Path) -> tuple[str, dict]:
        self.project(tenant, project)
        if temp.stat().st_size > self.settings.max_upload_bytes:
            raise UserError("Upload exceeds configured limit")
        info = probe(temp, self.settings.ffprobe, self.settings.max_duration_seconds)
        digest = digest_file(temp)
        dest = self.asset_path(tenant, project, digest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.is_file():
            os.replace(temp, dest)
        else:
            if digest_file(dest) != digest:
                raise MediaError("Existing content-addressed object is corrupted")
            temp.unlink(missing_ok=True)
        with self.db() as conn:
            conn.execute("INSERT OR IGNORE INTO assets VALUES (?,?,?,?,?,?)",
                         (tenant, project, digest, dest.stat().st_size, json.dumps(info), utc()))
            conn.commit()
        return digest, info

    def asset(self, tenant: str, project: str, sha: str) -> dict:
        with self.db() as conn:
            row = conn.execute("SELECT * FROM assets WHERE tenant=? AND project=? AND sha=?",
                               (tenant, project, sha)).fetchone()
        if not row:
            raise UserError("Asset not found")
        return {"sha256": sha, "size_bytes": row["size_bytes"], "media": json.loads(row["media_info"])}

    def event(self, tenant: str, project: str, kind: str, detail: dict | None = None) -> None:
        with self.db() as conn:
            conn.execute("INSERT INTO events (tenant,project,kind,detail,created_at) VALUES (?,?,?,?,?)",
                         (tenant, project, kind, json.dumps(detail or {}), utc()))
            conn.commit()

    def version(self, tenant: str, vid: str) -> dict:
        with self.db() as conn:
            row = conn.execute("SELECT * FROM versions WHERE tenant=? AND id=?", (tenant, vid)).fetchone()
        if row is None:
            raise UserError("Version not found")
        return self._version(row)

    @staticmethod
    def _version(row: sqlite3.Row) -> dict:
        return {"id": row["id"], "project_id": row["project"], "parent_version_id": row["parent"],
                "source_sha256": row["source_sha"], "output_sha256": row["output_sha"],
                "operation": row["operation"], "options": json.loads(row["operation_data"]),
                "fingerprint": row["fingerprint"], "created_at": row["created_at"],
                "sealed_manifest": json.loads(row["sealed_manifest"])}

    def list_versions(self, tenant: str, project: str) -> list[dict]:
        self.project(tenant, project)
        with self.db() as conn:
            rows = conn.execute("SELECT * FROM versions WHERE tenant=? AND project=? ORDER BY created_at,id",
                                (tenant, project)).fetchall()
        return [self._version(r) for r in rows]

    def _write_version(self, tenant: str, project: str, parent: str | None, source_sha: str,
                       output_sha: str, operation: str, options: dict, fingerprint: str,
                       media: dict, generator: dict | None = None) -> dict:
        vid = uid()
        created = utc()
        proj = self.project(tenant, project)
        subj = f"ecai:video:version:{vid}"
        relations = [
            {"subject": subj, "predicate": "uses_media_sha256", "object": output_sha},
            {"subject": subj, "predicate": "licensed_under", "object": proj["license"]},
        ]
        parent_commitment = None
        if parent:
            parent_version = self.version(tenant, parent)
            parent_commitment = sha256(canonical(parent_version["sealed_manifest"]))
            relations.append({"subject": subj, "predicate": "derived_from", "object": f"ecai:video:version:{parent}"})
        if generator:
            relations.append({"subject": subj, "predicate": "generated_by", "object": generator["backend"]})
        manifest = {
            "schema": "ecai.video.fastpath.v1", "version_id": vid,
            "project_id": project, "tenant": tenant, "title": proj["title"],
            "license": proj["license"], "tags": proj["tags"],
            "source_sha256": source_sha, "video_sha256": output_sha,
            "parent_version_id": parent, "parent_manifest_sha256": parent_commitment,
            "operation": operation, "operation_data": options,
            "media": media, "generator": generator,
            "identity_fingerprint": fingerprint, "created_at": created,
            "relations": relations,
            "processing": {
                "provider_generation_skipped": operation in ("metadata", "caption", "trim"),
                "media_render_skipped": operation in ("metadata", "import", "generated"),
                "reused_exact_video_bytes": source_sha == output_sha,
            }
        }
        sealed = self.signer.seal(manifest)
        with self.db() as conn:
            conn.execute("INSERT INTO versions VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                         (tenant, project, vid, parent, source_sha, output_sha, operation,
                          json.dumps(options), fingerprint, json.dumps(sealed), created))
            conn.commit()
        self.event(tenant, project, "revision", {"operation": operation, "version_id": vid,
                                                  "provider_generation_skipped": manifest["processing"]["provider_generation_skipped"]})
        return self.version(tenant, vid)

    def register_import(self, tenant: str, project: str, sha: str, origin: str = "upload",
                        generator: dict | None = None) -> dict:
        with self.lock:
            info = self.asset(tenant, project, sha)["media"]
            op = "generated" if generator else "import"
            fp = sha256(canonical({"pipeline": 1, "project": project, "sha": sha,
                                   "origin": origin, "generator": generator}))
            with self.db() as conn:
                row = conn.execute("SELECT * FROM versions WHERE tenant=? AND project=? AND fingerprint=?",
                                   (tenant, project, fp)).fetchone()
            if row:
                return {**self._version(row), "cache_hit": True}
            return self._write_version(tenant, project, None, sha, sha, op, {"origin": origin}, fp, info, generator)

    def create_revision(self, tenant: str, project: str, parent_id: str, operation: str, options: dict) -> dict:
        if operation not in ("metadata", "caption", "trim"):
            raise UserError("Operation must be metadata, caption or trim")
        if operation == "caption":
            if not isinstance(options.get("text"), str) or not 1 <= len(options["text"]) <= 400:
                raise UserError("Caption must be 1..400 characters")
            options = {"text": options["text"]}
        if operation == "metadata":
            if not isinstance(options.get("note", ""), str) or len(options.get("note", "")) > 1000:
                raise UserError("Metadata note must be a string <= 1000 characters")
            options = {"note": options.get("note", "")}
        if operation == "trim":
            try:
                start = float(options["start_seconds"])
                end = float(options["end_seconds"])
            except (KeyError, TypeError, ValueError) as exc:
                raise UserError("Trim requires numeric start_seconds, end_seconds") from exc
            if not 0 <= start < end:
                raise UserError("Invalid trim interval")
            options = {"start_seconds": start, "end_seconds": end}
        parent = self.version(tenant, parent_id)
        if parent["project_id"] != project:
            raise UserError("Parent belongs to another project")
        source_sha = parent["output_sha256"]
        input_info = self.asset(tenant, project, source_sha)["media"]
        if operation == "trim" and options["end_seconds"] > input_info["duration_seconds"] + 0.04:
            raise UserError("Trim end exceeds video duration")
        fp = sha256(canonical({"pipeline": 1, "project": project, "parent": parent_id,
                               "source": source_sha, "operation": operation, "options": options}))
        with self.lock:
            with self.db() as conn:
                row = conn.execute("SELECT * FROM versions WHERE tenant=? AND project=? AND fingerprint=?",
                                   (tenant, project, fp)).fetchone()
            if row:
                self.event(tenant, project, "cache_hit", {"fingerprint": fp})
                return {**self._version(row), "cache_hit": True}
            if operation == "metadata":
                out_sha, output_info = source_sha, input_info
            else:
                import tempfile
                (self.project_dir(tenant, project) / "tmp").mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix="render-", dir=self.project_dir(tenant, project) / "tmp") as scratch:
                    scratch_dir = Path(scratch)
                    temp = scratch_dir / "output.mp4"
                    render_variant(self.asset_path(tenant, project, source_sha), temp, operation, options,
                                   self.settings.ffmpeg, self.settings.ffmpeg_timeout, scratch_dir)
                    # Move into the object store before scratch is removed.
                    out_sha, output_info = self.ingest_temp(tenant, project, temp)
            return self._write_version(tenant, project, parent_id, source_sha,
                                       out_sha, operation, options, fp, output_info)

    def verify(self, tenant: str, version_id: str) -> dict:
        v = self.version(tenant, version_id)
        sealed = v["sealed_manifest"]
        sig_ok = verify_seal(sealed, self.signer.fingerprint)
        path = self.asset_path(tenant, v["project_id"], v["output_sha256"])
        bytes_ok = path.is_file() and digest_file(path) == v["output_sha256"]
        m = sealed["manifest"]
        graph_ok = bool(m.get("video_sha256") == v["output_sha256"] and
                        m.get("source_sha256") == v["source_sha256"] and
                        m.get("project_id") == v["project_id"] and
                        m.get("tenant") == tenant and m.get("version_id") == v["id"] and
                        m.get("parent_version_id") == v["parent_version_id"] and
                        m.get("operation") == v["operation"] and
                        m.get("operation_data") == v["options"])
        # Follow the signed dependency chain, detect missing/replaced ancestors
        # and cycles. No content fetches from external IPFS URLs here.
        lineage_ok = True
        seen = {v["id"]}
        child = v
        for _ in range(100):
            pid = child["parent_version_id"]
            if pid is None:
                if child["sealed_manifest"]["manifest"].get("parent_manifest_sha256") is not None:
                    lineage_ok = False
                break
            if pid in seen:
                lineage_ok = False
                break
            seen.add(pid)
            try:
                parent = self.version(tenant, pid)
                child_manifest = child["sealed_manifest"]["manifest"]
                if (parent["project_id"] != v["project_id"] or
                    not verify_seal(parent["sealed_manifest"], self.signer.fingerprint) or
                    child_manifest.get("parent_manifest_sha256") != sha256(canonical(parent["sealed_manifest"])) or
                    child["source_sha256"] != parent["output_sha256"]):
                    lineage_ok = False
                    break
                child = parent
            except UserError:
                lineage_ok = False
                break
        else:
            lineage_ok = False
        return {"verified": sig_ok and bytes_ok and graph_ok and lineage_ok,
                "signature_valid": sig_ok, "bytes_match_sha256": bytes_ok,
                "identity_matches": graph_ok, "lineage_valid": lineage_ok,
                "trusted_signer_fingerprint": self.signer.fingerprint,
                "video_sha256": v["output_sha256"], "version_id": version_id}

    def graph(self, tenant: str, project: str) -> dict:
        versions = self.list_versions(tenant, project)
        return {"project_id": project, "vertices": [
            {"id": v["id"], "video_sha256": v["output_sha256"], "operation": v["operation"]}
            for v in versions],
            "edges": [{"from": v["parent_version_id"], "to": v["id"], "relation": "derived_from"}
                      for v in versions if v["parent_version_id"]]}

    def metrics(self, tenant: str, project: str) -> dict:
        vs = self.list_versions(tenant, project)
        with self.db() as conn:
            upstream = conn.execute("SELECT COUNT(*) FROM events WHERE tenant=? AND project=? AND kind='provider_submit'",
                                    (tenant, project)).fetchone()[0]
            cache = conn.execute("SELECT COUNT(*) FROM events WHERE tenant=? AND project=? AND kind='cache_hit'",
                                 (tenant, project)).fetchone()[0]
        return {"revisions": len(vs), "external_provider_submissions": upstream,
                "revisions_without_provider_regeneration": sum(1 for v in vs if v["operation"] in ("metadata", "caption", "trim")),
                "exact_media_reuse_revisions": sum(1 for v in vs if v["operation"] == "metadata"),
                "repeated_operations_served_from_cache": cache,
                "avoided_provider_regenerations": sum(1 for v in vs if v["operation"] in ("metadata", "caption", "trim")),
                "note": "Counts indicate provider calls avoided by design; no monetary savings assumed."}

    def create_job(self, tenant: str, project: str, backend: str, prompt: str, backend_input: dict) -> dict:
        self.project(tenant, project)
        jid = uid()
        now = utc()
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            pending = conn.execute("SELECT COUNT(*) FROM jobs WHERE tenant=? AND project=? AND "
                                   "state IN ('queued','submitting','awaiting_result','polling','downloading')",
                                   (tenant, project)).fetchone()[0]
            if pending:
                raise UserError("Project already has an active provider generation")
            conn.execute("INSERT INTO jobs (id,tenant,project,backend,prompt,backend_input,state,created_at,updated_at) "
                         "VALUES (?,?,?,?,?,?,?,?,?)",
                         (jid, tenant, project, backend, prompt, json.dumps(backend_input), "queued", now, now))
        return self.job(tenant, jid)

    def list_jobs(self, tenant: str, project: str) -> list[dict]:
        self.project(tenant, project)
        with self.db() as conn:
            rows = conn.execute("SELECT * FROM jobs WHERE tenant=? AND project=? "
                                "ORDER BY created_at DESC,id DESC LIMIT 50", (tenant, project)).fetchall()
        return [{k: row[k] for k in row.keys() if k not in ("backend_input", "prompt")}
                for row in rows]

    def job(self, tenant: str, jid: str) -> dict:
        with self.db() as conn:
            r = conn.execute("SELECT * FROM jobs WHERE tenant=? AND id=?", (tenant, jid)).fetchone()
        if not r:
            raise UserError("Job not found")
        return {k: r[k] for k in r.keys() if k not in ("backend_input", "prompt")}

    def recover(self) -> None:
        # Ambiguous submit must not be automatically retried (potential duplicate billing).
        with self.db() as conn:
            conn.execute("UPDATE jobs SET state='needs_review',error='Submit outcome ambiguous after restart' "
                         "WHERE state='submitting'")
            conn.execute("UPDATE jobs SET state='awaiting_result' WHERE state='polling' AND (remote_id IS NOT NULL OR media_url IS NOT NULL)")
            conn.execute("UPDATE jobs SET state='awaiting_result' WHERE state='downloading' AND media_url IS NOT NULL")
            conn.execute("UPDATE jobs SET state='needs_review',error='Local delivery state requires operator review' "
                         "WHERE state IN ('downloading','polling') AND remote_id IS NULL AND media_url IS NULL")
            conn.commit()

    def claim_job(self) -> dict | None:
        import time
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM jobs WHERE state IN ('queued','awaiting_result') "
                               "AND next_check<=? ORDER BY created_at LIMIT 1", (time.time(),)).fetchone()
            if row is None:
                conn.commit()
                return None
            updated = "submitting" if row["state"] == "queued" else "polling"
            conn.execute("UPDATE jobs SET state=?,updated_at=?,attempts=attempts+1 WHERE id=?",
                         (updated, utc(), row["id"]))
            conn.commit()
        return {**dict(row), "state": updated, "backend_input": json.loads(row["backend_input"])}

    def update_job(self, jid: str, state: str, **values) -> None:
        allowed = {"remote_id", "result_url", "media_url", "version_id", "error", "next_check"}
        if not set(values).issubset(allowed):
            raise ValueError("Invalid job update")
        fragments = ["state=?", "updated_at=?"] + [f"{k}=?" for k in values]
        with self.db() as conn:
            conn.execute(f"UPDATE jobs SET {','.join(fragments)} WHERE id=?",
                         [state, utc(), *values.values(), jid])
            conn.commit()

    def retry_job(self, tenant: str, jid: str) -> dict:
        job = self.job(tenant, jid)
        if job["state"] not in ("needs_review", "failed"):
            raise UserError("Only failed or needs_review jobs can be retried")
        # Require explicit operator/user action; an ambiguous submit can be billed twice.
        self.update_job(jid, "queued", remote_id=None, result_url=None, media_url=None, error=None, next_check=0)
        return self.job(tenant, jid)

    def connect_backend(self, tenant: str, name: str, kind: str, url: str, token: str,
                        download_hosts: list[str], output_path: str, auth_scheme: str,
                        defaults: dict | None = None, allowed_parameters: list[str] | None = None) -> dict:
        import re
        from cryptography.fernet import Fernet
        from .providers import check_url
        if not self.settings.backend_encryption_key or not self.settings.allowed_connection_hosts:
            raise UserError("Customer-managed backends are disabled by operator configuration")
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,48}", name) or name in self.settings.backends:
            raise UserError("Connection ID invalid or already reserved")
        if kind not in ("http_sync", "fal_queue"):
            raise UserError("Unsupported connection kind")
        if auth_scheme not in ("Bearer", "Key") or not 8 <= len(token) <= 2048:
            raise UserError("Invalid provider credential")
        if not re.fullmatch(r"[a-zA-Z0-9_.]{1,100}", output_path):
            raise UserError("Invalid output field")
        defaults = defaults or {}
        allowed_parameters = allowed_parameters or []
        if len(json.dumps(defaults)) > 4000 or len(allowed_parameters) > 15:
            raise UserError("Connection defaults too large")
        if any(not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]{0,60}", k) for k in defaults):
            raise UserError("Invalid connection input field")
        if any(not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]{0,60}", k) for k in allowed_parameters):
            raise UserError("Invalid allowed parameter name")
        if "prompt" in defaults or "prompt" in allowed_parameters:
            raise UserError("Prompt is always controlled by generation request")
        approved = self.settings.allowed_connection_hosts
        if len(download_hosts) > 8 or any(host not in approved for host in download_hosts):
            raise UserError("Download hosts require operator approval")
        check_url(url, approved, self.settings.allow_private_connection_hosts)
        encrypted = Fernet(self.settings.backend_encryption_key.encode()).encrypt(token.encode()).decode()
        with self.db() as conn:
            conn.execute("INSERT INTO connections VALUES (?,?,?,?,?,?,?,?,?,?,?) "
                         "ON CONFLICT(tenant,id) DO UPDATE SET kind=excluded.kind,url=excluded.url,"
                         "download_hosts=excluded.download_hosts,output_path=excluded.output_path,"
                         "auth_scheme=excluded.auth_scheme,defaults=excluded.defaults,allowed_parameters=excluded.allowed_parameters,"
                         "encrypted_token=excluded.encrypted_token",
                         (tenant, name, kind, url, json.dumps(download_hosts), output_path,
                          auth_scheme, json.dumps(defaults), json.dumps(allowed_parameters), encrypted, utc()))
        return {"id": name, "kind": kind, "label": name, "is_demo": False, "connection": "tenant"}

    def backend_spec(self, tenant: str, name: str) -> dict:
        if name in self.settings.backends:
            return dict(self.settings.backends[name])
        from cryptography.fernet import Fernet
        with self.db() as conn:
            r = conn.execute("SELECT * FROM connections WHERE tenant=? AND id=?", (tenant, name)).fetchone()
        if r is None:
            raise UserError("Backend not found")
        token = Fernet(self.settings.backend_encryption_key.encode()).decrypt(r["encrypted_token"].encode()).decode()
        return {"kind": r["kind"], "url": r["url"], "download_hosts": json.loads(r["download_hosts"]),
                "output_path": r["output_path"], "auth_scheme": r["auth_scheme"],
                "defaults": json.loads(r["defaults"]), "allowed_parameters": json.loads(r["allowed_parameters"]),
                "api_token": token, "allow_private_network": self.settings.allow_private_connection_hosts}

    def list_backends(self, tenant: str) -> list[dict]:
        installed = [{"id": name, "kind": spec["kind"], "label": spec.get("label", name),
                      "is_demo": spec["kind"] == "demo", "connection": "operator"}
                     for name, spec in self.settings.backends.items()]
        with self.db() as conn:
            rows = conn.execute("SELECT id,kind FROM connections WHERE tenant=? ORDER BY id", (tenant,)).fetchall()
        return installed + [{"id": r["id"], "kind": r["kind"], "label": r["id"],
                             "is_demo": False, "connection": "tenant"} for r in rows]
