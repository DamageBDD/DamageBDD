#!/usr/bin/env python3
"""Auth colour regression tests; no authentication requests or credentials.

python3 -m unittest apps/ecai/test/test_auth_palette.py
python3 apps/ecai/test/test_auth_palette.py --browser [--fixture-only]

Browser mode normally requires the shared DamageBDD auth markup/CSS. Use the
explicit --fixture-only option in an ECAI-only checkout. That mode tests a
small, labelled style contract fixture, not the full shared auth integration.
Both modes omit auth controllers; this is not a login/wallet flow test.
"""
import argparse
import asyncio
import base64
import html
import json
import os
import re
import shutil
import tempfile
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
DAMAGE = APP.parent / 'damage'
CSS_PATH = APP / 'priv/static/css/ecai-auth.css'
TEMPLATE_PATH = APP / 'priv/templates/ui/dashboard/ecai_console.mustache'
VERSION = 'auth-colours-v1'


def rgb(value):
    if value.startswith('#'):
        return tuple(int(value[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return tuple(float(n) / 255 for n in re.findall(r'[\d.]+', value)[:3])


def contrast(a, b):
    def luminance(value):
        v = [x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4 for x in rgb(value)]
        return sum(x * weight for x, weight in zip(v, (.2126, .7152, .0722)))
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + .05) / (lo + .05)


def palettes():
    css = CSS_PATH.read_text()
    blocks = re.findall(r'#login-modal\s*\{([^}]+)\}', css)
    return [dict(re.findall(r'--ecai-auth-([\w-]+):\s*(#[0-9a-f]{6});', b)) for b in blocks[:2]]


class AuthPaletteContract(unittest.TestCase):
    def test_versioned_stylesheet_and_marker_agree(self):
        self.assertEqual(TEMPLATE_PATH.read_text().count(f'/static/css/ecai-auth.css?v={VERSION}"'), 1)
        self.assertIn(f'--ecai-auth-ui-version: {VERSION};', CSS_PATH.read_text())

    def test_complete_light_dark_foregrounds(self):
        light, dark = palettes()
        self.assertEqual(light.keys(), dark.keys())
        self.assertNotEqual(light['bg'], dark['bg'])
        pairs = [('text', 'bg'), ('text', 'field'), ('muted', 'bg'), ('muted', 'panel'),
                 ('muted', 'field'), ('accent', 'bg'), ('accent', 'selected'),
                 ('good', 'good-bg'), ('error', 'error-bg')]
        for name, palette in zip(('light', 'dark'), (light, dark)):
            for fg, bg in pairs:
                with self.subTest(theme=name, foreground=fg, background=bg):
                    self.assertGreaterEqual(contrast(palette[fg], palette[bg]), 4.5)
            self.assertGreaterEqual(contrast('#ffffff', palette['primary']), 4.5)
            self.assertGreaterEqual(contrast('#ffffff', palette['primary-hover']), 4.5)

    def test_control_boundaries_and_focus(self):
        for palette in palettes():
            for fg, bg in [('field-line', 'field'), ('field-line', 'bg'), ('focus', 'field'), ('focus', 'bg')]:
                self.assertGreaterEqual(contrast(palette[fg], palette[bg]), 3)

    def test_input_paint_autofill_and_system_colours(self):
        css = CSS_PATH.read_text()
        for text in ('-webkit-text-fill-color: currentColor', 'caret-color:',
                     'input:is(:autofill, :-webkit-autofill)', '(forced-colors: active)',
                     'box-shadow: none !important;', '[aria-invalid="true"]'):
            self.assertIn(text, css)
        self.assertNotRegex(css, r'transition\s*:[^;]*(?:999|5000|600000)')
        self.assertNotRegex(css, r'forced-color-adjust\s*:\s*none\s*[;}]')

    def test_modal_palette_does_not_use_global_text_tokens(self):
        modal = CSS_PATH.read_text().split('#login-modal {', 1)[1].split('@media(max-width:1000px)', 1)[0]
        for token in ('var(--ink)', 'var(--muted)', 'var(--blue)', 'var(--paper)'):
            self.assertNotIn(token, modal)
        self.assertIn('[data-theme="light"]', modal)
        self.assertIn('[data-theme="dark"]', modal)


def render_mustache(text):
    values = dict(logo_image='/static/img/ecai-brain.svg', auth_brand_name='ECAI',
                  auth_brand_label='INTELLIGENCE FABRIC', auth_brand_alt='ECAI brain mark',
                  auth_auto_open='false', auth_callback_path='/dashboard',
                  auth_allow_guest=True, auth_hide_node_wallet=True)
    sections = re.compile(r'{{([#^])\s*(\w+)\s*}}((?:(?!{{[#^]).)*?){{/\s*\2\s*}}', re.S)
    while sections.search(text):
        text = sections.sub(lambda m: m[3] if bool(values.get(m[2])) == (m[1] == '#') else '', text)
    text = re.sub(r'{{{\s*(\w+)\s*}}}', lambda m: str(values.get(m[1], '')), text)
    return re.sub(r'{{\s*(\w+)\s*}}', lambda m: html.escape(str(values.get(m[1], ''))), text)


# Deliberately loaded AFTER the production override, as /api/themes/css is.
# Test-only values reproduce the low-contrast fields without claiming to be
# the user's unavailable current damage_theme_manifest.erl output.
HOSTILE_THEME = '''
:root { --ink:#eff6ff; --muted:#c6d5ed; --auth-bg:#fff; --auth-text:#fff; }
input { background:#b3bdcf !important; color:white !important;
  -webkit-text-fill-color:white !important; box-shadow:0 0 0 1000px #b3bdcf inset !important; }
p, label { color:#e1ebff !important; }
button { background:#0a1020 !important; color:#eef6ff !important; }
'''


def browser_html(fixture_only):
    if fixture_only:
        markup = (APP / 'test/fixtures/auth_palette.html').read_text()
        base = '\n'.join(re.findall(r'<style>(.*?)</style>', markup, re.S))
        markup = re.sub(r'<style>.*?</style>', '', markup, flags=re.S)
    else:
        css = DAMAGE / 'priv/static/css/auth.css'
        template = DAMAGE / 'priv/templates/ui/dashboard/auth_modal.mustache'
        if not css.is_file() or not template.is_file():
            raise RuntimeError('Shared DamageBDD auth CSS/template missing. Use --fixture-only for style-contract tests only.')
        base = css.read_text()
        markup = render_mustache(template.read_text())
    # Never run real auth controllers from either kind of fixture.
    markup = re.sub(r'<script\b[^>]*>.*?</script>', '', markup, flags=re.S | re.I)
    icon = base64.b64encode((APP / 'priv/static/img/ecai-brain.svg').read_bytes()).decode()
    markup = markup.replace('/static/img/ecai-brain.svg', 'data:image/svg+xml;base64,' + icon)
    base_console = (APP / 'priv/static/css/ecai-console.css').read_text()
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>ECAI auth palette — style-only test</title><style>' + base_console + '</style>'
            '<style>' + base + '</style><style>' + CSS_PATH.read_text() + '</style>'
            '<style>' + HOSTILE_THEME + '</style></head><body>'
            '<input id="outside-auth" value="Scope sentinel" aria-label="Outside auth" style="position:fixed;left:-10000px;top:0">'
            + markup + '</body></html>')


async def styles(page, selector):
    return await page.locator(selector).first.evaluate('''el => {
      const s=getComputedStyle(el); return {bg:s.backgroundColor,fg:s.color,fill:s.webkitTextFillColor,
        caret:s.caretColor,border:s.borderTopColor,shadow:s.boxShadow,scheme:s.colorScheme,
        outline:s.outlineColor,outlineStyle:s.outlineStyle,opacity:s.opacity};
    }''')


async def check_page(page, expected):
    p = dict(zip(('light', 'dark'), palettes()))[expected]
    props = await page.locator('#login-modal').evaluate('''el => {
      const s=getComputedStyle(el);return {version:s.getPropertyValue('--ecai-auth-ui-version').trim(),scheme:s.colorScheme};
    }''')
    assert props == dict(version=VERSION, scheme=expected), props
    modal = await styles(page, '#login-modal .auth-modal')
    assert rgb(modal['bg']) == rgb(p['bg']), modal
    for selector in ('#login-username', '#password'):
        field = await styles(page, selector)
        assert rgb(field['bg']) == rgb(p['field']), field
        assert rgb(field['fill']) == rgb(p['text']), field
        assert field['shadow'] == 'none', field
        assert contrast(field['fill'], field['bg']) >= 4.5, field
    primary = await styles(page, '#loginSubmitBtn')
    assert rgb(primary['bg']) == rgb(p['primary']), primary
    assert contrast(primary['fg'], primary['bg']) >= 4.5, primary
    for selector in ('.auth-heading p', '.auth-mode-note', '.auth-footer p'):
        field = await styles(page, '#login-modal ' + selector)
        assert contrast(field['fg'], p['bg' if selector != '.auth-mode-note' else 'panel']) >= 4.5, (selector, field)
    await page.locator('#login-username').focus()
    focus = await styles(page, '#login-username')
    assert focus['outlineStyle'] == 'solid' and rgb(focus['outline']) == rgb(p['focus']), focus
    assert rgb(focus['border']) == rgb(p['focus']), focus
    assert await page.locator('#login-username').is_enabled()
    await page.locator('#login-username').evaluate('el => el.blur()')
    # Scope regression: our important field rules must NOT repaint other forms.
    assert (await styles(page, '#outside-auth'))['bg'] == 'rgb(179, 189, 207)'
    assert await page.evaluate('document.documentElement.scrollWidth <= innerWidth')
    assert await page.locator('#login-modal .auth-modal').evaluate('el => el.scrollWidth <= el.clientWidth + 2')


async def check_autofill(page, context, expected):
    palette = dict(zip(('light', 'dark'), palettes()))[expected]
    cdp = await context.new_cdp_session(page)
    await cdp.send('DOM.enable')
    await cdp.send('CSS.enable')
    doc = await cdp.send('DOM.getDocument')
    for selector in ('#login-username', '#password'):
        node = await cdp.send('DOM.querySelector', dict(nodeId=doc['root']['nodeId'], selector=selector))
        await cdp.send('CSS.forcePseudoState', dict(nodeId=node['nodeId'], forcedPseudoClasses=['autofill']))
        assert await page.locator(selector).evaluate('el => el.matches(":autofill")')
        paint = await styles(page, selector)
        assert rgb(paint['fill']) == rgb(palette['text']), paint
        assert 'inset' in paint['shadow'] and '1000px' in paint['shadow'], paint
        assert rgb(re.search(r'rgba?\([^)]+\)', paint['shadow'])[0]) == rgb(palette['field']), paint
        await page.locator(selector).focus()
        assert (await styles(page, selector))['outlineStyle'] == 'solid'
        await cdp.send('CSS.forcePseudoState', dict(nodeId=node['nodeId'], forcedPseudoClasses=[]))
        await page.locator(selector).evaluate('el => el.blur()')
    await cdp.detach()


async def browser_tests(args):
    from playwright.async_api import async_playwright
    markup = browser_html(args.fixture_only)
    output = Path(args.screenshots)
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    async with async_playwright() as pw:
        exe = os.environ.get('CHROMIUM') or shutil.which('chromium')
        browser = await pw.chromium.launch(headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'],
                                           **({'executable_path': exe} if exe else {}))
        for mode in ('light', 'dark'):
            for width in (1440, 772, 390, 320):
                context = await browser.new_context(viewport={'width': width, 'height': 1024}, color_scheme=mode)
                page = await context.new_page()
                await page.route('**/*', lambda route: route.abort())
                await page.set_content(markup)
                await page.locator('#login-modal').evaluate('el => {el.classList.add("is-open");el.setAttribute("aria-hidden","false");}')
                await page.evaluate('(bg) => document.body.style.background = bg', '#0b1628' if mode == 'dark' else '#e9eef7')
                # Fixtures use only invented example.test identity data.
                await page.locator('#login-username').fill('operator@example.test')
                await page.locator('#password').fill('FixtureOnly!123')
                await page.locator('#password').evaluate('el => el.blur()')
                await check_page(page, mode)
                await check_autofill(page, context, mode)
                await page.screenshot(path=str(output / f'ecai-login-{mode}-{width}.png'))
                count += 1
                # Explicit theme choices must win over the system setting.
                if width == 772:
                    for node, kind, chosen in [('html', 'data-theme', 'light'), ('body', 'data-theme', 'dark'),
                                               ('html', 'class', 'theme-dark'), ('body', 'class', 'theme-light'),
                                               ('html', 'class', 'force-light'), ('body', 'class', 'force-dark')]:
                        await page.evaluate('''([node,kind,value]) => {
                          for(const el of [document.documentElement,document.body]) {el.removeAttribute('data-theme');el.className='';}
                          document.querySelector(node).setAttribute(kind,value);
                        }''', [node, kind, chosen])
                        await check_page(page, 'dark' if chosen.endswith('dark') else 'light')
                    count += 1
                    await page.evaluate('for (const el of [document.documentElement,document.body]) {el.removeAttribute("data-theme");el.className="";}')
                    # Dynamic OS preference change without reload.
                    other = 'dark' if mode == 'light' else 'light'
                    await page.emulate_media(color_scheme=other)
                    await check_page(page, other)
                    await page.emulate_media(color_scheme=mode)
                    count += 1
                    # Disabled controls retain their actual disabled semantics.
                    await page.locator('#loginSubmitBtn').evaluate('el => el.disabled=true')
                    assert await page.locator('#loginSubmitBtn').is_disabled()
                    disabled = await styles(page, '#loginSubmitBtn')
                    assert contrast(disabled['fg'], disabled['bg']) >= 4.5, disabled
                    await page.locator('#loginSubmitBtn').evaluate('el => el.disabled=false')
                    await page.locator('#connect-status').evaluate('el => {el.dataset.kind="error";el.textContent="Unable to sign in. Check your details.";}')
                    error = await styles(page, '#connect-status')
                    assert contrast(error['fg'], error['bg']) >= 4.5, error
                    count += 1
                    if args.fixture_only:
                        # Show the other colour surfaces, without pretending to
                        # execute the absent shared auth controller.
                        for target in ('palette-signup', 'palette-wallet'):
                            await page.evaluate('''target => {
                              document.querySelectorAll('#login-modal [role="tabpanel"]').forEach(el=>el.hidden=el.id!==target);
                              document.querySelectorAll('#login-modal [role="tab"]').forEach(el=>el.setAttribute('aria-selected',String(el.getAttribute('aria-controls')===target)));
                              document.getElementById('connect-status').textContent='';
                            }''', target)
                            await page.screenshot(path=str(output / f'ecai-login-{mode}-{target}.png'))
                            assert await page.locator('#' + target).is_visible()
                        count += 1
                    await page.emulate_media(forced_colors='active')
                    await page.evaluate('document.documentElement.dataset.theme="dark"')
                    field = await styles(page, '#password')
                    assert rgb(field['fill']) == rgb(field['fg']), field
                    assert field['shadow'] == 'none', field
                    count += 1
                await context.close()
        await browser.close()
    print(f'PASS: {count} browser groups (layouts, autofill pseudo-state, theme overrides, live preference, disabled/error states, forced colours).')
    print('Basis: ' + ('contract fixture + production ECAI CSS; shared DamageBDD assets NOT tested.' if args.fixture_only else 'production ECAI CSS + shared DamageBDD auth CSS/template.'))
    print('Auth controllers omitted. Autofill is DevTools-forced, not a real password-manager integration test.')
    print('Screenshots:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--browser', action='store_true')
    parser.add_argument('--fixture-only', action='store_true')
    parser.add_argument('--screenshots', default=str(Path(tempfile.gettempdir()) / 'ecai-auth-palette'))
    args, rest = parser.parse_known_args()
    if args.browser:
        asyncio.run(browser_tests(args))
    else:
        unittest.main(argv=[__file__, *rest], verbosity=2)
