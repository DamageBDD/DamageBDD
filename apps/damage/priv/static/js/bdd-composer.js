import { MAX_PROMPT_BYTES, EXAMPLES, promptBytes, apiHeaders, filterSteps, stepLine,
  appendStep, featureStats, canAcceptDraft, validationSummary, featureFilename } from './bdd-composer-model.js';

function boot() {
  const byId = id => document.getElementById(id);
  const root = byId('bdd-composer'), editor = byId('damageTextArea');
  if (!root || !editor) return;
  const prompt = byId('bdd-prompt'), generate = byId('bdd-generate');
  const state = { steps: [], engine: false, active: null, sequence: 0,
    catalogSequence: 0, validationSequence: 0, validationController: null, draft: null, undo: null };
  const token = () => { try { return window.TokenManager?.getToken(); } catch { return undefined; } };
  const notify = (message, tone = 'info') => {
    const el = byId('bdd-generation-status'); el.textContent = message; el.dataset.tone = tone;
  };

  async function api(action, body, { signal, timeout = 15000, auth = token() } = {}) {
    const controller = new AbortController();
    const abort = () => controller.abort();
    if (signal?.aborted) controller.abort();
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, timeout);
    try {
      const response = await fetch(`/ai/bdd/${action}`, {
        method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin', cache: 'no-store',
        headers: apiHeaders(auth), signal: controller.signal,
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      });
      if (response.status === 401) throw new Error('Your session has expired. Sign in again to continue.');
      let data;
      try { data = await response.json(); } catch { throw new Error(`The node returned an unreadable response (HTTP ${response.status}).`); }
      if (!response.ok) throw new Error(typeof data?.message === 'string' ? data.message : `Request failed (HTTP ${response.status}).`);
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('The node returned an invalid JSON response.');
      return data;
    } finally {
      clearTimeout(timer); signal?.removeEventListener('abort', abort);
    }
  }

  function controls() {
    const bytes = promptBytes(prompt.value), busy = !!state.active;
    byId('bdd-prompt-count').textContent = `${bytes} / ${MAX_PROMPT_BYTES} bytes`;
    generate.disabled = busy || !prompt.value.trim() || bytes > MAX_PROMPT_BYTES || !state.engine || !state.steps.length;
    generate.textContent = busy ? 'Generating…' : '✦ Generate draft';
    byId('bdd-cancel').hidden = !busy;
    prompt.readOnly = busy;
    byId('bdd-prompt-form').setAttribute('aria-busy', String(busy));
    byId('bdd-refresh-catalog').disabled = busy;
    root.querySelectorAll('[data-bdd-example]').forEach(button => { button.disabled = busy; });
  }
  function stats() {
    const counts = featureStats(editor.value);
    byId('bdd-editor-count').textContent = editor.value.trim()
      ? `${counts.scenarios} scenario${counts.scenarios === 1 ? '' : 's'} · ${counts.steps} steps` : 'No feature yet';
    byId('bdd-download').disabled = !editor.value.trim();
  }
  function dirty() {
    state.validationSequence++;
    state.validationController?.abort(); state.validationController = null;
    byId('bdd-validate').disabled = false;
    byId('bdd-validation-status').textContent = 'Editor changed. Validate signatures again before running.';
    byId('bdd-validation-status').dataset.tone = 'info';
    byId('bdd-diagnostics').replaceChildren(); stats();
  }
  function changeEditor(text) {
    editor.value = text;
    // Required by the existing IPFS selection, line numbers and editor hooks.
    editor.dispatchEvent(new Event('input', { bubbles: true }));
  }
  function goToLine(line) {
    const offset = editor.value.split('\n').slice(0, Math.max(0, line - 1)).reduce((n, s) => n + s.length + 1, 0);
    editor.focus(); editor.setSelectionRange(offset, offset);
  }
  function renderValidation(validation) {
    const status = byId('bdd-validation-status');
    status.textContent = validationSummary(validation);
    status.dataset.tone = validation?.valid === true ? 'ok' : 'error';
    const box = byId('bdd-diagnostics'); box.replaceChildren();
    for (const item of validation?.diagnostics || []) {
      const row = document.createElement('div'); row.className = 'diagnostic';
      if (Number.isInteger(item.line) && item.line > 0) {
        const link = document.createElement('button'); link.type = 'button'; link.textContent = `Line ${item.line}`;
        link.addEventListener('click', () => goToLine(item.line)); row.append(link);
      }
      const message = document.createElement('p'); message.textContent = item.message || 'Review this step.'; row.append(message); box.append(row);
    }
    if (validation?.required_variables?.length) {
      const p = document.createElement('p'); p.textContent = `Context values required: ${validation.required_variables.join(', ')}. Values were not read or verified.`; box.append(p);
    }
  }

  function renderSteps() {
    const results = filterSteps(state.steps, byId('bdd-step-search').value);
    byId('bdd-search-status').textContent = `${Math.min(30, results.length)} of ${results.length} matching signatures${results.length > 30 ? ' — refine your search' : ''}.`;
    const list = byId('bdd-step-results'); list.replaceChildren();
    for (const step of results.slice(0, 30)) {
      const row = document.createElement('div'); row.className = 'bdd-step-item';
      const info = document.createElement('div'), code = document.createElement('code'), meta = document.createElement('small');
      code.textContent = stepLine(step); meta.textContent = `${step.module}:${step.source_line} · deployed signature`;
      info.append(code, meta);
      const button = document.createElement('button'); button.type = 'button'; button.className = 'workspace-button';
      button.textContent = 'Insert'; button.setAttribute('aria-label', `Insert ${stepLine(step)}`);
      button.addEventListener('click', () => {
        const next = appendStep(editor.value, step); changeEditor(next.text);
        editor.focus(); editor.setSelectionRange(next.start, next.end);
        notify('Step inserted. Replace any <Parameter> markers, then validate.');
      });
      row.append(info, button); list.append(row);
    }
  }
  async function loadCatalog() {
    const sequence = ++state.catalogSequence;
    state.engine = false; state.steps = []; controls();
    byId('bdd-catalog-status').textContent = 'Loading step signatures…';
    try {
      const data = await api('catalog');
      if (sequence !== state.catalogSequence) return;
      state.steps = Array.isArray(data.steps) ? data.steps.filter(s => typeof s.template === 'string' && Array.isArray(s.keywords)) : [];
      state.engine = data.engine?.generator_available === true;
      const missing = data.unavailable_modules?.length || 0;
      byId('bdd-catalog-status').textContent = `${state.steps.length} signatures · ${data.module_count || 0} module${data.module_count === 1 ? "" : "s"}${missing ? ` · ${missing} unavailable` : ''}`;
      byId('bdd-step-total').textContent = `${state.steps.length} signatures`;
      if (!state.engine) notify('ECAI generation is unavailable on this node. You can still edit features, browse steps and validate signatures.', 'error');
      else if (!state.steps.length) notify('No authoritative step signatures are available. Check the node’s BEAM debug information or catalog manifest.', 'error');
      else if (missing) notify('Some modules have no matching debug information or manifest. Their steps are excluded from static checks.', 'info');
      else notify('');
      renderSteps();
    } catch (error) {
      if (sequence !== state.catalogSequence) return;
      byId('bdd-catalog-status').textContent = 'Step catalog unavailable';
      notify(error.name === 'AbortError' ? 'Step catalog request timed out. Refresh to retry.' : error.message, 'error');
    } finally { if (sequence === state.catalogSequence) controls(); }
  }

  function draftNotes(draft) {
    const box = byId('bdd-draft-notes'); box.replaceChildren();
    const add = text => { const p = document.createElement('p'); p.textContent = text; box.append(p); };
    add(validationSummary(draft.validation));
    add(`ECAI knowledge cards used: ${draft.grounding?.knowledge_cards || 0}. Deployed signatures remain the validation authority.`);
    for (const note of draft.assumptions || []) add(`Assumption: ${note}`);
    for (const note of draft.missing_steps || []) add(`Unsupported requirement: ${note}`);
    for (const d of draft.validation?.diagnostics || []) add(`${d.line ? `Line ${d.line}: ` : ''}${d.message}`);
    if (draft.validation?.required_variables?.length) add(`Context values to supply: ${draft.validation.required_variables.join(', ')}.`);
    add('Review targets, inputs, permissions and assertions. Static validation does not prove runtime success.');
  }
  async function generateDraft(event) {
    event?.preventDefault();
    if (state.active || generate.disabled) return;
    const requestId = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
      : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
    const job = { id: requestId, controller: new AbortController(), auth: token(), sequence: ++state.sequence };
    state.active = job; state.draft = null;
    byId('bdd-draft-panel').hidden = true; byId('bdd-accept').disabled = true;
    controls(); notify('Generating a reviewable feature from available step signatures…');
    const started = performance.now();
    job.timer = setInterval(() => { byId('bdd-elapsed').textContent = `${Math.floor((performance.now() - started) / 1000)}s elapsed`; }, 1000);
    try {
      const draft = await api('generate', { request_id: job.id, user_prompt: prompt.value.trim() },
        { signal: job.controller.signal, auth: job.auth, timeout: 310000 });
      if (state.active !== job || job.sequence !== state.sequence) return;
      if (typeof draft.feature !== 'string' || !draft.validation) throw new Error('The node did not return a feature and validation result.');
      state.draft = draft;
      byId('bdd-draft-source').textContent = draft.feature;
      byId('bdd-draft-panel').hidden = false;
      byId('bdd-accept').disabled = !canAcceptDraft(draft);
      draftNotes(draft);
      notify(canAcceptDraft(draft) ? 'Draft checked. Review it, then choose “Use draft in editor”. Nothing has been run.'
        : 'This draft needs changes. Review the issues below and refine your prompt. Nothing has been run.',
        canAcceptDraft(draft) ? 'ok' : 'error');
    } catch (error) {
      if (state.active !== job || job.sequence !== state.sequence) return;
      notify(error.name === 'AbortError' ? 'Stopped waiting for generation. The node enforces its own deadline.' : error.message, 'error');
    } finally {
      clearInterval(job.timer);
      if (state.active === job && !job.cancelling) { state.active = null; byId('bdd-elapsed').textContent = ''; controls(); }
    }
  }
  async function cancelGeneration() {
    const job = state.active; if (!job) return;
    job.cancelling = true; state.sequence++; job.controller.abort(); clearInterval(job.timer);
    byId('bdd-cancel').disabled = true; notify('Cancelling generation…');
    try {
      const result = await api('cancel', { request_id: job.id }, { auth: job.auth });
      if (state.active === job) notify(result.cancelled === true
        ? 'Generation cancelled. Your editor has not changed.'
        : 'Stopped waiting. No matching active job was found; any late request remains bounded by the node deadline.');
    } catch {
      if (state.active === job) notify('Stopped waiting. Cancellation could not be confirmed; the node job remains bounded by its deadline.', 'error');
    } finally {
      if (state.active === job) { state.active = null; byId('bdd-elapsed').textContent = ''; controls(); }
      byId('bdd-cancel').disabled = false;
    }
  }
  async function validateEditor() {
    const text = editor.value, sequence = ++state.validationSequence;
    state.validationController?.abort();
    const controller = new AbortController(); state.validationController = controller;
    byId('bdd-validate').disabled = true;
    byId('bdd-validation-status').textContent = 'Checking Gherkin syntax and step signatures…';
    try {
      const data = await api('validate', { feature: text }, { signal: controller.signal });
      if (sequence !== state.validationSequence || text !== editor.value) return;
      renderValidation(data.validation);
    } catch (error) {
      if (sequence !== state.validationSequence || text !== editor.value) return;
      byId('bdd-validation-status').textContent = error.name === 'AbortError' ? 'Validation timed out. Retry when the node is available.' : error.message;
      byId('bdd-validation-status').dataset.tone = 'error';
    } finally {
      if (sequence === state.validationSequence) { byId('bdd-validate').disabled = false; state.validationController = null; }
    }
  }
  async function copy(text, message) {
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(text); notify(message);
    } catch { notify('Clipboard access was blocked. Select the text and copy it manually.', 'error'); }
  }

  byId('bdd-prompt-form').addEventListener('submit', generateDraft);
  prompt.addEventListener('input', controls);
  prompt.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); byId('bdd-prompt-form').requestSubmit(); }
  });
  root.querySelectorAll('[data-bdd-example]').forEach(button => button.addEventListener('click', () => {
    prompt.value = EXAMPLES[button.dataset.bddExample] || ''; controls(); prompt.focus();
  }));
  byId('bdd-cancel').addEventListener('click', cancelGeneration);
  byId('bdd-refresh-catalog')?.addEventListener('click', loadCatalog);
  byId('bdd-step-search').addEventListener('input', renderSteps);
  byId('bdd-copy-draft').addEventListener('click', () => copy(state.draft?.feature || '', 'Draft copied.'));
  byId('bdd-accept').addEventListener('click', () => {
    if (!canAcceptDraft(state.draft) || state.active) return;
    const ipfs = !byId('selected-ipfs-feature')?.hidden;
    if ((editor.value.trim() && editor.value !== state.draft.feature) || ipfs) {
      if (!window.confirm('Replace the current editor text with this draft and use editor text instead of an IPFS selection? The previous editor text can be restored with Undo draft.')) return;
    }
    state.undo = editor.value; byId('bdd-undo').hidden = false;
    changeEditor(state.draft.feature); renderValidation(state.draft.validation);
    byId('bdd-draft-panel').hidden = true; editor.focus();
    notify('Draft applied to the editor. Review it before explicitly choosing Run feature.');
  });
  byId('bdd-undo').addEventListener('click', () => {
    if (state.undo === null) return;
    if (!window.confirm('Restore the previous editor text? This replaces any changes made since applying the draft.')) return;
    changeEditor(state.undo); state.undo = null; byId('bdd-undo').hidden = true;
    notify('Previous editor text restored. Reselect an IPFS source separately when needed.');
  });
  byId('bdd-validate').addEventListener('click', validateEditor);
  byId('bdd-download').addEventListener('click', () => {
    const blob = new Blob([editor.value], { type: 'text/plain;charset=utf-8' }), url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = featureFilename(editor.value); a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  editor.addEventListener('input', dirty);
  editor.addEventListener('damage:source-loaded', dirty);
  editor.addEventListener('focus', stats);
  const reports = byId('run-reports');
  const updateReports = () => {
    byId('bdd-report-empty').hidden = !!byId('run-reports-ul')?.children.length;
    byId('bdd-copy-report').disabled = !reports.querySelector('code.report')?.textContent;
  };
  new MutationObserver(updateReports).observe(reports, { childList: true, subtree: true, characterData: true });
  byId('bdd-copy-report').addEventListener('click', () => {
    const outputs = reports.querySelectorAll('code.report');
    copy(outputs[outputs.length - 1]?.textContent || '', 'Latest run output copied.');
  });
  document.addEventListener('damage:execution-state', event => {
    const running = !!event.detail?.running;
    byId('bdd-run-status').dataset.running = String(running);
    byId('bdd-run-status').textContent = running ? 'Running' : 'Request complete';
  });
  document.addEventListener('auth:changed', () => {
    state.sequence++; state.active?.controller.abort(); clearInterval(state.active?.timer); state.active = null;
    state.draft = null; state.undo = null; byId('bdd-draft-panel').hidden = true; byId('bdd-undo').hidden = true;
    byId('bdd-elapsed').textContent = ''; dirty(); loadCatalog();
  });
  stats(); updateReports(); loadCatalog();
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
else boot();
