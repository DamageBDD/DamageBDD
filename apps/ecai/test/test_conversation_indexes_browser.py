"""Offline Chromium regression of conversation index selector and layout.

Runs from generated HTML/CSS fixtures without a network connection; it does
not claim a live model or indexer has been verified.
"""
from pathlib import Path
from shutil import which
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "priv" / "static"
TEMPLATE = ROOT / "priv" / "templates" / "ui" / "dashboard" / "ecai_console.mustache"


def main():
    source = TEMPLATE.read_text()
    start = source.index('<section class="view" data-panel="chat"')
    stop = source.index('<section class="view" data-panel="indexing"', start)
    chat = source[start:stop].replace('class="view" data-panel="chat"', 'class="view is-visible" data-panel="chat"')
    chat = chat.replace('aria-labelledby="chatTitle" hidden', 'aria-labelledby="chatTitle"')
    html = '''<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head><body>
      <div id="ecaiConsole" data-active-view="chat" class="console-shell">
        <div class="console-body"><main class="console-main">''' + chat + '''</main></div>
      </div></body></html>'''
    css = ''.join((STATIC / "css" / name).read_text() for name in [
        'ecai-console.css', 'ecai-knowledge-workspace.css', 'ecai-conversation-indexes.css'])
    theme = ''':root {--theme-color-scheme:dark;--theme-bg:#0c1421;--theme-surface:#182636;
        --theme-surface-alt:#213247;--theme-text:#e4eefd;--theme-muted:#b2c2d9;
        --theme-border:#53617a;--theme-accent:#9cd579;--theme-accent-soft:#253c36;
        --theme-control-border:#60718b;--theme-on-accent:#0d1b14;}'''
    # Browser uses a single script body: only strip ESM export markers, preserving
    # the exact production selector implementation.
    model = (STATIC / "js" / "ecai-knowledge-search.js").read_text().replace('export function ', 'function ')
    init = '''
      let changes = 0;
      window.__chooser = initKnowledgeIndexSelection({
        root: document, request: async () => ({ok:true,indexes:[
          {id:'shared',label:'Shared live index',kind:'shared',scope:'public',state:'ready'},
          {id:'wikimedia',label:'Wikimedia',kind:'wikimedia',scope:'public',state:'unavailable'},
          {id:'public-ipfs',label:'public-ipfs',kind:'disk',scope:'public',state:'ready'}
        ]}),
        authEpoch: () => 1, isActive: () => true, onChange: () => changes++,
        showError: e => e.message, timeoutMs: 1000,
        ids:{searchIndexes:'chatIndexes',searchIndexChoices:'chatIndexChoices',
          searchIndexSummary:'chatIndexSummary',searchIndexStatus:'chatIndexStatus',
          searchIndexAll:'chatIndexAll',searchIndexNone:'chatIndexNone',
          searchIndexRefresh:'chatIndexRefresh'}
      });
      window.__scope = () => window.__chooser.body();
      window.__changes = () => changes;
    '''
    with sync_playwright() as p:
        binary = which('chromium') or which('chromium-browser') or which('google-chrome')
        launch_opts = {'headless': True, 'args': ['--no-sandbox']}
        if binary: launch_opts['executable_path'] = binary
        browser = p.chromium.launch(**launch_opts)
        try:
            page = browser.new_page(viewport={'width':1400,'height':880})
            page.set_content(html)
            page.add_style_tag(content=css + theme)
            page.add_script_tag(content=model + init)
            page.wait_for_function('Boolean(window.__scope)')
            assert not page.locator('#chatIndexes').evaluate('(e) => e.open'), 'accordion must start closed'
            assert page.evaluate('JSON.stringify(window.__scope())') == '{}'
            assert page.locator('#chatIndexSummary').inner_text() == 'All indexes'
            page.locator('#chatIndexes > summary').click()
            page.get_by_role('button',name='Clear selection').click()
            assert page.evaluate('JSON.stringify(window.__scope())') == '{"indexes":[]}'
            page.get_by_role('checkbox',name='Search Shared live index').check()
            assert page.evaluate('JSON.stringify(window.__scope())') == '{"indexes":["shared"]}'
            assert '1 selected' in page.locator('#chatIndexSummary').inner_text()
            page.get_by_role('button',name='All indexes').click()
            assert page.evaluate('JSON.stringify(window.__scope())') == '{}'
            assert page.evaluate('window.__changes()') == 3
            assert page.locator('.chat-workspace').bounding_box()['width'] > 800
            page.set_viewport_size({'width': 540, 'height': 760})
            assert page.locator('#chatIndexes').bounding_box()['width'] <= 540
            assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth + 2')
            print('Browser checks passed: closed accordion, catalog, all/none/selected, mobile layout')
        finally:
            browser.close()


if __name__ == '__main__':
    main()
