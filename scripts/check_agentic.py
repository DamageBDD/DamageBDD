#!/usr/bin/env python3
"""Static checks only; NOT a substitute for erlc/EUnit or live integration tests."""
from pathlib import Path
import re
import unittest
from html.parser import HTMLParser
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'apps/damage/src'

# Scan punctuation after skipping Erlang strings, quoted atoms, comments and chars.
def delimiter_check(text):
    stack=[]; i=0
    while i<len(text):
        c=text[i]
        if c=='%':
            j=text.find('\n',i); i=len(text) if j<0 else j+1; continue
        if c in '\"\'':
            q=c; i+=1
            while i<len(text):
                if text[i]=='\\': i+=2; continue
                if text[i]==q: i+=1; break
                i+=1
            else: raise AssertionError('unterminated quote')
            continue
        if c=='$':
            i+=2
            if i>1 and text[i-1]=='\\': i+=1
            continue
        pair=text[i:i+2]
        if pair=='<<': stack.append('>>'); i+=2; continue
        if pair=='>>':
            if not stack or stack.pop()!='>>': raise AssertionError('unbalanced binary')
            i+=2; continue
        if c in '([{': stack.append({'(':')','[':']','{':'}'}[c])
        elif c in ')]}':
            if not stack or stack.pop()!=c: raise AssertionError(f'unbalanced {c} at {i}')
        i+=1
    assert not stack,stack

class Markup(HTMLParser):
    def __init__(self): super().__init__(); self.roles=set(); self.assets=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if 'data-role' in a: self.roles.add(a['data-role'])
        for k in ('src','href'):
            if a.get(k,'').startswith('/static/'): self.assets.append(a[k][8:])

class Contracts(unittest.TestCase):
    def test_balanced_erlang_and_config(self):
        for p in list(SRC.glob('*.erl'))+list((ROOT/'apps/damage/test').glob('*.erl'))+[ROOT/'config/agentic.config.sample']:
            with self.subTest(file=p.name): delimiter_check(p.read_text())
    def test_modules_and_exports_have_heads(self):
        for p in SRC.glob('*.erl'):
            t=p.read_text(); self.assertIn(f'-module({p.stem}).',t)
            heads=set(re.findall(r'^([a-z][\w]*)\s*\(',t,re.M))
            for group in re.findall(r'-export\(\[(.*?)\]\)',t,re.S):
                for name in re.findall(r'(\w+)\s*/\s*\d+',group): self.assertIn(name,heads,(p.name,name))
    def test_no_model_atom_or_shell_evaluation(self):
        for p in SRC.glob('*.erl'):
            t=p.read_text()
            for bad in ('list_to_atom(', 'binary_to_atom(', 'os:cmd(', 'erl_eval:', 'binary_to_term('):
                self.assertNotIn(bad,t,p.name)
    def test_dom_references_and_assets(self):
        base=ROOT/'apps/damage/priv/static'; markup=Markup(); markup.feed((base/'agent-tasks.html').read_text())
        js=(base/'js/agent-tasks.js').read_text()
        for role in re.findall(r"\$\('([^']+)'\)",js): self.assertIn(role,markup.roles)
        for asset in markup.assets: self.assertTrue((base/asset).is_file(),asset)
    def test_csrf_and_owner_pinning(self):
        http=(SRC/'damage_agent_http.erl').read_text(); steps=(SRC/'steps_agentic.erl').read_text()
        for value in ('x-damage-agent','Origin =:= Expected','damage_http:is_authorized'): self.assertIn(value,http)
        self.assertIn('proplists:get_value(public_key,C)',steps)
        self.assertNotIn('"I approve agent task"',steps)
    def test_intent_before_execution_and_no_paid_runner(self):
        task=(SRC/'damage_agent_task.erl').read_text()
        self.assertLess(task.index('action_started,#{skill => Skill'),task.index('operation(executing,fun()'))
        bdd=(SRC/'damage_agent_bdd.erl').read_text()
        self.assertNotIn('damage:execute_data(',bdd)
        self.assertIn('not maps:is_key(fail,New)',bdd)
        self.assertIn('assertion(Parts)',bdd)
    def test_learning_not_automatic_training(self):
        t=(SRC/'damage_agent.erl').read_text()
        self.assertIn('training_eligible => false',t)
        self.assertIn('damage_agent_store:bundle(O,Id)',t)
        self.assertNotIn('case {damage_agent_store:get(O,Id),events(O,Id)}',t)
        self.assertNotIn('ecai_codebase_learning:',t)

if __name__=='__main__': unittest.main(verbosity=2)
