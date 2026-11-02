#!/usr/bin/env python3
"""Real template/CSS/component with deterministic, mocked backend responses.

No live Erlang, authentication, IPFS, indexing, or payments are exercised.
Runs without network using the production module body (exports bound explicitly).
Run: python3 apps/ecai/test/test_knowledge_indexes_browser.py
Requires Python Playwright and Chromium. ECAI_SCREENSHOTS is optional.
"""
import asyncio
import os
import re
import shutil
from pathlib import Path
from playwright.async_api import async_playwright
from test_knowledge_workspace_browser import APP, console_html, theme_css, CONTRAST

BOOT = r'''
window.__epoch=0; window.__calls=[]; window.__plans=[]; window.__catalogPlan={}; window.__sourcePlan={};
window.__catalog=[
 {id:'shared',label:'Shared live index',kind:'shared',scope:'public',state:'ready',description:'Live verification records'},
 {id:'wikimedia',label:'Wikimedia',kind:'wikimedia',scope:'public',state:'unavailable',description:'Indexed articles'},
 {id:'public-ipfs',label:'Public IPFS',kind:'disk',scope:'public',state:'ready',description:'Published disk segments'},
 {id:'pool:mine',label:'My funded smoke test',kind:'funded',scope:'owner',state:'ready',description:'Accepted funded shards'}
];
const request=(path,options={})=>new Promise((resolve,reject)=>{
 const catalog=path.endsWith('/indexes'), source=path.endsWith('/source');
 const plan=structuredClone(catalog?__catalogPlan:source?__sourcePlan:(__plans.shift()||{}));
 const body=structuredClone(options.body||{}), listed=structuredClone(__catalog), epoch=__epoch;
 const call={path,body,epoch,aborted:false}; __calls.push(call);
 const ids=body.indexes??listed.map(i=>i.id), invalid=ids.some(id=>!listed.some(i=>i.id===id));
 let result;
 if(catalog) result={ok:true,indexes:listed,partial:Boolean(plan.partial)};
 else if(source) result={complete:true,text:'Retained source for '+body.source_ref.index,integrity:'verified_sha256',representation:'text'};
 else result={ok:true,selection:{mode:body.indexes?'selected':'all',indexes:ids},
   results:ids.filter(id=>id!=='wikimedia').map(id=>({doc_id:id+'-document',index:id,live:false,
     record:{title:'Redirect test / '+id,text:'Retained redirect test description.'},source_ref:{index:id,doc_id:id+'-document'}})),
   partial:ids.includes('wikimedia')||Boolean(plan.limited),
   backends:ids.map(id=>({id,state:id==='wikimedia'?'unavailable':plan.limited?'limited':'ready'}))};
 if(plan.noEcho) delete result.selection;
 const timer=setTimeout(()=>{
   if(plan.error) {const e=new Error(plan.error); reject(e);}
   else if(invalid&&!catalog&&!source){const e=new Error('Invalid index selection');e.body={error:'invalid_index_selection'};reject(e);}
   else resolve(result);
 },plan.delay??10);
 options.signal?.addEventListener('abort',()=>{call.aborted=true;
   if(!plan.ignoreAbort){clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));}
 });
});
document.querySelectorAll('[data-panel]').forEach(p=>{p.hidden=p.dataset.panel!=='search';p.classList.toggle('is-visible',!p.hidden)});
window.__search=initKnowledgeSearch({request,authEpoch:()=>__epoch,debounceMs:50,timeoutMs:1000});
'''

async def wait_text(page, selector, text):
    await page.wait_for_function("([s,t])=>document.querySelector(s)?.textContent.includes(t)", arg=[selector,text])

