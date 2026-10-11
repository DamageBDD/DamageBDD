"""Bring-your-own-model adapters: test pattern, synchronous HTTP, and fal queue.

All provider endpoints and result-host allowlists are operator configured.
No user-provided URL is ever fetched by this service.
"""
from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

import httpx

from .store import Store, UserError


class ProviderError(RuntimeError):
    pass


def check_url(url: str, allow_hosts: list[str], allow_private: bool = False) -> None:
    try:
        parsed = urlparse(url)
        host = parsed.hostname or ""
        if parsed.username or parsed.password or parsed.fragment or host.lower() not in [x.lower() for x in allow_hosts]:
            raise ValueError("URL host is not approved")
        if parsed.scheme != "https" and not (allow_private and parsed.scheme == "http"):
            raise ValueError("HTTPS required")
        if parsed.port and parsed.port not in (80, 443) and not allow_private:
            raise ValueError("Port not approved")
        try:
            ip = ipaddress.ip_address(host)
            if not ip.is_global and not allow_private:
                raise ValueError("Private IP denied")
        except ValueError as e:
            # A valid IP which failed the is_global check should not pass.
            if "Private IP denied" in str(e):
                raise
        if not parsed.path.startswith("/"):
            raise ValueError("URL has no path")
    except (ValueError, TypeError) as exc:
        raise ProviderError(f"Unsafe provider URL: {exc}") from exc


def lookup(doc: dict, key_path: str) -> str:
    value = doc
    for key in key_path.split("."):
        if not isinstance(value, dict) or key not in value:
            raise ProviderError(f"Provider missing configured output field: {key_path}")
        value = value[key]
    if not isinstance(value, str) or not value:
        raise ProviderError(f"Provider output field is not a URL: {key_path}")
    return value


