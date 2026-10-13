#!/usr/bin/env python3
"""Static contract checks usable without Erlang, DamageBDD or Chromium."""
import re
import shutil
import subprocess
import unittest
from html.parser import HTMLParser
from pathlib import Path

APP = Path(__file__).resolve().parents[1]

class HtmlIds(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=set(); self.views=set()
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if attrs.get('id'):self.ids.add(attrs['id'])
        if attrs.get('data-view'):self.views.add(attrs['data-view'])

class VideoContract(unittest.TestCase):
    def test_dashboard_nav_and_fragment_mount(self):
        shell=(APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        panel=(APP/'priv/templates/ui/dashboard/ecai_video.mustache').read_text()
        dash=(APP/'src/ecai_dashboard.erl').read_text()
        parser=HtmlIds();parser.feed(shell)
        self.assertIn('video',parser.views)
        self.assertIn('data-panel="video"',shell)
        # Detect the production failure: the nav rendered but an absent
        # video_studio context variable omitted the entire interactive panel.
        self.assertNotIn('{{{video_studio}}}',shell)
        normalized = lambda s: "\n".join(line.strip() for line in s.strip().splitlines())
        self.assertIn(normalized(panel),normalized(shell))
        self.assertEqual(shell.count('data-panel="video"'),1)
        self.assertIn('videoRefresh',parser.ids)
        self.assertIn('videoProjectForm',parser.ids)
        self.assertIn('videoBackendForm',parser.ids)
        self.assertNotIn('video_studio => VideoHtml',dash)
        self.assertIn('ecai-video.css',shell)
        self.assertIn('data-go="video"',shell)

    def test_all_controller_ids_are_in_the_dashboard(self):
        page=(APP/'priv/templates/ui/dashboard/ecai_video.mustache').read_text()
        parser=HtmlIds();parser.feed(page)
        src=(APP/'priv/static/js/ecai-video.js').read_text()
        controller_ids=set(re.findall(r'\$\("(video[A-Z][A-Za-z0-9]+)"\)',src))
        controller_ids.update(re.findall(r'\bon\("(video[A-Z][A-Za-z0-9]+)"',src))
        self.assertEqual(set(),controller_ids-parser.ids)
        # Fail before release if a new event binding bypasses the mount guard.
        required = re.search(r'const requiredIds = \[(.*?)\];', src, re.S)
        self.assertIsNotNone(required)
        guarded_ids=set(re.findall(r'"(video[A-Z][A-Za-z0-9]+)"',required.group(1)))
        self.assertEqual(set(),controller_ids-guarded_ids)
        self.assertNotIn('localStorage',src)
        self.assertNotIn('sessionStorage',src)
        self.assertIn('URL.revokeObjectURL',src)
        self.assertIn('currentToken()',src)
        self.assertIn('Video Studio',page)
        self.assertIn('NFT metadata',page)

    def test_video_esm_syntax_and_cache_version(self):
        # Parsing as a CommonJS script can miss strict-mode grammar errors in browser ES modules.
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the video ESM syntax regression check")
        video = (APP/'priv/static/js/ecai-video.js').read_text()
        console = (APP/'priv/static/js/ecai-console.js').read_text()
        for module, script in (("ecai-video.js", video), ("ecai-console.js", console)):
            result = subprocess.run([node, "--input-type=module", "--check"],
                                    input=script, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, f"{module}: {result.stderr}")
        shell = (APP/'priv/templates/ui/dashboard/ecai_console.mustache').read_text()
        console_version = re.search(r'/static/js/ecai-console\.js\?v=([^"\s]+)', shell)
        video_version = re.search(r'/static/js/ecai-video\.js\?v=([^"\s]+)', console)
        self.assertIsNotNone(console_version)
        self.assertIsNotNone(video_version)
        self.assertEqual(console_version.group(1), video_version.group(1))

    def test_missing_fragment_degrades_without_throwing(self):
        # Minimal DOM simulation reproducing the customer's null binding error:
        # the video nav exists, but there is no data-panel="video" markup.
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the missing-fragment regression check")
        script = r'''
import {strict as assert} from 'node:assert';
import {readFileSync} from 'node:fs';
const source = readFileSync(process.env.ECAI_VIDEO_MODULE, 'utf8');
const {initVideoStudio} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const createElement = (name) => ({tagName:name.toUpperCase(),dataset:{},children:[],
  replaceChildren(...children){this.children=children;}});
const main = {append(panel){this.panel=panel;}};
globalThis.document = {querySelector:()=>null,
  getElementById:(id)=>id==='consoleMain'?main:null,createElement};
const errors=[];
const oldError=console.error;
console.error=(...args)=>errors.push(args);
try {
  const studio=initVideoStudio({request:async()=>({}),currentToken:()=>'',
    managedSession:()=>false,openLogin:()=>{},toast:()=>{}});
  assert.ok(main.panel, 'a visible fallback panel was not mounted');
  assert.equal(main.panel.dataset.panel,'video');
  assert.equal(main.panel.children[0].textContent,'Video Studio template unavailable');
  assert.equal(typeof studio.refresh,'function');
  studio.setVisible(true);
  studio.reset();
  studio.dispose();
  assert.ok(errors.length > 0, 'missing controls must be reported');
} finally {console.error=oldError;}
'''
        import os
        result = subprocess.run([node, "--input-type=module", "-"], input=script,
                                text=True, capture_output=True, check=False,
                                env={**os.environ, "ECAI_VIDEO_MODULE":str(APP/'priv/static/js/ecai-video.js')})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_router_and_authenticated_fixed_upstreams(self):
        app=(APP/'src/ecai_app.erl').read_text()
        gateway=(APP/'src/ecai_video_dashboard_http.erl').read_text()
        console=(APP/'priv/static/js/ecai-console.js').read_text()
        self.assertIn('ecai_video_dashboard_http,',app)
        self.assertIn('damage_auth:resolve_oauth(Token, #{})',gateway)
        self.assertIn('managed_session_required',gateway)
        self.assertIn('bridge_token(Secret, Principal, Timestamp, Method, Path)',gateway)
        self.assertIn('crypto:mac(hmac, sha256',gateway)
        self.assertIn('route(projects',gateway)
        self.assertIn('trail("/ecai/video/projects/:project/assets", upload, post)',gateway)
        self.assertIn('initVideoStudio',console)
        self.assertIn('case "video": await videoStudio?.refresh();',console)
        self.assertNotIn('ECAI_VIDEO_TOKEN',gateway)

if __name__ == '__main__':unittest.main(verbosity=2)
