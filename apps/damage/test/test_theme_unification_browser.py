#!/usr/bin/env python3
"""Visual regression of actual app styles/templates, with offline fixture data.
No application JS/API actions run, except BOP's read-only theme loader test.
Requires: playwright, beautifulsoup4, lxml. Defaults to /usr/bin/chromium if available.
Set THEME_CSS_DIR to export_theme_css.escript output for real Erlang CSS; otherwise
uses a labelled Python reference. THEME_SCREENSHOTS chooses an output directory.
"""
import asyncio
import html
import json
import os
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit
from bs4 import BeautifulSoup
from playwright.async_api import async_playwright
from theme_palette_reference import ROOT, palettes, reference_css

OUT=Path(os.environ.get('THEME_SCREENSHOTS','/tmp/damage-theme-audit'))
CSS_DIR=os.environ.get('THEME_CSS_DIR')

def render(src,ctx):
    # Bounded Mustache subset for these static shells. Fixtures never contain
    # untrusted HTML, callbacks, remote content, payment/session credentials.
    pattern=re.compile(r'\{\{([#^])(\w+)\}\}(.*?)\{\{/\2\}\}',re.S)
    while pattern.search(src):
        src=pattern.sub(lambda m:render(m[3],ctx) if bool(ctx.get(m[2]))==(m[1]=='#') else '',src)
    src=re.sub(r'\{\{\{(\w+)\}\}\}',lambda m:str(ctx.get(m[1],'')),src)
    src=re.sub(r'\{\{(\w+)\}\}',lambda m:html.escape(str(ctx.get(m[1],'')),quote=True),src)
    return re.sub(r'\{\{!.*?\}\}', '',src,flags=re.S)

def template(app,path,ctx):return render((ROOT/f'apps/{app}/priv/templates'/path).read_text(),ctx)

def palette_css(app,palette):
    return (Path(CSS_DIR)/app/f'{palette}.css').read_text() if CSS_DIR else reference_css(app,palette)

def document(app,view,palette):
    ctx=dict(brand_name={'damage':'DamageBDD','ecai':'ECAI','nosternity':'Nosternity','bop':'BoP'}[app],brand_tagline='NODE WORKSPACE',name='Nosternity',title='Theme audit',
             description='Fixture content · no live services',authenticated=True,node_admin=True,
             auth_mode='managed',node_version='test',accent_color='#497a4a',username='Fixture account')
    if app=='ecai':
        pieces={'market_maker_panel':'ecai_market_maker','personalities_panel':'ecai_personalities',
                'math_paths_panel':'ecai_math_paths','evaluation_panel':'ecai_eval',
                'compute_settings_panel':'compute_settings','ollama_keys_panel':'ollama_keys'}
        ctx.update({k:template(app,f'ui/dashboard/{v}.mustache',ctx) for k,v in pieces.items()})
        ctx['browser_auth_modal']=template('damage','ui/dashboard/auth_modal.mustache',ctx)
        src=template(app,'ui/dashboard/ecai_console.mustache',ctx)
    elif app=='damage' and view in ('theme-studio','node-settings'):
        folder='themes' if view=='theme-studio' else 'settings'
        src=(ROOT/f'apps/damage/priv/static/{folder}/index.html').read_text().replace('__APP__','damage').replace('__MODE__','admin')
    elif app=='damage':
        d=ROOT/'apps/damage/priv/templates/ui/dashboard'
        for p in d.glob('*.mustache'):
            if p.stem!='page_shell':ctx[p.stem]=render(p.read_text(),ctx)
        src=template(app,'ui/dashboard/page_shell.mustache',ctx)
        if view=='schedules':
            # Extract the actual render-only shell: never run schedule APIs.
            js=(ROOT/'apps/damage/priv/static/js/schedules-v2.js').read_text()
            shell=re.search(r'function mount\(root\) \{\s*root.innerHTML = `([\s\S]+?)`;',js)[1]
            src=src.replace('<div class="sv2-bootstrap" role="status" aria-live="polite">Loading schedules…</div>',shell)
    elif app=='nosternity':
        d=ROOT/'apps/nosternity/priv/templates/ui/dashboard'
        ctx.update({p.stem:render(p.read_text(),ctx) for p in d.glob('*.mustache') if p.stem!='page'})
        if view!='feed':ctx['feed']=ctx.get(view,ctx['feed'])
        src=template(app,'ui/dashboard/page.mustache',ctx)
    elif app=='bop':src=(ROOT/f'apps/bop/priv/public/{view}.html').read_text()
    soup=BeautifulSoup(src,'lxml')
    for s in soup.select('script, noscript, link[rel="icon"]'):s.decompose()
    for link in soup.select('link[rel="stylesheet"]'):
        href=link.get('href','');url=urlsplit(href).path
        if url=='/api/themes/css':link.decompose();continue
        if href.startswith('http') or href.startswith('//'):link.decompose();continue
        if url.startswith('/dashboard/assets/'):
            p=ROOT/'apps/nosternity/priv/static/dashboard'/Path(url).name
        elif url.startswith('/assets/'):
            p=ROOT/'apps/bop/priv'/url[1:]
        elif url.startswith('/ecai/auth-assets/'):
            p=ROOT/'apps/damage/priv/static/css/auth.css'
        else:
            p=ROOT/f'apps/{app}/priv'/url[1:]
            if not p.exists():p=ROOT/'apps/damage/priv'/url[1:]
        if p.is_file():
            style=soup.new_tag('style');style['data-source']=str(p.relative_to(ROOT));style.string=p.read_text();link.replace_with(style)
        else:link.decompose()
    theme=soup.new_tag('style');theme['id']='test-theme'
    theme.string=palette_css(app,palette)
    soup.head.append(theme)
    return str(soup)

