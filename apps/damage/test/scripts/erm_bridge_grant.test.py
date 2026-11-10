#!/usr/bin/env python3
"""Exercise actual grant provisioning writes, failure atomicity and locking."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/erm_bridge_grant.escript"

class GrantTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="erm-grant-")
        self.parent = Path(self.tmp.name)
        self.path = self.parent / "grants.config"
    def tearDown(self):
        self.tmp.cleanup()
    def grant(self, name="alice", digest="a"*64, *extra):
        return subprocess.run(["escript", str(SCRIPT), "--id", name, "--sha256", digest,
            "--gid", str(os.getgid()), "--grants-file", str(self.path), *extra],
            capture_output=True, text=True)
    def test_grant_and_replace_preserve_other_users(self):
        self.assertEqual(0, self.grant().returncode)
        self.assertEqual(0, self.grant("bob", "b"*64).returncode)
        self.assertEqual(0, self.grant("alice", "c"*64).returncode)
        content = self.path.read_text()
        self.assertIn('<<"bob">>', content)
        self.assertNotIn('"' + "a"*64 + '"', content)
        self.assertIn("c"*64, content)
        self.assertEqual(0o640, self.path.stat().st_mode & 0o777)
    def test_duplicate_digest_cannot_disable_existing_registry(self):
        self.assertEqual(0, self.grant().returncode)
        before = self.path.read_bytes()
        self.assertNotEqual(0, self.grant("bob").returncode)
        self.assertEqual(before, self.path.read_bytes())
    def test_existing_lock_is_not_removed_by_other_writer(self):
        lock = self.parent / ".erm-users.lock"
        lock.mkdir()
        self.assertNotEqual(0, self.grant().returncode)
        self.assertTrue(lock.is_dir())
        self.assertFalse(self.path.exists())
    def test_symlink_target_is_untouched(self):
        real = self.parent / "real.config"
        real.write_text("[].\n")
        self.path.symlink_to(real)
        self.assertNotEqual(0, self.grant().returncode)
        self.assertEqual("[].\n", real.read_text())
    def test_invalid_existing_registry_is_not_rewritten(self):
        self.path.write_text('[#{id => <<"incomplete">>}].\n')
        self.path.chmod(0o640)
        before = self.path.read_bytes()
        self.assertNotEqual(0, self.grant().returncode)
        self.assertEqual(before, self.path.read_bytes())
    def test_unknown_operation_is_not_granted(self):
        self.assertNotEqual(0, self.grant("alice", "a"*64, "--ops", "rpc").returncode)
        self.assertFalse(self.path.exists())
    def test_group_writable_ancestor_is_rejected(self):
        self.parent.chmod(0o777)
        self.assertNotEqual(0, self.grant().returncode)
        self.assertFalse(self.path.exists())

if __name__ == "__main__":
    unittest.main()
