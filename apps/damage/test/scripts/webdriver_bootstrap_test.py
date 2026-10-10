#!/usr/bin/env python3
"""Offline tests for the provisioner. No npm, SDK, browser or device downloads."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HELPER = Path(__file__).resolve().parents[2] / 'priv/webdriver/bootstrap.py'
spec = importlib.util.spec_from_file_location('damage_webdriver_bootstrap', HELPER)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='damage-webdriver-')
        self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def request(self, **kw):
        return dict(schema=1, backend='chromedriver', root=str(self.root / 'cache'),
                    source='download', version='stable', bootstrap=True, offline=False, **kw)
    def assert_code(self, code, fn, *args, **kwargs):
        with self.assertRaises(b.ProvisionError) as ctx:
            fn(*args, **kwargs)
        self.assertEqual(code, ctx.exception.code)
    def zip(self, entries):
        path = self.root / 'test.zip'
        with zipfile.ZipFile(path, 'w') as z:
            for name, value in entries:
                z.writestr(name, value)
        return path
    def tar(self, entries):
        path = self.root / 'test.tar'
        with tarfile.open(path, 'w') as t:
            for info, value in entries:
                t.addfile(info, io.BytesIO(value) if value is not None else None)
        return path
    def program(self, name, version):
        p = self.root / name
        p.write_text('#!' + sys.executable + '\nprint(' + repr(version) + ')\n')
        p.chmod(0o755)
        return p

    def test_environment_does_not_inherit_secrets_or_hooks(self):
        with patch.dict(os.environ, {'DAMAGE_SECRET_KEY': 'private', 'NODE_OPTIONS': '--inspect',
                                     'PYTHONPATH': '/evil', 'NPM_TOKEN': 'private'}):
            env = b.clean_env(self.root)
        for k in ('DAMAGE_SECRET_KEY','NODE_OPTIONS','PYTHONPATH','NPM_TOKEN','SSH_AUTH_SOCK'):
            self.assertNotIn(k, env)
        self.assertEqual('1', env['APPIUM_SKIP_CHROMEDRIVER_INSTALL'])

    def test_argv_is_not_a_shell_command(self):
        sentinel = self.root / 'injected'
        arg = f'hello; touch {sentinel}; $(echo bad)'
        out = b.run([sys.executable, '-I', '-c', 'import sys; print(sys.argv[1])', arg],
                    b.clean_env(self.root), self.root)
        self.assertEqual(arg, out)
        self.assertFalse(sentinel.exists())

    def test_json_stdout_is_separate_from_diagnostics(self):
        with patch('sys.stderr', new=io.StringIO()):
            result = b.run_json([sys.executable, '-I', '-c',
                "import sys; print('warning',file=sys.stderr); print('{\"ok\":true}')"],
                b.clean_env(self.root), self.root)
        self.assertEqual({'ok':True}, result)

    def test_command_failure_has_a_sanitized_code(self):
        with patch('sys.stderr', new=io.StringIO()):
            self.assert_code('dependency_command_failed', b.run,
                [sys.executable, '-I', '-c', 'raise SystemExit(7)'], b.clean_env(self.root), self.root)

    def test_command_timeout_is_bounded(self):
        self.assert_code('dependency_command_timeout', b.run,
            [sys.executable, '-I', '-c', 'import time; time.sleep(30)'],
            b.clean_env(self.root), self.root, timeout=0.05)

    def test_embedded_nul_is_rejected(self):
        self.assert_code('invalid_configuration', b.run, ['a\x00b'], {}, self.root)

    def test_private_cache_rejects_symlink_ancestor(self):
        (self.root/'link').symlink_to(self.root, target_is_directory=True)
        self.assert_code('unsafe_path', b.private_dir, self.root/'link'/'new')

    def test_private_cache_rejects_writable_directory(self):
        p = self.root/'open'; p.mkdir(); p.chmod(0o777)
        self.assert_code('unsafe_path', b.private_dir, p)

    def test_atomic_json_is_private(self):
        p = self.root/'result.json'; b.atomic_json(p, {'ok': True})
        self.assertEqual({'ok': True}, b.load_json(p))
        self.assertEqual(0o600, stat.S_IMODE(p.stat().st_mode))

    def test_file_lock_serializes_installation(self):
        with b.lock(self.root):
            with self.assertRaises(b.ProvisionError) as ctx:
                with b.lock(self.root):
                    self.fail('lock accepted twice')
            self.assertEqual('install_locked', ctx.exception.code)
        with b.lock(self.root):
            pass

    def test_config_identity_ignores_network_policy_only(self):
        a = self.request()
        self.assertEqual(b.config_id(a), b.config_id(a | {'bootstrap':False, 'offline':True}))
        self.assertNotEqual(b.config_id(a), b.config_id(a | {'version':'140.0.1.2'}))

    def test_version_selector_is_persisted(self):
        i = b.Installer(self.request())
        self.assertEqual('140.0.1.2', i.select('chrome_version', lambda: '140.0.1.2'))
        other = b.Installer(self.request())
        def fail(): self.fail('floating version was resolved again')
        self.assertEqual('140.0.1.2', other.select('chrome_version', fail))

    def test_version_selector_rejects_shell_text(self):
        i = b.Installer(self.request())
        self.assert_code('invalid_configuration', i.select, 'chrome_version', lambda: '1.0.0;bad')

    def test_offline_cannot_install_missing_runtime(self):
        i = b.Installer(self.request() | {'offline': True})
        self.assert_code('runtime_not_installed', i.install)

    def test_https_and_host_allowlist(self):
        for url in ('http://nodejs.org/a', 'https://evil.invalid/a', 'https://user:pass@nodejs.org/a',
                    'https://nodejs.org/a#token'):
            self.assert_code('download_failed', b.validate_url, url, b.OFFICIAL)
        b.validate_url('https://nodejs.org/dist/index.json', b.OFFICIAL)

    def test_redirect_cannot_escape_allowlist(self):
        self.assert_code('download_failed', b.SafeRedirect(b.OFFICIAL).redirect_request,
            None, None, 302, 'Found', {}, 'https://evil.invalid/file')

    def test_download_hash_and_reuse(self):
        i = b.Installer(self.request()); payload = b'known release bytes'
        sha = hashlib.sha256(payload).hexdigest()
        with patch.object(b.urllib.request, 'build_opener') as build:
            build.return_value.open.side_effect = lambda *a, **k: io.BytesIO(payload)
            path = i.download('node', 'https://nodejs.org/file.tar.gz', sha)
            self.assertEqual(payload, path.read_bytes())
            i.download('node', 'https://nodejs.org/file.tar.gz', sha)
            self.assertEqual(1, build.return_value.open.call_count)
        self.assertEqual(sha, i.selection['artifacts']['node']['sha256'])

    def test_wrong_checksum_is_not_published(self):
        i = b.Installer(self.request())
        with patch.object(b.urllib.request, 'build_opener') as build:
            build.return_value.open.return_value = io.BytesIO(b'wrong')
            self.assert_code('hash_mismatch', i.download, 'node', 'https://nodejs.org/a', '0'*64)
        self.assertFalse(list(i.root.glob('download-*')))

    def test_offline_blocks_network_methods(self):
        i = b.Installer(self.request() | {'offline': True})
        self.assert_code('network_disabled', i.read_url, 'https://nodejs.org/a')
        self.assert_code('network_disabled', i.download, 'node', 'https://nodejs.org/a')

    def test_archive_normal_file_and_permissions(self):
        info = zipfile.ZipInfo('bin/program'); info.external_attr = (stat.S_IFREG | 0o4755) << 16
        archive = self.zip([(info, b'payload')]); target = self.root/'out'
        b.extract(archive, target, 'zip')
        self.assertEqual(b'payload', (target/'bin/program').read_bytes())
        self.assertEqual(0o755, stat.S_IMODE((target/'bin/program').stat().st_mode))

    def test_archive_path_traversal(self):
        self.assert_code('archive_invalid', b.extract, self.zip([('../escape', b'x')]), self.root/'out', 'zip')
        self.assertFalse((self.root/'escape').exists())

    def test_archive_absolute_path(self):
        self.assert_code('archive_invalid', b.extract, self.zip([('/absolute', b'x')]), self.root/'out', 'zip')

    def test_archive_duplicate_path(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            a = self.zip([('same',b'a'),('same',b'b')])
        self.assert_code('archive_invalid', b.extract, a, self.root/'out', 'zip')

    def test_archive_fifo(self):
        info = tarfile.TarInfo('fifo'); info.type = tarfile.FIFOTYPE
        self.assert_code('archive_invalid', b.extract, self.tar([(info,None)]), self.root/'out', 'tar')

    def test_archive_hard_link(self):
        info = tarfile.TarInfo('hard'); info.type = tarfile.LNKTYPE; info.linkname = 'file'
        self.assert_code('archive_invalid', b.extract, self.tar([(info,None)]), self.root/'out', 'tar')

    def test_archive_internal_symlink(self):
        info = tarfile.TarInfo('lib/file'); info.size = 4
        link = tarfile.TarInfo('bin/run'); link.type = tarfile.SYMTYPE; link.linkname = '../lib/file'
        dest = self.root/'out'; b.extract(self.tar([(info,b'data'),(link,None)]), dest, 'tar')
        self.assertEqual(b'data', (dest/'bin/run').read_bytes())

    def test_archive_escaping_symlink(self):
        link = tarfile.TarInfo('outside'); link.type = tarfile.SYMTYPE; link.linkname = '../outside'
        self.assert_code('archive_invalid', b.extract, self.tar([(link,None)]), self.root/'out', 'tar')

    def test_archive_symlink_is_never_used_as_write_path(self):
        link = zipfile.ZipInfo('redirect'); link.external_attr = (stat.S_IFLNK | 0o777) << 16
        a = self.zip([(link, '../escape'), ('redirect/payload', b'data')])
        self.assert_code('archive_invalid', b.extract, a, self.root/'out', 'zip')
        self.assertFalse((self.root/'escape').exists())

    def test_archive_size_limit(self):
        with patch.object(b, 'MAX_EXTRACTED', 3):
            self.assert_code('archive_invalid', b.extract,
                self.zip([('large',b'four')]), self.root/'out', 'zip')

    def test_archive_member_limit(self):
        with patch.object(b, 'MAX_MEMBERS', 1):
            self.assert_code('archive_invalid', b.extract,
                self.zip([('one',b'a'),('two',b'b')]), self.root/'out', 'zip')

    def test_cft_supported_and_unsupported_platforms(self):
        self.assertEqual('linux64', b.cft_platform('Linux','x86_64'))
        self.assertEqual('mac-arm64', b.cft_platform('Darwin','arm64'))
        self.assert_code('platform_unsupported', b.cft_platform, 'Linux','aarch64')

    def test_system_browser_and_driver_builds_must_match(self):
        driver = self.program('driver', 'ChromeDriver 140.0.10.1')
        chrome = self.program('chrome', 'Chrome for Testing 140.0.10.2')
        i = b.Installer(self.request() | {'source':'system','executable':str(driver),'browser':str(chrome)})
        manifest = i.install()
        self.assertEqual(str(chrome), manifest['chrome'])
        self.assertEqual(2, len(manifest['inventory']))

    def test_mismatch_does_not_publish_runtime_manifest(self):
        driver = self.program('driver','ChromeDriver 140.0.10.1')
        chrome = self.program('chrome','Chrome for Testing 141.0.10.1')
        i = b.Installer(self.request() | {'source':'system','executable':str(driver),'browser':str(chrome)})
        self.assert_code('version_mismatch', i.install)
        self.assertFalse((i.root/'runtime.json').exists())

    def test_fixture_and_cached_offline_restart(self):
        script = self.program('fixture', 'fixture test')
        req = self.request() | {'backend':'fixture','script':str(script)}
        first = b.Installer(req).install()
        i = b.Installer(req | {'bootstrap':False, 'offline':True})
        with patch.object(i, 'read_url', side_effect=AssertionError('network')):
            self.assertEqual(first, i.install())

    def test_cached_executable_tampering_is_rejected(self):
        script = self.program('fixture', 'initial')
        req = self.request() | {'backend':'fixture','script':str(script)}
        b.Installer(req).install(); script.write_text('changed')
        self.assert_code('cache_integrity_failed', b.Installer(req).install)

    def test_retargeted_executable_symlink_is_detected(self):
        first = self.program('v1', 'one'); second = self.program('v2', 'two')
        link = self.root/'entry'; link.symlink_to(first)
        req = self.request() | {'backend':'fixture','script':str(link)}
        b.Installer(req).install()
        link.unlink(); link.symlink_to(second)
        self.assert_code('cache_integrity_failed', b.Installer(req).install)

    def test_cached_offline_appium_disables_download_feature(self):
        req = self.request() | {'backend':'appium', 'chromedriver_autodownload':True}
        i = b.Installer(req)
        binary = self.program('fake-node','node test')
        b.atomic_json(i.root/'runtime.json', {'config_id':i.key, 'backend':'appium',
            'inventory':{str(binary):b.digest(binary)}, 'chromedriver_autodownload':True})
        offline = b.Installer(req | {'offline':True})
        self.assertIs(False, offline.install()['chromedriver_autodownload'])

    def test_sdk_license_acceptance_is_explicit(self):
        i = b.Installer(self.request() | {'android':{'enabled':True,'source':'download',
            'sha256':'0'*64, 'accept_licenses':False}})
        self.assert_code('android_licenses_not_accepted', i.android)

    def test_system_sdk_is_not_mutated(self):
        i = b.Installer(self.request() | {'android':{'enabled':True,'source':'system',
            'home':str(self.root), 'packages':['platform-tools']}})
        self.assert_code('invalid_configuration', i.android)

    def test_jdk_download_requires_explicit_hash(self):
        i = b.Installer(self.request() | {'java':{'source':'archive','url':'https://example.com/jdk.tar.gz'}})
        self.assert_code('invalid_configuration', i.java)

    def test_unknown_schema_is_rejected(self):
        self.assert_code('invalid_configuration', b.Installer, self.request() | {'schema':2})

    def test_root_cli_is_rejected_before_loading_request(self):
        with patch.object(sys, 'argv', ['bootstrap.py','--request','/nonexistent']), \
             patch.object(os, 'geteuid', return_value=0), patch('sys.stderr', new=io.StringIO()) as stderr:
            self.assertEqual(1, b.main())
            self.assertIn('root_not_allowed', stderr.getvalue())

if __name__ == '__main__':
    unittest.main(verbosity=2)
