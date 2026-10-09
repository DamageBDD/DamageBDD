#!/usr/bin/env python3
"""Compile the shipped LaTeX template with demonstration data.
This checks the template using pdflatex, not the Erlang renderer or billing API.
Run: python tools/check_invoice_template.py --output /tmp/invoice-template-check
"""
import argparse, json, os, re, subprocess
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',default='/tmp/invoice-template-check');a=p.parse_args()
out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
template=(REPO/'apps/damage/priv/templates/invoices/enterprise.tex.mustache').read_text()
esc={'\\':r'\textbackslash{}','{':r'\{','}':r'\}','&':r'\&','%':r'\%','$':r'\$','#':r'\#','_':r'\_','~':r'\textasciitilde{}','^':r'\textasciicircum{}','\n':r'\newline{}','\r':'','\t':' '}
def tex(s): return ''.join(esc.get(c,c) for c in str(s))
def compile_case(name, values):
    source=re.sub(r'\{\{([a-z_]+)\}\}',lambda m:values[m[1]],template)
    (out/f'{name}.tex').write_text(source)
    run=subprocess.run(['pdflatex','-no-shell-escape','-interaction=nonstopmode','-halt-on-error',f'{name}.tex'],cwd=out,
        env={**os.environ,'openin_any':'p','openout_any':'p'},capture_output=True,timeout=45)
    (out/f'{name}.compiler.log').write_bytes(run.stdout+run.stderr)
    if run.returncode: raise RuntimeError(run.stdout.decode(errors='replace')[-3000:])
    text=subprocess.check_output(['pdftotext',str(out/f'{name}.pdf'),'-']).decode()
    assert 'SAMPLE' in text and 'DO NOT PAY' in text
    assert not re.search(r'Overfull \\hbox', (out/f'{name}.log').read_text(errors='replace')), 'Layout has overfull horizontal boxes'
    return {'file':f'{name}.pdf','compiled':True,'template_placeholders_remaining':bool(re.search(r'\{\{[a-z_]+\}\}',source)),
            'pages':int(re.search(r'Pages:\s+(\d+)',subprocess.check_output(['pdfinfo',str(out/f'{name}.pdf')]).decode())[1])}
fields=dict(document_title='SAMPLE INVOICE',number='SAMPLE-ENT-000001',issued_on='2026-10-09',due_on='2026-10-16',currency='AUD',
    seller_name='DAMAGEBDD',seller_abn='39 865 763 306',seller_email='billing@damagebdd.com',seller_address='Demonstration only - do not pay',
    customer_name='Example Monthly Pty Ltd',customer_abn='',customer_email='billing@example.invalid',customer_address='Attn: Accounts Payable\nExample billing address\nAustralia',
    engagement='Monthly operations & maintenance retainer',period_start='2026-10-01',period_end='2026-10-31',
    notes='Ongoing support for Bitcoin Core, Core Lightning and the DamageBDD policy layer. AWS infrastructure costs are excluded and billed directly. SAMPLE ONLY - DO NOT PAY.',
    subtotal='850.00',tax='0.00',total='850.00',tax_label='Tax (none charged)',payment_instructions='SAMPLE ONLY - DO NOT PAY.\nProduction invoices use node-reviewed Bitcoin or bank payment instructions.\nNo live payment destination is included in this sample.')
values={k:tex(v) for k,v in fields.items()}
values['rows']=tex('Monthly operations & maintenance retainer')+' & 1 & 850.00 & 850.00 '+r'\\ \hline'+'\n'
checks=[compile_case('sample-enterprise-invoice',values)]
values.update(customer_name=tex('Example Fortnightly Company'),customer_address=tex('Demonstration account'),engagement=tex('Fortnightly operations & support subscription'),
              period_start='2026-10-09',period_end='2026-10-22',due_on='2026-10-09',subtotal='100.00',total='100.00',number='SAMPLE-ENT-000002',
              notes=tex('Initial deployment and commissioning fully waived. Hosting, transaction fees, Lightning liquidity and third-party charges are excluded. SAMPLE ONLY - DO NOT PAY.'),
              rows=tex('Fortnightly operations & support subscription')+' & 1 & 100.00 & 100.00 '+r'\\ \hline'+'\n')
checks.append(compile_case('sample-fortnightly-invoice',values))
values['notes']=tex(r'Escaping test: \input{/etc/passwd} & % $ # _ ~ ^ {{number}}. SAMPLE ONLY - DO NOT PAY.')
checks.append(compile_case('template-escaping-test',values))
report={'scope':'Real shipped template compiled by pdflatex with Python-supplied fixtures; Erlang rendering not executed','checks':checks}
(out/'pdf-checks.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
