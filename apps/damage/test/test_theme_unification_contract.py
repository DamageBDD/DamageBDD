#!/usr/bin/env python3
"""Static guard against new hardcoded first-party UI paint.
Run with Python unittest; requires tinycss2. No application/API side effects.
Fallback literals inside var(), intentionally independent artwork, QR quiet zones,
print styles and vendor grammars are not theme violations.
"""
from pathlib import Path
import re
import unittest
import tinycss2

ROOT = Path(__file__).resolve().parents[3]
EXEMPT = re.compile(r'qr|personality-(?:card-art|core)\b|brand-symbol\b|orbit-(?:core|ring)\b', re.I)
VENDORS = {'prism.css'}

def styles():
    for app, folder in [('damage','priv/static/css'),('ecai','priv/static/css'),
                        ('nosternity','priv/static/dashboard'),('bop','priv/assets/css'),
                        ('damage','priv/ui/ecai-market-maker')]:
        for p in (ROOT/'apps'/app/folder).glob('*.css'):
            if '.min.' not in p.name and p.name not in VENDORS:
                yield p

def literals(tokens):
    for t in tokens:
        if t.type == 'hash':
            yield t
        elif t.type == 'ident' and t.value.lower() in ('white','black','red','blue','green','purple','orange'):
            yield t
        elif t.type == 'function':
            if t.lower_name in ('rgb','rgba','hsl','hsla'):
                # Fully transparent endpoints have no independent palette.
                raw = tinycss2.serialize(t.arguments)
                if re.search(r'(?:,|/)\s*\.?0\s*$',raw):
                    continue
                yield t
            elif t.lower_name not in ('var','url'):
                yield from literals(t.arguments)

def violations(rules, path, printing=False):
    for r in rules:
        if r.type == 'at-rule' and r.content:
            yield from violations(tinycss2.parse_rule_list(r.content), path,
                                  printing or (r.lower_at_keyword=='media' and 'print' in tinycss2.serialize(r.prelude)))
        elif r.type == 'qualified-rule' and not printing:
            selector = tinycss2.serialize(r.prelude)
            if EXEMPT.search(selector):
                continue
            for d in tinycss2.parse_declaration_list(r.content):
                if d.type == 'declaration' and (d.name.startswith('--') or re.search(r'color|background|border|shadow|fill|stroke',d.name)):
                    for t in literals(d.value):
                        yield f'{path}:{t.source_line} {selector.strip()} {d.name}: {t.serialize()}'

class ThemeContract(unittest.TestCase):
    def test_first_party_paint_is_semantic(self):
        errors=[]
        for path in styles():
            errors.extend(violations(tinycss2.parse_stylesheet(path.read_text()),path.relative_to(ROOT)))
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_stylesheets_parse(self):
        # Tokenizer errors, including unclosed blocks/functions; var fallbacks
        # need browser evaluation too (covered by the separate browser suite).
        def check(ts):
            for t in ts:
                self.assertNotEqual(t.type,'error',repr(t))
                for attr in ('content','arguments'):
                    if getattr(t,attr,None):check(getattr(t,attr))
        for p in styles():check(tinycss2.parse_stylesheet(p.read_text()))

    def test_package_schema_is_still_six_colors(self):
        src=(ROOT/'apps/damage/src/damage_theme_manifest.erl').read_text()
        self.assertIn('-define(SCHEMA, <<"damage-theme/v1">>)',src)
        self.assertIn('true = maps:size(Colors) =:= 6',src)
        pre=src.split('%% Loaded last in <head>.')[0]
        self.assertNotIn('<<"theme-',pre)
        self.assertIn('term_to_binary(canonical(M), [deterministic])',src)

    def test_shared_theme_is_loaded_by_app_shells(self):
        for app,path in [('damage','ui/dashboard/page_shell.mustache'),
                         ('ecai','ui/dashboard/ecai_console.mustache'),
                         ('nosternity','ui/dashboard/page.mustache')]:
            src=(ROOT/'apps'/app/'priv/templates'/path).read_text()
            links=re.findall(r'<link\b[^>]+>',src,re.I)
            themes=[v for v in links if f'/api/themes/css?app={app}' in v]
            self.assertEqual(len(themes),1,app)
            self.assertEqual([v for v in links if re.search(r'rel=[\'"]stylesheet',v)][-1],themes[0])
        settings=(ROOT/'apps/damage/priv/static/settings/index.html').read_text()
        self.assertIn('/api/themes/css?app=__APP__',settings)

    def test_bop_assets_and_route(self):
        for p in (ROOT/'apps/bop/priv/assets').rglob('*'):
            if p.is_file() and p.suffix in ('.css','.js'):
                out=ROOT/'apps/bop/priv/public/assets'/p.relative_to(ROOT/'apps/bop/priv/assets')
                if out.exists():self.assertEqual(p.read_bytes(),out.read_bytes(),str(p))
        self.assertIn('{"/api/themes/css", damage_theme_http, #{action => css}}',
                      (ROOT/'apps/bop/src/bop_app.erl').read_text())
        self.assertIn('/api/themes/css?app=bop',(ROOT/'apps/bop/priv/assets/js/theme.js').read_text())

    def test_theme_injected_css_cannot_import_active_content(self):
        css=(ROOT/'apps/damage/src/damage_theme_manifest.erl').read_text().split('css(App, M)')[1]
        for unsafe in ('url(', '@import', '<script', 'javascript:'):
            self.assertNotIn(unsafe,css)

if __name__=='__main__':unittest.main()
