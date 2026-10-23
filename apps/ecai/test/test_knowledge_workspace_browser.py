#!/usr/bin/env python3
"""Chromium regressions for knowledge search + sample UI.

Uses the actual console template, search module, sample module and Quick Index JS.
Authentication, unrelated feature initializers and ALL backend replies are test
fixtures. No live indexing, IPFS, chain, payments or external network is exercised.

Run: python3 apps/ecai/test/test_knowledge_workspace_browser.py
Requires Playwright + Chromium (system chromium is accepted).
ECAI_OFFLINE_BROWSER=1 executes identical module bodies with explicitly bound
imports and inlined local CSS when URL navigation is unavailable. This mode
does not test the browser ESM loader or a live HTTP server.
"""
import asyncio
import base64
from types import SimpleNamespace
import hashlib
import html
import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
ORIGIN = "http://127.0.0.1:8765"
OFFLINE = os.environ.get("ECAI_OFFLINE_BROWSER") == "1"
OUT = Path(os.environ.get("ECAI_SCREENSHOTS", tempfile.gettempdir()))
PALETTES = {
    "dark": ("#0e1520", "#182535", "#e6edf7", "#9daec3", "#9dd576", "#344358"),
    "forest": ("#f5f8f0", "#ffffff", "#20352c", "#66796b", "#497a4a", "#dce5d6"),
    "violet": ("#141021", "#211a33", "#f1e9ff", "#b7a9d0", "#bc98ff", "#433758"),
}


def luminance(color):
    def linear(v):
        v /= 255
        return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4
    return sum(c * linear(int(color[i:i + 2], 16)) for i, c in ((1, .2126), (3, .7152), (5, .0722)))


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + .05) / (min(la, lb) + .05)


def contrast_text(bg):
    return "#000000" if ratio("#000000", bg) >= ratio("#ffffff", bg) else "#ffffff"


def readable(fg, bg):
    return fg if ratio(fg, bg) >= 4.5 else contrast_text(bg)


def semantic(dark, light, background):
    return dark if ratio(dark, background) >= 4.5 else readable(light, background)


def theme_css(name):
    """Mock the generated stylesheet; Erlang output itself has separate EUnit tests."""
    bg, surface, ink, muted, accent, border = PALETTES[name]
    ink, muted = readable(ink, surface), readable(muted, surface)
    values = dict(canvas=bg, paper=surface, ink=ink, text=ink, muted=muted,
                  background=bg, surface=surface, line=border, border=border, navy=surface,
                  blue=accent, accent=accent)
    values.update({"damage-bg": bg, "damage-surface": surface, "damage-text": ink,
                   "blue-strong": accent, "on-accent": contrast_text(accent),
                   "link": readable(accent, surface), "focus": readable(accent, surface),
                   "nav-ink": ink, "nav-muted": muted, "border-strong": muted,
                   "surface-2": f"color-mix(in srgb,{surface} 94%,{ink})",
                   "accent-soft": f"color-mix(in srgb,{accent} 12%,{surface})",
                   "nav-active-bg": f"color-mix(in srgb,{accent} 12%,{surface})",
                   "sky": f"color-mix(in srgb,{accent} 12%,{surface})",
                   "danger": semantic("#b4324e", "#ff9eae", surface), "success": semantic("#21805d", "#91d99c", surface),
                   "warning": semantic("#84621d", "#ffd392", surface),
                   "ecai-color-scheme": "dark" if luminance(surface) < .179 else "light"})
    return ":root,body{" + "".join(f"--{k}:{v};" for k, v in values.items()) + "}\n.console-topbar{background:var(--paper)}"