FIXTURE_JS=r'''([app,view])=>{
 document.querySelectorAll('button').forEach(b=>{ if(!b.getAttribute('aria-label') && !b.textContent.trim())b.setAttribute('aria-label','Fixture control')});
 if(app==='ecai') {
  document.querySelectorAll('[data-panel]').forEach(n=>{n.hidden=n.dataset.panel!==view;n.classList.toggle('is-visible',!n.hidden)});
  document.getElementById('ecaiConsole').dataset.activeView=view;
  if(!document.querySelector(`[data-panel="${view}"]`))throw new Error(`Missing actual view: ${view}`);
  const put=(id,html)=>{const n=document.getElementById(id);if(!n)throw new Error(`Missing fixture target: ${id}`);n.innerHTML=html};
  put('codeMetrics', ['Learning','Awaiting review','Approved patches'].map((label,i)=>`<div class="code-metric"><span class="code-metric-label">${label}</span><strong class="code-metric-value">${i+1}</strong><span class="code-metric-caption">Fixture status · no runtime action</span></div>`).join(''));
  put('codeServiceCards',['Code learner','Repair manager','Integration & review'].map(label=>`<article class="code-service"><div class="code-service-head"><h4>${label}</h4><span class="code-service-state ok">Standing by</span></div><p class="code-service-description">Current cycle and durable progress.</p><div class="code-mini-progress"><span style="width:60%"></span></div><div class="code-service-fact">Completed<strong>14</strong></div></article>`).join(''));
  put('chatProjects','<button class="chat-history-item is-active"><span class="chat-history-copy"><strong>All chats</strong><small>Every project</small></span></button>');
  put('chatHistoryList','<button class="chat-history-item"><span class="chat-history-copy"><strong>Theme audit conversation</strong><small>Today · fixture</small></span></button>');
  put('personalityCatalogue',['The Mathematician','The Skeptic','The Builder'].map((name,i)=>`<article class="personality-card"><div class="personality-card-art"><span class="personality-monogram">${['TM','TS','TB'][i]}</span></div><div class="personality-card-body"><h3>${name}</h3><p class="personality-tagline">Inspect an idea. Verify every step.</p><p>A portable personality with replayable evidence.</p><div class="personality-traits"><span>Curious</span><span>Practical</span></div><div class="personality-card-meta">100 editions · v1.0.0</div><div class="personality-card-footer"><span class="personality-price">21,000 sats</span><button class="button button-primary button-sm">View edition</button></div></div></article>`).join(''));
  put('mathMetrics',['Curve occurrences','Transformations','Composite degree','Edge-weight sum'].map(t=>`<div class="math-metric"><span>${t}</span><strong>4</strong></div>`).join(''));
  put('mathPointResult',['E0','E1','E2','E3'].map(t=>`<div class="math-point-image"><small>${t}</small><strong>(12, 36)</strong></div>`).join(''));
  put('mathInspectorBody','<pre class="math-formula">y² = x³ − 36x</pre><dl class="math-facts"><dt>Field</dt><dd>Q · exact rationals</dd></dl><figure class="math-real-plot"><svg viewBox="0 0 300 80"><path class="math-real-axis" d="M0 40H300 M150 0V80"/><path class="math-real-locus" d="M0 40Q100 0 150 40T300 40"/><text x="4" y="75">-750</text></svg><figcaption>Illustration only</figcaption></figure>');
  // Use the existing path container and CSS, retaining local horizontal scroll.
  const path=document.getElementById('mathGraph');
  if(path)path.innerHTML=['E0','E1','E2','E3'].map((t,i)=>`<button class="math-node" type="button" data-kind="curve" data-index="${i}" aria-pressed="${i===0}"><small>${i===0?'SOURCE':i===3?'TARGET':'INTERMEDIATE'}</small><strong>${t}</strong><span class="math-equation">y² = x³ − 36x</span><small>3E65D780…8D8F9F</small></button>${i<3?`<button class="math-edge" type="button" data-kind="map" data-index="${i}" aria-pressed="false"><span class="math-edge-title">φ${i+1} · degree 2</span><span class="math-arrow">⟶</span><small>Candidate</small></button>`:''}`).join('');
  document.querySelectorAll('.code-settings-card input').forEach(n=>{if(n.type==='checkbox')n.checked=true;else if(!n.value)n.value=n.type==='number'?'300':'main'});
 } else if(app==='damage') {
  document.querySelectorAll('[data-dashboard-view]').forEach(n=>{n.hidden=n.id!==view+'-tab';});
  document.querySelectorAll('.wallet-reveal').forEach(n=>{n.style.opacity=1;n.style.transform='none'});
  if(view==='theme-studio'){
   document.getElementById('studio-controls').hidden=false;
   document.getElementById('notice').textContent='Theme preview · offline fixture';
  }
  if(view==='schedules'){
   const list=document.getElementById('sv2-template-list');
   if(list)list.innerHTML=['HTTP uptime & latency','Page content canary','TLS certificate expiry','Web security headers','IPFS content availability','Nostr relay information'].map(title=>`<article class="sv2-template"><div class="sv2-template-category">AVAILABILITY</div><h4>${title}</h4><p>Inspect a known endpoint with a read-only verification.</p><small>Every 15 minutes · 1 probe / run</small><button class="sv2-secondary">Use template</button></article>`).join('');
  }
  if(view==='billing'){
   const panel=document.querySelector('#enterprise-billing'); if(panel)panel.hidden=false;
   const rows=document.getElementById('billing-invoice-rows');if(rows)rows.innerHTML='<tr><td>INV-1042</td><td>Example customer · service period</td><td>100 sats</td><td>30 Oct</td><td>Draft</td><td>Not sent</td><td>Not issued</td><td><button type="button">Review</button></td></tr>';
   for(const n of document.querySelectorAll('.billing-stat strong'))n.textContent='0';
  }
 }
}'''
# Return contrast observations for direct text nodes/controls only. Exclude
# intentional art, disabled controls, inaccessible hidden/inert/template content.
# Gradient endpoints are checked in addition to the flat backing colour.
AUDIT_JS=r'''()=>{
 const canvas=document.createElement('canvas');canvas.width=canvas.height=1;const ctx=canvas.getContext('2d',{willReadFrequently:true});
 const rgba=(c)=>{ctx.clearRect(0,0,1,1);ctx.fillStyle=c;ctx.fillRect(0,0,1,1);return [...ctx.getImageData(0,0,1,1).data].map((v,i)=>i===3?v/255:v)};
 const mix=(a,b)=>{const t=a[3];return [0,1,2].map(i=>a[i]*t+b[i]*(1-t)).concat(1)};
 const lum=c=>c.slice(0,3).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
 const ratio=(a,b)=>{let x=lum(a),y=lum(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05)};
 const background=(n)=>{if(!n)return [[255,255,255,1]];const s=getComputedStyle(n);const parent=background(n.parentElement);let bases=parent.map(c=>mix(rgba(s.backgroundColor),c));
  if(s.backgroundImage!=='none' && /gradient/.test(s.backgroundImage)){
   const colors=s.backgroundImage.match(/(?:rgba?|color)\([^()]+\)|#[\da-f]{3,8}/gi)||[];
   if(colors.length)bases=colors.map(c=>mix(rgba(c),bases[0]));
  }
  return bases;
 };
 const rows=[];
 document.querySelectorAll('body *').forEach(n=>{
  if(n.closest('template,script,style,svg,[hidden],[inert],[aria-hidden="true"],.personality-card-art,.personality-core,.brand-symbol,.orbit-art'))return;
  if(n.matches(':disabled')||n.closest('button:disabled,[aria-disabled="true"]'))return;
  const rect=n.getBoundingClientRect(), s=getComputedStyle(n);if(!rect.width||!rect.height||s.visibility!=='visible')return;
  if(n.closest('dialog')&&!n.closest('dialog').open)return;
  const text=[...n.childNodes].filter(x=>x.nodeType===3).map(x=>x.textContent.trim()).join(' ').trim() || (n.matches('input:not([type=checkbox]):not([type=radio])')?n.value:'');
  if(!/[\p{L}\d]/u.test(text)||text.length<2)return;
  let opacity=1;for(let a=n;a;a=a.parentElement)opacity*=+getComputedStyle(a).opacity;
  if(opacity===0)return;
  const f=rgba(s.color);f[3]*=opacity;
  const contrasts=background(n).map(b=>ratio(mix(f,b),b));
  const large=parseFloat(s.fontSize)>=24 || (+s.fontWeight>=700 && parseFloat(s.fontSize)>=18.66);
  const threshold=large?3:4.5, measured=Math.min(...contrasts);
  rows.push({selector:n.id?'#'+n.id:n.tagName.toLowerCase()+'.'+[...n.classList].join('.'),text:text.slice(0,65),ratio:+measured.toFixed(2),threshold,color:s.color,bg:s.backgroundColor,image:s.backgroundImage,opacity,fail:measured+.02<threshold});
 });
 return {rows,overflow:document.documentElement.scrollWidth>innerWidth+2,width:innerWidth,scrollWidth:document.documentElement.scrollWidth};
}'''

