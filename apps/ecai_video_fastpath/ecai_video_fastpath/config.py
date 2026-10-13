"""Static, operator-controlled configuration. No customer-requested outbound URLs."""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class Settings:
    data_dir: Path = Path("./data")
    # Tenant slug -> opaque API key. Never send keys to a browser except user entry.
    api_keys: dict[str, str] = field(default_factory=dict)
    backends: dict[str, dict[str, Any]] = field(default_factory=lambda: {"demo": {"kind": "demo"}})
    max_upload_bytes: int = 100 * 1024 * 1024
    max_duration_seconds: int = 180
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"
    ffmpeg_timeout: int = 240
    polling_seconds: float = 0.4
    # Optional self-service customer connectors: operator-approved HTTPS hosts only.
    allowed_connection_hosts: list[str] = field(default_factory=list)
    backend_encryption_key: str | None = None
    bridge_secret: str | None = None  # Shared only with the ECAI Cowboy node
    allow_private_connection_hosts: bool = False  # development tests only, never public

    def validate(self) -> "Settings":
        if not self.api_keys and not self.bridge_secret:
            raise ValueError("ECAI_VIDEO_KEYS or ECAI_VIDEO_BRIDGE_SECRET is required")
        if self.bridge_secret and len(self.bridge_secret) < 32:
            raise ValueError("ECAI_VIDEO_BRIDGE_SECRET must be at least 32 characters")
        for tenant, key in self.api_keys.items():
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,48}", tenant):
                raise ValueError("Tenant IDs must be safe slugs")
            if not isinstance(key, str) or len(key) < 12:
                raise ValueError("API keys must have at least 12 characters")
        if len(set(self.api_keys.values())) != len(self.api_keys):
            raise ValueError("API keys must be unique")
        for name, spec in self.backends.items():
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,48}", name):
                raise ValueError("Invalid backend name")
            if spec.get("kind") not in ("demo", "http_sync", "fal_queue"):
                raise ValueError(f"Unsupported backend kind for {name}")
            if spec["kind"] != "demo" and not spec.get("url"):
                raise ValueError(f"Backend {name} needs an operator URL")
            if spec["kind"] != "demo" and not spec.get("download_hosts"):
                raise ValueError(f"Backend {name} needs exact approved download_hosts")
        if self.max_upload_bytes < 1024 or self.max_duration_seconds <= 0:
            raise ValueError("Invalid media limits")
        if self.allowed_connection_hosts and not self.backend_encryption_key:
            raise ValueError("Self-service backend connections require ECAI_VIDEO_FERNET_KEY")
        if self.backend_encryption_key:
            from cryptography.fernet import Fernet
            try:
                Fernet(self.backend_encryption_key.encode("ascii"))
            except (ValueError, TypeError) as exc:
                raise ValueError("ECAI_VIDEO_FERNET_KEY must be a valid Fernet key") from exc
        self.data_dir = self.data_dir.resolve()
        return self

    @classmethod
    def from_env(cls) -> "Settings":
        keys = json.loads(os.environ.get("ECAI_VIDEO_KEYS", "{}"))
        backends = json.loads(os.environ.get("ECAI_VIDEO_BACKENDS", '{"demo":{"kind":"demo"}}'))
        return cls(
            data_dir=Path(os.environ.get("ECAI_VIDEO_DATA", "./data")),
            api_keys=keys,
            backends=backends,
            max_upload_bytes=int(os.environ.get("ECAI_VIDEO_MAX_UPLOAD_MB", "100")) * 1024 * 1024,
            max_duration_seconds=int(os.environ.get("ECAI_VIDEO_MAX_SECONDS", "180")),
            ffmpeg=os.environ.get("ECAI_VIDEO_FFMPEG", "ffmpeg"),
            ffprobe=os.environ.get("ECAI_VIDEO_FFPROBE", "ffprobe"),
            allowed_connection_hosts=json.loads(os.environ.get("ECAI_VIDEO_ALLOWED_CONNECT_HOSTS", "[]")),
            backend_encryption_key=os.environ.get("ECAI_VIDEO_FERNET_KEY"),
            bridge_secret=os.environ.get("ECAI_VIDEO_BRIDGE_SECRET"),
        ).validate()
