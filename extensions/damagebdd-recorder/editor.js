import {makeFeature, actionPreview, featureFilename} from './recorder-core.mjs';
const api = globalThis.browser || globalThis.chrome;
const $ = id => document.getElementById(id);
let session = {status: 'idle', actions: [], title: ''};
let custom = false;
const message = async data => api.runtime.sendMessage(data);
const icon = {navigation:'↗', click:'↖', fill:'≡', secret:'◈', select:'▾', check:'☑', press:'↵', assertText:'✓'};
const notice = (message, good = false) => { $('notice').textContent = message; $('notice').className = 'info-banner' + (good ? ' good' : '') + (!message ? ' hidden' : ''); };
function renderTimeline() {
  const previousScroll = $('timeline').scrollTop;
  $('timeline').replaceChildren();
  const entries = session.actions || [];
  $('actionCount').textContent = entries.length;
  if (!entries.length) {
    const div = document.createElement('div'); div.className = 'empty-state';
    div.innerHTML = '<div class="empty-illustration">◎</div><h3>Your story starts in the browser</h3><p>Click the extension icon on a web page and press <strong>Start recording</strong>. Your steps appear here as you explore.</p>';
    $('timeline').append(div); return;
  }
  entries.forEach((item, index) => {
    const row = document.createElement('div'); row.className = 'timeline-row' + (item.enabled === false ? ' off' : '');
    const check = document.createElement('input'); check.type = 'checkbox'; check.checked = item.enabled !== false; check.setAttribute('aria-label', 'Include step ' + (index + 1));
    check.addEventListener('change', async () => { item.enabled = check.checked; await persist(); });
    const type = document.createElement('span'); type.className = 'step-icon'; type.textContent = icon[item.kind] || '•';
    const text = document.createElement('div'); text.className = 'step-text';
    const heading = document.createElement('strong'); heading.textContent = actionPreview(item);
    const detail = document.createElement('small'); detail.textContent = item.selector || item.url || '';
    text.append(heading, detail);
    const commands = document.createElement('div'); commands.className = 'row-actions';
    for (const [symbol, movement, title] of [['↑',-1,'Move step up'],['↓',1,'Move step down']]) {
      const button = document.createElement('button'); button.textContent = symbol; button.title = title; button.setAttribute('aria-label', title);
      button.disabled = index + movement < 0 || index + movement >= entries.length;
      button.addEventListener('click', async () => { const [entry] = entries.splice(index, 1); entries.splice(index + movement, 0, entry); await persist(); });
      commands.append(button);
    }
    row.append(check, type, text, commands); $('timeline').append(row);
  });
  $('timeline').scrollTop = previousScroll;
}
function renderCode() {
  if (custom) return;
  try {
    const result = makeFeature(session);
    $('source').value = result.text;
    $('codeInfo').textContent = `${result.steps} executable steps · ${result.text.split('\n').length - 1} lines`;
    if (session.warning) notice(session.warning);
    else if (result.warnings.length) notice(result.warnings.join(' '));
    else notice('');
  } catch (err) { $('source').value = ''; $('codeInfo').textContent = 'Fix the recording before export'; notice(err.message || 'Could not generate a valid feature.'); }
}
function render() {
  const status = session.status || 'idle';
  $('editorStatus').textContent = status === 'recording' ? '● Recording live' : status === 'paused' ? 'Ⅱ Paused' : status === 'stopped' ? '✓ Recording saved' : '○ Ready to record';
  if (document.activeElement !== $('featureTitle')) $('featureTitle').value = session.title || '';
  renderTimeline(); renderCode();
}
async function reload() { const res = await message({type:'GET_STATE'}); if (res?.ok) { session = res.state; render(); } }
async function persist() {
  const res = await message({type:'UPDATE', title:session.title, actions:session.actions});
  if (res?.ok) { session = res.state; render(); } else notice(res.message || 'Could not save changes');
}
$('featureTitle').addEventListener('change', async ev => { session.title = ev.target.value.trim(); await persist(); });
$('editCode').addEventListener('click', () => {
  if (!custom) {
    custom = true; $('source').readOnly = false; $('editCode').textContent = 'Regenerate';
    notice('You are editing Gherkin directly. Your changes will be exported but will not update the step timeline.'); $('source').focus();
  } else { custom = false; $('source').readOnly = true; $('editCode').textContent = 'Edit source'; renderCode(); }
});
const output = () => $('source').value.trim() ? $('source').value.replace(/\s*$/, '\n') : '';
function download() {
  const value = output(); if (!value) return notice('Record at least one page before exporting.');
  const url = URL.createObjectURL(new Blob([value], {type:'text/plain;charset=utf-8'}));
  const a = document.createElement('a'); a.href = url; a.download = featureFilename(session.title); a.click();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
  notice(`${a.download} is exported. Replay it on a configured DamageBDD node as node_admin.`, true);
}
$('download').addEventListener('click', download);
$('downloadTop').addEventListener('click', download);
$('copyCode').addEventListener('click', async () => {
  if (!output()) return notice('There are no steps to copy yet.');
  try { await navigator.clipboard.writeText(output()); notice('Gherkin copied to clipboard.', true); }
  catch { $('source').focus(); $('source').select(); document.execCommand('copy'); notice('Gherkin copied.', true); }
});
$('recordTab').addEventListener('click', async () => {
  if (!session.tabId) return notice('Start a recording first.');
  try { await api.tabs.update(session.tabId, {active:true}); }
  catch { notice('The original tab is no longer available.'); }
});
$('newRecording').addEventListener('click', async () => {
  if (!confirm('Clear this local recording and all its steps? Export first if you want to keep it.')) return;
  const result = await message({type:'CLEAR'});
  if (result.ok) { custom = false; $('source').readOnly = true; $('editCode').textContent = 'Edit source'; await reload(); }
});
reload().catch(err => notice(String(err)));
// Keep a live read-only preview while recording; avoid overwriting manual edits.
setInterval(async () => {
  if (custom || document.activeElement === $('featureTitle') || session.status !== 'recording') return;
  await reload();
}, 2000);