async def interaction_cases(page, palette):
    """Real dialogs/controls, read-only paint; no event handlers from apps run."""
    checks=[]
    for app,view,action in [
        ('ecai','personalities',"""() => {
          const d=document.getElementById('personalityCheckout'); d.showModal();
          document.getElementById('personalityCheckoutStatus').textContent='Invoice unavailable · fixture';
          document.getElementById('personalityCheckoutStatus').dataset.error='true';
          document.getElementById('personalityPayment').hidden=false;
          document.getElementById('personalityInvoiceArea').hidden=false;
          document.getElementById('personalityOrderState').textContent='Paid';
          document.getElementById('personalityOrderState').dataset.status='paid';
          document.getElementById('personalityOrderAmount').textContent='21,000 sats';
        }"""),
        ('ecai','chat',"() => document.getElementById('chatSearchDialog').showModal()"),
        ('ecai','code',"""() => {
          const m=document.getElementById('login-modal');m.classList.add('is-open');
          m.setAttribute('aria-hidden','false');
        }"""),
        ('damage','wallet',"""() => {
          document.querySelector('.wallet-primary-button').focus();
          const qr=document.querySelector('#qrcode-damage');
          qr.innerHTML='<svg viewBox="0 0 32 32"><rect fill="#000" x="4" y="4" width="8" height="8"/></svg>';
        }"""),
        ('damage','billing',"""() => {
          const n=document.getElementById('billing-notice');n.hidden=false;
          n.textContent='Delivery failed · fixture';n.classList.add('is-error');
        }"""),
        ('damage','theme-studio',"""() => {
          const n=document.getElementById('notice');n.dataset.error='true';
          n.textContent='Package not available · fixture';
        }""")]:
        await page.set_content(document(app,view,palette));await page.evaluate(FIXTURE_JS,[app,view]);await page.evaluate(action)
        await page.wait_for_timeout(100)
        audit=await page.evaluate(AUDIT_JS)
        checks.append(dict(app=app,view=view,palette=palette,state='dialog/error/focus',checked=len(audit['rows']),failures=[r for r in audit['rows'] if r['fail']],overflow=audit['overflow']))
        if app=='damage' and view=='wallet':
            assert await page.locator('#qrcode-damage svg').evaluate("n=>getComputedStyle(n).backgroundColor")=='rgb(255, 255, 255)', 'QR quiet zone recoloured'
            assert await page.locator('.wallet-primary-button').first.evaluate("n=>getComputedStyle(n).outlineStyle")!='none', 'Focus not visible'
        if app=='ecai' and view=='code':
            assert await page.locator('.code-toggle').first.evaluate("n=>getComputedStyle(n).flexDirection")=='row', 'Stacked checkbox'
    return checks

