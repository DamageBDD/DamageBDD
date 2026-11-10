#!/usr/bin/env python3
"""Exercise launcher isolation without a platform-specific ERTS installation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="erm user release ")
        self.root = Path(self.tmp.name)
        (self.root / "bin").mkdir()
        (self.root / "releases" / "0.1.0").mkdir(parents=True)
        (self.root / "erts-1.2.3" / "bin").mkdir(parents=True)
        shutil.copyfile(HERE / "erm-user", self.root / "bin" / "erm-user")
        (self.root / "bin" / "erm-user").chmod(0o755)
        (self.root / "releases" / "start_erl.data").write_text("1.2.3 0.1.0\n")
        (self.root / "releases" / "0.1.0" / "start.boot").touch()
        (self.root / "runtime").mkdir(mode=0o700)
        self.exec = self.root / "erts-1.2.3" / "bin" / "erlexec"
        self.exec.write_text("#!/bin/sh\nprintf '%s\\n' \"${ERL_FLAGS-unset}\" \"${ERL_AFLAGS-unset}\" \"${ERL_ZFLAGS-unset}\"\nprintf '%s\\n' \"$HOME\" \"${ERM_USER_DESKTOP_HOME-unset}\"\nprintf '%s\\n' \"$@\"\n")
        self.exec.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_launcher(self, *args, **env):
        return subprocess.run([str(self.root / "bin" / "erm-user"), *args],
                              env={**os.environ, "ERM_USER_RUNTIME_DIR": str(self.root / "runtime"), **env}, text=True,
                              capture_output=True)

    def test_foreground_uses_bundled_boot_and_removes_inherited_vm_flags(self):
        p = self.run_launcher("foreground", ERL_FLAGS="-name damage@localhost",
                              ERL_AFLAGS="-setcookie secret", ERL_ZFLAGS="-sname injected")
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.splitlines()
        self.assertEqual(lines[:3], ["unset", "unset", "unset"])
        self.assertEqual(lines[lines.index("-boot") + 1],
                         str(self.root / "releases" / "0.1.0" / "start"))
        self.assertIn("-noinput", lines)
        self.assertNotIn("-name", lines)
        self.assertNotIn("-setcookie", lines)
        cookie_home = Path(lines[3])
        self.assertEqual(lines[4], os.environ["HOME"])
        self.assertNotIn("-home", lines)
        self.assertEqual(cookie_home.parent, self.root / "runtime")
        self.assertEqual(cookie_home.stat().st_mode & 0o777, 0o700)

    def test_relx_metadata_without_final_newline_is_accepted(self):
        (self.root / "releases" / "start_erl.data").write_text("1.2.3 0.1.0")
        p = self.run_launcher()
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_credentials_uses_clean_boot_and_fixed_entry(self):
        p = self.run_launcher("credentials")
        self.assertEqual(p.returncode, 0, p.stderr)
        args = p.stdout.splitlines()
        self.assertEqual(args[args.index("-boot") + 1],
                         str(self.root / "releases" / "0.1.0" / "start_clean"))
        self.assertEqual(args[-3:], ["-run", "erm_user_credentials", "main"])
        self.assertNotIn("-home", args)

    def test_check_uses_clean_boot_and_fixed_health_entry(self):
        p = self.run_launcher("check")
        self.assertEqual(p.returncode, 0, p.stderr)
        args = p.stdout.splitlines()
        self.assertEqual(args[args.index("-boot") + 1],
                         str(self.root / "releases" / "0.1.0" / "start_clean"))
        self.assertEqual(args[-3:], ["-run", "erm_user_check", "main"])
        self.assertNotIn("-home", args)

    def test_public_runtime_directory_is_rejected(self):
        (self.root / "runtime").chmod(0o755)
        self.assertEqual(self.run_launcher().returncode, 73)

    def test_rpc_and_extra_erl_arguments_are_rejected(self):
        for args in [("rpc",), ("foreground", "-sname", "injected")]:
            with self.subTest(args=args):
                p = self.run_launcher(*args)
                self.assertEqual(p.returncode, 64)
                self.assertEqual(p.stdout, "")

    def test_release_metadata_cannot_escape_release_root(self):
        for data in ["../../usr 0.1.0\n", "1.2.3 ../../tmp\n", "1.2.3 0.1.0 extra\n"]:
            with self.subTest(data=data):
                (self.root / "releases" / "start_erl.data").write_text(data)
                self.assertEqual(self.run_launcher().returncode, 65)

    def test_admin_grant_wrapper_uses_bundled_escript_and_literal_arguments(self):
        grant = self.root / "bin" / "erm-bridge-grant"
        shutil.copyfile(HERE.parents[3] / "apps" / "damage" / "scripts" / "erm-bridge-grant", grant)
        grant.chmod(0o755)
        escript = self.exec.parent / "escript"
        escript.write_text("#!/bin/sh\nprintf '%s\\n' \"${ERL_FLAGS-unset}\" \"$@\"\n")
        escript.chmod(0o755)
        (self.root / "releases" / "start_erl.data").write_text("1.2.3 0.1.0")
        p = subprocess.run([str(grant), "--principal", "a name;literal"],
                           env={**os.environ, "ERL_FLAGS": "-setcookie damage"},
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines(), ["unset",
            str(self.root / "share" / "damage" / "erm" / "erm_bridge_grant.escript"),
            "--principal", "a name;literal"])

    def test_incomplete_release_fails_before_exec(self):
        self.exec.unlink()
        self.assertEqual(self.run_launcher().returncode, 66)


if __name__ == "__main__":
    unittest.main()
