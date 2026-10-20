#!/usr/bin/env python3
"""Chromium tests of the production knowledge-search function block.

The DOM and request/auth helpers are isolated test doubles: this does not test
Cowboy, real authentication, Erlang retrieval, cloud, Lightning or NFT execution.
No network request or real account is used. Requires Playwright + Chromium.
"""
import asyncio
import json
import os
import shutil
from pathlib import Path
from playwright.async_api import async_playwright

APP = Path(__file__).resolve().parents[1]
HTML = '''<section data-panel="search"><form id="searchForm">
<input id="searchQuery" value="needle"><input id="searchLimit" value="5">
<input id="searchLiveRefresh" type="checkbox" checked></form>
<div id="searchResults"></div><div id="searchStatus"></div><pre id="searchProofs"></pre></section>'''
HELPERS = r'''
const state = {authEpoch: 0};
const $ = id => document.getElementById(id);
function element(tag, cls, text) {const e = document.createElement(tag); e.className=cls;
  if(text !== undefined) e.textContent=String(text); return e;}
function put(id, value) {$(id).textContent = typeof value === 'object' ? JSON.stringify(value) : value;}
function expectSuccess(data) {if(data.ok === false) throw Error('mock refusal'); return data;}
async function task(fn, status) {try{return await fn();}catch(e){if(status)put(status,e.message);}}
window.fixture = {calls: [], generation: 1, holdSearch: false, holdSource: false, release: null, token: null};
async function request(path, opts) {
  fixture.calls.push({path, opts, token:fixture.token});
  if((path.endsWith('/search') && fixture.holdSearch) || (path.endsWith('/source') && fixture.holdSource))
    await new Promise(resolve => fixture.release = resolve);
  if(path.endsWith('/source')) return {ok:true, complete:true, representation:'original_utf8_bytes',
    integrity:'verified_sha256', text:'FULL_SOURCE <img src=x onerror="window.INJECTED=true">'};
  return {ok:true, partial:false, ranking:'reciprocal_rank_fusion', backends:[],
    results:Array.from({length:fixture.generation}, (_,n)=>({doc_id:n+1,index:'public-ipfs',live:true,
      record:{text:'needle excerpt',source_retrieval:{complete:true}},
      source_ref:{index:'public-ipfs',doc_id:n+1,sha256:'a'.repeat(64)}}))};
}
'''

async def main():
    source=(APP/'priv/static/js/ecai-console.js').read_text()
    block='let knowledgeRefreshTimer'+source.split('let knowledgeRefreshTimer',1)[1].split('  function chatProject(',1)[0]
    async with async_playwright() as pw:
        executable=os.environ.get('CHROMIUM') or shutil.which('chromium')
        browser=await pw.chromium.launch(**({'executable_path':executable} if executable else {}),
            headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
        page=await browser.new_page()
        errors=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        await page.clock.install()
        await page.set_content(HTML)
        await page.add_script_tag(content=HELPERS+block+'\nwindow.runSearch=()=>search({preventDefault(){}});')
        await page.evaluate('runSearch()')
        assert await page.locator('.result-card').count()==1
        assert 'Live / partial build' in await page.locator('#searchResults').inner_text()
        print('PASS: production search renders a live result and source locator')
        await page.evaluate('fixture.generation=2')
        await page.clock.run_for(3100)
        assert await page.locator('.result-card').count()==2
        print('PASS: live refresh displays newly accepted mock results')
        await page.get_by_role('button',name='Retrieve source').first.click()
        await page.wait_for_function("document.querySelector('pre.code-display') !== null")
        assert 'FULL_SOURCE' in await page.locator('pre.code-display').inner_text()
        assert await page.locator('#searchResults img').count()==0
        assert not await page.evaluate('Boolean(window.INJECTED)')
        assert not await page.locator('#searchLiveRefresh').is_checked()
        assert await page.evaluate("fixture.calls.at(-1).opts.body.source_ref.sha256")=='a'*64
        print('PASS: source locator round-trip, exact display text, no HTML execution, refresh paused')
        await page.evaluate("state.authEpoch++; document.dispatchEvent(new CustomEvent('ecai:identity-changed'))")
        assert await page.locator('.result-card').count()==0
        await page.clock.run_for(4000)
        assert await page.locator('.result-card').count()==0
        print('PASS: identity change clears source/results and cancels refresh')
        await page.evaluate('fixture.holdSearch=true; void runSearch()')
        await page.wait_for_function('fixture.release !== null')
        await page.evaluate("state.authEpoch++; document.dispatchEvent(new CustomEvent('ecai:identity-changed')); fixture.release();fixture.release=null")
        await page.wait_for_function("document.getElementById('searchResults').children.length===0")
        await page.evaluate('fixture.holdSearch=false')
        await page.evaluate('runSearch()')
        assert await page.locator('.result-card').count()==2
        print('PASS: late search response cannot repaint a previous identity')
        await page.evaluate('fixture.holdSource=true')
        await page.get_by_role('button',name='Retrieve source').first.click()
        await page.wait_for_function('fixture.release !== null')
        await page.evaluate("state.authEpoch++; document.dispatchEvent(new CustomEvent('ecai:identity-changed')); fixture.release();fixture.release=null")
        assert await page.locator('#searchResults').inner_text()==''
        assert not errors,errors
        print('PASS: late source response cannot disclose content after identity change')
        await browser.close()
        print('6 browser scenarios passed; isolated helpers and backend responses are mocked.')

if __name__=='__main__': asyncio.run(main())
