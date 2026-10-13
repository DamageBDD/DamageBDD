import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hook", Path(__file__).parents[2] / "priv/share/omdrop_ecai_hook.py")
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

class HookTests(unittest.TestCase):
    def test_disabled_without_directory(self):
        with tempfile.TemporaryDirectory() as root:
            hook.completed(root, ["a.txt"])
            self.assertEqual(os.listdir(root), [])

    def test_atomic_private_event_and_unicode(self):
        with tempfile.TemporaryDirectory() as root:
            events = Path(root) / ".ecai-events"
            events.mkdir(mode=0o700)
            name = "a 'quote' λ.md"
            hook.completed(root, [name])
            files = list(events.iterdir())
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].suffix, ".json")
            data = json.loads(files[0].read_bytes())
            self.assertEqual(os.fsdecode(base64.b64decode(data["name_b64"])), name)
            self.assertEqual(data["transport"], "airdrop")
            self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)

    def test_symlink_or_world_readable_spool_rejected(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            events = Path(root) / ".ecai-events"
            events.symlink_to(outside)
            hook.completed(root, ["a.txt"])
            self.assertEqual(os.listdir(outside), [])
            events.unlink()
            events.mkdir(mode=0o755)
            events.chmod(0o755)
            hook.completed(root, ["a.txt"])
            self.assertEqual(os.listdir(events), [])

    def test_traversal_and_queue_limit(self):
        with tempfile.TemporaryDirectory() as root:
            events = Path(root) / ".ecai-events"
            events.mkdir(mode=0o700)
            hook.completed(root, ["../secret"])
            self.assertEqual(os.listdir(events), [])
            for i in range(1024): (events / str(i)).touch()
            hook.completed(root, ["valid.txt"])
            self.assertEqual(len(os.listdir(events)), 1024)

if __name__ == "__main__": unittest.main()
