#!/usr/bin/env python3
"""Offline integration sanity checks, NOT an Erlang compiler or runtime tests.
Requires Python 3.10+, Pygments and Node. Run from any directory.
"""
from __future__ import annotations
import json
import re
import subprocess
from pathlib import Path
from pygments import lex
from pygments.lexers import ErlangLexer
from pygments.token import Token

ROOT = Path(__file__).resolve().parents[1]

def balanced(path: Path) -> None:
    tokens=[]; line=1
    for typ,value in lex(path.read_text(), ErlangLexer()):
        if typ not in Token.Comment and typ not in Token.Literal.String and typ not in Token.Text.Whitespace:
            tokens.append((typ,value,line))
        line += value.count('\n')
    stack=[]
    for i,(typ,value,line) in enumerate(tokens):
        value='{' if value=='#{' else value
        assert typ not in Token.Error, f'{path}:{line}: lexical error {value!r}'
        if value in ('(','[','{'): stack.append((value,line))
        elif value in (')',']','}'):
            expected={')':'(',']':'[','}':'{'}[value]
            assert stack and stack[-1][0]==expected, f'{path}:{line}: unexpected {value}, stack={stack[-3:]}'
            stack.pop()
        elif value in ('case','try','if','receive','begin','maybe'): stack.append(('block',line))
        elif value=='fun':
            tail=[v for _,v,_ in tokens[i+1:i+4]]
            if tail and (tail[0]=='(' or (len(tail)>1 and tail[1]=='(')): stack.append(('block',line))
        elif value=='end':
            assert stack and stack[-1][0]=='block',f'{path}:{line}: unexpected end, stack={stack[-3:]}'
            stack.pop()
    assert not stack,f'{path}: unclosed delimiters: {stack}'

def main() -> None:
    checks=[]
    scripts=['apps/ecai/priv/static/js/ecai-eval.js','apps/ecai/priv/static/js/ecai-console.js',
             'apps/damage/priv/static/js/evaluation-account-settings.js','apps/damage/priv/static/js/settings.js']
    for name in scripts:
        subprocess.run(['node','--check',str(ROOT/name)],check=True,capture_output=True,text=True)
        checks.append('Node ES-module syntax: '+name)
    modules=list((ROOT/'apps/ecai/src').glob('ecai_eval*.erl'))+list((ROOT/'apps/ecai/test').glob('ecai_eval*.erl'))+[ROOT/'apps/damage/src/steps_ecai_eval.erl', ROOT/'apps/damage/test/steps_ecai_eval_tests.erl']
    for p in modules:
        balanced(p); checks.append('Erlang lexical/delimiter sanity only: '+str(p.relative_to(ROOT)))
    policy=(ROOT/'apps/ecai/src/ecai_eval_policy.erl').read_text()
    schema=(ROOT/'apps/damage/src/damage_settings_schema.erl').read_text()
    definitions=re.findall(r'\{<<"[a-z_]+">>, (eval_[a-z_]+), (false|true|\[\]|\d+), (boolean|integer|string_list), (\d+), (\d+)\}',policy)
    assert len(definitions)==20,'Expected twenty operator fields'
    for key,default,typ,lo,hi in definitions:
        line=next(x for x in schema.splitlines() if f'key => {key},' in x)
        assert f'type => {typ},' in line and f'default => {default},' in line
        if typ=='integer': assert f'min => {lo}, max => {hi}' in line
    checks.append('All 20 node policy fields match Damage settings schema types/defaults/bounds')
    html=(ROOT/'apps/ecai/priv/templates/ui/dashboard/ecai_eval.mustache').read_text()
    js=(ROOT/'apps/ecai/priv/static/js/ecai-eval.js').read_text()
    ids=re.findall(r'\bid="([^"]+)"',html); assert len(ids)==len(set(ids))
    used=set(re.findall(r"\$\('(eval[A-Za-z0-9]+)'\)",js))
    assert used <= set(ids), f'Missing template elements: {used-set(ids)}'
    code_without_comments=re.sub(r'/\*.*?\*/|//[^\n]*','',js,flags=re.S)
    assert 'innerHTML' not in code_without_comments and 'localStorage' not in code_without_comments
    console=(ROOT/'apps/ecai/priv/static/js/ecai-console.js').read_text()
    template=(ROOT/'apps/ecai/priv/templates/ui/dashboard/ecai_console.mustache').read_text()
    assert 'initEvaluation({' in console and 'evaluation_panel' in template and 'data-view="evaluation"' in template
    assert 'evaluation_panel => Evaluation' in (ROOT/'apps/ecai/src/ecai_dashboard.erl').read_text()
    assert 'ecai_eval_http' in (ROOT/'apps/ecai/src/ecai_app.erl').read_text()
    assert 'ecai_eval_sup' in (ROOT/'apps/ecai/src/ecai_sup.erl').read_text()
    assert 'evaluation_handlers()' in (ROOT/'apps/damage/src/damage_app.erl').read_text()
    assert 'initEvaluationAccountSettings' in (ROOT/'apps/damage/priv/static/js/settings.js').read_text()
    checks.append('Workspace IDs, route/render/supervisor hooks and account settings integration')
    for name,expected in [('dialogue',6),('paper-trading',4)]:
        suite=json.loads((ROOT/f'apps/ecai/priv/static/eval/{name}.json').read_text())
        cases=suite['cases']; assert len(cases)==expected
        assert len({c['id'] for c in cases})==expected
        seen={}
        for case in cases:
            for key in [('group',case['group']),('prompt',json.dumps(case['messages'],sort_keys=True))]:
                assert key not in seen or seen[key]==case['split']
                seen[key]=case['split']
        trades=[c for c in cases if c['domain']=='trading']; rank={'dev':0,'test':1,'holdout':2}
        for a in trades:
            for b in trades:
                if a['market']['symbol']==b['market']['symbol'] and rank[a['split']]<rank[b['split']]:
                    assert a['market']['tape'][-1]['time_ms']<b['market']['as_of_ms']
        checks.append(f'Synthetic {name} fixture parses and satisfies static ID/split checks ({expected} cases)')
    print(json.dumps({'status':'passed','scope':'Static checks only; not compilation, EUnit, auth or provider execution',
                      'check_count':len(checks),'checks':checks},indent=2))

if __name__=='__main__':main()
