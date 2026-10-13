"""Test package node config initialization without systemd/root modifications."""
import os
import pathlib
import pwd
import grp
import stat
import subprocess
import tempfile
import unittest

PKG = pathlib.Path(__file__).resolve().parents[2] / 'priv' / 'pkg'
POST10 = PKG / 'postinst.d' / '10-setup-users.sh'
POST20 = PKG / 'postinst.d' / '20-systemd.sh'


class NodeConfigPackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='damage-pkg-xdg-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.sysconfig = self.root / 'etc' / 'damage' / 'damage.config'
        self.state = self.root / 'var' / 'lib' / 'damage'
        self.xdg = self.state / '.config'
        self.managed = self.xdg / 'damage' / 'damage.config'
        self.unit = self.root / 'damage.service'
        self.unit.write_text('[Unit]\nDescription=Test\n')
        user = pwd.getpwuid(os.getuid())
        group = grp.getgrgid(os.getgid())
        self.env = os.environ.copy()
        self.env.update({
            'APP': 'damage',
            'PKG_USER': user.pw_name,
            'PKG_GROUP': group.gr_name,
            'VAR_DIR': str(self.state),
            'ETC_DIR': str(self.sysconfig.parent),
            'CONFIG_FILE': str(self.sysconfig),
            'SERVICE_FILE': str(self.unit),
            'LOG_DIR': str(self.root / 'logs'),
            'INSTALL_LOG': str(self.root / 'logs' / 'install.log'),
            'AUTO_START': 'false',
            'XDG_CONFIG_HOME': str(self.xdg),
            'CREATE_USER': 'false',
            'BIN': str(self.root / 'no-executable'),
            'LINK': str(self.root / 'not-created'),
        })
        self.env.pop('DAMAGE_CONFIG_FILE', None)

    def invoke(self, script, *, check=True, env=None):
        return subprocess.run(['sh', str(script)], env=env or self.env,
                              cwd=self.root, capture_output=True, text=True,
                              check=check)

    def test_first_install_creates_xdg_and_operator_configs(self):
        self.invoke(POST10)
        self.invoke(POST20)
        self.assertTrue(self.sysconfig.is_file())
        self.assertTrue(self.managed.is_file())
        contents = self.managed.read_text()
        for app in ['damage', 'ecai', 'nosternity', 'erm', 'bop']:
            self.assertIn('{' + app + ', []}', contents)
        self.assertEqual(0o600, stat.S_IMODE(self.managed.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.managed.parent.stat().st_mode))
        self.assertIn('node_admins', self.sysconfig.read_text())

    def test_upgrade_preserves_both_configs(self):
        self.invoke(POST20)
        self.managed.write_text('[{damage,[{ae_fee_multiplier,7}]}].\n')
        self.sysconfig.write_text('[{damage,[{port,4490}]}].\n')
        self.invoke(POST20)
        self.assertIn('ae_fee_multiplier,7', self.managed.read_text())
        self.assertIn('port,4490', self.sysconfig.read_text())

    def test_legacy_overlay_is_imported_when_new_file_is_absent(self):
        self.sysconfig.parent.mkdir(parents=True)
        legacy = self.sysconfig.with_name('damage.dashboard.config')
        legacy.write_text('[{damage,[{ae_fee_multiplier,4}]}].\n')
        self.invoke(POST20)
        self.assertEqual(legacy.read_bytes(), self.managed.read_bytes())
        self.assertTrue(legacy.exists())
        self.assertEqual(0o600, stat.S_IMODE(self.managed.stat().st_mode))

    def test_refuses_symlink_config_without_modifying_target(self):
        self.managed.parent.mkdir(parents=True)
        victim = self.root / 'victim'
        victim.write_text('unchanged')
        self.managed.symlink_to(victim)
        result = self.invoke(POST20, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual('unchanged', victim.read_text())

    def test_ignores_package_manager_xdg_and_config_overrides(self):
        env = self.env.copy()
        env['DAMAGE_CONFIG_FILE'] = str(self.sysconfig)
        env['XDG_CONFIG_HOME'] = str(self.root / 'root-config')
        self.invoke(POST20, env=env)
        self.assertTrue(self.managed.is_file())
        self.assertFalse((self.root / 'root-config').exists())
        self.assertIn('node_admins', self.sysconfig.read_text())

    def test_ignores_relative_inherited_xdg_home(self):
        env = self.env.copy()
        env['XDG_CONFIG_HOME'] = 'relative-xdg'
        self.invoke(POST20, env=env)
        self.assertTrue(self.managed.is_file())
        self.assertFalse((self.root / 'relative-xdg').exists())


if __name__ == '__main__':
    unittest.main()
