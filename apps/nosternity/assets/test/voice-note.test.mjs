import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';
import {mountVoiceNote,SilenceGate,recorderOptions,onDeviceAvailable} from '../src/voice-note.js';

const html=await readFile(new URL('../../priv/templates/ui/dashboard/voice-note.mustache',import.meta.url),'utf8');
const flush=()=>new Promise(r=>setTimeout(r,0));
async function until(fn){for(let i=0;i<30;i++){if(fn())return;await flush();}assert.fail('UI did not settle');}

async function fixture({local=false,permission,failures=0,transcription}={}) {
  const dom=new JSDOM(html,{url:'https://nostr.example',pretendToBeVisual:true});
  const w=dom.window,root=w.document.body,calls=[],inserted=[],revoked=[],recorders=[],recognizers=[],contexts=[];
  let now=0,rms=.1,stopped=0,intervalId=0;const intervals=new Map();
  Object.defineProperty(w,'isSecureContext',{value:true,configurable:true});
  w.HTMLMediaElement.prototype.pause=function(){};w.HTMLMediaElement.prototype.load=function(){};
  w.URL.createObjectURL=()=> 'blob:clip';w.URL.revokeObjectURL=u=>revoked.push(u);
  Object.defineProperty(w.performance,'now',{value:()=>now});
  w.setInterval=fn=>{const id=++intervalId;intervals.set(id,fn);return id;};w.clearInterval=id=>intervals.delete(id);
  const stream={getTracks:()=>[{stop:()=>{stopped++;}}]};
  Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:()=>permission?permission(stream):Promise.resolve(stream)}});
  w.AudioContext=class {state='running';constructor(){contexts.push(this);}resume(){return Promise.resolve();}
    close(){this.state='closed';return Promise.resolve();}createMediaStreamSource(){return{connect(){},disconnect(){}};}
    createAnalyser(){return {getFloatTimeDomainData:a=>a.fill(rms)};}};
  w.MediaRecorder=class {static isTypeSupported(t){return t==='audio/webm;codecs=opus';}
    state='inactive';constructor(stream,opts){this.options=opts;this.mimeType=opts.mimeType;recorders.push(this);}
    start(){this.state='recording';}stop(){this.state='inactive';queueMicrotask(()=>{
      this.ondataavailable?.({data:new w.Blob(['compressed clip'],{type:this.mimeType})});this.onstop?.();});}};
  w.SpeechRecognition=class {processLocally=false;static available(){return Promise.resolve(local?'available':'unavailable');}
    constructor(){recognizers.push(this);}start(){this.started=true;}
    stop(){queueMicrotask(()=>{const result=Object.assign([{transcript:'Hello from the microphone'}],{isFinal:true});
      this.onresult?.({results:[result]});this.onend?.();});}abort(){this.aborted=true;}};
  w.fetch=async(path,opts)=>{calls.push({path,opts});
    assert.equal(opts.credentials,'same-origin');assert.equal(opts.headers['X-Nosternity-Auth'],'1');
    if(path.endsWith('/options'))return{ok:true,json:async()=>({enabled:true,cleanup_enabled:true,max_duration_ms:30000,max_audio_bytes:2097152})};
    if(transcription)return transcription(opts);
    if(failures-->0)return{ok:false,json:async()=>({error:'transcription_unavailable'})};
    return{ok:true,json:async()=>({text:'Hello from ECAI.',raw_text:'hello from ecai',cleanup_applied:true})};
  };
  const widget=mountVoiceNote(root,{env:w,onInsert:t=>inserted.push(t)});
  const q=n=>root.querySelector('[data-voice="'+n+'"]');
  await until(()=>!q('status').textContent.startsWith('Checking'));
  function sample(at,level){now=at;rms=level;for(const fn of intervals.values())fn();}
  const speech=()=>{for(let t=50;t<=300;t+=50)sample(t,.1);};
  return {w,widget,q,root,calls,inserted,revoked,recorders,recognizers,contexts,sample,speech,
    stopped:()=>stopped,uploads:()=>calls.filter(c=>c.path.endsWith('/transcribe')),
    close(){widget.destroy();dom.window.close();}};
}

test('silence gate waits for speech, ignores a brief spike, then stops on pause or duration',()=>{
  const g=new SilenceGate(0);assert.equal(g.update(100,0),null);assert.equal(g.update(200,.2),null);
  assert.equal(g.update(1500,0),null);assert.equal(g.update(6000,0),'no-speech');
  const h=new SilenceGate(0);for(let t=50;t<=300;t+=50)assert.equal(h.update(t,.1),null);
  assert.equal(h.update(1499,0),null);assert.equal(h.update(1500,0),'silence');
  assert.equal(new SilenceGate(0).update(30000,.1),'limit');
});

test('codec preference chooses Opus, then AAC; unsupported compression fails',()=>{
  assert.equal(recorderOptions({isTypeSupported:t=>t.includes('opus')}).mimeType,'audio/webm;codecs=opus');
  assert.equal(recorderOptions({isTypeSupported:t=>t==='audio/mp4'}).mimeType,'audio/mp4');
  assert.throws(()=>recorderOptions({isTypeSupported:()=>false}),/compressed/);
});

test('browser recognition is considered local only with an explicit capability and installed pack',async()=>{
  assert.equal(await onDeviceAvailable(class{static available(){return Promise.resolve('available');}},'en-AU'),false);
  assert.equal(await onDeviceAvailable(class{processLocally=false;static available(){return Promise.resolve('downloadable');}},'en-AU'),false);
});

