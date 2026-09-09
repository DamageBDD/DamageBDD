#!/usr/bin/env python3
"""Fetch one public HTTPS image, normalize it, then return one JSON line.

No redirects, no shell, no proxy environment, no remote SVG renderer. The TCP
connection uses a DNS result already checked with ipaddress; TLS still checks
the original hostname. This closes the usual DNS-rebinding/second-lookup gap.
"""
from __future__ import annotations
import argparse
import hashlib
import http.client
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import stat
import socket
import ssl
import sys
import tempfile
import time
from urllib.parse import urlsplit
import warnings
try:
    from PIL import Image, ImageOps
except ImportError:
    Image = ImageOps = None

MAX_BYTES = 8 * 1024 * 1024
MAX_PIXELS = 16_000_000
MAX_CACHE_FILES = 256
MAX_CACHE_BYTES = 256 * 1024 * 1024
if Image is not None:
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    warnings.simplefilter("error", Image.DecompressionBombWarning)


def checked_url(url: str, allowed_hosts: list[str]) -> tuple[str, str]:
    if len(url) > 4096 or any(ord(c) < 33 or ord(c) == 127 for c in url):
        raise ValueError("invalid_url")
    try:
        u = urlsplit(url)
        port = u.port
    except ValueError as exc:
        raise ValueError("invalid_url") from exc
    if (u.scheme != "https" or not u.hostname or u.username is not None
            or u.password is not None or port not in (None, 443) or u.fragment):
        raise ValueError("https_only_no_credentials")
    try:
        host = u.hostname.encode("idna").decode("ascii").lower()
        allowed_hosts = [h.encode("idna").decode("ascii").lower() for h in allowed_hosts]
    except UnicodeError as exc:
        raise ValueError("invalid_host") from exc
    if allowed_hosts and host not in allowed_hosts:
        raise ValueError("image_host_not_allowed")
    if "%" in host or host.endswith("."):
        raise ValueError("invalid_host")
    return host, (u.path or "/") + (("?" + u.query) if u.query else "")


def public_addresses(host: str) -> list[tuple]:
    entries = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    if not entries:
        raise ValueError("dns_empty")
    for _, _, _, _, address in entries:
        ip = ipaddress.ip_address(address[0])
        # Reject IPv4-mapped IPv6, even if their mapped address is public.
        if (not ip.is_global or ip.is_multicast or ip.is_reserved
                or getattr(ip, "ipv4_mapped", None) is not None
                or getattr(ip, "sixtofour", None) is not None
                or getattr(ip, "teredo", None) is not None):
            raise ValueError("non_public_image_address")
    return entries


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host: str, address: tuple):
        super().__init__(host, 443, timeout=8, context=ssl.create_default_context())
        self.address = address

    def connect(self) -> None:
        family, socktype, proto, _, sockaddr = self.address
        raw = socket.socket(family, socktype, proto)
        raw.settimeout(self.timeout)
        try:
            raw.connect(sockaddr)
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def fetch(url: str, hosts: list[str]) -> bytes:
    host, path = checked_url(url, hosts)
    conn = PinnedHTTPS(host, public_addresses(host)[0])
    end = time.monotonic() + 20
    try:
        conn.request("GET", path, headers={"User-Agent": "ERM-Lens/0.1",
                     "Accept": "image/png,image/jpeg,image/webp,image/avif,image/gif",
                     "Accept-Encoding": "identity"})
        response = conn.getresponse()
        if response.status != 200:
            raise ValueError("image_http_status_" + str(response.status))
        if response.getheader("Content-Encoding", "identity").lower() != "identity":
            raise ValueError("encoded_body_not_supported")
        length = response.getheader("Content-Length")
        if length and (not length.isascii() or not length.isdigit() or len(length) > 10 or int(length) > MAX_BYTES):
            raise ValueError("image_too_large")
        mime = response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
        if mime not in {"image/png", "image/jpeg", "image/webp", "image/avif", "image/gif", "image/apng"}:
            raise ValueError("unsupported_media_type")
        chunks: list[bytes] = []
        total = 0
        while True:
            if time.monotonic() > end:
                raise TimeoutError("image_deadline")
            chunk = response.read(min(65536, MAX_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BYTES:
                raise ValueError("image_too_large")
            chunks.append(chunk)
        if length is not None and total != int(length):
            raise ValueError("truncated_image_body")
        return b"".join(chunks)
    finally:
        conn.close()


def normalize(data: bytes, expected_hash: str = "") -> bytes:
    if len(data) > MAX_BYTES:
        raise ValueError("image_too_large")
    if expected_hash:
        if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            raise ValueError("invalid_image_hash")
        if hashlib.sha256(data).hexdigest() != expected_hash:
            raise ValueError("image_hash_mismatch")
    with Image.open(io.BytesIO(data)) as source:
        if source.format not in {"PNG", "JPEG", "WEBP", "AVIF", "GIF"}:
            raise ValueError("unsupported_image_format")
        if source.width * source.height > MAX_PIXELS:
            raise ValueError("image_dimensions_too_large")
        # Display a single still. Do not decode an unbounded animation.
        source.seek(0)
        image = ImageOps.exif_transpose(source)
        image.thumbnail((1280, 1280))
        # Palette PNG/GIF transparency is carried in info, not an A band.
        has_alpha = "A" in image.getbands() or "transparency" in image.info
        image = image.convert("RGBA" if has_alpha else "RGB")
        # New image discards metadata, including EXIF location and embedded text.
        clean = Image.new(image.mode, image.size)
        clean.paste(image)
        output = io.BytesIO()
        clean.save(output, format="PNG")
        result = output.getvalue()
        if len(result) > MAX_BYTES:
            raise ValueError("normalized_image_too_large")
        return result


def trim_cache(root: Path, keep: Path) -> None:
    files = []
    for p in root.glob("*.png"):
        try:
            if re.fullmatch(r"[0-9a-f]{64}\.png", p.name):
                st = p.lstat()
                if stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid():
                    files.append((st.st_mtime, st.st_size, p))
        except FileNotFoundError:
            continue
    size = sum(s for _, s, _ in files)
    count = len(files)
    for _, s, p in sorted(files):
        if count <= MAX_CACHE_FILES and size <= MAX_CACHE_BYTES:
            break
        if p == keep:
            continue
        try:
            p.unlink()
            size -= s
            count -= 1
        except FileNotFoundError:
            pass


def cached_image(url: str, root: Path, sha256: str, hosts: list[str]) -> Path:
    checked_url(url, hosts)
    if sha256 and not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("invalid_image_hash")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink():
        raise ValueError("unsafe_cache_directory")
    root = root.resolve()
    if root.stat().st_uid != os.getuid():
        raise ValueError("cache_not_owned_by_user")
    os.chmod(root, 0o700)
    key = hashlib.sha256((url + "\0" + sha256).encode()).hexdigest()
    target = root / (key + ".png")
    if target.is_symlink():
        raise ValueError("unsafe_cache_entry")
    if target.exists():
        if not target.is_file():
            raise ValueError("unsafe_cache_entry")
        if valid_cached_png(target):
            os.utime(target, None, follow_symlinks=False)
            trim_cache(root, target)
            return target
        # An interrupted/corrupt old cache entry must not poison every retry.
        target.unlink(missing_ok=True)
    image = normalize(fetch(url, hosts), sha256)
    temp: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=root, prefix=".lens-", delete=False) as f:
            temp = f.name
            f.write(image)
        os.replace(temp, target)
        temp = None
        trim_cache(root, target)
        return target
    finally:
        if temp:
            Path(temp).unlink(missing_ok=True)



def valid_cached_png(path: Path) -> bool:
    """Do not trust a file merely because its cache key ends in .png."""
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                    or st.st_size <= 8 or st.st_size > MAX_BYTES):
                return False
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            return False
        with Image.open(io.BytesIO(data)) as image:
            if (image.format != "PNG" or image.mode not in {"RGB", "RGBA"}
                    or not (0 < image.width <= 1280 and 0 < image.height <= 1280)
                    or getattr(image, "n_frames", 1) != 1 or image.info):
                return False
            image.verify()
        # verify() validates container integrity; load() also checks decoding.
        with Image.open(io.BytesIO(data)) as image:
            image.load()
        return True
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError,
            Image.DecompressionBombWarning):
        return False


