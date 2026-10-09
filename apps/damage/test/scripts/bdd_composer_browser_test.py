#!/usr/bin/env python3
"""Real Chromium UI tests with explicit API fixtures; not a live-node integration test.
Requires Python playwright and a Chromium executable. No target requests or inference.
Usage: python3 apps/damage/test/scripts/bdd_composer_browser_test.py --out /tmp/bdd-ui
"""
from pathlib import Path
import argparse
import base64
import json
import html
import re
from playwright.sync_api import sync_playwright

APP = Path(__file__).resolve().parents[2]

def render_template(text: str, context: dict) -> str:
    """Render the scalar/boolean Mustache subset used by the dashboard fixtures."""
    sections = re.compile(r'{{([#^])\s*(\w+)\s*}}((?:(?!{{[#^]).)*?){{/\s*\2\s*}}', re.S)
    while sections.search(text):
        text = sections.sub(lambda m: m[3] if bool(context.get(m[2])) == (m[1] == '#') else '', text)
    text = re.sub(r'{{{\s*(\w+)\s*}}}', lambda m: str(context.get(m[1], '')), text)
    return re.sub(r'{{\s*(\w+)\s*}}', lambda m: html.escape(str(context.get(m[1], ''))), text)

def build_preview(node_admin: bool = False) -> str:
    templates = APP / 'priv/templates/ui/dashboard'
    static = APP / 'priv/static'
    shell = (templates / 'page_shell.mustache').read_text()
    css_paths = re.findall(r'href=[\'\"](/static/css/[^\'\"]+)', shell)
    css = '\n'.join((static / path.removeprefix('/static/')).read_text() for path in css_paths)
    logo = base64.b64encode((static / 'img/logo.png').read_bytes()).decode()
    context = {'logo_image': 'data:image/png;base64,' + logo, 'authenticated': True,
               'node_admin': node_admin, 'node_version': 'fixture'}
    context['footer'] = render_template((templates / 'footer.mustache').read_text(), context)
    context['sidebar'] = render_template((templates / 'sidebar.mustache').read_text(), context)
    # Use the production shell and server-rendered panels, not an alternate DOM.
    # Backend/wallet integrations remain simulated and are not exercised here.
    names = {'swaps_tab': 'swap_options_tab', 'node_cln_admin_tab': 'node_cln_admin',
             'node_public_key_modal': 'node_details_modal'}
    for key in re.findall(r'{{{(\w+)}}}', shell):
        if key in context:
            continue
        template = templates / (names.get(key, key) + '.mustache')
        context[key] = render_template(template.read_text(), context) if template.exists() else ''
    page_html = render_template(shell, context)
    page_html = re.sub(r'<script\b[^>]*>.*?</script>', '', page_html, flags=re.S | re.I)
    page_html = re.sub(r'<link\b[^>]*>', '', page_html, flags=re.I)
    page_html = re.sub(r'<meta\b[^>]*(?:property|name)=["\'](?:og:|twitter:)[^>]*>', '', page_html, flags=re.I)
    page_html = page_html.replace('<head>', '<head><style>' + css + '</style>')
    page_html = page_html.replace('<main id="content"', '<div class="preview-banner"><strong>INTERACTIVE PREVIEW</strong> · Simulated API responses. No wallet, model or target requests.</div><main id="content"')
    page_html = page_html.replace('</head>', '<style>.preview-banner {padding:8px 12px; background:#172335; color:#c6d3e4; font:11px/1.5 system-ui; text-align:center;} .preview-banner strong {color:#eef3fa;}</style></head>')
    helpers = (static / 'js/bdd-composer-model.js').read_text().replace('export ', '')
    controller = re.sub(r'^import .*?;\s*', '', (static / 'js/bdd-composer.js').read_text(), count=1, flags=re.S)
    main = (static / 'js/main.js').read_text()
    execution_guard = main[main.index('let executionInFlight = false;'):main.index('async function submitDamageFormRequest()')]
    catalog = json.loads((APP / 'test/fixtures/bdd-composer/catalog.json').read_text())
    draft = json.loads((APP / 'test/fixtures/bdd-composer/draft.json').read_text())
    fixtures = 'const FIXTURE_CATALOG = ' + json.dumps(catalog) + ';\nconst FIXTURE_DRAFT = ' + json.dumps(draft) + ';\n'
    mock = r'''
// PREVIEW ONLY: never send network requests. Production bdd-composer.js uses real fetch.
window.__mock = { mode: 'ok', delay: 160, calls: [], executions: 0 };
window.fetch = async (url, options = {}) => {
  const action = String(url).split('/').pop(), state = window.__mock;
  state.calls.push({action, body: options.body ? JSON.parse(options.body) : null, headers: options.headers});
  const mode = state.mode;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, action === 'catalog' || action === 'cancel' ? 10 : state.delay);
    if (options.signal?.aborted) { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')); }
    options.signal?.addEventListener('abort', () => { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')); }, {once: true});
  });
  const respond = (body, status = 200) => new Response(JSON.stringify(body), {status, headers: {'Content-Type': 'application/json'}});
  if (action === 'catalog') {
    const value = structuredClone(FIXTURE_CATALOG);
    if (mode === 'no-engine') value.engine.generator_available = false;
    return respond(value);
  }
  if (action === 'cancel') return respond({status:'ok',cancelled:true});
  if (mode === 'http-error') return respond({message:'Preview: model service unavailable. Retry.'}, 503);
  if (mode === 'unauthorized') return respond({message:'Unauthorized'}, 401);
  if (action === 'validate') return respond({validation: FIXTURE_DRAFT.validation});
  if (action === 'generate') {
    const value = structuredClone(FIXTURE_DRAFT);
    if (mode === 'invalid') { value.validation.valid = false; value.validation.diagnostics = [{line:5,message:'Preview: unknown step'}]; }
    if (mode === 'incomplete') { value.complete = false; value.missing_steps = ['Preview: unsupported requirement']; }
    if (mode === 'xss') value.feature += '\n# <img src=x onerror="window.__injected=true">';
    return respond(value);
  }
  throw new Error('No live network requests are allowed in this preview.');
};
window.TokenManager = {getToken: () => undefined, getAddress: () => 'ak_fixture'};
window.Reports = {renderRunReports: () => {window.__mock.reportRefreshes = (window.__mock.reportRefreshes || 0) + 1;}};
async function updateSchedulesTable() {window.__mock.scheduleRefreshes = (window.__mock.scheduleRefreshes || 0) + 1;}
'''
    setup = r'''
async function submitDamageFormRequest() {
  window.__mock.executions++;
  await new Promise(resolve => setTimeout(resolve, 250));
  const reports = document.getElementById('run-reports');
  const li = document.createElement('li'); li.textContent = 'Preview only';
  document.getElementById('run-reports-ul').append(li);
  const pre = document.createElement('pre'), code = document.createElement('code'); code.className = 'report';
  code.textContent = 'PREVIEW ONLY — no feature was executed.\nThe deployed dashboard uses the existing authenticated execution endpoint.';
  pre.append(code); reports.append(pre);
}
window.__submitDamageForm = submitDamageForm;
document.addEventListener('DOMContentLoaded', () => {
  initDashboardNavigation();
  bindDashboardPanelRefresh(window.dashboardNavigation);
  document.getElementById('damageForm').addEventListener('submit', event => {event.preventDefault(); submitDamageForm();});
  document.getElementById('damageTextArea').addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {event.preventDefault(); document.getElementById('damageForm').requestSubmit();}
  });
  document.getElementById('damageTextArea').addEventListener('input', () => {document.getElementById('selected-ipfs-feature').hidden = true;});
  document.getElementById('edit-execution-context-btn').addEventListener('click', event => {
    const box = document.getElementById('execution-context-editor'); box.hidden = !box.hidden;
    event.target.setAttribute('aria-expanded', String(!box.hidden));
  });
  for (const id of ['installBtn','logoutBtn','open-wallet-modal-btn','balanceRefreshBtn','open-feature-picker','open-ipfs-feature-picker','save-runtime-context-btn','clear-runtime-context-btn','save-account-context-btn','refresh-account-context-btn','clear-account-context-editor-btn']) {
    document.getElementById(id)?.addEventListener('click', event => { event.preventDefault(); alert('Preview only. This action uses the existing dashboard integration in the deployed application.'); });
  }
  document.querySelector('.workspace-reference').addEventListener('click', event => {event.preventDefault(); document.querySelector('.bdd-step-library').open = true; document.getElementById('bdd-step-search').focus();});
  document.getElementById('activity-link').addEventListener('click', event => {event.preventDefault(); window.dashboardNavigation.navigate('activity-tab');});
});
'''
    # Inline local assets: the downloadable preview works without a server or CDN.
    navigation = (static / 'js/dashboard-navigation.js').read_text().replace('export ', '')
    panel_refresh = main[main.index('function bindDashboardPanelRefresh('):main.index('function normalizeIpfsExecutionPath(')]
    script = navigation + fixtures + mock + execution_guard + panel_refresh + setup + '\n' + (static/'js/lineNumbers.js').read_text()
    safe_script = script.replace('</script', '<\\/script')
    return page_html.replace('</body>', f'<script>{safe_script}</script><script type="module">{helpers}\n{controller}</script></body>')

