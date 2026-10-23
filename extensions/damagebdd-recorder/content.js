/* Injected only after the user starts recording. No network traffic or value
 * collection from secret-like fields. Remains in the isolated extension world. */
(() => {
  'use strict';
  if (globalThis.__damageRecorderInstalled) return;
  globalThis.__damageRecorderInstalled = true;
  const api = globalThis.browser || globalThis.chrome;
  let enabled = false, sessionId = '', mode = 'record', pill, lastUrl = location.href;
  const previousValues = new Map();
  function secretKey(css) {
    const text = location.origin + '|' + css;
    let hash = 2166136261;
    for (let i = 0; i < text.length; i++) { hash ^= text.charCodeAt(i); hash = Math.imul(hash, 16777619); }
    return 'browser_secret_' + (hash >>> 0).toString(16).padStart(8, '0');
  }
  let previousClick = 0;
  const trim = (s, n = 120) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n);
  const isSecret = el => {
    const text = [el.name, el.id, el.getAttribute('autocomplete'), el.getAttribute('placeholder'), el.type].join(' ');
    return el.type === 'password' || /password|passcode|secret|token|credential|one.time|otp|2fa|cvv|cvc|cc-|card|credit|iban|routing|account.number|ssn|social.security|api.key|private.key|seed.phrase/i.test(text);
  };
  const isEditable = el => el && (el.matches('input,textarea,select') || el.isContentEditable);
  const skip = el => !el || !!el.closest('[data-damage-recorder-ui]') ||
      !!el.closest('[contenteditable="true"]') || el.matches('[type="hidden"],[type="file"]');
  const isSafeAttr = s => typeof s === 'string' && s.length > 0 && s.length < 85 && !s.includes('"') && !/[\n\r\x00-\x1f]/.test(s);
  function selector(el) {
    if (!(el instanceof Element)) return '';
    if (el.id && isSafeAttr(el.id)) {
      const candidate = '#' + CSS.escape(el.id);
      if (!candidate.includes('"') && document.querySelectorAll(candidate).length === 1) return candidate;
    }
    for (const attr of ['data-testid', 'data-test', 'data-qa', 'name', 'aria-label']) {
      const val = el.getAttribute(attr);
      if (isSafeAttr(val) && !val.includes("'") && !/pass|secret|token|key/i.test(attr === 'name' ? val : '')) {
        const candidate = `${el.localName}[${attr}='${CSS.escape(val)}']`;
        try { if (!candidate.includes('"') && document.querySelectorAll(candidate).length === 1) return candidate; } catch {}
      }
    }
    const chunks = [];
    for (let node = el; node && node.nodeType === 1 && chunks.length < 8; node = node.parentElement) {
      let part = node.localName;
      if (node.id && isSafeAttr(node.id)) { chunks.unshift('#' + CSS.escape(node.id)); break; }
      if (node.parentElement) {
        const siblings = [...node.parentElement.children].filter(x => x.localName === node.localName);
        if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(node) + 1})`;
      }
      chunks.unshift(part);
      try { if (document.querySelectorAll(chunks.join(' > ')).length === 1) break; } catch {}
    }
    const candidate = chunks.join(' > ');
    if (!candidate || candidate.includes('"')) return '';
    try { return document.querySelectorAll(candidate).length === 1 ? candidate : ''; } catch { return ''; }
  }
  function send(event) {
    if (!enabled || !sessionId) return;
    api.runtime.sendMessage({type: 'RECORDER_EVENT', sessionId, event}).catch?.(() => {});
  }
  function warning(message) { api.runtime.sendMessage({type:'RECORDER_WARN', sessionId, message}).catch?.(() => {}); }
  function valueChange(el, publish = true) {
    if (skip(el) || !isEditable(el) || el.isContentEditable || el.matches('button,[type="submit"],[type="reset"]')) return;
    if (el.localName === 'select' && el.multiple) { warning('Multi-select fields are not supported by this recorder. Add those steps manually.'); return; }
    const css = selector(el);
    if (!css) { warning('Could not identify one field uniquely. Choose a more stable selector before export.'); return; }
    if (el.matches('input[type="checkbox"],input[type="radio"]')) {
      const event = {kind:'check', selector:css, label:trim(el.getAttribute('aria-label') || el.name || el.id), checked:el.checked};
      if (publish) send(event);
      return event;
    }
    if (isSecret(el)) {
      const key = secretKey(css);
      if (publish && previousValues.get(css) === key) return;
      previousValues.set(css, key);
      const event = {kind:'secret', selector:css, secretKey:key, label:'Private field — configure a secret to replay'};
      if (publish) send(event);
      return event;
    }
    const rawValue = String(el.value ?? '');
    if (rawValue.length > 2000) { warning('A field exceeds the 2,000-character recording limit. Review and add it manually.'); return; }
    const value = rawValue;
    if (value.includes('"""') || value.includes('```')) { warning('A text value contains a Gherkin document delimiter; it was not recorded.'); return; }
    if (publish && previousValues.get(css) === value) return;
    previousValues.set(css, value);
    const event = {kind:el.localName === 'select' ? 'select' : 'fill', selector:css, value, label:trim(el.getAttribute('aria-label') || el.placeholder || el.name || el.id)};
    if (publish) send(event);
    return event;
  }
  function onClick(ev) {
    if (!enabled || !ev.isTrusted) return;
    const node = ev.target instanceof Element ? ev.target : ev.target?.parentElement;
    if (!node || skip(node)) return;
    if (mode === 'assert') {
      ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation();
      const target = node.closest('button,a,[role="button"],h1,h2,h3,p,span,label,div') || node;
      const text = trim(target.innerText || target.textContent || '', 180);
      const css = selector(target);
      if (text && css) { send({kind:'assertText', selector:css, value:text, label:text}); mode = 'record'; api.runtime.sendMessage({type:'RECORDER_ASSERT_DONE',sessionId}).catch?.(() => {}); paint(); }
      else warning('Select a smaller visible text element to add an assertion.');
      return;
    }
    if (node.closest('input[type="checkbox"],input[type="radio"],label:has(input[type="checkbox"]),label:has(input[type="radio"])')) return;
    const clickable = node.closest('a,button,[role="button"],input[type="button"],input[type="submit"],summary');
    if (!clickable || skip(clickable) || clickable.hasAttribute('disabled')) return;
    const css = selector(clickable);
    if (!css) { warning('Could not identify a clicked control uniquely.'); return; }
    previousClick = Date.now();
    send({kind:'click', selector:css, label:trim(clickable.innerText || clickable.value || clickable.getAttribute('aria-label') || clickable.title || clickable.localName)});
  }
  function onChange(ev) { if (enabled && ev.isTrusted) valueChange(ev.target); }
  function onKeydown(ev) {
    if (!enabled || !ev.isTrusted || mode !== 'record' || ev.key !== 'Enter' || !isEditable(ev.target)) return;
    const el = ev.target;
    if (el.matches('textarea')) return; // typing a newline is part of the text value
    valueChange(el);
    const css = selector(el);
    if (css) send({kind:'press', selector:css, label:'Enter'});
  }
  function onBlur(ev) { if (enabled && ev.isTrusted && ev.target?.matches?.('input,textarea,select')) valueChange(ev.target); }
  function onNavigation() {
    if (!enabled || location.href === lastUrl) return;
    lastUrl = location.href;
    send({kind:'navigation', url:location.href, cause: Date.now() - previousClick < 2000 ? 'click' : 'manual'});
  }
  function paint() {
    if (!pill) {
      pill = document.createElement('div');
      pill.dataset.damageRecorderUi = '';
      pill.style.cssText = 'position:fixed!important;z-index:2147483647!important;top:16px!important;right:16px!important;font:600 12px system-ui!important;pointer-events:none!important;';
      const root = pill.attachShadow({mode:'closed'});
      const badge = document.createElement('span'); badge.id = 'badge';
      badge.style.cssText = 'display:inline-flex;align-items:center;gap:8px;background:#131c32;color:white;border-radius:24px;padding:9px 13px;box-shadow:0 8px 30px #101b3855;border:1px solid #ffffff2b;';
      root.append(badge); pill._badge = badge;
      (document.documentElement || document.body).append(pill);
    }
    pill._badge.textContent = mode === 'assert' ? '✚ Click text to assert · DamageBDD' : '● Recording · DamageBDD';
    pill._badge.style.color = mode === 'assert' ? '#a5ffdc' : '#fff';
    pill.style.display = enabled ? 'block' : 'none';
  }
  const onMessage = (msg, _sender, respond) => {
    if (msg?.type === 'RECORDER_ARM') {
      enabled = true; sessionId = msg.sessionId; mode = msg.mode === 'assert' ? 'assert' : 'record'; lastUrl = location.href;
      paint(); respond({ok:true}); return;
    }
    if (msg?.type === 'RECORDER_DISARM') { enabled = false; mode = 'record'; if (pill) pill.style.display = 'none'; respond({ok:true}); return; }
    if (msg?.type === 'RECORDER_FLUSH') {
      const focused = document.activeElement;
      const event = enabled && focused?.matches?.('input,textarea,select') ? valueChange(focused, false) : null;
      respond({ok:true, event}); return;
    }
  };
  api.runtime.onMessage.addListener(onMessage);
  document.addEventListener('click', onClick, true);
  document.addEventListener('change', onChange, true);
  document.addEventListener('blur', onBlur, true);
  document.addEventListener('keydown', onKeydown, true);
  window.addEventListener('popstate', onNavigation, true);
  window.addEventListener('hashchange', onNavigation, true);
  setInterval(onNavigation, 750);
})();
