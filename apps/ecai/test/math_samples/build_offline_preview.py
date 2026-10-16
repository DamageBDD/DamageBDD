#!/usr/bin/env python3
"""Package the production sample workbench as one offline HTML file. No backend."""
import base64
from pathlib import Path
import re
import sys

APP = Path(__file__).resolve().parents[2]

def module_url(source):
    for name in ('ecai-math-samples.js', 'ecai-math-exact.js'):
        source = re.sub(r"(['\"])\./" + re.escape(name) + r"(?:\?[^'\"]*)?\1",
                        lambda _: repr(module_url((APP / 'priv/static/js' / name).read_text())), source)
    return 'data:text/javascript;base64,' + base64.b64encode(source.encode()).decode()

def build():
    css = '\n'.join((APP / 'priv/static/css' / name).read_text() for name in ('ecai-console.css', 'ecai-math-paths.css'))
    panel = (APP / 'priv/templates/ui/dashboard/ecai_math_paths.mustache').read_text()
    module = module_url((APP / 'priv/static/js/ecai-math-paths.js').read_text())
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">
<title>ECAI · Offline mathematical examples</title><style>''' + css + '''
.console-body{width:100%}.console-main{max-width:1580px;width:100%;margin:auto}
.offline-note{padding:12px 22px;background:#fff8e5;color:#674819;border-bottom:1px solid #ead8aa;font-size:13px}
</style></head><body><div class="console-shell" id="ecaiConsole"><div class="console-body">
<header class="console-topbar"><div class="breadcrumb">ECAI <span>/</span> <strong>Mathematical paths</strong></div><span class="status-tag">Offline public examples</span></header>
<div class="offline-note" id="offlineNote" role="status">13 local examples. Exact point experiments and exports work offline. Live node verification requires the deployed, authenticated dashboard.</div>
<main class="console-main">''' + panel + '''</main></div></div>
<script type="module">
import {initMathPaths} from "''' + module + '''";
const panel=document.querySelector('[data-panel="math"]');panel.hidden=false;panel.classList.add('is-visible');
const note=document.getElementById('offlineNote');
window.mathPreview=initMathPaths({request:async()=>{throw Error('No backend in this offline preview.');},
currentToken:()=>'',managedSession:()=>false,openLogin:()=>{note.textContent='Deploy the integration and sign in there to run native verification. This file never connects to a node or starts a job.';note.scrollIntoView({block:'nearest'});},toast:(text)=>{note.textContent=text;}});
window.mathPreview.setVisible(true);
const link=document.getElementById('mathSampleLink');link.disabled=true;link.title='Public example links are available on the deployed dashboard, not this local file.';
window.addEventListener('beforeunload',()=>window.mathPreview.dispose());
</script></body></html>'''

if __name__ == '__main__':
    destination = Path(sys.argv[1] if len(sys.argv) > 1 else 'ecai-math-samples-preview.html')
    destination.write_text(build(), encoding='utf-8')
    print(destination)