async def boot(page):
    markup = console_html(component=True)
    markup = re.sub(r'<script\b[^>]*>.*?</script>', '', markup, flags=re.S)
    markup = re.sub(r'<link\b[^>]*>', '', markup)
    await page.set_content(markup)
    for path in ['ecai-console.css','ecai-knowledge-workspace.css']:
        await page.add_style_tag(content=(APP/'priv/static/css'/path).read_text())
    await page.add_style_tag(content=theme_css('dark'))
    module = (APP/'priv/static/js/ecai-knowledge-search.js').read_text()
    module = re.sub(r'\bexport (?=(?:async )?(?:function|const|let|class))', '', module)
    await page.add_script_tag(content='(()=>{\n'+module+'\nwindow.initKnowledgeSearch=initKnowledgeSearch;})();')
    await page.add_script_tag(content=BOOT)
    await wait_text(page,'#searchIndexStatus','4 indexes listed')

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path=os.getenv('CHROMIUM_EXECUTABLE') or shutil.which('chromium'),
            headless=True,args=['--no-sandbox'])
        page = await browser.new_page(viewport={'width':1440,'height':1040})
        errors=[]; page.on('pageerror',lambda e:errors.append(str(e)))
        try:
            await boot(page)
            # Keyboard-operated native accordion and initially checked all scope.
            summary=page.locator('#searchIndexes > summary')
            await summary.focus(); await page.keyboard.press('Enter')
            assert await page.locator('#searchIndexes').get_attribute('open') is not None
            assert await page.locator('#searchIndexChoices input:checked').count()==4
            q=page.locator('#searchQuery'); await q.fill('redire'); await q.press('Enter')
            await wait_text(page,'#searchStatus','3 results')
            assert await page.locator('#searchWarning').is_visible()
            assert await page.evaluate("!Object.hasOwn(__calls.find(c=>c.path.endsWith('/search')).body,'indexes')")
            # Excluding a down index removes its warning, without hiding real hits.
            await page.locator('#searchIndexChoices input[value="wikimedia"]').uncheck()
            await wait_text(page,'#searchStatus','3 selected indexes')
            assert not await page.locator('#searchWarning').is_visible()
            assert await page.evaluate("__calls.filter(c=>c.path.endsWith('/search')).at(-1).body.indexes") == ['pool:mine','public-ipfs','shared']
            # Empty selection pauses, does not default back to all or retain hits.
            await page.locator('#searchIndexNone').click()
            await wait_text(page,'#searchStatus','No indexes selected')
            assert await page.locator('.knowledge-result').count()==0
            before=await page.evaluate("__calls.filter(c=>c.path.endsWith('/search')).length")
            await q.fill('test'); await q.press('Enter'); await page.wait_for_timeout(100)
            assert await page.evaluate("__calls.filter(c=>c.path.endsWith('/search')).length")==before
            await page.locator('#searchIndexChoices input[value="shared"]').check()
            await wait_text(page,'#searchStatus','1 result')
            assert 'shared' in await page.locator('.knowledge-result-title').inner_text()
            # A backend deployment that ignores indexes is rejected by the UI.
            await page.evaluate('__plans.push({noEcho:true})')
            await q.press('Enter'); await wait_text(page,'#searchStatus','server did not confirm')
            # Late response from old scope must never replace the new scope.
            await page.evaluate('__plans.push({delay:350,ignoreAbort:true})')
            await q.fill('race'); await q.press('Enter')
            await page.wait_for_function("__calls.some(c=>c.body.q==='race')")
            await page.locator('#searchIndexChoices input[value="shared"]').uncheck()
            await page.locator('#searchIndexChoices input[value="public-ipfs"]').check()
            await wait_text(page,'.knowledge-result-title','public-ipfs')
            await page.wait_for_timeout(450)
            assert 'public-ipfs' in await page.locator('.knowledge-result-title').inner_text()
            assert await page.evaluate("__calls.find(c=>c.body.q==='race'&&c.body.indexes[0]==='shared').aborted")
            # Scope changes cancel source retrieval, even when it ignores abort.
            await page.evaluate('__sourcePlan={delay:300,ignoreAbort:true}')
            await page.locator('.knowledge-result-actions button').click()
            await page.locator('#searchIndexNone').click()
            await page.wait_for_timeout(400)
            assert await page.locator('.knowledge-source').count()==0
            # Selected IDs survive failed and incomplete catalogs, never widening.
            await page.locator('#searchIndexChoices input[value="public-ipfs"]').check()
            await wait_text(page,'#searchStatus','1 result')
            await page.evaluate('__catalogPlan={error:"offline"}')
            await page.locator('#searchIndexRefresh').click()
            await wait_text(page,'#searchIndexStatus','selection has not changed')
            assert await page.locator('#searchIndexChoices input:checked').count()==1
            # A vanished selected ID remains visible so the user can unselect it.
            await page.evaluate('__catalogPlan={};__catalog=__catalog.filter(i=>i.id!=="public-ipfs")')
            await page.locator('#searchIndexRefresh').click()
            await wait_text(page,'#searchIndexChoices','No longer listed')
            assert await page.locator('#searchIndexChoices input[value="public-ipfs"]').is_checked()
            await q.press('Enter')
            await wait_text(page,'#searchResults','no longer accessible')
            assert await page.locator('.knowledge-result').count()==0
            # All resets explicitly to omission, including newly published IDs.
            await page.evaluate('__catalog.push({id:"disk-new",label:"New disk",kind:"disk",scope:"public",state:"ready"})')
            await page.locator('#searchIndexRefresh').click(); await wait_text(page,'#searchIndexChoices','New disk')
            await page.locator('#searchIndexAll').click(); await wait_text(page,'#searchStatus','3 results')
            assert await page.evaluate("!Object.hasOwn(__calls.filter(c=>c.path.endsWith('/search')).at(-1).body,'indexes')")
            # Late catalog responses cannot restore the previous owner's entries.
            await page.evaluate('__catalogPlan={delay:350,ignoreAbort:true}')
            await page.locator('#searchIndexRefresh').click()
            await page.evaluate("__epoch++;__catalogPlan={};__catalog=__catalog.filter(i=>i.scope!=='owner');document.dispatchEvent(new Event('ecai:identity-changed'))")
            await page.wait_for_timeout(500)
            assert await page.locator('#searchIndexChoices input[value="pool:mine"]').count()==0
            assert await q.input_value()==''
            assert await page.locator('#searchIndexSummary').inner_text()=='All indexes'
            assert await page.locator('.knowledge-result').count()==0
            # Limited coverage must not incorrectly claim services are unavailable.
            await page.locator('#searchIndexNone').click()
            await page.locator('#searchIndexChoices input[value="shared"]').check()
            await page.evaluate('__plans.push({limited:true})')
            await q.fill('test'); await q.press('Enter')
            await wait_text(page,'#searchWarning','Search limits were reached')
            # Untrusted display metadata must remain text, not HTML.
            await page.evaluate('__catalog[0].label="<img src=x onerror=window.__xss=1>"')
            await page.locator('#searchIndexRefresh').click(); await wait_text(page,'#searchIndexChoices','<img')
            assert await page.locator('#searchIndexChoices img').count()==0
            assert await page.evaluate('window.__xss||0')==0
            await page.evaluate('__catalog[0].label="Shared live index"')
            await page.locator('#searchIndexRefresh').click(); await wait_text(page,'#searchIndexChoices','Shared live index')
            # Three themes; real rendered contrast, 18px checkboxes, no overflow.
            out = Path(os.environ['ECAI_SCREENSHOTS']) if os.getenv('ECAI_SCREENSHOTS') else None
            if out: out.mkdir(parents=True,exist_ok=True)
            for palette in ['dark','forest','violet']:
                await page.add_style_tag(content=theme_css(palette))
                for width in [1440,390]:
                    await page.set_viewport_size({'width':width,'height':1040 if width>400 else 844})
                    for selector in ['.knowledge-index-copy strong','.knowledge-index-description','.knowledge-index-state','#searchIndexSummary','#searchIndexStatus']:
                        result=await page.evaluate(CONTRAST,selector)
                        assert result['ratio']>=4.5,(palette,width,selector,result)
                    size=await page.locator('#searchIndexChoices input').first.bounding_box()
                    assert size['width']==18 and size['height']==18,size
                    overflow=await page.evaluate('document.documentElement.scrollWidth-document.documentElement.clientWidth')
                    assert overflow<=1,(palette,width,overflow)
                    if out:
                        await page.evaluate('window.scrollTo(0,0)')
                        await page.screenshot(path=str(out/f'index-selection-{palette}-{width}.png'),full_page=True)
            assert not errors, errors
            print('PASS: all/subset/none payloads, backend echo guard, old-scope request/source cancellation, stale catalog and identity isolation, catalog failures/removal, late additions, partial/limited warnings, text-only rendering, keyboard accordion, three palettes, desktop/mobile contrast and overflow')
        finally:
            await browser.close()

if __name__=='__main__': asyncio.run(main())
