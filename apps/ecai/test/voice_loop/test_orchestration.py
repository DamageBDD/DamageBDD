#!/usr/bin/env python3
"""Exercise the real Bash loop with explicitly fake Erlang/audio executables.

These tests measure orchestration ONLY. They do not compile Erlang, compute voice
features or prove that a physical microphone works. No microphone is opened.
Python 3 standard library only; do not put these mocks on your normal PATH.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

APP = Path(__file__).resolve().parents[2]
LOOP = APP / "test" / "run_voice_loop.sh"
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time, wave
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
def event(kind, **kw):
    with (root/'events.jsonl').open('a') as f:
        f.write(json.dumps(dict(kind=kind, time=time.monotonic(), **kw))+'\n')
def wav(path, seconds=2):
    with wave.open(str(path), 'wb') as f:
        f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        f.writeframes(b'\x00\x01' * (16000*seconds))
def fail(kind, rc=1):
    event(kind)
    print(kind, file=sys.stderr)
    sys.exit(rc)
if name == 'erlc':
    event('compile')
    sys.exit(1 if os.environ.get('FAIL_COMPILE') else 0)
elif name in ('espeak-ng', 'espeak'):
    event('tts', args=args)
    if os.environ.get('FAIL_TTS'): fail('tts_failed')
    wav(args[args.index('-w')+1])
elif name == 'aplay':
    if os.environ.get('FAIL_PLAYBACK'): fail('playback_failed')
    event('play_start')
    time.sleep(0.02)
    event('play_end')
elif name == 'arecord':
    event('record_start', args=args)
    if os.environ.get('FAIL_CAPTURE'): fail('capture_failed')
    if os.environ.get('WAIT_CAPTURE'):
        (root/'capture.pid').write_text(str(os.getpid()))
        def stopped(sig, frame):
            event('capture_terminated')
            sys.exit(128+sig)
        signal.signal(signal.SIGTERM, stopped)
        time.sleep(60)
    wav(args[-1], int(args[args.index('-d')+1]))
    event('record_end')
elif name == 'erl':
    action = os.environ['ECAI_VOICE_LOOP_ACTION']
    session = pathlib.Path(os.environ['ECAI_VOICE_LOOP_SESSION'])
    event('backend', action=action, expected=os.environ.get('ECAI_VOICE_LOOP_EXPECTED'))
    if action == 'import':
        (session/'speakers.txt').write_text('alice\nbob\n')
        (session/'voices.ecv').write_bytes(b'FAKE_PROFILE_NOT_ERLANG')
    elif action == 'build':
        if os.environ.get('FAIL_CALIBRATION'): fail('calibration_not_separable')
        (session/'voices.ecv').write_bytes(b'FAKE_PROFILE_NOT_ERLANG')
        (session/'dataset.term').write_text('fake_for_orchestration_only.\n')
    elif action == 'inspect':
        if os.environ.get('FAIL_INSPECT'): fail('invalid_profile')
    elif action == 'check':
        countfile = root/'check_count'
        n = int(countfile.read_text()) if countfile.exists() else 0
        countfile.write_text(str(n+1))
        if os.environ.get('REJECT_FIRST_CHECK') and n == 0: fail('insufficient_audio')
    elif action == 'score':
        if os.environ.get('FAIL_SCORE'): fail('scoring_failed')
        p = pathlib.Path(os.environ['ECAI_VOICE_LOOP_SAMPLE'])
        pathlib.Path(str(p)+'.result.term').write_text('{ok, #{status => matched, speaker => <<"alice">>}}.\n')
        pathlib.Path(str(p)+'.feedback.txt').write_text('Voice match: alice.')
    print('{ok, mock_only}.')
else:
    fail('unexpected_mock_'+name)
'''

class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ecai-loop-mock-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("erl", "erlc", "espeak-ng", "arecord", "aplay"):
            path = self.bin / name
            path.write_text(MOCK.replace("#!/usr/bin/env python3", f"#!{sys.executable} -S", 1))
            path.chmod(0o755)
        self.session = self.root / "session with spaces"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        MOCK_ROOT=str(self.root), ECAI_VOICE_BUILD_DIR=str(self.root/"build"))
        self.profile = self.root / "input.ecv"
        self.profile.write_bytes(b"fake")

    def tearDown(self):
        self.tmp.cleanup()

    def command(self, *args):
        return ["bash", str(LOOP), "--session", str(self.session), "--consent",
                "--seconds", "2", "--settle-ms", "250", *args]

    def run_loop(self, *args, data="", env=None):
        return subprocess.run(self.command(*args), input=data, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env={**self.env, **(env or {})}, timeout=25)

    def events(self):
        p = self.root / "events.jsonl"
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def kinds(self):
        return [e["kind"] for e in self.events()]

    def imported(self, *args, **kw):
        return self.run_loop("--profile", str(self.profile), *args, **kw)

    def test_import_two_rounds_and_ordering(self):
        r = self.imported("--auto", "--rounds", "2")
        self.assertEqual(r.returncode, 0, r.stdout)
        events = self.events()
        recordings = [e for e in events if e['kind'] == 'record_start']
        self.assertEqual(len(recordings), 2)
        for rec in recordings:
            preceding = [e for e in events if e['kind'] == 'play_end' and e['time'] < rec['time']]
            self.assertTrue(preceding)
            self.assertGreaterEqual(rec['time']-preceding[-1]['time'], .24)
            for flag, val in [('-f','S16_LE'),('-r','16000'),('-c','1'),('-d','2')]:
                self.assertEqual(rec['args'][rec['args'].index(flag)+1], val)
        self.assertEqual(len(list((self.session/'tests').glob('*.result.term'))), 2)
        self.assertEqual((self.session/'voices.ecv').read_bytes(), b'FAKE_PROFILE_NOT_ERLANG')
        self.assertFalse(any(e.get('action')=='build' for e in events))
        self.assertEqual(self.session.stat().st_mode & 0o777, 0o700)
        for f in (self.session/'tests').glob('*'):
            self.assertEqual(f.stat().st_mode & 0o077, 0)

    def test_manual_ground_truth_before_score_then_quit(self):
        r = self.imported(data="bob\nq\n")
        self.assertEqual(r.returncode, 0, r.stdout)
        scores = [e for e in self.events() if e.get('action')=='score']
        self.assertEqual(len(scores), 1)
        self.assertEqual(scores[0]['expected'], 'bob')
        metadata = next((self.session/'tests').glob('*.capture.txt')).read_text()
        self.assertIn('expected=bob', metadata)

    def test_development_wizard_then_test(self):
        # Four takes: readiness + acceptance each. No unknown calibration; one test; q.
        r = self.run_loop('--speakers', 'alice,bob', data='\n'*8+'n\nalice\nq\n')
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(len(list((self.session/'develop').glob('*.wav'))), 4)
        events = self.events()
        self.assertEqual(sum(e.get('action')=='check' for e in events), 4)
        self.assertEqual(sum(e.get('action')=='build' for e in events), 1)
        self.assertEqual(sum(e.get('action')=='score' for e in events), 1)
        self.assertEqual(self.kinds().count('record_start'), 5)

    def test_resume_does_not_reenroll(self):
        first = self.imported(data='q\n')
        self.assertEqual(first.returncode, 0, first.stdout)
        self.assertNotIn('record_start', self.kinds())
        second = self.run_loop('--auto', '--rounds', '1')
        self.assertEqual(second.returncode, 0, second.stdout)
        self.assertEqual(self.kinds().count('record_start'), 1)
        self.assertFalse(any(e.get('action')=='build' for e in self.events()))

    def test_tts_failure_prevents_recording(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_TTS':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('record_start', self.kinds())

    def test_playback_failure_prevents_recording(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_PLAYBACK':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('record_start', self.kinds())

    def test_compile_failure_prevents_recording(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_COMPILE':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('record_start', self.kinds())

    def test_bad_profile_prevents_recording(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_INSPECT':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('record_start', self.kinds())

    def test_capture_failure_never_scores(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_CAPTURE':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(e.get('action')=='score' for e in self.events()))
        self.assertEqual(len(list((self.session/'tests').glob('*.wav'))), 1)

    def test_score_failure_never_announces_match(self):
        r = self.imported('--auto','--rounds','1', env={'FAIL_SCORE':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.kinds().count('tts'), 1)

    def test_calibration_failure_stops_before_test(self):
        r = self.run_loop('--speakers','alice,bob', data='\n'*8+'n\n', env={'FAIL_CALIBRATION':'1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(list((self.session/'develop').glob('*.wav'))), 4)
        self.assertFalse((self.session/'voices.ecv').exists())
        self.assertFalse(any(e.get('action')=='score' for e in self.events()))

    def test_rejected_quality_not_accepted(self):
        r = self.run_loop('--speakers','alice,bob', data='\nq\n', env={'REJECT_FIRST_CHECK':'1'})
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(len(list((self.session/'develop').glob('*.wav'))), 0)
        self.assertEqual(len(list((self.session/'takes').glob('*.wav'))), 1)

    def test_unknown_calibration_separate_take(self):
        r = self.run_loop('--speakers','alice,bob', data='\n'*8+'y\n\n\nq\n')
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue((self.session/'develop'/'calibrate--unknown--01.wav').exists())
        self.assertEqual(self.kinds().count('record_start'), 5)

    def test_option_injection_and_invalid_auto_refused(self):
        for args in [('--seconds','0'), ('--seconds','6;touch /tmp/ecai-should-not-exist'),
                     ('--auto',), ('--settle-ms','0'), ('--backend','bogus')]:
            r = self.run_loop(*args)
            self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('record_start', self.kinds())

    def test_label_injection_and_duplicates_refused(self):
        r = self.run_loop('--speakers','alice,$(touch hacked)')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.session/'speakers.txt').exists())
        r = self.run_loop('--speakers','alice,alice')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.session/'speakers.txt').exists())
        self.assertNotIn('record_start', self.kinds())

    def test_device_argument_is_literal(self):
        marker = self.root/'INJECTED'
        device = f'default;touch {marker}'
        r = self.imported('--auto','--rounds','1','--device',device)
        self.assertEqual(r.returncode, 0, r.stdout)
        rec = next(e for e in self.events() if e['kind']=='record_start')
        self.assertEqual(rec['args'][rec['args'].index('-D')+1], device)
        self.assertFalse(marker.exists())

    def test_second_writer_blocked_and_term_stops_capture(self):
        env={**self.env, 'WAIT_CAPTURE':'1'}
        with subprocess.Popen(self.command('--profile',str(self.profile),'--auto','--rounds','1'),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env=env, start_new_session=True) as proc:
            try:
                deadline=time.monotonic()+8
                while not (self.root/'capture.pid').exists() and time.monotonic()<deadline:
                    time.sleep(.03)
                self.assertTrue((self.root/'capture.pid').exists())
                second=self.run_loop('--auto','--rounds','1')
                self.assertNotEqual(second.returncode, 0)
                self.assertIn('Another loop',second.stdout)
                proc.send_signal(signal.SIGTERM)
                output,_=proc.communicate(timeout=8)
                self.assertEqual(proc.returncode,143,output)
                self.assertIn('capture_terminated',self.kinds())
                self.assertFalse(any(e.get('action')=='score' for e in self.events()))
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid,signal.SIGKILL)
                    proc.communicate()

    def test_interrupt_stops_active_capture(self):
        env={**self.env, 'WAIT_CAPTURE':'1'}
        with subprocess.Popen(self.command('--profile',str(self.profile),'--auto','--rounds','1'),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env=env, start_new_session=True) as proc:
            try:
                deadline=time.monotonic()+8
                while not (self.root/'capture.pid').exists() and time.monotonic()<deadline:
                    time.sleep(.03)
                self.assertTrue((self.root/'capture.pid').exists())
                proc.send_signal(signal.SIGINT)
                output,_=proc.communicate(timeout=8)
                self.assertEqual(proc.returncode,130,output)
                self.assertIn('capture_terminated',self.kinds())
                self.assertFalse(any(e.get('action')=='score' for e in self.events()))
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid,signal.SIGKILL)
                    proc.communicate()

    def test_capture_deadline_stops_hung_recorder(self):
        r=self.imported('--auto','--rounds','1',env={'WAIT_CAPTURE':'1'})
        self.assertNotEqual(r.returncode,0,r.stdout)
        self.assertIn('capture_terminated',self.kinds())
        self.assertFalse(any(e.get('action')=='score' for e in self.events()))

    def test_session_capture_budget(self):
        r=self.imported(data='q\n')
        self.assertEqual(r.returncode,0,r.stdout)
        for n in range(200):
            (self.session/'tests'/f'take-{n}.wav').write_bytes(b'')
        r=self.run_loop('--auto','--rounds','1')
        self.assertNotEqual(r.returncode,0,r.stdout)
        self.assertIn('budget',r.stdout)
        self.assertNotIn('record_start',self.kinds())

if __name__ == '__main__':
    unittest.main(verbosity=2)
