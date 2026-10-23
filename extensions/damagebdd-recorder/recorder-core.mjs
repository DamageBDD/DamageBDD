/* Pure Gherkin generator; imported by the editor and node:test. */
const actions = new Set(['navigation', 'click', 'fill', 'secret', 'select', 'check', 'press', 'assertText']);
const cleanTitle = text => String(text || 'My first browser journey').replace(/[\r\n\t]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 90);
const quoted = text => {
  const value = String(text ?? '');
  if (!value || !value.trim()) throw new Error('Step parameters cannot be empty.');
  if (/["\x00-\x1f\x7f]/.test(value)) throw new Error('Quoted step parameters cannot contain double quotes or newlines.');
  return `"${value}"`;
};
const docString = value => {
  const str = String(value ?? '').replace(/\r\n?/g, '\n');
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(str)) throw new Error('Remove control characters from the text before exporting.');
  if (str.includes('"""') || str.includes('```')) throw new Error('This text contains a Gherkin docstring delimiter; edit the step before exporting.');
  return `\n      """\n${str.split('\n').map(s => '      ' + s).join('\n')}\n      """`;
};
const validateUrl = raw => {
  const u = new URL(raw);
  if (!['http:', 'https:'].includes(u.protocol)) throw new Error('Only HTTP and HTTPS websites can be recorded.');
  if (u.username || u.password) throw new Error('URLs with credentials cannot be exported.');
  return u.toString();
};
const urlPrefix = raw => {
  const u = new URL(validateUrl(raw));
  if (!/^#!?\//.test(u.hash) || /token|secret|pass|auth|session|code|signature|credential|jwt|nonce|ticket/i.test(u.hash)) u.hash = '';
  u.search = ''; u.username = ''; u.password = '';
  return u.toString();
};
export function actionPreview(action) {
  switch (action.kind) {
    case 'navigation': return action.cause === 'click' ? 'Verify page navigation' : 'Navigate to page';
    case 'click': return 'Click ' + (action.label || action.selector);
    case 'fill': return 'Type into ' + (action.label || action.selector);
    case 'secret': return 'Enter a private value (secret required)';
    case 'select': return 'Select ' + (action.label || action.selector);
    case 'check': return (action.checked ? 'Check ' : 'Uncheck ') + (action.label || action.selector);
    case 'press': return 'Press Enter';
    case 'assertText': return 'Verify: ' + (action.label || action.value);
    default: return 'Unknown action';
  }
}
export function makeFeature(session) {
  const all = Array.isArray(session?.actions) ? session.actions.filter(a => a?.enabled !== false) : [];
  if (all.some(a => !a || !actions.has(a.kind))) throw new Error('This recording contains an unsupported action. Disable it or record it again.');
  const warnings = [];
  const first = all[0];
  if (!first) throw new Error('Record a browser page before exporting a scenario.');
  if (first.kind !== 'navigation') throw new Error('The first enabled step must open a browser page. Move the starting page above the actions, or enable it again.');
  const lines = [`Feature: ${cleanTitle(session.title)}`, '', '  Scenario: Replay the recorded journey'];
  let opened = false;
  const usedSecret = new Set();
  const push = (step, doc) => {
    lines.push('    ' + step + (doc === undefined ? '' : docString(doc)));
  };
  for (const action of all) {
    const selector = action.selector;
    switch (action.kind) {
      case 'navigation': {
        if (!opened) {
          push('Given I start a recorded browser at ' + quoted(validateUrl(action.url)));
          opened = true;
        } else if (action.cause === 'click') {
          push('Then the recorded browser URL should start with ' + quoted(urlPrefix(action.url)));
        } else {
          push('When I navigate the recorded browser to ' + quoted(validateUrl(action.url)));
        }
        break;
      }
      case 'click': push('When I click recorded element ' + quoted(selector)); break;
      case 'fill': push('When I type into recorded field ' + quoted(selector), action.value); break;
      case 'secret': {
        const key = action.secretKey || 'browser_secret_1';
        usedSecret.add(key);
        push('When I type secret ' + quoted(key) + ' into recorded field ' + quoted(selector));
        break;
      }
      case 'select': push('When I select recorded option in ' + quoted(selector), action.value); break;
      case 'check': push('When I set recorded checkbox ' + quoted(selector) + ' to ' + (action.checked ? 'checked' : 'unchecked')); break;
      case 'press': push('When I press Enter in recorded field ' + quoted(selector)); break;
      case 'assertText': push('Then recorded element ' + quoted(selector) + ' should contain text', action.value); break;
    }
  }
  push('Then I close the recorded browser');
  if (usedSecret.size) {
    warnings.push(`${usedSecret.size} private field(s) require matching account-scoped secrets for the replaying node_admin account.`);
    lines.splice(2, 0, ...[...usedSecret].map(k => `  # Set account secret: ${k} (never include its value in this file)`));
  }
  if (all.some(a => a.kind === 'navigation' && /[?]/.test(a.url))) {
    warnings.push('Review recorded URLs before sharing: non-sensitive query parameters may still contain personal data.');
  }
  if (!all.some(a => a.kind === 'assertText' || a.kind === 'navigation' && a.cause === 'click')) {
    warnings.push('Consider adding a visible-text assertion so replay checks an outcome, not just clicks.');
  }
  return {text: lines.join('\n') + '\n', warnings, steps: all.length + 1};
}
export function featureFilename(title) {
  return (cleanTitle(title).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'browser-journey') + '.feature';
}
