#!/usr/bin/env python3
"""Production workers, fake devices/models. NOT live speech-quality evidence."""
import io
import math
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import wave

LAB, CAPTURE_WORKER, CAPTURE, PLAYER = sys.argv[1:5]
passed = 0

def check(name, fn):
    global passed
    fn()
    passed += 1
    print('PASS', name, flush=True)

class Peer:
    def __init__(self, args, env=None):
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        self.buffer = bytearray()
        self.meters = []
    def send(self, body):
        self.p.stdin.write(struct.pack('>I', len(body)) + body)
        self.p.stdin.flush()
    def read(self, timeout=4):
        until = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 4:
                size, = struct.unpack_from('>I', self.buffer)
                assert size <= 1048576
                if len(self.buffer) >= 4 + size:
                    result = bytes(self.buffer[4:4+size])
                    del self.buffer[:4+size]
                    if result[:1] == b'L' and len(result) == 14:
                        meter = struct.unpack('>QfB', result[1:])
                        assert math.isfinite(meter[1]) and -200 <= meter[1] <= 10 and meter[2] in (0, 1)
                        self.meters.append(meter)
                        continue
                    return result
            remaining = until - time.monotonic()
            if remaining <= 0 or not select.select([self.p.stdout], [], [], remaining)[0]:
                raise TimeoutError('packet timeout')
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError(('worker EOF', self.p.poll(), self.p.stderr.read()))
            self.buffer.extend(chunk)
    def close(self):
        self.p.stdin.close()
        try:
            self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
            raise AssertionError('native EOF did not terminate')
        self.p.stdout.close()
        self.p.stderr.close()
    def __enter__(self): return self
    def __exit__(self, *_): self.close()

def blob(b): return struct.pack('>I', len(b)) + b

def request(b, env=None):
    with Peer([LAB, PLAYER, 'default'], env) as peer:
        peer.send(b)
        return peer.read()

def pcm():
    return b''.join(struct.pack('<h', round(4000*math.sin(i*2*math.pi*140/16000)))
                    for i in range(24000))

def analysis():
    response = request(b'A' + blob(pcm()))
    assert response[:1] == b'A'
    n, = struct.unpack_from('>I', response, 1)
    return response[5:5+n], response[5+n:]

MODEL, FEATURE = analysis()

def profile(sample=FEATURE):
    record = b'\x01' + sample
    return b'L' + struct.pack('>QffH', 1, .35, .08, 3) + record*3

def render(model=MODEL, options=(1., 1., .15)):
    return request(b'Y' + struct.pack('>fff', *options) + blob(model) + blob(profile()))

WAVE_RESPONSE = render()
assert WAVE_RESPONSE[:1] == b'Y', WAVE_RESPONSE[:200]
WAV = WAVE_RESPONSE[31:]

def analysis_format():
    assert MODEL[:4] == b'ELS1'
    samples, frames = struct.unpack_from('>IH', MODEL, 4)
    assert samples == 24000 and frames == 150 and len(MODEL) == 10 + 76*frames
    ms, count = struct.unpack_from('>IH', FEATURE)
    assert ms == 1500 and len(FEATURE) == 6+count*13*4
check('same input produces bounded recognition and synthesis representations', analysis_format)

def digital():
    response = request(b'V' + blob(profile()) + FEATURE)
    reason, action, distance, margin = struct.unpack('>BBff', response[1:])
    assert response[:1] == b'V' and reason == 0 and action == 1 and distance == 0
    assert margin == 1000 # single-action sentinel, not certainty
    with wave.open(io.BytesIO(WAV), 'rb') as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 16000, 24000)
    assert WAVE_RESPONSE == render()
check('digital evaluator and repeatable 16-kHz WAV round trip', digital)

def bad_models():
    for invalid in [b'bad', MODEL[:-1], MODEL+b'extra', MODEL[:10]+struct.pack('>f', float('nan'))+MODEL[14:]]:
        assert render(invalid)[:1] == b'E'
    assert render(options=(0., 1., .15))[:1] == b'E'
    assert request(b'V' + blob(profile()) + FEATURE + b'extra')[:1] == b'E'
