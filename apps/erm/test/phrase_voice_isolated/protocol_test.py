#!/usr/bin/env python3
"""Real native worker, fake external SDK/capture. No microphone accuracy claims."""
import os
import select
import struct
import subprocess
import sys
import time
from pathlib import Path

worker, capture = sys.argv[1:3]
passed = 0

def check(name, fn):
    global passed
    fn()
    passed += 1
    print('PASS', name, flush=True)

class Peer:
    def __init__(self, phrases=True, reject_whisper=True):
        env = os.environ.copy()
        if reject_whisper:
            env['PHRASE_TEST_FORBID_WHISPER'] = '1'
        self.p = subprocess.Popen([worker, '--phrases-only' if phrases else 'unused',
            'unused-vad', 'unused-speaker', capture, 'default', 'en', '2', '700', '8000'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.buffer = bytearray()
        assert self.read() == b'R\0\2' + bytes([5 if phrases else 4])
    def send(self, packet):
        self.p.stdin.write(struct.pack('>I', len(packet)) + packet)
        self.p.stdin.flush()
    def read(self, timeout=2):
        deadline=time.monotonic()+timeout
        while True:
            if len(self.buffer)>=4:
                size=struct.unpack_from('>I',self.buffer)[0]
                assert size<=1048576
                if len(self.buffer)>=4+size:
                    out=bytes(self.buffer[4:4+size]);del self.buffer[:4+size];return out
            left=deadline-time.monotonic()
            if left<=0 or not select.select([self.p.stdout],[],[],left)[0]:
                raise TimeoutError('no native packet')
            data=os.read(self.p.stdout.fileno(),65536)
            if not data:
                raise RuntimeError(('native EOF',self.p.poll(),self.p.stderr.read()))
            self.buffer.extend(data)
    def quiet(self):
        try: msg=self.read(.12)
        except TimeoutError: return
        raise AssertionError(('unexpected packet',msg[:40]))
    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=2)
        except subprocess.TimeoutExpired: self.p.kill();self.p.wait()
        self.p.stdout.close();self.p.stderr.close()
    def __enter__(self): return self
    def __exit__(self, *_): self.close()

def load(peer, revision=1, records=()):
    peer.send(b'L'+struct.pack('>QffH',revision,.35,.08,len(records))+b''.join(records))
    assert peer.read()==b'L'+struct.pack('>Q',revision)

def frame(peer, epoch):
    peer.send(b'P'+struct.pack('>Q',epoch*2))
    begin=peer.read();assert begin[:1]==b'B' and struct.unpack_from('>Q',begin,1)[0]==epoch
    audio=peer.read();assert audio[:1]==b'P'
    assert struct.unpack_from('>QQ',audio,1)==struct.unpack_from('>QQ',begin,1)
    assert peer.read()==b'F'
    return audio

def parse(audio):
    ms,dim=struct.unpack_from('>IH',audio,17)
    offset=39+4*dim
    rev,reason,action,distance,margin,version,frames,fdim=struct.unpack_from('>QBBffBHB',audio,offset)
    features=audio[offset+22:]
    assert version==1 and fdim==13 and len(features)==frames*13*4
    return ms,frames,features,rev,reason,action,distance,margin

def startup():
    with Peer() as p:
        p.quiet() # no inference/capture output before explicit P
        load(p)
        data=parse(frame(p,2));assert data[4]==1 and data[3]==1
        p.quiet() # one-shot seal really closes capture
check('phrase mode does not initialize or call Whisper; explicit one-shot gate',startup)

def train_recognize():
    with Peer() as p:
        load(p)
        ms,n,features,_,_,_,_,_=parse(frame(p,2))
        sample=b'\x01'+struct.pack('>IH',ms,n)+features
        load(p,7,[sample]*3)
        data=parse(frame(p,3));assert data[3]==7 and data[4]==0 and data[5]==1
        load(p,8,[sample]*3+[b'\x02'+sample[1:]]*3)
        data=parse(frame(p,4));assert data[3]==8 and data[4]==3
check('native profile revision, accepted match and ambiguous match',train_recognize)

def epochs():
    with Peer() as p:
        load(p)
        p.send(b'P'+struct.pack('>Q',10*2))
        b=p.read();assert b[0:1]==b'B'
        p.send(b'M'+struct.pack('>Q',11*2+1))
        # Delayed fake speaker model leaves time for M to invalidate inference.
        assert p.read()==b'F'
        p.quiet()
        a=parse(frame(p,12));assert a[3]==1
check('mute invalidates in-flight inference; newer epoch can resume',epochs)

def acoustics():
    with Peer() as p:
        p.send(b'C'+struct.pack('>QffIII',3,-3.,.6,900,250,8000))
        assert p.read()==b'C'+struct.pack('>Q',1)
        load(p)
        a=frame(p,2);assert struct.unpack_from('>f',a,35)[0]==-3.
check('acoustic configuration acknowledgement and effective gain',acoustics)

def invalid():
    for pkt in [b'L'+struct.pack('>QffH',1,.35,.08,1),
                b'L'+struct.pack('>QffH',1,float('nan'),.08,0),
                b'L'+struct.pack('>QffH',1,.35,.08,0)+b'extra']:
        with Peer() as p:
            p.send(pkt);assert p.read()[:1]==b'E';assert p.p.wait(timeout=2)==2
check('invalid native profiles fail closed',invalid)

def legacy():
    with Peer(phrases=False,reject_whisper=False) as p:
        p.send(b'M'+struct.pack('>Q',2))
        assert p.read()[:1]==b'B'
        a=p.read();assert a[:1]==b'A' and a.endswith(b'bob stop')
        assert p.read()==b'F'
check('existing protocol-4 Whisper invocation remains operational',legacy)
print('Native protocol tests passed:',passed)