COMPONENT = r'''
import {initKnowledgeSearch} from '/static/js/ecai-knowledge-search.js';
window.__epoch=0; window.__calls=[]; window.__plans={}; window.__sourcePlan={};
const response=(q)=>({results:[{doc_id:'damage-analytics:'+ 'Q'.repeat(90),
  preview:'Opaque preview',score:12.322,index:'shared',live:q==='live',source_ref:{id:q},
  record:{title:q==='unsafe'?'<img src=x onerror=window.__xss=1>':q+' — result',
    description:'A readable excerpt about '+q+'. Account ak_'+'a'.repeat(50)}}],
  partial:q==='partial',backends:{shared:'available',other:q==='partial'?'unavailable':'available'}});
const request=(path,options)=>new Promise((resolve,reject)=>{
  if(path.endsWith('/indexes')) {resolve({indexes:[{id:'shared',kind:'shared',scope:'public',state:'ready'}]});return;}
  const q=options.body.q, source=path.endsWith('/source');
  const plan=source?window.__sourcePlan:(window.__plans[q]||{});
  const call={path,q,aborted:false};window.__calls.push(call);
  const timer=setTimeout(()=>{
    if(plan.error) reject(new Error(plan.error));
    else resolve(plan.data || (source?{complete:true,text:'Retained <script>window.__xss=1</script> source',integrity:'verified',representation:'text'}:response(q)));
  },plan.delay??5);
  options.signal.addEventListener('abort',()=>{call.aborted=true;
    if(!plan.ignoreAbort){clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));}
  });
});
document.querySelectorAll('[data-panel]').forEach(p=>{p.hidden=p.dataset.panel!=='search';p.classList.toggle('is-visible',!p.hidden)});
window.__search=initKnowledgeSearch({request,authEpoch:()=>window.__epoch,
  debounceMs:300,refreshMs:180,timeoutMs:Number(new URL(location.href).searchParams.get('timeout')||30000)});
window.__ready=true;
'''


def console_html(component=False):
    page = (APP / "priv/templates/ui/dashboard/ecai_console.mustache").read_text()
    ctx = {"brand_name": "ECAI", "brand_tagline": "INTELLIGENCE FABRIC", "node_version": "UI regression"}
    sections = re.compile(r"{{([#^])\s*(\w+)\s*}}((?:(?!{{[#^]).)*?){{/\s*\2\s*}}", re.S)
    while sections.search(page):
        page = sections.sub(lambda m: m[3] if bool(ctx.get(m[2])) == (m[1] == "#") else "", page)
    page = re.sub(r"{{{.*?}}}", "", page)
    page = re.sub(r"{{\s*(\w+)\s*}}", lambda m: html.escape(str(ctx.get(m[1], ""))), page)
    if component:
        page = re.sub(r"<script\b[^>]*>.*?</script>", "", page, flags=re.S)
        page = page.replace("</body>", '<script type="module" src="/test-component.js"></script></body>')
    return page


STUB_AUTH = '''
export const TokenManager={session:()=>window.__session,getToken:()=>window.__session?.access_token||'',
 getAddress:()=>window.__session?.address||'',refreshSession:async()=>window.__session,
 logout:()=>{window.__session=null;document.dispatchEvent(new Event('auth:changed'))}};
export async function logoutActiveSession(){TokenManager.logout()}
'''
INIT_STUB = "export function NAME(){return new Proxy({}, {get:()=>()=>{}})}"
INITIALIZERS = {"ecai-model-internals.js": "initModelInternals", "ecai-personalities.js": "initPersonalities",
                "ecai-eval.js": "initEvaluation", "ecai-math-paths.js": "initMathPaths",
                "ecai-video.js": "initVideoStudio", "ecai-market-maker.js": "initMarketMaker"}


