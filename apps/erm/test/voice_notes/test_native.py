"""Native protocol/PCM regression tests; no microphone or sound server needed."""
import os, pathlib, struct, subprocess, tempfile, time, unittest, math, json
BIN=pathlib.Path('apps/erm/priv/bin/erm_voice_notes_audio').resolve()
def packets(proc):
    while True:
        h=proc.stdout.read(4)
        if not h: return
        n=struct.unpack('>I',h)[0]
        assert n<=8192
        b=proc.stdout.read(n)
        assert len(b)==n
        yield b
class Native(unittest.TestCase):
    def launch(self, args):
        proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        def cleanup():
            if proc.poll() is None:proc.kill();proc.wait()
            proc.stdin.close();proc.stdout.close()
        self.addCleanup(cleanup)
        return proc
    def test_exact_pcm_and_duration(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'source.pcm'
            data=b''.join(struct.pack('<h',int(8000*math.sin(i/11))) for i in range(3200))
            p.write_bytes(data)
            proc=self.launch([str(BIN),'capture-file',str(p),'1000'])
            result=list(packets(proc));self.assertEqual(0,proc.wait())
            self.assertEqual(data,b''.join(x[1:] for x in result if x[:1]==b'A'))
            self.assertEqual(b'D\x02',result[-1])
    def test_max_duration_bounds(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'source.pcm';p.write_bytes(b'\x01\x00'*16000)
            proc=self.launch([str(BIN),'capture-file',str(p),'100'])
            result=list(packets(proc));self.assertEqual(0,proc.wait())
            self.assertEqual(3200,sum(len(x)-1 for x in result if x[:1]==b'A'))
            self.assertEqual(b'D\x01',result[-1])
    def test_stop_and_parent_eof(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'source.pcm';p.write_bytes(b'\x01\x00'*16000)
            proc=self.launch([str(BIN),'capture-file',str(p),'1000'])
            it=packets(proc);self.assertEqual(b'H',next(it)[:1]);next(it)
            proc.stdin.write(b'\0\0\0\1S');proc.stdin.flush()
            result=list(it);self.assertEqual(0,proc.wait(timeout=2));self.assertEqual(b'D\0',result[-1])
            proc=self.launch([str(BIN),'capture-file',str(p),'1000'])
            proc.stdin.close();list(packets(proc));self.assertEqual(0,proc.wait(timeout=2))
    def test_invalid_device_and_wav(self):
        proc=self.launch([str(BIN),'capture','default','1000'])
        self.assertEqual(b'E',next(packets(proc))[:1]);self.assertNotEqual(0,proc.wait())
        with tempfile.NamedTemporaryFile() as f:
            f.write(b'bad WAV');f.flush()
            proc=self.launch([str(BIN),'check-wav',f.name,'unused'])
            self.assertEqual(b'E',next(packets(proc))[:1]);self.assertNotEqual(0,proc.wait())
    @unittest.skipUnless(os.environ.get('ECAI_NOTES_TEST_EBIN'), 'requires compiled Erlang test modules')
    def test_cold_vm_reloads_saved_features(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'notes';source=pathlib.Path(d)/'source.pcm'
            source.write_bytes(b''.join(struct.pack('<h',int(8000*math.sin(2*math.pi*130*i/16000))) for i in range(28800)))
            def erl(expr):
                result=subprocess.run(['erl','+S','2:2','-noshell','-pa',os.environ['ECAI_NOTES_TEST_EBIN'],'-eval',expr],capture_output=True,text=True,timeout=10)
                self.assertEqual(0,result.returncode,result.stdout+result.stderr)
            expr=('{ok,P}=file:read_file('+json.dumps(str(source))+'),'
                '{ok,R}=erm_voice_notes_store:open('+json.dumps(str(root))+'),'
                '{ok,N,F}=erm_voice_notes_store:begin_note(R,"fixture"),ok=file:write(F,P),'
                '{ok,N1}=erm_voice_notes_store:finish(R,N,F,#{}),'
                'A=erm_voice_notes_analysis:analyze(R,N1),ready=maps:get(status,A),'
                'ok=erm_voice_notes_store:save(R,N1#{analysis=>A,speaker=><<"fixture">>,split=>train,transcription=>#{status=>unavailable}}),halt().')
            erl(expr)
            erl('{ok,_}=erm_voice_notes:start_link(#{directory=>'+json.dumps(str(root))+'}),'
                '[#{analysis:=#{status:=ready},speaker:= <<"fixture">>}]=erm_voice_notes:notes(),'
                'ok=erm_voice_notes:stop(),halt().')
if __name__=='__main__':unittest.main(verbosity=2)
