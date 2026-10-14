"""Broker policy/lifecycle tests without root, systemd, KVM or guest execution."""
import base64
import builtins
from contextlib import ExitStack
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, Mock, MagicMock

RUNNER = Path(__file__).resolve().parents[2] / 'priv/firecracker/damage-firecracker-runner'
loader = importlib.machinery.SourceFileLoader('runner', str(RUNNER))
spec = importlib.util.spec_from_loader(loader.name, loader)
r = importlib.util.module_from_spec(spec)
loader.exec_module(r)


def policy():
    return {'max_jobs': 2, 'uid_base': 41000, 'gid_base': 41000,
            'jailer': '/usr/local/libexec/firecracker/jailer',
            'firecracker': '/usr/local/libexec/firecracker/firecracker',
            'profiles': {'shell': {'kernel': '/kernel', 'rootfs': '/rootfs',
                'kernel_sha256': 'a' * 64, 'rootfs_sha256': 'b' * 64}}}


def request(script=b'echo hello\n'):
    return {'version': 1, 'profile': 'shell', 'timeout_ms': 1000,
            'script_b64': base64.b64encode(script).decode()}


class PolicyTests(unittest.TestCase):
    def validate(self, req):
        with patch.object(r, 'trusted_path', side_effect=Path):
            return r.validate_request(req, policy())

    def test_script_bytes_preserved_not_interpolated(self):
        script = b"printf '%s' '$(touch /host-marker); `id`'\n"
        self.assertEqual(self.validate(request(script))[2], script)

    def test_unknown_profile_and_paths_rejected(self):
        for name in ['../shell', '/etc/passwd', 'shell;id', 'other', '', 'x' * 65]:
            req = request(); req['profile'] = name
            with self.subTest(name=name), self.assertRaises(r.Failure): self.validate(req)
        req = request(); req['rootfs'] = '/etc/shadow'
        with self.assertRaises(r.Failure): self.validate(req)

    def test_script_limits_and_nul(self):
        for data in [b'', b'a' * 65537, b'a\0b']:
            with self.subTest(size=len(data)), self.assertRaises(r.Failure): self.validate(request(data))
        self.assertEqual(len(self.validate(request(b'a' * 65536))[2]), 65536)

    def test_base64_and_timeout_rejected(self):
        for value in [True, -1, 0, 999, 60001, '1000', None]:
            req = request(); req['timeout_ms'] = value
            with self.subTest(value=value), self.assertRaises(r.Failure): self.validate(req)
        req = request(); req['script_b64'] = '!bad!'
        with self.assertRaises(r.Failure): self.validate(req)

    def test_no_network_or_writable_disks_or_api(self):
        _, profile, _, _ = self.validate(request())
        config = r.vm_configuration(profile)
        self.assertNotIn('network-interfaces', config)
        self.assertTrue(config['drives'][0]['is_read_only'])
        cmd = r.launch_command(policy(), profile, Mock(index=1), 'dmg-test', 'test.service', 1.2)
        self.assertIn('--no-api', cmd)
        self.assertIn('--property=RuntimeMaxSec=2', cmd)
        self.assertIn('--property=PrivateNetwork=yes', cmd)
        self.assertIn('--property=KillMode=control-group', cmd)
        self.assertIn('41001', cmd)
        self.assertNotIn('--no-seccomp', cmd)
        self.assertNotIn('--daemonize', cmd)

    def test_trusted_path_rejects_symlink_and_writable_parent(self):
        # /tmp itself must be rejected even for a root-owned descendant.
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'image'; f.write_bytes(b'x')
            with self.assertRaises(r.Failure): r.trusted_path(f)
            link = Path(d) / 'link'; link.symlink_to(f)
            with self.assertRaises(r.Failure): r.trusted_path(link)

    def test_copy_checks_digest_and_size(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / 'image'; src.write_bytes(b'known bytes')
            dst = Path(d) / 'copy'
            digest = hashlib.sha256(src.read_bytes()).hexdigest()
            r.copy_verified(src, dst, digest, 100, Mock())
            self.assertEqual(dst.read_bytes(), src.read_bytes())
            self.assertEqual(dst.stat().st_mode & 0o777, 0o444)
            with self.assertRaisesRegex(r.Failure, 'digest'):
                r.copy_verified(src, Path(d) / 'bad', '0' * 64, 100, Mock())
            with self.assertRaisesRegex(r.Failure, 'too_large'):
                r.copy_verified(src, Path(d) / 'big', digest, 1, Mock())

    def test_slot_limits_and_quarantine(self):
        with tempfile.TemporaryDirectory() as d, patch.object(r, 'STATE', Path(d)):
            a = r.Slot(1); a.record('dmg-test', 'test.service')
            with self.assertRaisesRegex(r.Failure, 'busy'): r.Slot(1)
            a.release(False)
            with self.assertRaisesRegex(r.Failure, 'quarantined'): r.Slot(1)
            (Path(d) / 'slot-0').write_bytes(b'')
            a = r.Slot(1); a.record('dmg-test', 'test.service'); a.release(True)
            b = r.Slot(1); b.release(True)

    def test_unit_state_is_fail_closed(self):
        for output, code, expected in [
            (b'LoadState=not-found\nActiveState=inactive\n', 1, True),
            (b'LoadState=loaded\nActiveState=inactive\n', 0, True),
            (b'LoadState=loaded\nActiveState=active\n', 0, False),
            (b'', 1, False), (b'garbage', 0, False)]:
            with patch.object(r.subprocess, 'run', return_value=Mock(stdout=output, returncode=code)):
                self.assertEqual(r.unit_inactive('test.service'), expected)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.input_r, self.input_w = os.pipe()
        self.guard = r.Guard(2, self.input_r)
        self.host, self.guest = socket.socketpair()
        self.host.setblocking(False)

    def tearDown(self):
        self.host.close(); self.guest.close()
        os.close(self.input_r)
        if self.input_w is not None: os.close(self.input_w)

    def test_fragmented_reply_and_binary_output(self):
        def peer():
            data = bytearray()
            while len(data) < 16: data.extend(self.guest.recv(16 - len(data)))
            self.assertEqual(bytes(data), struct.pack('!4sII', b'DFC1', 4, 100) + b'test')
            reply = struct.pack('!4sIII', b'DFR1', 7, 0, 3) + b'\xff\x00x'
            for byte in reply: self.guest.sendall(bytes([byte]))
        t = threading.Thread(target=peer); t.start()
        self.assertEqual(r.exchange(self.host, b'test', 100, self.guard), (7, False, b'\xff\x00x'))
        t.join()

    def test_oversized_response_refused_before_body(self):
        self.guest.sendall(struct.pack('!4sIII', b'DFR1', 0, 0, 101))
        with self.assertRaisesRegex(r.Failure, 'invalid_guest_response'):
            r.exchange(self.host, b'x', 100, self.guard)

    def test_invalid_magic_exit_and_flag(self):
        for magic, code, flag in [(b'EVIL', 0, 0), (b'DFR1', 256, 0), (b'DFR1', 0, 2)]:
            self.guest.sendall(struct.pack('!4sIII', magic, code, flag, 0))
            with self.assertRaises(r.Failure): r.exchange(self.host, b'x', 100, self.guard)

    def test_caller_eof_cancels(self):
        os.close(self.input_w); self.input_w = None
        with self.assertRaisesRegex(r.Failure, 'cancelled'): self.guard.check()

    def test_extra_input_cancels(self):
        os.write(self.input_w, b'extra')
        with self.assertRaisesRegex(r.Failure, 'unexpected_input'): self.guard.check()

    def test_timeout(self):
        self.guard.deadline = time.monotonic() - 1
        with self.assertRaisesRegex(r.Failure, 'timeout'): self.guard.check()

    def test_request_reader_bounds_and_preserves_connection(self):
        os.write(self.input_w, json.dumps(request()).encode() + b'\n')
        self.assertEqual(r.read_request(self.input_r), request())
        self.guard.check()

    def test_guest_disconnect(self):
        self.guest.close()
        with self.assertRaisesRegex(r.Failure, 'guest_disconnected'):
            r.receive_exact(self.host, 16, self.guard)


class LifecycleTests(unittest.TestCase):
    def exercise(self, guest_error=False, stop_ok=True):
        with tempfile.TemporaryDirectory() as d, ExitStack() as stack:
            base = Path(d)
            cfg = policy()
            for key in ('kernel', 'rootfs'):
                image = base / key; image.write_bytes(key.encode())
                cfg['profiles']['shell'][key] = str(image)
                cfg['profiles']['shell'][key + '_sha256'] = hashlib.sha256(image.read_bytes()).hexdigest()
            stack.enter_context(patch.object(r, 'STATE', base / 'state'))
            stack.enter_context(patch.object(r, 'JAILS', base / 'jails'))
            stack.enter_context(patch.object(r, 'trusted_path', side_effect=Path))
            stack.enter_context(patch.object(r, 'private_directory',
                side_effect=lambda p: p.mkdir(mode=0o700, parents=True, exist_ok=True)))
            real_open = builtins.open
            stack.enter_context(patch.object(r, 'open',
                side_effect=lambda p, *a, **kw: io.BytesIO() if p == '/dev/kvm' else real_open(p, *a, **kw), create=True))
            guard = stack.enter_context(patch.object(r, 'Guard'))
            guard.return_value.deadline = time.monotonic() + 1
            process = stack.enter_context(patch.object(r.subprocess, 'Popen')).return_value
            connect = stack.enter_context(patch.object(r, 'connect_guest', return_value=MagicMock()))
            exchange = stack.enter_context(patch.object(r, 'exchange', return_value=(0, False, b'ok')))
            if guest_error: exchange.side_effect = r.Failure('guest_disconnected')
            stop = stack.enter_context(patch.object(r, 'stop_unit', return_value=stop_ok))
            if not stop_ok:
                with self.assertRaisesRegex(r.Failure, 'quarantined'): r.execute(request(), cfg)
            elif guest_error:
                with self.assertRaisesRegex(r.Failure, 'guest_disconnected'): r.execute(request(), cfg)
            else:
                result = r.execute(request(), cfg)
                self.assertEqual(base64.b64decode(result['output_b64']), b'ok')
                self.assertEqual(result['profile'], 'shell')
            stop.assert_called_once()
            self.assertEqual(stop.call_args.args[1], process)
            record = (base / 'state/slot-0').read_bytes()
            self.assertEqual(bool(record), not stop_ok)
            jails = list((base / 'jails/firecracker').iterdir())
            self.assertEqual(len(jails), 0 if stop_ok else 1)

    def test_success_stops_and_removes_vm(self): self.exercise()
    def test_protocol_failure_still_stops_vm(self): self.exercise(guest_error=True)
    def test_failed_stop_preserves_jail_and_quarantines_uid(self): self.exercise(stop_ok=False)


if __name__ == '__main__': unittest.main()
