const api = globalThis.browser || globalThis.chrome;
const $ = id => document.getElementById(id);
let tab = null, state = {status:'idle', actions:[]};
const cmd = async data => api.runtime.sendMessage(data);
const showMessage = message => { $('message').textContent = message || ''; $('message').classList.toggle('hidden', !message); };
function render() {
  const recording = state.status === 'recording', paused = state.status === 'paused', stopped = state.status === 'stopped';
  const otherTab = state.tabId && tab && state.tabId !== tab.id;
  $('statePill').textContent = recording ? '● Recording' : paused ? 'Paused' : stopped ? 'Saved' : 'Ready';
  $('statePill').className = 'state-pill' + (recording ? ' active' : stopped ? ' saved' : '');
  $('stepCount').textContent = (state.actions || []).length;
  $('recordHint').textContent = recording ? 'Live capture' : paused ? 'Paused on this tab' : stopped ? 'Ready to export' : 'Nothing recorded yet';
  $('siteName').textContent = state.tabId ? state.title || 'Recorded browser tab' : tab?.title || 'Current browser tab';
  $('siteUrl').textContent = state.lastUrl || tab?.url || 'Choose a page to record';
  $('startButton').classList.toggle('hidden', recording || paused);
  $('startButton').innerHTML = stopped ? '<span class="record-dot"></span> Start a new recording' : '<span class="record-dot"></span> Start recording';
  $('controls').classList.toggle('hidden', !(recording || paused));
  $('pauseButton').textContent = paused ? 'Resume' : 'Pause';
  $('pauseButton').disabled = Boolean(otherTab);
  $('stopButton').textContent = 'Finish recording';
  $('assertButton').classList.toggle('hidden', !recording);
  $('assertButton').textContent = state.mode === 'assert' ? '✚ Click a visible text element…' : '✚ Add a text assertion';
  $('assertButton').disabled = Boolean(otherTab);
  showMessage(state.warning || (otherTab && (recording || paused) ? 'Switch back to the recorded tab to control this session.' : ''));
}
async function refresh() {
  const [tabs, result] = await Promise.all([api.tabs.query({active:true,currentWindow:true}), cmd({type:'GET_STATE'})]);
  tab = tabs[0] || null; state = result.state || state;
  render();
}
async function start() {
  if (state.status === 'stopped' && state.actions?.length && !confirm('Start a new recording? Export the previous one first if you want to keep it.')) return;
  if (!tab || !/^https?:\/\//.test(tab.url || '')) return showMessage('Open a normal website first (browser settings and new-tab pages cannot be recorded).');
  $('startButton').disabled = true; showMessage('');
  try {
    const origin = new URL(tab.url).origin + '/*';
    try { await api.permissions.request({origins:[origin]}); } catch {} // activeTab can still suffice.
    const result = await cmd({type:'START', tabId:tab.id, url:tab.url, title:tab.title});
    if (!result.ok) showMessage(result.message);
    await refresh();
  } finally { $('startButton').disabled = false; }
}
async function sendAndRefresh(data) { const result = await cmd(data); if (!result.ok) showMessage(result.message); else await refresh(); }
function openEditor() { api.tabs.create({url:api.runtime.getURL('editor.html')}); window.close(); }
$('startButton').addEventListener('click', start);
$('pauseButton').addEventListener('click', () => sendAndRefresh({type:state.status === 'paused' ? 'RESUME' : 'PAUSE'}));
$('stopButton').addEventListener('click', () => sendAndRefresh({type:'STOP'}));
$('assertButton').addEventListener('click', () => sendAndRefresh({type:'ASSERT_MODE', enabled:state.mode !== 'assert'}));
$('reviewButton').addEventListener('click', openEditor);
$('openEditor').addEventListener('click', openEditor);
refresh().catch(err => showMessage(String(err)));