class Backend:
    def __init__(self):
        self.theme = "dark"
        self.calls = []
        self.jobs = []
        self.sample_error = False
        self.sample = (APP / "priv/static/samples/knowledge-smoke.jsonl").read_bytes()
        self.sha = hashlib.sha256(self.sample).hexdigest()

    async def route(self, route):
        req = route.request
        url = urlsplit(req.url)
        path = url.path
        if url.netloc != urlsplit(ORIGIN).netloc:
            return await route.abort()
        if path == "/":
            return await route.fulfill(content_type="text/html", body=console_html("component" in parse_qs(url.query)))
        if path == "/test-component.js":
            return await route.fulfill(content_type="text/javascript", body=COMPONENT)
        if path == "/api/themes/css":
            return await route.fulfill(content_type="text/css", body=theme_css(self.theme))
        if path == "/ecai/auth-assets/js/wallet-switcher.js":
            return await route.fulfill(content_type="text/javascript", body=STUB_AUTH)
        if path == "/ecai/auth-assets/js/auth-ui.js":
            return await route.fulfill(content_type="text/javascript", body="export function initAuthUI(){window.DamageAuth={open:()=>{},status:()=>{}}}")
        if path.startswith("/ecai/auth-assets/"):
            return await route.fulfill(content_type="text/css" if path.endswith(".css") else "text/javascript", body="")
        if path.startswith("/static/"):
            file = APP / "priv/static" / path.removeprefix("/static/")
            if file.name in INITIALIZERS:
                return await route.fulfill(content_type="text/javascript", body=INIT_STUB.replace("NAME", INITIALIZERS[file.name]))
            if file.suffix == ".js" and file.name not in ("ecai-console.js", "ecai-knowledge-search.js", "ecai-index-samples.js", "ecai-quick-index.js"):
                return await route.fulfill(content_type="text/javascript", body="")
            if file.is_file():
                mime = {".css": "text/css", ".js": "text/javascript", ".jsonl": "application/x-ndjson"}.get(file.suffix, "application/octet-stream")
                return await route.fulfill(content_type=mime, body=file.read_bytes())
            return await route.fulfill(status=404, body="Missing fixture asset")
        self.calls.append((req.method, path, req.headers, req.post_data_buffer))
        data = {"ok": True}
        if path == "/ecai/auth/session":
            data = {"authenticated": True, "public_key": "ak_test", "node_admin": False, "code_admin": False}
        elif path == "/ecai/chat":
            data = {"status": "ok"}
        elif path == "/ecai/index-jobs/status":
            data = {"status": {"running": 0, "queued": 0, "max_concurrency": 1}}
        elif path == "/ecai/index-jobs/presets":
            data = {"presets": [
                {"id": "laptop-smoke", "label": "Laptop smoke test (3 records)", "project": "enwiki", "description": "Bundled four-record Wikimedia fixture; selects the top three without external downloads."},
                {"id": "enwiki", "label": "English Wikipedia", "project": "enwiki", "description": "English-language articles ranked by readership."}]}
        elif path == "/ecai/index-jobs":
            data = {"jobs": self.jobs}
        elif path == "/ecai/quick-index/inspect":
            assert req.post_data_buffer == self.sample, "Inspect must receive the real sample bytes"
            data = {"ok": True, "analysis": {"sha256": self.sha, "format": "jsonl", "label": "JSON Lines", "indexable": True,
                    "size_bytes": len(self.sample), "records_estimate": 3, "line_count": 3, "structure": "3 JSON objects", "pipeline": "IPFS → searchable disk"}}
        elif path == "/ecai/quick-index":
            assert req.post_data_buffer == self.sample
            assert req.headers.get("x-ecai-expected-sha256") == self.sha
            assert req.headers.get("idempotency-key")
            job = self.job("quick-sample", "ipfs_cid")
            self.jobs = [job]
            data = {"ok": True, "job": job, "cid": "bafy-test-fixture"}
        elif path == "/ecai/index-jobs/presets/laptop-smoke":
            assert req.headers.get("idempotency-key")
            job = self.job("wiki-sample", "wikimedia_visibility")
            self.jobs.append(job)
            data = {"ok": True, "job": job}
        elif path == "/ecai/wikimedia/sample":
            if self.sample_error:
                return await route.fulfill(status=503, json={"ok": False, "error": ["wikimedia_fixture_catalog_unavailable", "not_running"]})
            data = {"ok": True, "sample": {"ready": True}}
        elif path.endswith("/artifact"):
            data = {"artifact": {"status": "ready"}}
        elif path.startswith("/ecai/index-jobs/") and path.endswith("/events"):
            return await route.fulfill(content_type="text/event-stream", body="event: snapshot\ndata: " + json.dumps({"job": self.jobs[-1]}) + "\n\n")
        elif path.startswith("/ecai/index-jobs/"):
            data = {"job": next((j for j in self.jobs if j['id'] == path.split('/')[-1]), self.job("sample", "ipfs_cid"))}
        elif path == "/ecai/knowledge/search":
            q = json.loads(req.post_data)["q"]
            record = json.loads(self.sample.splitlines()[0])
            if q == "Quantum mechanics":
                record = {"title": "Quantum mechanics", "text": "Quantum mechanics is the theory of matter and energy at microscopic scales."}
            data = {"results": [{"doc_id": record.get("id", "wiki-1"), "record": record, "index": "shared", "source_ref": {"id": "test"}, "live": False}], "partial": False}
        elif path == "/ecai/knowledge/indexes":
            data = {"indexes": [{"id": "shared", "kind": "shared", "scope": "public", "state": "ready"}]}
        elif path == "/ecai/knowledge/source":
            data = {"complete": True, "integrity": "verified", "text": self.sample.decode(), "representation": "JSONL"}
        return await route.fulfill(json=data)

    @staticmethod
    def job(name, kind):
        return {"id": name, "state": "completed", "spec": {"kind": kind, "source": {"project": "enwiki"}, "target": {}},
                "event_seq": 2, "progress": {"percent": 100, "phase": "completed", "completed": 3, "total": 3}}


