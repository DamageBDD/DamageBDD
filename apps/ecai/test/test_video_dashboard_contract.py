#!/usr/bin/env python3
"""Static contract checks usable without Erlang, DamageBDD or Chromium."""
import re
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
        parser=HtmlIds();parser.feed(shell+panel)
        self.assertIn('video',parser.views)
        self.assertIn('data-panel="video"',panel)
        self.assertIn('{{{video_studio}}}',shell)
        self.assertIn('ecai_video.mustache',dash)
        self.assertIn('video_studio => VideoHtml',dash)
        self.assertIn('ecai-video.css',shell)
        self.assertIn('data-go="video"',shell)

    def test_all_controller_ids_are_in_the_dashboard(self):
        page=(APP/'priv/templates/ui/dashboard/ecai_video.mustache').read_text()
        parser=HtmlIds();parser.feed(page)
        src=(APP/'priv/static/js/ecai-video.js').read_text()
        missing=set(re.findall(r'\$\("(video[A-Z][A-Za-z0-9]+)"\)',src))-parser.ids
        self.assertEqual(set(),missing)
        self.assertNotIn('localStorage',src)
        self.assertNotIn('sessionStorage',src)
        self.assertIn('URL.revokeObjectURL',src)
        self.assertIn('currentToken()',src)
        self.assertIn('Video Studio',page)
        self.assertIn('NFT metadata',page)

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