async def bop_loader_cases(browser):
    """Mock only the read-only CSS endpoint; do not execute payment scripts."""
    script=(ROOT/'apps/bop/priv/assets/js/theme.js').read_text()
    for available in (True,False):
        page=await browser.new_page()
        async def route_handler(route):
            if route.request.url.endswith('/api/themes/css?app=bop'):
                if available:await route.fulfill(content_type='text/css',body=palette_css('bop','forest'))
                else:await route.fulfill(status=503,body='Unavailable')
            else:await route.fulfill(content_type='text/html',body='<html><head></head><body><button id="theme-button" onclick="toggleTheme()">Theme</button></body></html>')
        await page.route('**/*',route_handler)
        await page.set_content('<html><head><base href="http://127.0.0.1/"></head><body><button id="theme-button" onclick="toggleTheme()">Theme</button></body></html>')
        await page.add_script_tag(content=script)
        await page.wait_for_function("() => document.documentElement.dataset.nodeTheme === '"+('active' if available else 'unavailable')+"'")
        assert await page.locator('#theme-button').is_disabled()==available
        if not available:
            before=await page.locator('body').evaluate("n=>n.classList.contains('dark')")
            await page.click('#theme-button')
            after=await page.locator('body').evaluate("n=>n.classList.contains('dark')")
            assert before!=after, 'Standalone toggle lost'
        await page.close()

