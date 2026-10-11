"""Contract tests for installing the node-admin settings section without clobbering accounts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'integrate_damage_node_settings.py'
spec = importlib.util.spec_from_file_location('integrate_node_settings', SCRIPT)
integration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integration)

DAMAGE_APP = '''-module(damage_app).
start(_Type, _Args) ->
    ok = init_something(),
    damage_sup:start_link().
get_trails() ->
    Handlers = [damage_http, damage_dashboard, damage_accounts],
    trails:trails(Handlers).
'''
DAMAGE_SUP = '''-module(damage_sup).
init([]) ->
    Core = [
        #{id => secrets, start => {secrets, start_link, []}}
    ],
    {ok, {{one_for_one, 10, 10}, Core}}.
'''
PAGE_SHELL = '''<!doctype html><body>
<nav><a href="/dashboard/settings">Account settings</a></nav>
<main>Unrelated dashboard</main>
</body></html>
'''


class IntegrationTests(unittest.TestCase):
    def test_application_bootstrap_and_trails_are_idempotent(self):
        first = integration.rewrite_app(DAMAGE_APP)
        self.assertIn('ok = damage_settings:bootstrap(),', first)
        self.assertIn('damage_settings_http,', first)
        self.assertLess(first.index('damage_settings_http,'), first.index('damage_dashboard,'))
        self.assertEqual(first, integration.rewrite_app(first))

    def test_supervisor_starts_settings_first_and_is_idempotent(self):
        first = integration.rewrite_sup(DAMAGE_SUP)
        self.assertLess(first.index('id => damage_settings'), first.index('id => secrets'))
        self.assertEqual(first, integration.rewrite_sup(first))

    def test_nav_keeps_account_settings_untouched(self):
        changed = integration.rewrite_shell(PAGE_SHELL)
        self.assertIn('href="/dashboard/settings">Account settings', changed)
        self.assertIn('/static/js/damage-node-settings-nav.js', changed)
        self.assertEqual(changed, integration.rewrite_shell(changed))

    def test_refuse_unsupported_host_without_partial_edits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, contents in (
                (integration.APP_FILE, DAMAGE_APP),
                (integration.SUP_FILE, DAMAGE_SUP),
                (integration.SHELL_FILE, '<div>Template without closing body</div>'),
            ):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            with self.assertRaises(integration.IntegrationError):
                integration.integrate(root, apply=True)
            self.assertEqual((root / integration.APP_FILE).read_text(), DAMAGE_APP)
            self.assertEqual((root / integration.SUP_FILE).read_text(), DAMAGE_SUP)

    def test_write_three_hosts_then_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, contents in (
                (integration.APP_FILE, DAMAGE_APP),
                (integration.SUP_FILE, DAMAGE_SUP),
                (integration.SHELL_FILE, PAGE_SHELL),
            ):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            self.assertEqual(integration.integrate(root, apply=True), 0)
            self.assertEqual(integration.integrate(root, apply=True), 0)
            self.assertIn('damage_settings_http,', (root / integration.APP_FILE).read_text())
            self.assertIn('damage_settings:bootstrap()', (root / integration.APP_FILE).read_text())
            self.assertIn('damage-node-settings-nav.js', (root / integration.SHELL_FILE).read_text())


if __name__ == '__main__':
    unittest.main()
