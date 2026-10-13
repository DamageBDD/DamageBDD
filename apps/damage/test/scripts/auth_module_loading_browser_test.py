#!/usr/bin/env python3
"""Module-failure DOM regression. Production UI/loader; simulated wallet, API,
origin, Storage and reload. NOT an HTTP, cookie, OTP or Selenium/Appium test.

Requires the same Playwright/Chromium setup as auth_browser_test.py.
"""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
from auth_dom_fixture import offline_html


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--out', default='/tmp/damage-auth-module-loading.json')
    args = parser.parse_args()
    checks, errors = [], []
    variants = {
        'legacy exports': 'export function connectWalletSmart(){window.__legacyWalletCalled=true;}',
        'evaluation error': 'throw new Error("sensitive provider error");',
        'syntax error': 'export const = ;',
    }
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=args.chromium, headless=True, args=['--no-sandbox'])
        try:
            for name, wallet in variants.items():
                context = browser.new_context(viewport={'width': 1280, 'height': 900})
                page = context.new_page()
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.set_content(offline_html(wallet_source=wallet))
                expect(page.locator('#login-modal')).to_have_attribute('data-auth-bound', 'true')
                expect(page.locator('#login-username')).to_be_visible()
                assert page.evaluate('!window.TokenManager.isAuthenticated()')
                checks.append(name + ': session 401 opens login without wallet loading')
                page.click('#auth-wallet-tab')
                page.click('#connect-button')
                expected = 'outdated wallet module' if name == 'legacy exports' else 'could not be loaded'
                expect(page.locator('#connect-status')).to_contain_text(expected)
                expect(page.locator('#connect-button')).to_be_enabled()
                expect(page.locator('#wallet-sign-in')).to_be_disabled()
                checks.append(name + ': recoverable error and restored controls')
                counts = page.evaluate('window.__authFixture.counts')
                assert all(counts[key] == 0 for key in ('connect', 'sign', 'verify', 'challenge', 'tx'))
                assert page.evaluate('!window.__legacyWalletCalled')
                checks.append(name + ': no legacy fallback or verification request')
                if name == 'legacy exports':
                    page.click('#auth-signup-tab')
                    page.fill('#signup-username', 'new@fixture.example')
                    page.press('#signup-username', 'Enter')
                    expect(page.locator('#signup-confirmation')).to_be_visible()
                    assert page.evaluate('window.__authFixture.counts.signup') == 1
                    checks.append('signup still works after wallet module failure')
                    page.click('#auth-login-tab')
                    page.click('#loginResetPasswdBtn')
                    page.fill('#recovery-email', 'recover@fixture.example')
                    page.press('#recovery-email', 'Enter')
                    expect(page.locator('#connect-status')).to_contain_text('Reset link requested')
                    assert page.evaluate('window.__authFixture.counts.recovery') == 1
                    checks.append('password recovery still works after wallet module failure')
                page.click('#auth-login-tab')
                page.fill('#login-username', 'existing@fixture.example')
                page.fill('#password', 'Fixture-Only-Password1!')
                page.press('#password', 'Enter')
                expect(page.locator('#auth-fixture-dashboard')).to_be_visible()
                assert page.evaluate('window.TokenManager.isAuthenticated()')
                checks.append(name + ': email sign-in still works after failure')
                context.close()
        finally:
            browser.close()
    if errors:
        raise AssertionError('Unexpected uncaught page errors: ' + repr(errors))
    report = {'passed': len(checks), 'checks': checks, 'page_errors': errors,
              'scope': 'Chromium DOM; production JS and simulated APIs, wallet, origin, Storage and reload'}
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