PUBLIC_ERRORS = frozenset({
    "invalid_url", "https_only_no_credentials", "image_host_not_allowed",
    "invalid_host", "dns_empty", "non_public_image_address",
    "encoded_body_not_supported", "image_too_large", "unsupported_media_type",
    "invalid_image_hash", "image_hash_mismatch", "unsupported_image_format",
    "image_dimensions_too_large", "unsafe_cache_directory", "cache_not_owned_by_user",
    "unsafe_cache_entry", "truncated_image_body", "normalized_image_too_large",
    "image_deadline",
})


def public_error(exc: Exception) -> str:
    # Parser/codec ValueErrors can echo the input, including URL credentials or
    # query tokens. Only our fixed codes and numeric HTTP status codes escape.
    message = str(exc)
    if message in PUBLIC_ERRORS:
        return message
    if re.fullmatch(r"image_http_status_[1-5][0-9]{2}", message):
        return message
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "image_deadline"
    if isinstance(exc, (Image.DecompressionBombError, Image.DecompressionBombWarning)):
        return "image_dimensions_too_large"
    if isinstance(exc, MemoryError):
        return "decoder_memory_limit"
    return "image_decode_or_io_failed"


def set_resource_limits() -> None:
    """Additional Unix process budgets, not a decoder sandbox."""
    try:
        import resource
    except ImportError:
        return
    for name, value in (("RLIMIT_AS", 512 * 1024 * 1024), ("RLIMIT_CPU", 20),
                        ("RLIMIT_FSIZE", MAX_BYTES)):
        limit = getattr(resource, name, None)
        if limit is None:
            continue
        try:
            soft, hard = resource.getrlimit(limit)
            cap = min(value, hard) if hard != resource.RLIM_INFINITY else value
            if soft != resource.RLIM_INFINITY:
                cap = min(cap, soft)
            resource.setrlimit(limit, (cap, cap))
        except (OSError, ValueError):
            # Some containers/platforms disallow changing these limits. Byte,
            # pixel, socket and alarm checks remain active; no sandbox claim.
            continue

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--sha256", default="")
    parser.add_argument("--host", action="append", default=[])
    args = parser.parse_args()
    if Image is None:
        print(json.dumps({"error": "pillow_unavailable"}), flush=True)
        return 1
    set_resource_limits()
    # Bound DNS, TLS, reads, and decode on Linux/Unix as well as socket timeouts.
    if hasattr(signal, "SIGALRM"):
        def expired(_signum: int, _frame: object) -> None:
            raise TimeoutError("image_deadline")
        signal.signal(signal.SIGALRM, expired)
        signal.alarm(25)
    try:
        path = cached_image(args.url, args.cache, args.sha256, args.host)
        print(json.dumps({"ok": str(path)}, ensure_ascii=True), flush=True)
        return 0
    except Exception as e:
        # Do not leak URL query parameters, credentials, local paths, or traceback.
        print(json.dumps({"error": public_error(e)}), flush=True)
        return 1

if __name__ == "__main__":
    sys.exit(main())
