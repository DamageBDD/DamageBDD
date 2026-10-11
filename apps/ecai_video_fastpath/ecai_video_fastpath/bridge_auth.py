"""Short-lived, method/path-bound credentials issued by an authenticated ECAI node.

The shared secret must never be sent to a browser. TLS or loopback is mandatory
between Cowboy and Fastpath. Static API keys remain supported for direct users.
"""
from __future__ import annotations

import hashlib
import hmac
import re
import time

TOKEN = re.compile(r"bridge1\.([A-Za-z0-9_-]{1,48})\.([0-9]{10,11})\.([0-9a-f]{64})")


def message(tenant: str, timestamp: str, method: str, path: str) -> bytes:
    return f"{tenant}\n{timestamp}\n{method.upper()}\n{path}".encode("utf-8")


def sign(secret: str, tenant: str, method: str, path: str, *, now: int | None = None) -> str:
    if not secret or len(secret) < 32:
        raise ValueError("Bridge secret must have at least 32 characters")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,48}", tenant):
        raise ValueError("Invalid tenant")
    stamp = str(int(time.time() if now is None else now))
    digest = hmac.new(secret.encode(), message(tenant, stamp, method, path), hashlib.sha256).hexdigest()
    return f"bridge1.{tenant}.{stamp}.{digest}"


def verify(secret: str | None, token: str, method: str, path: str, *, now: int | None = None) -> str | None:
    if not secret:
        return None
    match = TOKEN.fullmatch(token)
    if not match:
        return None
    tenant, stamp, actual = match.groups()
    current = int(time.time() if now is None else now)
    if abs(current - int(stamp)) > 60:
        return None
    expected = hmac.new(secret.encode(), message(tenant, stamp, method, path), hashlib.sha256).hexdigest()
    return tenant if hmac.compare_digest(actual, expected) else None
