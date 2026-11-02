// Pure rendering/input helpers for the server-owned starter catalogue.
export function escapeTemplateText(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
const esc = escapeTemplateText;
export function cadenceLabel(cron) {
  return ({'*/15 * * * *':'Every 15 minutes', '0 * * * *':'Hourly', '0 9 * * *':'Daily at 09:00 UTC'})[cron] || `${cron} (UTC)`;
}
export function templateCards(templates) {
  return templates.map(t => `<article class="sv2-template">
    <div class="sv2-template-category">${esc(t.category)}</div>
    <h4>${esc(t.title)}</h4><p>${esc(t.description)}</p>
    <small>${esc(cadenceLabel(t.cron_spec))} · ${esc(t.requests_per_run)} probe${t.requests_per_run === 1 ? '' : 's'} / run</small>
    <button type="button" class="sv2-secondary" data-template-id="${esc(t.id)}">Use template</button>
  </article>`).join('');
}
export function templateFields(template) {
  return template.fields.map(f => {
    const type = ['url','number','text'].includes(f.type) ? f.type : 'text';
    const bounds = type === 'number' ? `min="${esc(f.min)}" max="${esc(f.max)}" step="1"` : `maxlength="${esc(f.max_length || 2048)}"`;
    return `<label class="sv2-field"><span>${esc(f.label)}</span><input name="${esc(f.key)}" type="${type}" ${bounds}
      value="${esc(f.default ?? '')}" placeholder="${esc(f.placeholder || '')}" ${f.required ? 'required' : ''} autocomplete="off"></label>`;
  }).join('');
}
export function templateParams(template, values, authorized) {
  if (authorized !== true) throw new Error('Confirm that you own this system or have permission to test it.');
  const out = {authorized: true};
  for (const field of template.fields) {
    const raw = String(values[field.key] ?? '').trim();
    if (field.required && !raw) throw new Error(`${field.label} is required.`);
    if (field.type === 'number') {
      const value = Number(raw);
      if (!Number.isSafeInteger(value) || value < field.min || value > field.max) {
        throw new Error(`${field.label} must be an integer from ${field.min} to ${field.max}.`);
      }
      out[field.key] = value;
    } else {
      if (raw.length > (field.max_length || 2048)) throw new Error(`${field.label} is too long.`);
      // Server validation is authoritative; do not silently rewrite a target.
      if (/[\u0000-\u001f\u007f"\\{}]/.test(raw)) throw new Error(`${field.label} contains unsupported characters.`);
      if (field.type === 'url') {
        let url;
        try { url = new URL(raw); } catch { throw new Error('Enter an absolute HTTP(S) URL.'); }
        if (!['http:','https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
          throw new Error('Use an HTTP(S) URL without credentials, a query string or a fragment.');
        }
      }
      out[field.key] = raw;
    }
  }
  return out;
}
export function templateDefaults(draft) {
  if (!draft || typeof draft.feature !== 'string' || !draft.feature.trim()) throw new Error('The server did not return a template feature.');
  const frequency = ({'*/15 * * * *':'15m','0 * * * *':'hourly','0 9 * * *':'daily-utc'})[draft.cron_spec] || 'custom';
  return {feature: draft.feature, frequency, cron: draft.cron_spec, days: 7};
}
// A pending/accepted cost preview belongs to an exact immutable spec. Editing
// invalidates it, including while the request is in flight; old replies lose.
export function createPreviewGate() {
  let revision = 0, pending = null, accepted = null;
  return {
    invalidate() { revision++; accepted = null; },
    begin(spec) { accepted = null; pending = {revision, spec: structuredClone(spec)}; return pending; },
    accept(ticket, preview) {
      if (ticket !== pending || ticket.revision !== revision) return false;
      accepted = {spec: ticket.spec, preview}; pending = null; return true;
    },
    current(spec) { return accepted && JSON.stringify(spec) === JSON.stringify(accepted.spec) ? accepted : null; }
  };
}