async def load_page(page, backend, *, component=False, view="", timeout=30000):
    """Offline mode uses no URL navigation or external resources.

    Identical module bodies run in isolated functions; static ESM imports bind
    explicitly to the same exports. fetch and EventSource are test doubles.
    Use normal mode to exercise the browser's actual ESM loader as well.
    """
    if not OFFLINE:
        query = f"?component=1&timeout={timeout}" if component else ""
        await page.goto(ORIGIN + "/" + query + ("#" + view if view else ""))
        return
    source = console_html()
    css = []
    for href in re.findall(r'<link[^>]+href="([^"]+)"', source):
        path = urlsplit(href).path
        if path.startswith("/static/") and path.endswith(".css"):
            file = APP / "priv/static" / path.removeprefix("/static/")
            if file.is_file(): css.append(file.read_text())
        elif path == "/api/themes/css":
            css.append(theme_css(backend.theme))
    source = re.sub(r'<script\b[^>]*>.*?</script>', '', source, flags=re.S)
    source = re.sub(r'<link\b[^>]*>', '', source)
    await page.set_content(source)
    for style in css: await page.add_style_tag(content=style)
    await page.evaluate("view=>{location.hash=view;window.__session={mode:'custodial',address:'ak_test',email:'operator@example.test',access_token:'test-only'}}", view)

    async def fake_http(_source, request):
        # Reuse all normal-mode route assertions, including exact file bytes.
        class Reply:
            result = None
            async def fulfill(self, status=200, content_type=None, body=None, json=None):
                payload = globals()["json"].dumps(json).encode() if json is not None else body
                if isinstance(payload, str): payload = payload.encode()
                self.result = dict(status=status, contentType=content_type or "application/json",
                                   body=base64.b64encode(payload or b"").decode())
            async def abort(self):
                self.result = dict(status=404, contentType="text/plain", body="")
        reply = Reply()
        raw = base64.b64decode(request.get("body") or "")
        reply.request = SimpleNamespace(url=ORIGIN + request["path"], method=request["method"],
            headers=request["headers"], post_data_buffer=raw, post_data=raw.decode("utf-8", errors="replace"))
        await backend.route(reply)
        return reply.result
    await page.expose_binding("__fakeHttp", fake_http)
    await page.evaluate(r"""()=>{
      window.fetch=async (path, options={})=>{
        const signal=options.signal;if(signal?.aborted)throw new DOMException('Aborted','AbortError');
        const raw=options.body==null?new Uint8Array():new Uint8Array(await new Blob([options.body]).arrayBuffer());
        const headers=Object.fromEntries(new Headers(options.headers||{}));
        const result=await window.__fakeHttp({path:String(path),method:options.method||'GET',headers,
          body:btoa(String.fromCharCode(...raw))});
        if(signal?.aborted)throw new DOMException('Aborted','AbortError');
        return new Response(Uint8Array.from(atob(result.body),c=>c.charCodeAt(0)),{status:result.status,
          headers:{'content-type':result.contentType}});
      };
      window.EventSource=class {static OPEN=1;readyState=1;addEventListener(){}close(){}};
    }""")
    async def module(body, exports=()):
        body = re.sub(r'^import\s+.*?;\s*$', '', body, flags=re.M)
        body = re.sub(r'\bexport (?=(?:async )?(?:function|const|let|class))', '', body)
        await page.add_script_tag(content="(()=>{\n" +
            f"const location=new Proxy(window.location,{{get:(t,k)=>k==='origin'?'{ORIGIN}':typeof t[k]==='function'?t[k].bind(t):t[k]}});\n" + body + "\n" +
            "".join(f"window.{name}={name};" for name in exports) + "\n})();")
    await module((APP / "priv/static/js/ecai-knowledge-search.js").read_text(), ["initKnowledgeSearch"])
    if component:
        body = COMPONENT.replace("Number(new URL(location.href).searchParams.get('timeout')||30000)", str(timeout))
        await module(body)
        return
    await module(STUB_AUTH, ["TokenManager", "logoutActiveSession"])
    await page.add_script_tag(content="window.initAuthUI=()=>{window.DamageAuth={open:()=>{},status:()=>{}}};")
    for initializer in INITIALIZERS.values():
        await module(INIT_STUB.replace("NAME", initializer), [initializer])
    await module((APP / "priv/static/js/ecai-index-samples.js").read_text(), ["initIndexSamples"])
    await module((APP / "priv/static/js/ecai-quick-index.js").read_text())
    await module((APP / "priv/static/js/ecai-console.js").read_text())


