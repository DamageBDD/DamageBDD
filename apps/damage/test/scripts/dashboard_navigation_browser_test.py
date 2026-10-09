#!/usr/bin/env python3
"""Chromium checks using the production shell/controller and simulated integrations.
No wallet, model, target or billing service is contacted. Run from any directory.
"""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright
from bdd_composer_browser_test import APP, build_preview, render_template


def run(out: Path, chromium: str) -> None:
    out.mkdir(parents=True, exist_ok=True)
    checks, errors = [], []
    ordinary, admin = build_preview(), build_preview(node_admin=True)

    def passed(name):
        checks.append(name)
        print('PASS', name, flush=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chromium, headless=True, args=['--no-sandbox'])

        page_fixtures = {}
        blocked_contexts = set()

        def new_context(width=1440, blocked_storage=False):
            context = browser.new_context(viewport={'width': width, 'height': 950}, reduced_motion='reduce')
            if blocked_storage:
                blocked_contexts.add(context)
            context.route('**/*', lambda route: route.abort())
            return context

        def install_fixture(page, content, seed=None):
            # about:blank permits native same-document history, but not native
            # Storage. Success-path preference checks use an explicit Storage
            # fixture; the blocked-storage case exercises the browser denial.
            if page.context not in blocked_contexts:
                page.evaluate("""(seed) => {
                  const values = {...(seed || {})};
                  window.__fixtureStorage = values;
                  Object.defineProperty(window, 'localStorage', {configurable: true, value: {
                    getItem: key => values[key] ?? null,
                    setItem: (key, value) => { values[key] = String(value); },
                    removeItem: key => { delete values[key]; }
                  }});
                }""", seed)
            page.set_content(content, wait_until='load')
            page.wait_for_function('!!window.dashboardNavigation?.activePanel')

        def load(context, path='/'):
            page = context.new_page()
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.set_default_timeout(6000)
            hash_ = '#' + path.split('#', 1)[1] if '#' in path else ''
            page.goto('about:blank' + hash_)
            content = admin if path.startswith('/admin') else ordinary
            page_fixtures[page] = content
            install_fixture(page, content)
            return page

        def reload_fixture(page):
            seed = page.evaluate('window.__fixtureStorage || null')
            page.reload()
            install_fixture(page, page_fixtures[page], seed)

        def active(page, panel_id):
            page.wait_for_function('(id) => window.dashboardNavigation.activePanel === id', arg=panel_id)
            assert page.locator('[data-dashboard-view]:visible').count() == 1
            assert page.locator(f'#{panel_id}').is_visible()
            assert page.locator(f'#dashboard-navigation a[href="#{panel_id}"]').get_attribute('aria-current') == 'page'

        context = new_context()
        page = load(context)
        active(page, 'execution-tab')
        assert page.locator('.tabsbar, [data-tabs]').count() == 0
        assert page.locator('#dashboard-navigation [role="tab"]').count() == 0
        assert page.locator('[data-dashboard-panel]').count() == 8
        assert page.locator('#dashboard-sidebar').is_visible()
        assert page.locator('.dashboard-main').bounding_box()['x'] >= 216
        passed('native grouped sidebar replaces primary tabs and reserves desktop content space')

        before = 'Feature: Keep my manual work\n  Scenario: Retain it\n    Given I set the variable "x" to "1"\n'
        page.locator('#damageTextArea').fill(before)
        page.locator('#bdd-prompt').fill('Keep this prompt while switching panels.')
        page.evaluate("document.getElementById('run-reports-ul').dataset.probe = 'keep-output'")
        page.locator('#dashboard-link-activity').click()
        active(page, 'activity-tab')
        assert page.title() == 'Run history · DamageBDD'
        assert page.locator('#activity-tab').evaluate('(e) => e === document.activeElement')
        assert page.url.endswith('#activity-tab')
        assert page.evaluate('window.__mock.reportRefreshes') == 1
        page.locator('#dashboard-link-execution').click()
        assert page.locator('#damageTextArea').input_value() == before
        assert page.locator('#bdd-prompt').input_value() == 'Keep this prompt while switching panels.'
        assert page.evaluate("document.getElementById('run-reports-ul').dataset.probe") == 'keep-output'
        passed('panel changes update URL/title/focus and preserve editor, prompt and output DOM')

        page.evaluate("() => { window.TokenManager.getToken = () => 'fixture'; initDashboardNavigation(); bindDashboardPanelRefresh(window.dashboardNavigation); }")
        page.locator('#dashboard-link-schedules').click()
        active(page, 'schedules-tab')
        assert page.evaluate('window.__mock.scheduleRefreshes') == 1
        page.locator('#dashboard-link-schedules').click()
        assert page.evaluate('window.__mock.scheduleRefreshes') == 1
        passed('idempotent setup and selecting the active panel do not duplicate lazy refresh hooks')

        page.locator('#dashboard-link-activity').click()
        page.locator('#dashboard-link-analytics').click()
        page.go_back(); active(page, 'activity-tab')
        page.go_back(); active(page, 'schedules-tab')
        page.go_forward(); active(page, 'activity-tab')
        passed('Back and Forward synchronize visible panel and active navigation')

        page.locator('#dashboard-link-execution').click()
        page.locator('#dashboard-link-execution').focus()
        page.keyboard.press('ArrowDown')
        assert page.locator('#dashboard-link-activity').evaluate('(e) => e === document.activeElement')
        active(page, 'execution-tab')
        page.keyboard.press('Enter'); active(page, 'activity-tab')
        page.locator('#dashboard-link-ecai-jobs').focus(); page.keyboard.press('ArrowDown')
        assert page.locator('#dashboard-link-settings').evaluate('(e) => e === document.activeElement')
        page.keyboard.press('Home')
        assert page.locator('#dashboard-link-execution').evaluate('(e) => e === document.activeElement')
        page.keyboard.press('End')
        assert page.locator('#dashboard-link-settings').evaluate('(e) => e === document.activeElement')
        passed('keyboard navigation skips hidden billing, with Enter activation and Home/End')

        assert not page.evaluate("window.dashboardNavigation.navigate('billing-tab')")
        assert not page.evaluate("window.dashboardNavigation.navigate('node-cln-admin-tab')")
        assert not page.evaluate("window.dashboardNavigation.navigate('wallet-modal')")
        assert page.locator('#billing-tab').is_hidden()
        assert page.locator('#node-cln-admin-tab').count() == 0
        passed('hidden invoices, omitted administrator panels and unknown destinations are not selectable')

        page.locator('#dashboard-nav-toggle').click()
        assert page.locator('[data-dashboard-shell]').evaluate('(e) => e.classList.contains("sidebar-collapsed")')
        assert page.locator('#dashboard-nav-toggle').get_attribute('aria-expanded') == 'false'
        assert page.locator('.dashboard-main').bounding_box()['x'] == 76
        reload_fixture(page); active(page, 'activity-tab')
        assert page.locator('.dashboard-main').bounding_box()['x'] == 76
        page.screenshot(path=str(out / 'damagebdd-sidebar-collapsed.png'))
        page.locator('#dashboard-nav-toggle').click()
        passed('desktop collapse retains names and restores the stored preference after fixture reload')

        page2 = load(context, '/#schedules-tab')
        active(page2, 'schedules-tab')
        page2.wait_for_timeout(80)
        active(page2, 'schedules-tab')
        page2.close()
        page2 = load(context, '/#node-cln-admin-tab')
        active(page2, 'execution-tab')
        page2.close()
        passed('initial deep links are retained, while absent admin routes fall back to Workspace')

        page2 = load(context, '/#billing-tab')
        active(page2, 'execution-tab')
        assert page2.locator('#billing-nav').is_hidden()
        page2.evaluate("() => { document.getElementById('enterprise-billing').hidden = false; document.getElementById('billing-nav').hidden = false; }")
        active(page2, 'billing-tab')
        page2.locator('#billing-title').evaluate('(e) => {e.tabIndex=-1; e.focus();}')
        page2.evaluate("document.getElementById('billing-nav').hidden = true")
        active(page2, 'execution-tab')
        assert page2.url.endswith('#execution-tab')
        assert page2.locator('#execution-tab').evaluate('(e) => e === document.activeElement')
        page2.close()
        passed('deferred invoice deep link waits for reveal; revocation returns URL and focus to Workspace')

        page2 = load(context, '/admin#node-cln-admin-tab')
        active(page2, 'node-cln-admin-tab')
        assert page2.locator('[data-dashboard-panel]').count() == 11
        passed('server-rendered administrator navigation exposes all three existing node panels')

        for width in [320, 390, 768, 900, 901, 1024, 1440]:
            page2.set_viewport_size({'width': width, 'height': 950})
            for id_ in ['execution-tab', 'activity-tab', 'analytics-tab', 'schedules-tab', 'settings-tab',
                        'swap-options-tab', 'ecai-jobs-tab', 'node-transactions-tab', 'node-channels-tab', 'node-cln-admin-tab']:
                page2.evaluate('(id) => window.dashboardNavigation.navigate(id, {focus: false})', id_)
                assert page2.evaluate('document.documentElement.scrollWidth <= innerWidth'), (width, id_)
            passed(f'no document horizontal overflow across ten panels at {width}px')
        page2.close()

        page.locator('#dashboard-link-execution').click()
        page.set_viewport_size({'width': 390, 'height': 844})
        assert page.locator('#dashboard-sidebar').is_hidden()
        assert page.locator('#dashboard-sidebar').evaluate('(e) => e.inert')
        assert page.locator('#dashboard-nav-toggle').get_attribute('aria-expanded') == 'false'
        # The mobile header must remain a compact horizontal toolbar.
        assert page.locator('.dashboard-topbar').evaluate('(e) => getComputedStyle(e).flexDirection') == 'row'
        assert page.locator('.dashboard-topbar').bounding_box()['height'] < 100
        page.locator('#dashboard-nav-toggle').click()
        assert page.locator('#dashboard-sidebar').get_attribute('aria-modal') == 'true'
        assert page.locator('#dashboard-main').evaluate('(e) => e.inert')
        assert page.locator('#dashboard-link-execution').evaluate('(e) => e === document.activeElement')
        page.screenshot(path=str(out / 'damagebdd-sidebar-mobile-open.png'))
        passed('mobile drawer opens above an inert main area with active-link focus and a compact header')

        page.locator('#open-node-wallet-btn').focus(); page.keyboard.press('Tab')
        assert page.locator('[data-dashboard-home]').evaluate('(e) => e === document.activeElement')
        page.keyboard.press('Shift+Tab')
        assert page.locator('#open-node-wallet-btn').evaluate('(e) => e === document.activeElement')
        page.keyboard.press('Escape')
        assert page.locator('#dashboard-sidebar').is_hidden()
        assert page.locator('#dashboard-nav-toggle').evaluate('(e) => e === document.activeElement')
        assert not page.locator('#dashboard-main').evaluate('(e) => e.inert')
        passed('mobile Tab/Shift+Tab stay in the drawer; Escape unlocks content and restores opener focus')

        page.locator('#dashboard-nav-toggle').click()
        page.locator('#dashboard-link-schedules').click()
        active(page, 'schedules-tab')
        assert page.locator('#dashboard-sidebar').is_hidden()
        assert page.locator('#schedules-tab').evaluate('(e) => e === document.activeElement')
        page.locator('#dashboard-nav-toggle').click()
        page.locator('#dashboard-nav-backdrop').click(position={'x': 370, 'y': 50})
        assert page.locator('#dashboard-sidebar').is_hidden()
        assert page.locator('#dashboard-nav-toggle').evaluate('(e) => e === document.activeElement')
        passed('mobile panel selection and backdrop dismissal close the drawer without leaving focus hidden')

        page.locator('#dashboard-nav-toggle').click()
        page.evaluate("document.getElementById('installBtn').addEventListener('click', () => {window.__releasedBeforeModal = !document.getElementById('dashboard-main').inert && !document.getElementById('dashboard-sidebar').hasAttribute('aria-modal');})")
        page.once('dialog', lambda d: d.accept())
        page.locator('#installBtn').click()
        assert page.evaluate('window.__releasedBeforeModal')
        assert not page.locator('#dashboard-main').evaluate('(e) => e.inert')
        passed('sidebar action releases its focus trap before an existing modal button handler runs')

        page.locator('#dashboard-nav-toggle').click()
        page.set_viewport_size({'width': 1440, 'height': 950})
        assert page.locator('#dashboard-sidebar').is_visible()
        page.locator('#dashboard-nav-backdrop').wait_for(state='hidden')
        assert not page.locator('#dashboard-main').evaluate('(e) => e.inert')
        assert page.evaluate('getComputedStyle(document.body).overflow') != 'hidden'
        page.locator('#dashboard-nav-toggle').click()  # collapsed desktop
        page.set_viewport_size({'width': 390, 'height': 844})
        page.locator('#dashboard-nav-toggle').click(); page.keyboard.press('Escape')
        page.set_viewport_size({'width': 1440, 'height': 950})
        page.wait_for_function("document.querySelector('.dashboard-main').getBoundingClientRect().x === 76")
        passed('breakpoint changes release drawer locks and preserve the desktop collapse preference')

        blocked = new_context(blocked_storage=True)
        blocked_page = load(blocked)
        blocked_page.locator('#dashboard-nav-toggle').click()
        assert blocked_page.locator('.dashboard-main').bounding_box()['x'] == 76
        blocked_page.locator('#dashboard-link-activity').click()
        active(blocked_page, 'activity-tab')
        blocked.close()
        passed('blocked browser storage does not break navigation or collapse')

        # Integration wiring remains bounded to the shell and panel refresh hooks.
        main_source = (APP / 'priv/static/js/main.js').read_text()
        billing_source = (APP / 'priv/static/js/billing.js').read_text()
        assert "Tabby('[data-tabs]')" not in main_source
        assert 'damage:panelchange' in billing_source and '"tabby"' not in billing_source
        assert main_source.count('initDamageBDDPicker({') == 1
        assert 'setDashboardVisible(false)' in main_source
        shell_source = (APP / 'priv/templates/ui/dashboard/page_shell.mustache').read_text()
        noauth = render_template(shell_source, {'authenticated': False, 'node_admin': False})
        assert 'data-dashboard-shell' not in noauth
        assert 'id="content"' not in noauth
        assert '{{{tabs_bar}}}' not in shell_source
        passed('no primary Tabby reset, one picker setup, invoice event migration and unauthenticated shell omission')

        assert not errors, errors
        passed('no browser JavaScript exceptions')
        context.close()
        browser.close()

    (out / 'navigation-test-results.json').write_text(json.dumps({
        'test_type': 'Chromium with production templates/controller, native same-document history and simulated Storage/API integrations',
        'passed': len(checks), 'checks': checks
    }, indent=2))
    print(f'{len(checks)} navigation checks passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path('/tmp/damage-sidebar-tests'))
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    args = parser.parse_args()
    run(args.out, args.chromium)