test('compressed recording stops on silence, uploads once, and inserts only after review',async()=>{
  const f=await fixture();try{
    await f.widget.start();assert.equal(f.recorders[0].options.audioBitsPerSecond,24000);
    assert.equal(f.recognizers.some(r=>r.started),false);f.speech();f.sample(1550,0);
    await until(()=>!f.widget.busy);assert.equal(f.stopped(),1);assert.equal(f.uploads().length,1);
    const opts=f.uploads()[0].opts;assert.equal(opts.body.type,'audio/webm;codecs=opus');
    assert.equal(opts.headers['X-Voice-Language'],'en');assert.equal(f.inserted.length,0);
    assert.equal(f.q('original').hidden,false);f.q('text').value='Reviewed transcript';f.q('insert').click();
    assert.deepEqual(f.inserted,['Reviewed transcript']);assert.equal(f.revoked.length,1);
  }finally{f.close();}
});

test('confirmed on-device recognition returns text without uploading the clip',async()=>{
  const f=await fixture({local:true});try{
    await f.widget.start();f.speech();f.widget.stop();await until(()=>!f.widget.busy);
    const r=f.recognizers.find(r=>r.started);assert.equal(r.processLocally,true);
    assert.equal(f.uploads().length,0);assert.equal(f.q('text').value,'Hello from the microphone');
  }finally{f.close();}
});

test('explicit browser speech mode may use remote recognition, auto never does',async()=>{
  const f=await fixture();try{
    f.q('mode').value='browser';await f.widget.start();f.speech();f.widget.stop();await until(()=>!f.widget.busy);
    assert.equal(f.recognizers.find(r=>r.started).processLocally,false);assert.equal(f.uploads().length,0);
  }finally{f.close();}
});

test('an early-ended recognizer discards partial text and transcribes the full clip with ECAI',async()=>{
  const f=await fixture({local:true});try{
    await f.widget.start();f.speech();const r=f.recognizers.find(r=>r.started);r.onend();
    f.widget.stop();await until(()=>!f.widget.busy);assert.equal(f.uploads().length,1);
  }finally{f.close();}
});

test('silence-only clip never goes to the model',async()=>{
  const f=await fixture();try{await f.widget.start();f.sample(6100,0);await until(()=>!f.widget.busy);
    assert.equal(f.uploads().length,0);assert.match(f.q('status').textContent,/No speech/);assert.equal(f.stopped(),1);
  }finally{f.close();}
});

test('permission denied closes audio context and leaves typing usable',async()=>{
  const f=await fixture({permission:async()=>{throw Object.assign(Error(),{name:'NotAllowedError'});}});try{
    await f.widget.start();assert.equal(f.widget.busy,false);assert.equal(f.contexts[0].state,'closed');
    assert.match(f.q('status').textContent,/denied/);assert.equal(f.uploads().length,0);
  }finally{f.close();}
});

test('release/destroy during a permission prompt stops a late microphone stream',async()=>{
  let permit;const f=await fixture({permission:stream=>new Promise(resolve=>{permit=()=>resolve(stream);})});try{
    const starting=f.widget.start();f.widget.stop();f.widget.destroy();permit();await starting;
    assert.equal(f.stopped(),1);assert.equal(f.recorders.length,0);assert.equal(f.uploads().length,0);
  }finally{f.close();}
});

test('a failed upload retains the same clip for retry and escapes transcript markup',async()=>{
  const f=await fixture({failures:1});try{
    await f.widget.start();f.speech();f.widget.stop();await until(()=>!f.widget.busy);
    assert.equal(f.q('review').hidden,false);assert.equal(f.q('retry').hidden,false);
    f.q('retry').click();await until(()=>!f.widget.busy);assert.equal(f.uploads().length,2);
    assert.equal(f.uploads()[0].opts.body,f.uploads()[1].opts.body);
    f.q('text').value='<img src=x onerror=alert(1)>';assert.equal(f.root.querySelector('img'),null);
  }finally{f.close();}
});

test('discard during transcription aborts upload and ignores its late response',async()=>{
  let resolve;const f=await fixture({transcription:()=>new Promise(r=>{resolve=r;})});try{
    await f.widget.start();f.speech();f.widget.stop();await until(()=>f.uploads().length===1);
    const signal=f.uploads()[0].opts.signal;f.widget.cancel();assert.equal(signal.aborted,true);
    resolve({ok:true,json:async()=>({text:'Late response'})});await flush();
    assert.equal(f.q('text').value,'');assert.equal(f.q('review').hidden,true);assert.equal(f.revoked.length,1);
  }finally{f.close();}
});

test('hiding the tab stops capture and does not transcribe',async()=>{
  const f=await fixture();try{await f.widget.start();f.speech();
    Object.defineProperty(f.w.document,'hidden',{value:true});f.w.document.dispatchEvent(new f.w.Event('visibilitychange'));
    await flush();assert.equal(f.widget.busy,false);assert.equal(f.stopped(),1);assert.equal(f.uploads().length,0);
  }finally{f.close();}
});

test('keyboard push-to-talk stops on key release; cap stops even with continuous speech',async()=>{
  const f=await fixture();try{
    f.q('ptt').dispatchEvent(new f.w.KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}));
    await until(()=>f.recorders.length===1);f.speech();
    f.q('ptt').dispatchEvent(new f.w.KeyboardEvent('keyup',{key:' ',bubbles:true,cancelable:true}));
    await until(()=>!f.widget.busy);assert.equal(f.uploads().length,1);
    await f.widget.start();for(let t=350;t<=650;t+=50)f.sample(t,.1);f.sample(30000,.1);
    await until(()=>!f.widget.busy);assert.equal(f.stopped(),2);
  }finally{f.close();}
});
