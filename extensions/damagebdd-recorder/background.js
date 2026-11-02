/* DamageBDD Recorder — persistent session state belongs to storage.local, never a tab.
 * Chrome uses an MV3 worker; Firefox uses a background event page. No user data
 * is sent to a server by this extension. */
(() => {
  'use strict';
  const api = globalThis.browser || globalThis.chrome;
  const KEY = 'damagebdd.recorder.session.v1';
  const validEvents = new Set(['click', 'fill', 'secret', 'select', 'check', 'press', 'assertText', 'navigation']);
  const validStates = new Set(['recording', 'paused', 'stopped']);
  let queue = Promise.resolve();
  const enqueue = (job) => {
    const next = queue.then(job);
    queue = next.catch(() => {});
    return next;
  };
  const read = async () => ({...(await api.storage.local.get(KEY))[KEY] || {status: 'idle', actions: []}});
  const write = async (s) => { await api.storage.local.set({[KEY]: s}); return s; };
  const isWeb = (url) => /^https?:\/\//i.test(url || '');
  const limit = (value, length) => typeof value === 'string' ? value.slice(0, length) : '';
  const cleanUrl = (raw) => {
    try {
      const u = new URL(raw);
      if (!['https:', 'http:'].includes(u.protocol)) return '';
      u.username = ''; u.password = '';
      // Preserve safe hash-based SPA routes; discard arbitrary fragments and auth callbacks.
      if (!/^#!?\//.test(u.hash) || /token|secret|pass|auth|session|code|signature|credential|jwt|nonce|ticket/i.test(u.hash)) u.hash = '';
      const suspicious = /token|key|secret|pass|auth|session|code|signature|credential|jwt|state|email|phone|otp|nonce|ticket/i;
      for (const key of [...u.searchParams.keys()]) if (suspicious.test(key)) u.searchParams.delete(key);
      return u.toString().slice(0, 2000);
    } catch { return ''; }
  };
  const safeAction = (event) => {
    if (!event || !validEvents.has(event.kind)) return null;
    const action = {kind: event.kind, at: Date.now(), label: limit(event.label, 120)};
    if (event.kind === 'navigation') {
      action.url = cleanUrl(event.url);
      action.cause = event.cause === 'click' ? 'click' : 'manual';
      if (!action.url) return null;
    } else {
      action.selector = limit(event.selector, 500);
      if (!action.selector || action.selector.includes('"') || /[\r\n]/.test(action.selector)) return null;
      if (event.kind === 'fill' || event.kind === 'select' || event.kind === 'assertText') {
        action.value = limit(event.value, 2000);
        if (action.value.includes('"""') || action.value.includes('```')) return null;
      }
      if (event.kind === 'secret') action.secretKey = limit(event.secretKey, 70).replace(/[^a-zA-Z0-9_]/g, '');
      if (event.kind === 'check') action.checked = event.checked === true;
    }
    return action;
  };
  const add = (state, action) => {
    if (!action) return state;
    const previous = state.actions.at(-1);
    if (action.kind === 'navigation' && previous?.kind === 'navigation' && previous.url === action.url) return state;
    if (action.kind === 'fill' && previous?.kind === 'fill' && previous.selector === action.selector) {
      state.actions[state.actions.length - 1] = {...action, id: previous.id};
    } else if (action.kind === 'check' && previous?.kind === 'check' && previous.selector === action.selector) {
      state.actions[state.actions.length - 1] = {...action, id: previous.id};
    } else {
      state.actions.push({...action, id: `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`, enabled: true});
    }
    state.updatedAt = Date.now();
    return state;
  };
  const messageTab = async (tabId, data) => {
    try { return await api.tabs.sendMessage(tabId, data); } catch { return null; }
  };
  const arm = async (state) => {
    if (!Number.isInteger(state.tabId)) return {ok: false, message: 'No browser tab selected.'};
    try {
      await api.scripting.executeScript({target: {tabId: state.tabId}, files: ['content.js']});
      await api.tabs.sendMessage(state.tabId, {type: 'RECORDER_ARM', sessionId: state.id, mode: state.mode});
      return {ok: true};
    } catch (error) {
      return {ok: false, message: 'Page access is needed. Open the recorder on this tab and grant access to this site. (' + limit(String(error?.message || ''), 130) + ')'};
    }
  };
  const stateResponse = (s) => ({ok: true, state: s});
  async function handle(msg, sender) {
    if (!msg || typeof msg.type !== 'string') return {ok: false, message: 'Unknown command.'};
    if (msg.type === 'GET_STATE') return stateResponse(await read());
    if (msg.type === 'START') {
      const existing = await read();
      if (existing.status === 'recording' || existing.status === 'paused') return {ok:false, message:'Finish the current recording before starting another.'};
      if (!Number.isInteger(msg.tabId)) return {ok: false, message: 'Choose a browser tab first.'};
      if (!isWeb(msg.url)) return {ok: false, message: 'Open an http:// or https:// page to begin.'};
      const state = {
        id: crypto.randomUUID(), status: 'recording', mode: 'record', tabId: msg.tabId,
        title: limit(msg.title || 'Browser journey', 90), startedAt: Date.now(), updatedAt: Date.now(),
        actions: [], warning: '', lastUrl: cleanUrl(msg.url)
      };
      add(state, safeAction({kind: 'navigation', url: msg.url, cause: 'manual'}));
      const attached = await arm(state);
      if (!attached.ok) return attached;
      return stateResponse(await write(state));
    }
    let state = await read();
    if (msg.type === 'RECORDER_EVENT') {
      if (sender.tab?.id !== state.tabId || msg.sessionId !== state.id || state.status !== 'recording') return {ok: false};
      if (msg.event?.kind === 'navigation' && msg.event?.url) state.lastUrl = cleanUrl(msg.event.url);
      add(state, safeAction(msg.event));
      return stateResponse(await write(state));
    }
    if (msg.type === 'RECORDER_ASSERT_DONE') {
      if (sender.tab?.id !== state.tabId || msg.sessionId !== state.id) return {ok:false};
      state.mode = 'record'; return stateResponse(await write(state));
    }
    if (msg.type === 'RECORDER_WARN') {
      if (sender.tab?.id !== state.tabId || msg.sessionId !== state.id) return {ok: false};
      state.warning = limit(msg.message, 260);
      return stateResponse(await write(state));
    }
    if (msg.type === 'PAUSE' || msg.type === 'STOP') {
      if (state.status === 'idle') return stateResponse(state);
      const flush = await messageTab(state.tabId, {type: 'RECORDER_FLUSH', sessionId: state.id});
      if (flush?.event) add(state, safeAction(flush.event));
      state.status = msg.type === 'PAUSE' ? 'paused' : 'stopped';
      state.mode = 'record';
      await messageTab(state.tabId, {type: 'RECORDER_DISARM'});
      return stateResponse(await write(state));
    }
    if (msg.type === 'RESUME') {
      if (!['paused', 'stopped'].includes(state.status)) return {ok: false, message: 'Nothing paused to resume.'};
      state.status = 'recording'; state.mode = 'record'; state.warning = '';
      const attached = await arm(state);
      if (!attached.ok) return attached;
      return stateResponse(await write(state));
    }
    if (msg.type === 'ASSERT_MODE') {
      if (state.status !== 'recording') return {ok: false, message: 'Start recording before adding an assertion.'};
      state.mode = msg.enabled ? 'assert' : 'record';
      await messageTab(state.tabId, {type: 'RECORDER_ARM', sessionId: state.id, mode: state.mode});
      return stateResponse(await write(state));
    }
    if (msg.type === 'UPDATE') {
      if (typeof msg.title === 'string') state.title = limit(msg.title.trim(), 90);
      if (Array.isArray(msg.actions)) {
        const oldById = new Map(state.actions.map(a => [a.id, a]));
        // Editor can reorder and disable existing actions; it cannot fabricate unsafe selectors.
        state.actions = msg.actions.slice(0, 500).map(item => {
          const existing = oldById.get(item.id);
          return existing ? {...existing, enabled: item.enabled !== false} : null;
        }).filter(Boolean);
      }
      return stateResponse(await write(state));
    }
    if (msg.type === 'CLEAR') {
      await messageTab(state.tabId, {type: 'RECORDER_DISARM'});
      return stateResponse(await write({status: 'idle', actions: []}));
    }
    return {ok: false, message: 'Unknown command.'};
  }
  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    enqueue(() => handle(msg, sender)).then(sendResponse).catch(err => sendResponse({ok: false, message: String(err?.message || err)}));
    return true;
  });
  api.tabs.onUpdated.addListener((tabId, change, tab) => {
    if (!change.url && change.status !== 'complete') return;
    enqueue(async () => {
      const state = await read();
      if (state.status !== 'recording' || state.tabId !== tabId) return;
      if (change.url && isWeb(change.url)) {
        const url = cleanUrl(change.url);
        if (url !== state.lastUrl) {
          state.lastUrl = url;
          const last = state.actions.at(-1);
          add(state, safeAction({kind: 'navigation', url, cause: ['click', 'press'].includes(last?.kind) ? 'click' : 'manual'}));
          await write(state);
        }
      }
      if (change.status === 'complete') {
        const injected = await arm(state);
        if (!injected.ok) { state.warning = injected.message; await write(state); }
        else if (state.warning) { state.warning = ''; await write(state); }
      }
    });
  });
  api.tabs.onRemoved.addListener(tabId => enqueue(async () => {
    const state = await read();
    if (state.tabId === tabId && state.status === 'recording') {
      state.status = 'stopped'; state.warning = 'The recorded tab closed. Your steps are saved.'; await write(state);
    }
  }));
})();
