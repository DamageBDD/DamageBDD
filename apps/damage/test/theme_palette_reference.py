"""Offline reference for CSS visual tests, NOT a replacement for the Erlang generator.
Use THEME_CSS_DIR with css/<app>/<theme>.css emitted by the escript to test runtime
CSS instead. No API, billing, contract, search or session activity is performed.
"""
from pathlib import Path
import math
import re

ROOT = Path(__file__).resolve().parents[3]

def palettes():
    src = (ROOT / 'apps/damage/src/damage_theme_manifest.erl').read_text().split('key(M) ->')[0]
    return {name: dict(re.findall(r'<<"(\w+)">> => <<"(#[0-9a-fA-F]{6})">>', block))
            for name, block in re.findall(r'<<"id">> => <<"([^"]+)">>.*?<<"tokens">> => #\{(.*?)\}', src, re.S)}

def luminance(c):
    rgb = [int(c[i:i+2], 16) / 255 for i in (1, 3, 5)]
    return sum(w * (v / 12.92 if v <= .04045 else ((v + .055) / 1.055)**2.4)
               for w, v in zip((.2126, .7152, .0722), rgb))

def ratio(a, b):
    a,b = luminance(a),luminance(b)
    return (max(a,b)+.05)/(min(a,b)+.05)

def contrast_text(bg):
    return '#000000' if ratio('#000000',bg)>=ratio('#ffffff',bg) else '#ffffff'

def readable(fg, bg):
    return fg if ratio(fg,bg)>=4.5 else contrast_text(bg)

def semantic(dark, light, bg):
    return dark if ratio(dark,bg)>=4.5 else readable(light,bg)

def readable_on(fg, bgs):
    target = max(('#000000','#ffffff'),key=lambda c:min(ratio(c,b) for b in bgs))
    for n in range(21):
        vals=[math.floor((int(fg[i:i+2],16)*(20-n)+int(target[i:i+2],16)*n)/20+.5) for i in (1,3,5)]
        out='#'+''.join(f'{v:02x}' for v in vals)
        if min(ratio(out,b) for b in bgs)>=4.7 or n==20:return out

def mix(a,b,n=94):return f'color-mix(in srgb,{a} {n}%,{b})'

def reference_css(app, name):
    c=palettes()[name]
    bg,surface,text,muted,accent,border=(c[k] for k in ('background','surface','text','muted','accent','border'))
    ink,soft,link=(readable_on(v,[surface,bg]) for v in (text,muted,accent))
    good=semantic('#17694f','#91d99c',surface);bad=semantic('#a72c43','#ff9eae',surface)
    warning=semantic('#795917','#ffd392',surface);info=semantic('#285eae','#a9c9ff',surface)
    scheme='dark' if luminance(surface)<.179 else 'light'
    roles={'bg':bg,'surface':surface,'surface-alt':mix(surface,ink,96),'input':bg,
           'text':ink,'muted':soft,'link':link,'border':border,'control-border':soft,
           'accent':accent,'accent-hover':accent,'accent-soft':mix(surface,accent),
           'on-accent':contrast_text(accent),'focus':link,'success':good,'danger':bad,
           'warning':warning,'info':info,'backdrop':'rgba(0,0,0,.6)','color-scheme':scheme,'shadow':'rgba(0,0,0,.18)','focus-glow':mix(link,'transparent',20)}
    for role,color in [('success',good),('danger',bad),('warning',warning),('info',info)]:
        roles[role+'-soft']=mix(surface,color);roles['on-'+role]=contrast_text(color)
    v={'theme-'+k:val for k,val in roles.items()}
    v.update({'damage-bg':bg,'damage-surface':surface,'damage-text':'var(--theme-text)',
              'damage-muted':'var(--theme-muted)','damage-accent':accent,'damage-border':border,
              'ws-bg':bg,'ws-panel':surface,'ws-surface':surface,'ws-input':bg,
              'ws-raised':'var(--theme-surface-alt)','ws-text':'var(--theme-text)',
              'ws-muted':'var(--theme-muted)','ws-accent':accent,'ws-accent-text':contrast_text(accent),
              'ws-error':'var(--theme-danger)','ws-line':border,'green':accent,'ink':'var(--theme-text)',
              'line':border,'muted':'var(--theme-muted)','node-accent':accent,'accent':accent,
              'background':bg,'surface':surface,'text':'var(--theme-text)','bg':bg,'fg':'var(--theme-text)',
              'paper':surface,'panel':surface,'card':surface,'on-accent':contrast_text(accent)})
    if app=='ecai':
        v.update({'canvas':bg,'paper':surface,'ink':ink,'text':ink,'muted':soft,
                  'navy':surface,'navy-soft':bg,'nav-ink':ink,'nav-muted':soft,
                  'blue':accent,'blue-strong':accent,'on-accent':contrast_text(accent),
                  'link':link,'focus':link,'border':border,'border-strong':soft,
                  'surface-2':mix(surface,ink,94),'accent-soft':mix(accent,surface,12),
                  'sky':mix(accent,surface,12),'nav-active-bg':mix(accent,surface,12),
                  'success':semantic('#21805d','#91d99c',surface),
                  'danger':semantic('#b4324e','#ff9eae',surface),
                  'warning':semantic('#84621d','#ffd392',surface),'ecai-color-scheme':scheme})
    extra={
        'ecai':'.console-shell,.console-body{background:var(--damage-bg);color:var(--damage-text)}.console-sidebar,.console-topbar{background:var(--damage-surface)}',
        'damage':'.damage-dashboard .dashboard-sidebar,.damage-dashboard .dashboard-topbar{background:var(--damage-surface)}.damage-dashboard .dashboard-main{background:var(--damage-bg)}',
        'nosternity':'body{background:var(--theme-bg);color:var(--theme-text)}',
        'bop':'body,body.dark{background:var(--theme-bg);color:var(--theme-text)}'}[app]
    return ':root,body{'+''.join(f'--{k}:{val};' for k,val in v.items())+'color-scheme:var(--theme-color-scheme)}'+extra