CONTRAST = r'''(selector)=>{
 const e=document.querySelector(selector);if(!e)throw Error('Missing '+selector);
 const cv=document.createElement('canvas');cv.width=cv.height=1;const cx=cv.getContext('2d',{willReadFrequently:true});
 function rgba(c){cx.clearRect(0,0,1,1);cx.fillStyle=c;cx.fillRect(0,0,1,1);return [...cx.getImageData(0,0,1,1).data]}
 function over(a,b){let x=a[3]/255;return [0,1,2].map(i=>a[i]*x+b[i]*(1-x)).concat(255)}
 let chain=[],n=e;while(n){chain.unshift(n);n=n.parentElement}let bg=[255,255,255,255];
 for(const n of chain)bg=over(rgba(getComputedStyle(n).backgroundColor),bg);
 const c=getComputedStyle(e), fg=over(rgba(c.color),bg);
 const L=a=>a.slice(0,3).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4}).reduce((a,v,i)=>a+v*[.2126,.7152,.0722][i],0);
 const f=L(fg),b=L(bg);return {ratio:(Math.max(f,b)+.05)/(Math.min(f,b)+.05),fg:c.color,bg:getComputedStyle(e).backgroundColor};
}'''


async def expect_text(page, selector, text):
    await page.wait_for_function("([s,t])=>document.querySelector(s)?.textContent.includes(t)", arg=[selector, text])


