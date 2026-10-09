// Pure helpers shared by the dashboard and Node tests. No credentials/storage.
export const MAX_PROMPT_BYTES = 8000;
export const EXAMPLES = Object.freeze({
  health: 'Check that GET https://api.example.com/health returns HTTP 200 and JSON status is ok.',
  auth: 'Use https://api.example.com as the server. Make a GET request to /profile with an Authorization Bearer header using the api_token account-context variable. Expect HTTP 200. Do not print credentials or the response body.',
  negative: 'Verify that GET https://api.example.com/private returns HTTP 401 when no credentials are provided.'
});
export function promptBytes(value) { return new TextEncoder().encode(value).length; }
export function apiHeaders(token) {
  const headers = { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Damage-BDD': '1' };
  if (typeof token === 'string' && token && token !== 'null' && token !== 'undefined') {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}
export function filterSteps(steps, query) {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return steps.filter(step => {
    const haystack = `${step.module} ${step.template} ${(step.keywords || []).join(' ')}`.toLowerCase();
    return words.every(word => haystack.includes(word));
  });
}
export function stepLine(step) {
  const keyword = ['Given', 'When', 'Then'].find(k => step.keywords?.includes(k));
  return `${keyword || step.keywords?.[0] || 'Given'} ${step.template}`;
}
export function appendStep(text, step) {
  const prefix = text.trim() ? `${text.replace(/\s+$/, '')}\n` : 'Feature: New behaviour\n\n  Scenario: Verify the behaviour\n';
  const next = `${prefix}    ${stepLine(step)}\n`;
  const marker = next.indexOf('<', prefix.length);
  const end = marker >= 0 ? next.indexOf('>', marker) : -1;
  return { text: next, start: marker >= 0 && end >= 0 ? marker : next.length,
    end: marker >= 0 && end >= 0 ? end + 1 : next.length };
}
export function featureStats(text) {
  let fence = null, scenarios = 0, steps = 0;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    const marker = trimmed.startsWith('"""') ? '"""' : trimmed.startsWith('```') ? '```' : null;
    if (marker && (fence === null || marker === fence)) { fence = fence ? null : marker; continue; }
    if (fence) continue;
    if (/^Scenario(?: Outline| Template)?:/.test(trimmed)) scenarios++;
    if (/^(Given|When|Then|And|But)\s/.test(trimmed)) steps++;
  }
  return { scenarios, steps };
}
export function canAcceptDraft(draft) {
  return !!(draft && typeof draft.feature === 'string' && draft.feature.trim() &&
    draft.validation?.valid === true && draft.complete === true &&
    Array.isArray(draft.missing_steps) && draft.missing_steps.length === 0);
}
export function validationSummary(validation) {
  if (!validation || typeof validation.valid !== 'boolean') return 'No validation result available.';
  if (!validation.valid) {
    const count = validation.diagnostics?.length || 1;
    return `${count} issue${count === 1 ? '' : 's'} to review. No steps were executed.`;
  }
  const count = validation.step_count || 0;
  return `Syntax and ${count} step signature${count === 1 ? '' : 's'} checked. Runtime behaviour is not verified.`;
}
export function featureFilename(text) {
  const title = text.match(/^\s*Feature:\s*(.+)$/m)?.[1] || 'feature';
  const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 80);
  return `${slug || 'feature'}.feature`;
}
