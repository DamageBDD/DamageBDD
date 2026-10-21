// One disposable recorder per composer. Audio, drafts and object URLs stay in memory.
export const LIMITS = Object.freeze({maxMs:30000, maxBytes:2097152, silenceMs:1200,
  noSpeechMs:6000, minSpeechMs:150, threshold:0.015});

export function recorderOptions(Recorder) {
  for (const mimeType of ['audio/webm;codecs=opus','audio/ogg;codecs=opus','audio/mp4']) {
    if (Recorder.isTypeSupported?.(mimeType)) return {mimeType, audioBitsPerSecond:24000};
  }
  // Do not silently record unbounded PCM when compressed recording is unavailable.
  throw Error('This browser cannot record a supported compressed audio format. You can still type your note.');
}

export class SilenceGate {
  constructor(start, limits=LIMITS) { this.start=start; this.last=start; this.voicedMs=0; this.previous=start; this.limits=limits; }
  update(now, rms) {
    const l=this.limits, step=Math.min(100, Math.max(0,now-this.previous)); this.previous=now;
    if(rms>=l.threshold) { this.last=now; this.voicedMs+=step; }
    if(now-this.start>=l.maxMs) return 'limit';
    if(this.voicedMs>=l.minSpeechMs && now-this.last>=l.silenceMs) return 'silence';
    if(this.voicedMs<l.minSpeechMs && now-this.start>=l.noSpeechMs) return 'no-speech';
    return null;
  }
  get heardSpeech() { return this.voicedMs>=this.limits.minSpeechMs; }
}

export async function onDeviceAvailable(Recognition, lang) {
  try {
    if(!Recognition || !('processLocally' in new Recognition()) || !Recognition.available) return false;
    return await Promise.race([Recognition.available({langs:[lang],processLocally:true,quality:'dictation'}),
      new Promise(resolve=>setTimeout(()=>resolve('unavailable'),1500))]) === 'available';
  } catch { return false; }
}

const errors={unauthorized:'Your session expired. Sign in again.',voice_disabled:'ECAI transcription is not enabled on this node.',
 voice_busy:'The transcriber is busy. Keep this clip and retry shortly.',rate_limited:'Too many requests. Wait a minute and retry.',
 no_speech:'No speech was detected. Try speaking closer to the microphone.',audio_too_long:'The clip exceeds the server duration limit.',
 invalid_audio:'This recording could not be decoded.',body_too_large:'The recording is too large.',
 transcription_unavailable:'The speech server is unavailable. Keep this clip and retry.',
 voice_config_invalid:'The voice server configuration needs attention.',transcription_timeout:'Transcription timed out. You can retry this clip.'};