class Providers:
    def __init__(self, store: Store):
        self.store = store
        self.settings = store.settings

    @staticmethod
    def _credentials(spec: dict) -> dict[str, str]:
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if spec.get("api_token"):
            scheme = spec.get("auth_scheme", "Bearer")
            headers["Authorization"] = f"{scheme} {spec['api_token']}"
        elif spec.get("auth_env"):
            secret = os.environ.get(spec["auth_env"])
            if not secret:
                raise ProviderError(f"Missing configured provider credential environment variable: {spec['auth_env']}")
            scheme = spec.get("auth_scheme", "Bearer")
            if scheme not in ("Bearer", "Key"):
                raise ProviderError("Unsupported provider authentication scheme")
            headers["Authorization"] = f"{scheme} {secret}"
        return headers

    def _validate_backend_url(self, spec: dict, url: str) -> None:
        permitted = [urlparse(spec["url"]).hostname] + spec.get("download_hosts", [])
        check_url(url, permitted, spec.get("allow_private_network", False))

    def submit(self, job: dict) -> None:
        jid, tenant, project = job["id"], job["tenant"], job["project"]
        spec = self.store.backend_spec(tenant, job["backend"])
        kind = spec["kind"]
        if kind == "demo":
            temp = self.store.new_temp(tenant, project)
            try:
                cmd = [self.settings.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                       "testsrc2=size=640x360:rate=12", "-t", "2", "-c:v", "libx264", "-preset", "ultrafast",
                       "-pix_fmt", "yuv420p", str(temp)]
                p = subprocess.run(cmd, capture_output=True, timeout=60)
                if p.returncode:
                    raise ProviderError(f"Local demo ffmpeg failed: {p.stderr.decode('utf-8', 'replace')[-300:]}")
                sha, _ = self.store.ingest_temp(tenant, project, temp)
                v = self.store.register_import(tenant, project, sha, "demo-pattern",
                                               {"backend": "demo", "model": "synthetic-test-pattern", "job_id": jid})
                self.store.update_job(jid, "completed", version_id=v["id"])
            finally:
                temp.unlink(missing_ok=True)
            return
        url = spec["url"]
        self._validate_backend_url(spec, url)
        payload = {**spec.get("defaults", {}), "prompt": job["prompt"], **job["backend_input"]}
        # Remote provider receives a stable request ID; honoring idempotency is provider dependent.
        headers = {**self._credentials(spec), "X-ECAI-Job-ID": jid}
        try:
            with httpx.Client(timeout=httpx.Timeout(90.0), follow_redirects=False, trust_env=False) as client:
                r = client.post(url, json=payload, headers=headers)
                r.raise_for_status()
                doc = r.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise ProviderError(f"Provider submit failed: {type(exc).__name__}") from exc
        self.store.event(tenant, project, "provider_submit", {"backend": job["backend"], "job_id": jid})
        if kind == "http_sync":
            media_url = lookup(doc, spec.get("output_path", "video_url"))
            self._validate_backend_url(spec, media_url)
            self.store.update_job(jid, "downloading", media_url=media_url)
            self.deliver(job, media_url)
        elif kind == "fal_queue":
            rid = doc.get("request_id")
            if not isinstance(rid, str) or not re.fullmatch(r"[0-9a-zA-Z_-]{5,160}", rid):
                raise ProviderError("Provider did not return a valid request_id")
            response_url = doc.get("response_url") or (url.rstrip("/") + "/requests/" + rid)
            self._validate_backend_url(spec, response_url)
            self.store.update_job(jid, "awaiting_result", remote_id=rid, result_url=response_url,
                                  next_check=time.time() + 2)
        else:
            raise ProviderError("Backend kind not handled")

    def poll(self, job: dict) -> None:
        if job.get("media_url"):
            self.deliver(job, job["media_url"])
            return
        spec = self.store.backend_spec(job["tenant"], job["backend"])
        if spec["kind"] == "http_sync":
            if not job["media_url"]:
                raise ProviderError("Missing stored media URL")
            self.deliver(job, job["media_url"])
            return
        if spec["kind"] != "fal_queue":
            raise ProviderError("Unexpected polling state")
        rid = job.get("remote_id")
        if not rid or not re.fullmatch(r"[0-9a-zA-Z_-]{5,160}", rid):
            raise ProviderError("Remote request ID missing")
        url = spec["url"].rstrip("/") + "/requests/" + rid + "/status"
        self._validate_backend_url(spec, url)
        try:
            with httpx.Client(timeout=30, follow_redirects=False, trust_env=False) as client:
                response = client.get(url, headers=self._credentials(spec))
                response.raise_for_status()
                status = response.json().get("status")
                if status in ("IN_QUEUE", "IN_PROGRESS", "PENDING", "PROCESSING"):
                    self.store.update_job(job["id"], "awaiting_result", next_check=time.time() + 5)
                    return
                if status != "COMPLETED":
                    raise ProviderError(f"Unexpected provider status: {status}")
                result_url = job.get("result_url") or (spec["url"].rstrip("/") + "/requests/" + rid)
                self._validate_backend_url(spec, result_url)
                result = client.get(result_url, headers=self._credentials(spec))
                result.raise_for_status()
                doc = result.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise ProviderError(f"Provider status/result failed: {type(exc).__name__}") from exc
        media_url = lookup(doc, spec.get("output_path", "video.url"))
        self._validate_backend_url(spec, media_url)
        self.store.update_job(job["id"], "downloading", media_url=media_url)
        self.deliver(job, media_url)

    def deliver(self, job: dict, media_url: str) -> None:
        spec = self.store.backend_spec(job["tenant"], job["backend"])
        self._validate_backend_url(spec, media_url)
        temp = self.store.new_temp(job["tenant"], job["project"])
        try:
            with httpx.Client(timeout=httpx.Timeout(120, connect=20), follow_redirects=False, trust_env=False) as client:
                with client.stream("GET", media_url) as r:
                    r.raise_for_status()
                    total = 0
                    with temp.open("wb") as out:
                        for chunk in r.iter_bytes(1024 * 1024):
                            total += len(chunk)
                            if total > self.settings.max_upload_bytes:
                                raise ProviderError("Provider video exceeds media limit")
                            out.write(chunk)
            sha, _ = self.store.ingest_temp(job["tenant"], job["project"], temp)
            version = self.store.register_import(job["tenant"], job["project"], sha, "provider-result",
                                                  {"backend": job["backend"], "job_id": job["id"],
                                                   "remote_id": job.get("remote_id")})
            self.store.update_job(job["id"], "completed", version_id=version["id"])
        except (httpx.HTTPError, ValueError, OSError, UserError) as exc:
            raise ProviderError(f"Provider media delivery failed: {type(exc).__name__}: {exc}") from exc
        finally:
            temp.unlink(missing_ok=True)

    def process_job(self, job: dict) -> None:
        try:
            if job["state"] == "submitting":
                self.submit(job)
            else:
                self.poll(job)
        except Exception as exc:  # Don't kill worker on a job-specific failure.
            # Network failures after submit may be ambiguous; never auto-resubmit.
            self.store.update_job(job["id"], "needs_review" if job["state"] == "submitting" else "failed",
                                  error=f"{type(exc).__name__}: {str(exc)[:300]}")