async def component_tests(browser):
    backend = Backend()
    page = await browser.new_page(viewport={"width": 1360, "height": 960})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    await page.route("**/*", backend.route)
    await load_page(page, backend, component=True)
    await page.wait_for_function("window.__ready")
    query = page.locator("#searchQuery")
    await query.fill("t")
    await page.wait_for_timeout(80)
    await query.fill("test")
    await page.wait_for_timeout(80)
    await query.fill("testing")
    assert await page.evaluate("__calls.length") == 0
    await expect_text(page, ".knowledge-result-title", "testing")
    assert await page.evaluate("__calls.length") == 1
    assert await page.locator(".knowledge-result-snippet mark").count() > 0
    # A slow old request deliberately ignores abort to exercise sequence guards.
    await page.evaluate("__plans['race-old']={delay:800,ignoreAbort:true}")
    await query.fill("race-old"); await query.press("Enter")
    await page.wait_for_function("__calls.some(c=>c.q==='race-old')")
    await query.fill("race-new"); await query.press("Enter")
    await expect_text(page, ".knowledge-result-title", "race-new")
    await page.wait_for_timeout(850)
    assert "race-new" in await page.locator(".knowledge-result-title").inner_text()
    assert await page.evaluate("__calls.find(c=>c.q==='race-old').aborted")
    # Empty input cancels requests and clears results and diagnostics.
    await query.fill("race-old"); await query.press("Enter")
    await page.locator("#searchClear").click()
    await page.wait_for_timeout(850)
    assert await page.locator(".knowledge-result").count() == 0
    # IME changes should cause exactly one committed query, no intermediate search.
    before = await page.evaluate("__calls.length")
    await query.dispatch_event("compositionstart")
    await query.fill("日本語")
    await page.wait_for_timeout(350)
    assert await page.evaluate("__calls.length") == before
    await query.dispatch_event("compositionend")
    await expect_text(page, ".knowledge-result-title", "日本語")
    assert await page.evaluate("__calls.length") == before + 1
    await query.fill("partial"); await query.press("Enter")
    await expect_text(page, "#searchWarning", "unavailable")
    assert await page.locator("#searchWarning").is_visible()
    await page.evaluate("__plans.error={error:'Backend unavailable'}")
    await query.fill("error"); await query.press("Enter")
    await expect_text(page, "#searchStatus", "Search failed")
    assert "partial" in await page.locator(".knowledge-result-title").inner_text()
    # Backend titles/source markup never executes or becomes an element.
    await query.fill("unsafe"); await query.press("Enter")
    await expect_text(page, ".knowledge-result-title", "<img")
    assert await page.locator("#searchResults img").count() == 0
    await page.locator(".knowledge-result-actions button").click()
    await expect_text(page, ".knowledge-source pre", "<script>")
    assert await page.evaluate("window.__xss||0") == 0
    assert await page.locator(".knowledge-source").count() == 1
    await page.locator(".knowledge-result-actions button").click()
    assert await page.evaluate("__calls.filter(c=>c.path.endsWith('/source')).length") == 1
    # Cancel old identity data, including a retained-source request ignoring abort.
    await query.fill("private"); await query.press("Enter")
    await expect_text(page, ".knowledge-result-title", "private")
    await page.evaluate("__sourcePlan={delay:400,ignoreAbort:true}")
    await page.locator(".knowledge-result-actions button").click()
    await page.evaluate("__epoch++;document.dispatchEvent(new Event('ecai:identity-changed'))")
    await page.wait_for_timeout(450)
    assert await page.locator(".knowledge-source").count() == 0
    assert await query.input_value() == ""
    # Live polling pauses for open source/details and off-screen panels.
    await page.evaluate("__sourcePlan={}")
    await query.fill("live"); await query.press("Enter")
    await expect_text(page, ".knowledge-result-title", "live")
    await page.locator(".knowledge-technical summary").click()
    count = await page.evaluate("__calls.length")
    await page.wait_for_timeout(450)
    assert await page.evaluate("__calls.length") == count
    await page.locator(".knowledge-technical summary").click()
    await page.wait_for_function(f"__calls.length>{count}")
    await page.evaluate("__search.setVisible(false)")
    count = await page.evaluate("__calls.length")
    await page.wait_for_timeout(450)
    assert await page.evaluate("__calls.length") == count
    assert not errors, errors
    await page.close()
    # Request timeout restores the UI instead of leaving a permanent busy flag.
    page = await browser.new_page()
    await page.route("**/*", backend.route)
    await load_page(page, backend, component=True, timeout=40)
    await page.wait_for_function("window.__ready")
    await page.evaluate("__plans.slow={delay:300}")
    await page.locator("#searchQuery").fill("slow")
    await page.locator("#searchQuery").press("Enter")
    await expect_text(page, "#searchStatus", "timed out")
    assert await page.locator("#searchResults").get_attribute("aria-busy") == "false"
    await page.close()
    print("PASS: debounce, Enter, race guard, abort, clear, IME, partial/errors, XSS-safe rendering, source reuse, identity reset, polling pause and timeout")