def run(out: Path, chromium: str) -> None:
    out.mkdir(parents=True, exist_ok=True)
    preview = out / 'damagebdd-dashboard-preview.html'
    preview.write_text(build_preview())
    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chromium, headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width':1440,'height':1150}, reduced_motion='reduce')
        page.set_default_timeout(5000)
        errors = []
        page.on('pageerror', lambda err: errors.append(str(err)))
        page.set_content(preview.read_text(), wait_until="load")
        page.wait_for_function("document.querySelector('#bdd-catalog-status').textContent.includes('6')")
        def passed(name):
            results.append(name); print('PASS', name, flush=True)
        def mode(name, delay=160):
            page.evaluate('([mode,delay]) => Object.assign(window.__mock, {mode,delay})', [name,delay])
        def generate():
            page.locator('#bdd-prompt').fill('Check the health endpoint returns 200.')
            page.locator('#bdd-generate').click()
            page.locator('#bdd-cancel').wait_for(state='hidden')

        # Rebase regression: invoice integrations must coexist with the composer.
        # These are wiring checks, not authenticated/live invoice API tests.
        shell = (APP / 'priv/templates/ui/dashboard/page_shell.mustache').read_text()
        for asset in ['/static/css/billing.css', '/static/css/dashboard-workspace.css',
                      '/static/js/billing.js', '/static/js/bdd-composer.js']:
            assert shell.count(asset) == 1, asset
        assert shell.index('/static/css/billing.css') < shell.index('/static/css/dashboard-workspace.css')
        assert 'id="billing-tab"' in shell and '{{{billing_tab}}}' in shell
        routes = (APP / 'src/damage_app.erl').read_text()
        supervisor = (APP / 'src/damage_sup.erl').read_text()
        for module in ['damage_invoice_http', 'damage_bdd_http']:
            assert len(re.findall(r'^\s+' + module + r',\s*$', routes, re.M)) == 1, module
        for module in ['damage_enterprise_invoices', 'damage_bdd_service']:
            assert supervisor.count('id => ' + module + ',') == 1, module
            assert supervisor.count('start => {' + module + ', start_link, []}') == 1, module
        passed('shell, route and supervisor wiring retain both invoice and composer integrations')

        assert not page.locator('[data-tabs], .tabsbar').count()
        assert page.evaluate("""() => [...document.querySelectorAll('#dashboard-navigation a[data-dashboard-panel]')].every(
            a => document.getElementById(a.getAttribute('href').slice(1)))""")
        passed('all retained dashboard navigation links resolve to panels')

        assert page.locator('#billing-nav').is_hidden()
        # Simulate a visibility change only; billing.js authorization is not mocked here.
        page.locator('#billing-nav').evaluate('(e) => { e.hidden = false; }')
        page.locator('[href="#billing-tab"]').click()
        assert page.locator('#billing-tab').is_visible()
        assert page.locator('#execution-tab').is_hidden()
        page.locator('#dashboard-navigation [href="#execution-tab"]').click()
        page.locator('#billing-nav').evaluate('(e) => { e.hidden = true; }')
        assert page.locator('#execution-tab').is_visible()
        assert page.locator('#billing-nav').is_hidden()
        passed('invoice navigation remains hidden and supports explicit reveal and return to workspace')

        assert page.locator('#bdd-generate').is_disabled()
        page.locator('[data-bdd-example="health"]').click()
        assert page.locator('#bdd-generate').is_enabled()
        passed('empty prompt disabled; example prompt enables generation')

        original = 'Feature: Existing work\n\n  Scenario: Keep my edits\n    Given I set the variable "x" to "1"\n'
        page.locator('#damageTextArea').fill(original)
        page.locator('#bdd-prompt').press('Control+Enter')
        page.locator('#bdd-prompt').press('Control+Enter')
        page.locator('#bdd-cancel').wait_for(state='hidden')
        assert page.evaluate("window.__mock.calls.filter(x=>x.action==='generate').length") == 1
        assert page.locator('#damageTextArea').input_value() == original
        assert page.evaluate('window.__mock.executions') == 0
        passed('duplicate prompt shortcut submits once; generation neither replaces nor runs feature')

        page.once('dialog', lambda d: d.dismiss())
        page.locator('#bdd-accept').click()
        assert page.locator('#damageTextArea').input_value() == original
        page.once('dialog', lambda d: d.accept())
        page.locator('#bdd-accept').click()
        assert 'API health' in page.locator('#damageTextArea').input_value()
        assert 'Runtime behaviour is not verified' in page.locator('#bdd-validation-status').inner_text()
        page.once('dialog', lambda d: d.accept())
        page.locator('#bdd-undo').click()
        assert page.locator('#damageTextArea').input_value() == original
        passed('replace confirmation, explicit use, honest validation status and undo')

        for name in ['invalid','incomplete']:
            mode(name); generate()
            assert page.locator('#bdd-accept').is_disabled()
            assert page.locator('#damageTextArea').input_value() == original
            passed(name + ' draft cannot be accepted')

        mode('ok', 700)
        page.locator('#bdd-validate').click()
        page.locator('#damageTextArea').fill('Feature: Changed while validating\n')
        page.wait_for_timeout(900)
        assert 'Editor changed' in page.locator('#bdd-validation-status').inner_text()
        assert page.locator('#bdd-validate').is_enabled()
        passed('stale validation does not validate changed editor content')

        mode('ok', 1800)
        page.locator('#bdd-generate').click()
        page.locator('#bdd-cancel').click()
        page.locator('#bdd-cancel').wait_for(state='hidden')
        assert 'cancelled' in page.locator('#bdd-generation-status').inner_text()
        assert page.locator('#bdd-generate').is_enabled()
        assert not page.locator('#bdd-prompt').evaluate('(el)=>el.readOnly')
        passed('cancellation restores controls and confirms unchanged editor')

        for name in ['http-error','unauthorized']:
            mode(name); generate()
            assert page.locator('#bdd-generate').is_enabled()
            assert 'Changed while validating' in page.locator('#damageTextArea').input_value()
            assert page.locator('#bdd-generation-status').get_attribute('data-tone') == 'error'
            passed(name + ' recovers controls without wiping editor')

        mode('xss'); generate()
        assert '<img' in page.locator('#bdd-draft-source').text_content()
        assert not page.locator('#bdd-draft-source img').count()
        assert not page.evaluate('!!window.__injected')
        passed('model output is rendered as text, not executable HTML')

        page.locator('.bdd-step-library summary').click()
        page.locator('#bdd-step-search').fill('GET')
        assert page.locator('.bdd-step-item').count() == 1
        page.locator('.bdd-step-item button').click()
        assert '<Path>' in page.locator('#damageTextArea').input_value()
        assert page.locator('#damageTextArea').evaluate('(e)=>e.value.slice(e.selectionStart,e.selectionEnd)') == '<Path>'
        passed('live step search and insertion select argument placeholder')
        page.locator('.bdd-step-library summary').click()

        page.evaluate('() => { window.__submitDamageForm(); window.__submitDamageForm(); }')
        page.wait_for_timeout(350)
        assert page.evaluate('window.__mock.executions') == 1
        assert page.locator('#execute-feature-btn').is_enabled()
        assert page.locator('#bdd-run-status').inner_text() == 'Request complete'
        passed('actual main.js execution guard blocks duplicate submissions and restores run button')

        mode('no-engine')
        page.locator('#bdd-refresh-catalog').click()
        page.wait_for_timeout(100)
        assert page.locator('#bdd-generate').is_disabled()
        assert page.locator('#bdd-validate').is_enabled()
        passed('missing ECAI disables generation but preserves manual editing and validation')

        # Fresh page for screenshots: no simulated execution results or invented metrics.
        page.close()
        page = browser.new_page(viewport={"width":1440,"height":1150}, reduced_motion="reduce")
        page.on("pageerror", lambda err: errors.append(str(err)))
        page.set_content(preview.read_text(), wait_until="load")
        page.wait_for_function("document.querySelector('#bdd-catalog-status').textContent.includes('6')")
        page.locator('[data-bdd-example="health"]').click()
        page.locator('#bdd-generate').click(); page.locator('#bdd-cancel').wait_for(state='hidden')
        page.locator('#bdd-accept').click()
        for width in [320,390,768,1440]:
            page.set_viewport_size({'width':width,'height':1150})
            page.wait_for_timeout(100)
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), page.evaluate("({width:innerWidth,scroll:document.documentElement.scrollWidth,wide:[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1).map(e=>({id:e.id,cls:e.className,right:e.getBoundingClientRect().right})).slice(0,20)})")
            passed(f'no document horizontal overflow at {width}px')
            assert page.evaluate("getComputedStyle(document.getElementById('damageTextArea')).lineHeight === getComputedStyle(document.getElementById('damageLineNumbers')).lineHeight")
            assert page.evaluate("document.querySelectorAll('#damageLineNumbers span').length === document.getElementById('damageTextArea').value.split('\\n').length")
            if width in [390,1440]:
                page.screenshot(path=str(out / ('damagebdd-dashboard-mobile.png' if width==390 else 'damagebdd-dashboard-desktop.png')), full_page=True)
        passed('editor gutter tracks logical lines with matching line height at all tested widths')
        assert not errors, errors
        passed('no browser JavaScript exceptions')
        browser.close()
    (out/'browser-test-results.json').write_text(json.dumps({'test_type':'real Chromium with simulated API responses','passed':len(results),'checks':results}, indent=2))
    print(f'{len(results)} browser checks passed; preview: {preview}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path('/tmp/damage-bdd-preview'))
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    args = parser.parse_args()
    run(args.out, args.chromium)
