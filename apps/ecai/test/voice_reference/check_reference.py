#!/usr/bin/env python3
"""Independent numerical checks for Erlang fixtures, not an Erlang test runner.

Optional development dependencies: numpy, scipy, cryptography.
No Python or Python-generated features are called by the Erlang recognizer.
Writes a summary and cross-language fixtures only when invoked explicitly.
"""
from __future__ import annotations
import json
import math
import sys
from pathlib import Path
import numpy as np
from scipy.fft import dct
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

SR, FRAME, HOP, NFFT = 16000, 640, 160, 1024
PROFILES = {'voice_a': (125., .85, 1.2), 'voice_b': (210., 1.15, 1.),
            'unknown': (310., 1.38, 1.6), 'same_pitch_b': (125., 1.35, .6)}
VOWELS = ((500,1500,2500),(300,2200,3000),(700,1200,2600),(350,900,2300))

def synth(kind: str, take: int, seconds: int = 2) -> np.ndarray:
    f0, shift, tilt = PROFILES[kind]
    t = np.arange(seconds * SR, dtype=np.float64) / SR
    vowel = (np.trunc(t * 2).astype(int) + take - 1) % 4
    phase = 2*np.pi*f0*t + .18*np.sin(2*np.pi*(1.1+take*.02)*t) + take*.37
    signal = np.zeros(len(t))
    for idx, (f1,f2,f3) in enumerate(VOWELS):
        mask = vowel == idx
        for h in range(1, int(7000/f0)+1):
            res = lambda center,width: 1/(1+((h*f0-center)/width)**2)
            w = (.03+res(f1*shift,100)+.75*res(f2*shift,150)+.55*res(f3*shift,200))/h**tilt
            signal[mask] += w*np.sin(h*phase[mask]+.07*h*h)
    x = (.70+.30*np.sin(2*np.pi*2*t+.1*take))*signal + .0002*np.sin(2*np.pi*7191*t+take)
    gain = .22 if take%3 == 0 else .55
    y = 32767*gain*x/np.max(np.abs(x))
    # Match Erlang round (halves away from zero).
    return (np.sign(y)*np.floor(np.abs(y)+.5)).astype('<i2')

def features(pcm: np.ndarray) -> tuple[list[int], dict]:
    raw=pcm.astype(np.float64)/32768
    x=raw-np.mean(raw)
    rms=np.sqrt(np.mean(x*x))
    frames=np.lib.stride_tricks.sliding_window_view(x,FRAME)[::HOP].copy()
    energy=np.sqrt(np.mean(frames*frames,axis=1))
    active=frames[energy>max(1e-5,np.quantile(energy,.95)*.1)]
    z=(active-np.mean(active,axis=1,keepdims=True))*np.hanning(FRAME)
    ac=np.fft.irfft(np.abs(np.fft.rfft(z,n=2048))**2,n=2048)[:,:FRAME]
    ac/=np.maximum(ac[:,:1],1e-20)
    pitches=[]
    for row in ac:
        peaks=np.flatnonzero((row[40:266]>row[39:265]) & (row[40:266]>=row[41:267]))+40
        if not len(peaks):continue
        peak=np.max(row[peaks])
        if peak<.35:continue
        lag=int(peaks[np.flatnonzero(row[peaks]>=.90*peak)[0]])
        den=row[lag-1]-2*row[lag]+row[lag+1]
        offset=0 if abs(den)<1e-12 else np.clip(.5*(row[lag-1]-row[lag+1])/den,-.5,.5)
        pitches.append(SR/(lag+offset))
    assert len(pitches)*.01>=.25
    a=active/rms
    e=a.copy(); e[:,0]*=.03; e[:,1:]=a[:,1:]-.97*a[:,:-1]
    power=np.abs(np.fft.rfft(e*np.hanning(FRAME),n=1024))**2
    mel=lambda f:2595*np.log10(1+f/700)
    edges=700*(10**(np.linspace(mel(80),mel(7600),34)/2595)-1)
    freq=np.arange(513)*SR/1024
    bank=[]
    for l,c,r in zip(edges[:-2],edges[1:-1],edges[2:]):
        b=np.maximum(0,np.minimum((freq-l)/(c-l),(r-freq)/(r-c)))
        bank.append(b/max(1e-12,np.sum(b)))
    ceps=dct(np.log(np.maximum(power@np.array(bank).T,1e-10)),type=2,norm='ortho')[:,1:14]
    desc=np.r_[np.median(ceps,axis=0)/6,(np.quantile(ceps,.75,axis=0)-np.quantile(ceps,.25,axis=0))/12,
               np.quantile(np.log2(np.array(pitches)/150),[.25,.5,.75])/.5,len(pitches)/len(active)]
    q=np.sign(desc)*np.floor(np.abs(32*desc)+.5)
    assert np.sum(np.abs(q)>255)<=3
    return np.clip(q,-255,255).astype(int).tolist(), {'pitch_median_hz':float(np.median(pitches))}

def main(out: Path) -> None:
    out.mkdir(parents=True,exist_ok=True)
    fs={f'{kind}_{take}':features(synth(kind,take))[0]
        for kind in PROFILES for take in range(1,6)}
    dist=lambda a,b:sum(abs(x-y) for x,y in zip(fs[a],fs[b]))
    templates=('voice_a','voice_b')
    genuine=[dist(f'{k}_2',f'{k}_1') for k in templates]
    imp=[dist('voice_a_2','voice_b_1'),dist('voice_b_2','voice_a_1'),
         min(dist('unknown_2',f'{k}_1') for k in templates)]
    margins=[dist(f'{a}_2',f'{b}_1')-dist(f'{a}_2',f'{a}_1')
             for a,b in [('voice_a','voice_b'),('voice_b','voice_a')]]
    separable=max(genuine)<min(imp) and min(margins)>0
    radius=(max(genuine)+min(imp))//2; margin=max(1,min(margins)//2)
    def classify(key):
        scores=sorted((dist(key,f'{k}_1'),k) for k in templates)
        d,label=scores[0];gap=scores[1][0]-d
        return {'speaker': label if d<=radius and gap>=margin else None,'distance':d,'margin':gap}
    tests={k:classify(k) for k in ('voice_a_3','voice_b_3','unknown_3')}
    timeline={k:classify(k) for k in ('voice_a_4','voice_b_4','voice_a_5','unknown_4')}
    curves={str(k):ec.derive_private_key(k,ec.SECP256K1()).public_key().public_bytes(
        Encoding.X962,PublicFormat.CompressedPoint).hex() for k in (1,2,17,255,510)}
    summary={'execution':'Python independent numerical reference only; Erlang NOT executed',
             'calibration_separable':separable,'worst_genuine':max(genuine),'nearest_impostor':min(imp),
             'minimum_genuine_margin':min(margins),'max_distance':radius,'min_margin':margin,
             'test_predictions':tests,'timeline_predictions':timeline,
             'same_pitch_distance':dist('voice_a_1','same_pitch_b_1'),
             'feature_vectors':fs,'openssl_curve_vectors':curves}
    (out/'reference-results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k not in ('feature_vectors','openssl_curve_vectors')},indent=2))
    assert separable
    assert tests['voice_a_3']['speaker']=='voice_a'
    assert tests['voice_b_3']['speaker']=='voice_b'
    assert tests['unknown_3']['speaker'] is None
    assert timeline['voice_a_4']['speaker']=='voice_a'
    assert timeline['voice_b_4']['speaker']=='voice_b'
    assert timeline['voice_a_5']['speaker']=='voice_a'
    assert timeline['unknown_4']['speaker'] is None

if __name__=='__main__':
    main(Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).parent)
