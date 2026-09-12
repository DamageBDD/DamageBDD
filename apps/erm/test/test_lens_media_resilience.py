"""Offline regression tests: no public image requests, wallets, or relays."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import ssl
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image, PngImagePlugin

MODULE_PATH = Path(__file__).resolve().parents[1] / "priv" / "lens_media.py"
spec = importlib.util.spec_from_file_location("lens_media_hardened", MODULE_PATH)
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


def png(size=(16, 12), mode="RGB", metadata=False):
    im = Image.new(mode, size)
    options = {}
    if metadata:
        info = PngImagePlugin.PngInfo()
        info.add_text("location", "private")
        options["pnginfo"] = info
    out = io.BytesIO()
    im.save(out, format="PNG", **options)
    return out.getvalue()


class URLTests(unittest.TestCase):
    def test_https_url(self):
        self.assertEqual(("example.com", "/p.png?x=1"), media.checked_url("https://example.com/p.png?x=1", []))

    def test_host_allowlist_normalization(self):
        self.assertEqual("example.com", media.checked_url("https://example.com/x", ["EXAMPLE.COM"])[0])

    def test_credentials(self):
        with self.assertRaises(ValueError): media.checked_url("https://user:secret@example.com/x", [])

    def test_fragment(self):
        with self.assertRaises(ValueError): media.checked_url("https://example.com/x#secret", [])

    def test_bad_port(self):
        with self.assertRaisesRegex(ValueError, "^invalid_url$"):
            media.checked_url("https://example.com:supersecret/x", [])

    def test_bad_ipv6(self):
        with self.assertRaisesRegex(ValueError, "^invalid_url$"):
            media.checked_url("https://[secret/x", [])

    def test_cleartext_denied(self):
        with self.assertRaises(ValueError): media.checked_url("http://example.com/x", [])

    def test_controls_denied(self):
        for c in ("\n", "\r", "\x00", "\x7f", " "):
            with self.subTest(c=c), self.assertRaises(ValueError):
                media.checked_url("https://example.com/" + c, [])

    def test_host_not_allowed(self):
        with self.assertRaisesRegex(ValueError, "image_host_not_allowed"):
            media.checked_url("https://evil.example/x", ["example.com"])

    def test_mixed_public_private_dns_denied(self):
        rows = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 443)) for ip in ("8.8.8.8", "127.0.0.1")]
        with patch.object(socket, "getaddrinfo", return_value=rows), self.assertRaises(ValueError):
            media.public_addresses("example.com")

    def test_ipv4_mapped_denied(self):
        row = (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("::ffff:8.8.8.8", 443, 0, 0))
        with patch.object(socket, "getaddrinfo", return_value=[row]), self.assertRaises(ValueError):
            media.public_addresses("example.com")


class NormalizationTests(unittest.TestCase):
    def test_metadata_stripped(self):
        with Image.open(io.BytesIO(media.normalize(png(metadata=True)))) as image:
            self.assertFalse(image.info)

    def test_hash_verified(self):
        data = png()
        self.assertTrue(media.normalize(data, hashlib.sha256(data).hexdigest()).startswith(b"\x89PNG"))

    def test_wrong_hash_rejected(self):
        with self.assertRaisesRegex(ValueError, "image_hash_mismatch"):
            media.normalize(png(), "0" * 64)

    def test_hash_syntax(self):
        with self.assertRaisesRegex(ValueError, "invalid_image_hash"):
            media.normalize(png(), "x" * 64)

    def test_palette_alpha_preserved(self):
        im = Image.new("P", (8, 8), color=0)
        im.putpalette([0, 0, 0] * 256)
        out = io.BytesIO(); im.save(out, format="PNG", transparency=0)
        with Image.open(io.BytesIO(media.normalize(out.getvalue()))) as image:
            self.assertEqual("RGBA", image.mode)
            self.assertEqual(0, image.getpixel((0, 0))[3])

    def test_resize_bound(self):
        with Image.open(io.BytesIO(media.normalize(png((1600, 800))))) as image:
            self.assertEqual((1280, 640), image.size)

    def test_input_byte_limit(self):
        with patch.object(media, "MAX_BYTES", 8), self.assertRaisesRegex(ValueError, "image_too_large"):
            media.normalize(png())

    def test_normalized_byte_limit(self):
        # A 1-bit source is smaller than its normalized RGB representation.
        source = png((64, 64), "1")
        with patch.object(media, "MAX_BYTES", len(source)), self.assertRaisesRegex(ValueError, "normalized_image_too_large"):
            media.normalize(source)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "cache"
        self.url = "https://example.com/p.png"
        self.key = hashlib.sha256((self.url + "\0").encode()).hexdigest()
        self.target = self.root / (self.key + ".png")

    def tearDown(self): self.tmp.cleanup()

    def test_cache_miss_then_hit(self):
        with patch.object(media, "fetch", return_value=png()) as fetch:
            first = media.cached_image(self.url, self.root, "", [])
            second = media.cached_image(self.url, self.root, "", [])
            self.assertEqual(first, second); self.assertEqual(1, fetch.call_count)
            self.assertTrue(media.valid_cached_png(first))

    def test_corrupt_entry_recovered(self):
        self.root.mkdir(); self.target.write_bytes(b"corrupt")
        with patch.object(media, "fetch", return_value=png()) as fetch:
            result = media.cached_image(self.url, self.root, "", [])
            self.assertTrue(media.valid_cached_png(result)); fetch.assert_called_once()

    def test_metadata_cache_replaced(self):
        self.root.mkdir(); self.target.write_bytes(png(metadata=True))
        with patch.object(media, "fetch", return_value=png()) as fetch:
            media.cached_image(self.url, self.root, "", []); fetch.assert_called_once()

    def test_cache_symlink_denied(self):
        self.root.mkdir(); outside = Path(self.tmp.name) / "outside"; outside.write_bytes(png())
        self.target.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "unsafe_cache_entry"):
            media.cached_image(self.url, self.root, "", [])
        self.assertTrue(outside.exists())

    def test_root_symlink_denied(self):
        actual = Path(self.tmp.name) / "actual"; actual.mkdir(); self.root.symlink_to(actual)
        with self.assertRaisesRegex(ValueError, "unsafe_cache_directory"):
            media.cached_image(self.url, self.root, "", [])

    def test_directory_entry_denied(self):
        self.target.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "unsafe_cache_entry"):
            media.cached_image(self.url, self.root, "", [])

    def test_prune_does_not_delete_unrelated_png(self):
        self.root.mkdir(); other = self.root / "important.png"; other.write_bytes(png())
        self.target.write_bytes(png())
        with patch.object(media, "MAX_CACHE_FILES", 0), patch.object(media, "MAX_CACHE_BYTES", 0):
            media.trim_cache(self.root, self.target)
        self.assertTrue(other.exists()); self.assertTrue(self.target.exists())

    def test_count_bound_preserves_current(self):
        self.root.mkdir()
        for n in range(5):
            p = self.root / (f"{n:064x}.png"); p.write_bytes(png()); os.utime(p, (n, n))
        self.target.write_bytes(png())
        with patch.object(media, "MAX_CACHE_FILES", 3): media.trim_cache(self.root, self.target)
        self.assertEqual(3, len(list(self.root.glob("*.png")))); self.assertTrue(self.target.exists())

    def test_permissions_private(self):
        with patch.object(media, "fetch", return_value=png()):
            media.cached_image(self.url, self.root, "", [])
        self.assertEqual(0o700, self.root.stat().st_mode & 0o777)
        self.assertEqual(0o600, self.target.stat().st_mode & 0o777)

    def test_truncated_png_cache_invalid(self):
        self.root.mkdir(); self.target.write_bytes(png()[:-15])
        self.assertFalse(media.valid_cached_png(self.target))

    def test_non_png_cache_invalid(self):
        out = io.BytesIO(); Image.new("RGB", (10, 10)).save(out, format="JPEG")
        self.root.mkdir(); self.target.write_bytes(out.getvalue())
        self.assertFalse(media.valid_cached_png(self.target))


class PrivacyTests(unittest.TestCase):
    def test_raw_value_error_redacted(self):
        self.assertEqual("image_decode_or_io_failed", media.public_error(ValueError("secret@example.com?token=secret")))

    def test_os_error_redacted(self):
        self.assertEqual("image_decode_or_io_failed", media.public_error(OSError("/home/private/file")))

    def test_known_code_preserved(self):
        self.assertEqual("invalid_url", media.public_error(ValueError("invalid_url")))

    def test_http_status_preserved(self):
        self.assertEqual("image_http_status_503", media.public_error(ValueError("image_http_status_503")))

    def test_status_with_payload_redacted(self):
        self.assertEqual("image_decode_or_io_failed", media.public_error(ValueError("image_http_status_503 secret")))

    def test_timeout_code(self):
        self.assertEqual("image_deadline", media.public_error(TimeoutError("secret")))

    def test_memory_code(self):
        self.assertEqual("decoder_memory_limit", media.public_error(MemoryError()))


class FetchTests(unittest.TestCase):
    def fetch_response(self, body=b"abc", headers=None, status=200):
        headers = {"Content-Type": "image/png", **(headers or {})}
        class Response:
            def __init__(self): self.status = status; self.stream = io.BytesIO(body)
            def getheader(self, name, default=None): return headers.get(name, default)
            def read(self, n): return self.stream.read(n)
        class Connection:
            closed = False
            def request(self, *a, **kw): pass
            def getresponse(self): return Response()
            def close(self): self.closed = True
        connection = Connection()
        with patch.object(media, "PinnedHTTPS", return_value=connection), patch.object(media, "public_addresses", return_value=[None]):
            try: return media.fetch("https://example.com/p.png", [])
            finally: self.assertTrue(connection.closed)

    def test_truncated_content_length(self):
        with self.assertRaisesRegex(ValueError, "truncated_image_body"):
            self.fetch_response(headers={"Content-Length": "10"})

    def test_matching_length(self): self.assertEqual(b"abc", self.fetch_response(headers={"Content-Length": "3"}))
    def test_redirect_denied(self):
        with self.assertRaisesRegex(ValueError, "image_http_status_302"): self.fetch_response(status=302)
    def test_content_encoding_denied(self):
        with self.assertRaisesRegex(ValueError, "encoded_body_not_supported"):
            self.fetch_response(headers={"Content-Encoding": "gzip"})
    def test_mime_denied(self):
        with self.assertRaisesRegex(ValueError, "unsupported_media_type"):
            self.fetch_response(headers={"Content-Type": "image/svg+xml"})
    def test_absurd_length_denied(self):
        with self.assertRaisesRegex(ValueError, "image_too_large"):
            self.fetch_response(headers={"Content-Length": "9" * 10000})
    def test_unicode_length_denied(self):
        with self.assertRaisesRegex(ValueError, "image_too_large"):
            self.fetch_response(headers={"Content-Length": "٣"})


if __name__ == "__main__": unittest.main()