check('invalid models, options and evaluation payloads are rejected', bad_models)

def playback():
    assert request(b'B'+blob(WAV)) == b'B'
    env = os.environ.copy(); env['PHRASE_LAB_PLAYER_FAIL'] = '1'
    assert request(b'B'+blob(WAV), env) == b'Elab_player_failed'
    assert request(b'B'+blob(b'not wave')) == b'Elab_wav_format'
check('native player success, failure and strict WAV boundary', playback)

def cancellation():
    with tempfile.TemporaryDirectory() as directory:
        pidfile = Path(directory)/'pid'
        env = os.environ.copy(); env['PHRASE_LAB_PLAYER_PID'] = str(pidfile)
        peer = Peer([LAB, PLAYER, 'default'], env)
        try:
            peer.send(b'B'+blob(WAV))
            for _ in range(200):
                if pidfile.exists() and pidfile.read_text(): break
                time.sleep(.01)
            pid = int(pidfile.read_text())
        finally:
            peer.close()
        for _ in range(200):
            stat = Path(f'/proc/{pid}/stat')
            if not stat.exists() or stat.read_text().split()[2] == 'Z': break
            time.sleep(.01)
        else: raise AssertionError('playback child still running after EOF')
check('cancelling the BEAM-style port kills its dedicated playback child', cancellation)

def worker(flag='--phrases-lab'):
    env = os.environ.copy(); env['PHRASE_TEST_FORBID_WHISPER'] = '1'
    p = Peer([CAPTURE_WORKER, flag, 'vad', 'speaker', CAPTURE, 'default', 'en', '2', '700', '8000'], env)
    expected = 6 if flag == '--phrases-lab' else 5
    assert p.read() == b'R\0\2'+bytes([expected])
    p.send(profile()); assert p.read() == b'L'+struct.pack('>Q', 1)
    return p

def duplex_capture():
    with worker() as p:
        epoch = 10
        p.send(b'S'+struct.pack('>Q', epoch*2))
        assert p.read() == b'K'+struct.pack('>Q', epoch)
        begin = p.read(); assert begin[:1] == b'B'
        assert any(e == epoch for e, _, _ in p.meters), 'no lab capture meter'
        result = p.read(); assert result[:1] == b'Q'
        size, = struct.unpack_from('>I', result, 1)
        rec, synth = result[5:5+size], result[5+size:]
        assert rec[:1] == b'P' and synth[:4] == b'ELS1'
        assert struct.unpack_from('>QQ', rec, 1) == struct.unpack_from('>QQ', begin, 1)
        assert struct.unpack_from('>I', synth, 4)[0]//16 == struct.unpack_from('>I', rec, 17)[0]
        assert p.read() == b'F'
        try: p.read(.15)
        except TimeoutError: pass
        else: raise AssertionError('lab capture was not one-shot')
check('protocol 6 shares an epoch-tagged utterance; no Whisper calls', duplex_capture)

def stale():
    with worker() as p:
        p.send(b'S'+struct.pack('>Q', 20))
        assert p.read()[:1] == b'K'
        assert p.read()[:1] == b'B'
        p.send(b'M'+struct.pack('>Q', 23))
        assert p.read() == b'F'
check('mute cancels an in-flight synthesis-analysis sample', stale)

def old_mode():
    with worker('--phrases-only') as p:
        p.send(b'S'+struct.pack('>Q', 20))
        assert p.p.wait(timeout=2) == 2
    with worker() as p:
        p.send(b'S'+struct.pack('>Q', 21))
        assert p.p.wait(timeout=2) == 2
check('lab-only opcode rejected in old mode and with an invalid gate', old_mode)

def oversized():
    with Peer([LAB]) as p:
        p.p.stdin.write(struct.pack('>I',1048577)); p.p.stdin.flush()
        assert p.p.wait(timeout=2) == 2
check('native request allocation is bounded before reading body', oversized)
print('Lab protocol/lifecycle tests passed:', passed)