async def integration_tests(browser):
    backend = Backend()
    page = await browser.new_page(viewport={"width": 1440, "height": 1100})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("dialog", lambda dialog: dialog.accept())
    await page.add_init_script("window.__session={mode:'custodial',address:'ak_test',email:'operator@example.test',access_token:'test-only'};")
    await page.route("**/*", backend.route)
    await load_page(page, backend, view="indexing")
    await page.locator("#indexSampleLoad").wait_for()
    await page.locator("#indexSampleLoad").click()
    await expect_text(page, "#quickIndexStatus", "ready to index")
    assert not any(p == "/ecai/quick-index" for _, p, _, _ in backend.calls), "Loading must not queue"
    await page.locator("#quickIndexQueue").click()
    await expect_text(page, "#quickIndexStatus", "Queued")
    await page.locator('.index-job-item[data-job-id="quick-sample"]').wait_for()
    assert sum(p == "/ecai/quick-index" for _, p, _, _ in backend.calls) == 1
    await page.locator('[data-sample-query="orbital orchard"]').click()
    await expect_text(page, ".knowledge-result-title", "Orbital orchard")
    await page.locator(".knowledge-result-actions button").click()
    await expect_text(page, ".knowledge-source pre", "Orbital orchard")
    await page.locator('[data-view="wikimedia"]').click()
    await page.locator("#wikiSampleCheck").click()
    await expect_text(page, "#wikiSampleStatus", "responded")
    backend.sample_error = True
    await page.locator("#wikiSampleCheck").click()
    await expect_text(page, "#wikiSampleStatus", "Restart ECAI")
    backend.sample_error = False
    await page.locator("#wikiSampleSelect").click()
    await expect_text(page, "#wikiSelectedCount", "1 selected")
    assert await page.locator("#wikiPresetChoices input:checked").count() == 1
    assert await page.locator("#wikiPresetChoices input:checked").get_attribute("aria-label") == "Select Laptop smoke test (3 records)"
    await page.locator("#wikiQueueSelected").click()
    await expect_text(page, "#wikiPickerStatus", "1/1")
    assert sum(p == "/ecai/index-jobs/presets/laptop-smoke" for _, p, _, _ in backend.calls) == 1
    # Check actual controls under the same token values as all bundled palettes.
    for palette in PALETTES:
        backend.theme = palette
        if OFFLINE:
            await page.add_style_tag(content=theme_css(palette))
        else:
            await page.reload()
        await page.locator('[data-view="search"]').click()
        await page.locator("#searchQuery").fill("orbital orchard")
        await expect_text(page, ".knowledge-result-title", "Orbital orchard")
        for view, selectors in {
            "search": [".knowledge-title-action", ".knowledge-result-snippet", "#searchQuery", ".knowledge-search-options label", "#searchStatus"],
            "indexing": ["#indexSampleTitle", ".index-samples > p", "#quickIndexTitle", "#quickIndexFileName", ".preset-card h3", ".preset-card p", ".sample-flow span", "#queueWorkers", "#quickIndexInspect", "#quickIndexQueue"],
            "wikimedia": ["#wikiSampleTitle", ".wiki-project-card-copy strong", ".wiki-project-description", ".wiki-project-card-copy small", "#wikiSelectedCount", "#wikiSampleSelect"],
        }.items():
            await page.locator(f'[data-view="{view}"]').click()
            await page.wait_for_timeout(80)
            for selector in selectors:
                scoped = f'[data-panel="{view}"] {selector}'
                r = await page.evaluate(CONTRAST, scoped)
                assert r["ratio"] >= 4.5, (palette, scoped, r)
            if view == "search":
                size = await page.locator("#searchLiveRefresh").bounding_box()
                assert 16 <= size['height'] <= 20 and 16 <= size['width'] <= 20, size
            if view == "wikimedia":
                size = await page.locator("#wikiPresetChoices input").first.bounding_box()
                assert 16 <= size['height'] <= 20, size
            await page.evaluate("window.scrollTo(0,0)")
            if palette in ("dark", "forest"):
                await page.screenshot(path=str(OUT / f"ecai-{view}-{palette}.png"), full_page=True)
            await page.set_viewport_size({"width": 390, "height": 844})
            await page.wait_for_timeout(80)
            overflow = await page.evaluate("document.documentElement.scrollWidth-document.documentElement.clientWidth")
            assert overflow <= 1, (palette, view, overflow)
            await page.set_viewport_size({"width": 1440, "height": 1100})
    assert not errors, errors
    await page.close()
    print("PASS: production console binding; real sample bytes → mocked inspect → explicit queue → history → search → retained source; smoke selection/errors; dark/forest/violet contrast and mobile layout")


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as p:
        executable = os.environ.get("CHROMIUM_EXECUTABLE") or shutil.which("chromium")
        browser = await p.chromium.launch(headless=True, executable_path=executable, args=["--no-sandbox"])
        try:
            await component_tests(browser)
            await integration_tests(browser)
        finally:
            await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