export function mountVoiceNote(root,{onInsert, env=window}={}) {
  const q=name=>root.querySelector('[data-voice="'+name+'"]');
  const Recognition=env.SpeechRecognition||env.webkitSpeechRecognition;
  const controller=new env.AbortController();
  let disposed=false, current=null, clip=null, url=null, sequence=0, local=false, probe=0;
  let server={enabled:false,cleanup_enabled:false,max_duration_ms:30000,max_audio_bytes:2097152};
  const setStatus=text=>{if(!disposed)q('status').textContent=text;};
  const busy=()=>!!current;
  function controls() {
    const recording=current?.phase==='recording', waiting=current?.phase==='requesting';
    const working=busy()&&!recording&&!waiting;
    q('ptt').disabled=working; q('toggle').disabled=working;
    q('ptt').setAttribute('aria-pressed',String(recording));
    q('ptt').textContent=recording?'● Recording…':'● Hold to talk';
    q('toggle').textContent=recording||waiting?'Stop':'Tap to record';
    q('mode').disabled=busy();q('language').disabled=busy();q('text').disabled=busy();
    q('cleanup').disabled=busy()||!server.cleanup_enabled;
    q('cancel').hidden=!busy()&&!clip;
    q('insert').disabled=busy()||!q('text').value.trim();
  }
  function clearClip() {
    if(url)env.URL.revokeObjectURL(url);url=null;clip=null;
    q('audio').pause();q('audio').removeAttribute('src');q('audio').load();
    q('review').hidden=true;q('text').value='';q('raw').textContent='';q('time').textContent='0:00';
    q('original').hidden=true;q('retry').hidden=true;
  }
  function release(s) {
    if(s.released)return;s.released=true;
    env.clearInterval(s.timer);env.clearTimeout(s.hardTimer);
    s.stream?.getTracks().forEach(t=>t.stop());s.source?.disconnect();
    if(s.context)void s.context.close().catch(()=>{});
    q('level').value=0;
  }
  function cancel(message='Recording discarded.') {
    const s=current;current=null;sequence++;
    if(s){s.abort?.abort();try{s.recognition?.abort();}catch{};try{if(s.recorder?.state==='recording')s.recorder.stop();}catch{};release(s);}
    clearClip();controls();setStatus(message);
  }
  async function probeLocal() {
    const id=++probe;local=false;
    const result=await onDeviceAvailable(Recognition,q('language').value);
    if(disposed||id!==probe)return;local=result;
    if(!busy())setStatus(result?'On-device transcription is available. Hold or tap to talk.':
      server.enabled?'Ready. ECAI will transcribe this clip.':
      Recognition?'On-device transcription is unavailable. Select the browser speech service or ask the operator to enable ECAI.':
      'Recording is available. Ask the operator to enable ECAI transcription.');
  }
  async function request(path,options={},signal=controller.signal) {
    const response=await env.fetch(path,{...options,credentials:'same-origin',signal,
      headers:{Accept:'application/json','X-Nosternity-Auth':'1',...options.headers}});
    let body;try{body=await response.json();}catch{throw Error('The voice server did not return JSON.');}
    if(!response.ok)throw Error(errors[body.error]||'Voice request failed. Please retry.');
    return body;
  }
  function recognize(s) {
    if(!Recognition||s.mode==='server'||(s.mode==='auto'&&!local))return;
    const r=new Recognition();s.recognition=r;s.finalText='';s.recognitionOK=true;
    s.recognitionDone=new Promise(resolve=>{s.resolveRecognition=resolve;});
    r.lang=s.lang;r.continuous=true;r.interimResults=true;r.maxAlternatives=1;
    if(s.mode==='auto')r.processLocally=true;
    else if('processLocally' in r)r.processLocally=false;
    r.onresult=e=>{
      if(current!==s)return;
      const final=[],interim=[];
      for(let i=0;i<e.results.length;i++)(e.results[i].isFinal?final:interim).push(e.results[i][0].transcript);
      s.finalText=final.join(' ').trim();
      if(s.phase==='recording')setStatus('Listening… '+[s.finalText,...interim].join(' ').trim());
    };
    r.onerror=()=>{s.recognitionOK=false;s.resolveRecognition();};
    r.onend=()=>{s.recognitionEnded=true;if(s.phase==='recording')s.recognitionOK=false;s.resolveRecognition();};
    try{r.start();}catch{s.recognitionOK=false;s.resolveRecognition();}
  }
  async function start() {
    if(disposed||busy())return;
    clearClip();
    const s={id:++sequence,phase:'requesting',chunks:[],size:0,mode:q('mode').value,
      lang:q('language').value,cleanup:q('cleanup').checked};current=s;controls();
    setStatus('Allow microphone access, then keep holding or use Tap to record.');
    try {
      if(!env.isSecureContext)throw Error('Microphone recording needs HTTPS or localhost.');
      if(!env.navigator.mediaDevices?.getUserMedia||!env.MediaRecorder||!(env.AudioContext||env.webkitAudioContext))
        throw Error('Voice recording is unavailable in this browser. You can still type your note.');
      const options=recorderOptions(env.MediaRecorder);
      // Create/resume AudioContext during the user gesture, before the permission await.
      s.context=new (env.AudioContext||env.webkitAudioContext)();
      const resumed=s.context.resume();resumed.catch(()=>{});
      const stream=await env.navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,
        noiseSuppression:true,autoGainControl:true},video:false});
      if(current!==s||disposed){stream.getTracks().forEach(t=>t.stop());return;}
      s.stream=stream;await resumed;
      if(current!==s||disposed)return;
      if(s.context.state==='suspended')throw Error('Audio is suspended. Tap to record after granting microphone permission.');
      s.source=s.context.createMediaStreamSource(stream);s.analyser=s.context.createAnalyser();
      s.analyser.fftSize=2048;s.source.connect(s.analyser);s.samples=new Float32Array(2048);
      s.recorder=new env.MediaRecorder(stream,options);
      s.recorder.ondataavailable=e=>{if(current!==s||!e.data.size)return;s.size+=e.data.size;
        if(s.size>Math.min(LIMITS.maxBytes,server.max_audio_bytes)){cancel('Recording exceeded the size limit. Try a shorter clip.');return;}s.chunks.push(e.data);};
      s.recorder.onerror=()=>{if(current===s)cancel('Recording failed. Check microphone access and try again.');};
      s.recorder.onstop=()=>{if(current!==s)return;if(s.phase==='recording')cancel('Recording was interrupted. Please try again.');else void finish(s);};
      s.phase='recording';s.start=env.performance.now();
      s.gate=new SilenceGate(s.start,{...LIMITS,maxMs:Math.min(LIMITS.maxMs,server.max_duration_ms)-300});
      s.recorder.start(250);recognize(s);controls();
      setStatus(s.recognition?(s.mode==='auto'?'Listening on this device…':'Listening with the browser speech service…'):'Recording for ECAI transcription…');
      s.timer=env.setInterval(()=>{
        if(current!==s||s.phase!=='recording')return;
        s.analyser.getFloatTimeDomainData(s.samples);
        const rms=Math.sqrt(s.samples.reduce((sum,x)=>sum+x*x,0)/s.samples.length);
        const now=env.performance.now();q('level').value=Math.min(1,rms*5);
        q('time').textContent='0:'+String(Math.floor((now-s.start)/1000)).padStart(2,'0');
        const reason=s.gate.update(now,rms);if(reason)stop(reason);
      },50);
      s.hardTimer=env.setTimeout(()=>stop('limit'),s.gate.limits.maxMs);
    } catch(e) {
      if(current!==s)return;
      cancel(e.name==='NotAllowedError'?'Microphone permission was denied. Allow access and try again.':
        e.name==='NotFoundError'?'No microphone was found. Connect one and try again.':e.message);
    }
  }
  function stop(reason='release') {
    const s=current;if(!s)return;
    if(s.phase==='requesting'){cancel('Released before recording started. Tap to record when permission is ready.');return;}
    if(s.phase!=='recording')return;
    s.phase='finishing';s.reason=reason;controls();
    setStatus(reason==='silence'?'Pause detected. Finishing clip…':'Finishing clip…');
    try{s.recognition?.stop();}catch{s.recognitionOK=false;s.resolveRecognition?.();}
    try{s.recorder.stop();}catch{cancel('Could not finish this recording.');return;}
    release(s);
  }
  async function finish(s) {
    if(current!==s||disposed)return;
    if(s.recognitionDone){let timer;await Promise.race([s.recognitionDone,new Promise(resolve=>{timer=env.setTimeout(()=>{
      s.recognitionOK=false;resolve();},1500);})]);env.clearTimeout(timer);}
    if(!s.recognitionEnded)try{s.recognition?.abort();}catch{}
    if(current!==s||disposed)return;
    if(s.reason==='no-speech'||!s.gate.heardSpeech){cancel('No speech detected. Try again closer to the microphone.');return;}
    const blob=new env.Blob(s.chunks,{type:s.recorder.mimeType});
    s.chunks=[];
    if(!blob.size){cancel('The recording was empty. Try again.');return;}
    clip={blob,lang:s.lang,cleanup:s.cleanup};url=env.URL.createObjectURL(blob);
    q('audio').src=url;q('review').hidden=false;
    if(s.recognitionOK&&s.finalText){showText(s.finalText,s.finalText);
      setStatus(s.mode==='auto'?'Transcribed on this device. Review and insert your text.':'Transcribed by the browser speech service. Review your text.');
      current=null;controls();return;}
    current=null;await transcribe();
  }
  function showText(text,raw) {
    q('text').value=text;q('raw').textContent=raw;q('original').hidden=text===raw;
  }
  async function transcribe() {
    if(!clip||busy()||disposed)return;
    q('retry').hidden=true;
    if(!server.enabled){q('retry').hidden=false;setStatus('ECAI transcription is disabled. You can listen to the clip and type a transcript.');controls();return;}
    const s={id:++sequence,phase:'transcribing',abort:new env.AbortController()};current=s;controls();
    setStatus('Transcribing with ECAI / Whisper…');
    const timer=env.setTimeout(()=>s.abort.abort(),65000);
    try {
      const result=await request('/api/nosternity/voice/transcribe',{method:'POST',body:clip.blob,
        headers:{'Content-Type':clip.blob.type,'X-Voice-Language':clip.lang.split('-')[0],
          'X-Voice-Cleanup':clip.cleanup?'1':'0'}},s.abort.signal);
      if(current!==s||disposed)return;
      if(typeof result.text!=='string'||!result.text.trim())throw Error('No transcript was returned. Listen to the clip or retry.');
      showText(result.text,typeof result.raw_text==='string'?result.raw_text:result.text);
      setStatus(result.cleanup_applied?'Transcribed and polished. Compare the original before inserting.':
        result.warning?'Transcribed. Ollama cleanup was unavailable; the original is preserved.':'Transcribed. Review and insert your text.');
    } catch(e) {if(current===s&&!disposed){setStatus(e.name==='AbortError'?'Transcription timed out. Your clip is available to retry.':e.message);q('retry').hidden=false;}}
    finally {env.clearTimeout(timer);if(current===s){current=null;controls();}}
  }
  const listen=(el,event,fn)=>el.addEventListener(event,fn,{signal:controller.signal});
  listen(q('ptt'),'pointerdown',e=>{if(e.button!==0||!e.isPrimary)return;e.preventDefault();q('ptt').setPointerCapture?.(e.pointerId);void start();});
  listen(q('ptt'),'pointerup',()=>stop());
  listen(q('ptt'),'pointercancel',()=>cancel());
  listen(q('ptt'),'lostpointercapture',()=>{if(current?.phase==='recording'||current?.phase==='requesting')stop();});
  listen(q('ptt'),'keydown',e=>{if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();void start();}});
  listen(q('ptt'),'keyup',e=>{if(e.key===' '||e.key==='Enter'){e.preventDefault();stop();}});
  listen(q('ptt'),'click',e=>e.preventDefault());
  listen(q('toggle'),'click',()=>{if(busy())stop();else void start();});
  listen(q('cancel'),'click',()=>cancel());listen(q('retry'),'click',()=>{void transcribe();});
  listen(q('text'),'input',controls);
  listen(q('insert'),'click',()=>{
    const text=q('text').value.trim();if(!text||busy())return;
    try{onInsert(text);cancel('Transcript inserted. Review the note before publishing.');}catch(e){setStatus(e.message);}
  });
  listen(q('language'),'change',()=>{void probeLocal();});
  listen(q('mode'),'change',()=>setStatus(q('mode').value==='browser'?
    'Your browser may send audio to its speech provider. Select ECAI to use this node instead.':
    'Automatic mode uses confirmed on-device recognition, with ECAI as the fallback.'));
  listen(env.document,'visibilitychange',()=>{if(env.document.hidden&&busy())cancel('Recording cancelled when this tab was hidden.');});
  listen(env,'pagehide',()=>cancel());
  q('mode').querySelector('[value="browser"]').disabled=!Recognition;
  controls();
  void request('/api/nosternity/voice/options').then(options=>{
    if(disposed)return;server={...server,...options};controls();return probeLocal();
  }).catch(()=>{if(!disposed)void probeLocal();});
  return {start,stop,cancel,get busy(){return busy();},destroy(){if(disposed)return;cancel();disposed=true;probe++;controller.abort();}};
}