async def main():
    OUT.mkdir(parents=True,exist_ok=True)
    scenarios={'ecai':['code','math','chat','personalities','indexing','wikimedia','compute','evaluation','market-maker','keys','operations','overview','video','search','knowledge','marketplace','network','api','account','node-settings'],
               'damage':['execution','analytics','schedules','billing','wallet','settings','theme-studio','node-settings'],
               'nosternity':['feed','wallet','analytics'],'bop':['index','gym']}
    findings=[];results=[];interactions=[]
    async with async_playwright() as pw:
        browser=await pw.chromium.launch(executable_path=shutil.which('chromium'),args=['--no-sandbox'])
        page=await browser.new_page(viewport={'width':1440,'height':1000},device_scale_factor=1)
        await page.route('**/*',lambda route:route.abort())
        for width in map(int,os.environ.get('THEME_WIDTHS','1440,390').split(',')):
          await page.set_viewport_size({'width':width,'height':1000})
          for palette in os.environ.get('THEME_PALETTES',','.join(palettes())).split(','):
              for app,views in scenarios.items():
                  for view in views:
                      if os.environ.get('THEME_VERBOSE'):print(width,palette,app,view,flush=True)
                      await page.emulate_media(color_scheme='dark' if palette=='forest' else 'light',reduced_motion='reduce')
                      await page.set_content(document(app,view,palette))
                      await page.evaluate(FIXTURE_JS,[app,view])
                      await page.wait_for_timeout(70)
                      audit=await page.evaluate(AUDIT_JS)
                      failures=[r for r in audit['rows'] if r['fail']]
                      record=dict(app=app,view=view,palette=palette,width=width,checked=len(audit['rows']),failures=failures,overflow=audit['overflow'])
                      results.append(record)
                      if failures or audit['overflow']:findings.append(record)
                      if palette=='damage-dark' and view in ('code','math','chat','personalities','wallet','billing','feed','index'):
                          await page.screenshot(path=str(OUT/f'{app}-{view}-{palette}-{width}.png'),full_page=True)
              print(palette,'complete',flush=True)
        await page.set_viewport_size({'width':1440,'height':1000})
        for palette in palettes():
            interactions.extend(await interaction_cases(page,palette))
        await bop_loader_cases(browser)
        await browser.close()
    report={'css_source':'erlang export' if CSS_DIR else 'offline Python reference (Erlang not executed)',
            'scenarios':results,'interactions':interactions,'bop_loader':{'available':True,'unavailable':True},'failures':findings}
    (OUT/'contrast-report.json').write_text(json.dumps(report,indent=2))
    print('Scenarios',len(results),'failing',len(findings),'observations',sum(r['checked'] for r in results))
    for r in findings:
        print(r['app'],r['view'],r['palette'],r['width'],'overflow' if r['overflow'] else '', [(x['selector'],x['ratio'],x['text'][:30]) for x in r['failures'][:8]])
    state_failures=[r for r in interactions if r['failures'] or r['overflow']]
    print('Interaction cases',len(interactions),'failing',len(state_failures))
    for r in state_failures:print(r['app'],r['view'],r['palette'],r['failures'],r['overflow'])
    if findings or state_failures:raise SystemExit(1)

if __name__=='__main__':asyncio.run(main())
