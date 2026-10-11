const $ = (id) => document.getElementById(id);
const state = { generated: null, run: null };

function status(message, isError = false) {
  $('status').textContent = message;
  $('status').classList.toggle('error', isError);
}
function busy(button, value) { button.disabled = value; }
async function postJSON(path, data) {
  const response = await fetch(path, {
    method: 'POST', credentials: 'same-origin', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
    body: JSON.stringify(data)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `HTTP ${response.status}`);
  }
  return payload;
}

$('connect-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  state.generated = null;
  state.run = null;
  $('test-panel').classList.add('hidden');
  $('result-panel').classList.add('hidden');
  busy($('generate'), true);
  status('Generating Gherkin…');
  try {
    const generated = await postJSON('/api/quickstart/generate', { url: $('target').value.trim() });
    state.generated = generated;
    $('feature').textContent = generated.feature;
    $('test-panel').classList.remove('hidden');
    $('run').disabled = !generated.trial_available;
    $('trial-note').textContent = generated.trial_available
      ? 'This target is approved for one free HTTP status check in this browser.'
      : 'Generation is available, but a free run requires an operator-approved exact HTTPS target. You can download this test or sign in to execute it using normal domain authorization.';
    status('Test generated. Review the scenario before execution.');
  } catch (error) { status(`Could not generate test: ${error.message}`, true); }
  finally { busy($('generate'), false); }
});

$('copy').addEventListener('click', async () => {
  if (!state.generated) return;
  try { await navigator.clipboard.writeText(state.generated.feature); status('Feature copied.'); }
  catch { status('Clipboard blocked; select and copy the feature text.', true); }
});
$('download').addEventListener('click', () => {
  if (!state.generated) return;
  const blob = new Blob([state.generated.feature], { type: 'text/plain;charset=utf-8' });
  const objectUrl = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = objectUrl;
  link.download = 'first-api-verification.feature';
  link.click();
  URL.revokeObjectURL(objectUrl);
});
$('run').addEventListener('click', async () => {
  if (!state.generated) return;
  busy($('run'), true);
  status('Running the approved GET check…');
  try {
    const result = await postJSON('/api/quickstart/run', { url: state.generated.url });
    state.run = result;
    $('result').textContent = result.passed
      ? `PASS · HTTP ${result.observed_status} · ${result.elapsed_ms} ms`
      : `FAIL · ${result.error || `HTTP ${result.observed_status}`} · ${result.elapsed_ms || 0} ms`;
    $('share').href = result.report_url;
    $('result-panel').classList.remove('hidden');
    status('Report ready. Save the link or schedule a paid recurring check.');
  } catch (error) { status(`Trial unavailable: ${error.message}`, true); }
  finally { busy($('run'), false); }
});

$('schedule').addEventListener('click', async () => {
  if (!state.generated) return;
  busy($('schedule'), true);
  status('Creating a daily schedule in your account…');
  try {
    // Uses the existing authenticated DamageBDD schedules API, not trial credits.
    // Equivalent to: curl --data-binary @test.feature /schedules/daily/every/1/day
    const response = await fetch('/schedules/daily/every/1/day', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json' },
      body: state.generated.feature
    });
    const responseBody = await response.text();
    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        throw new Error('Sign in with your DamageBDD account to schedule paid runs.');
      }
      throw new Error(`Schedule rejected (HTTP ${response.status}): ${responseBody.slice(0, 180)}`);
    }
    status('Schedule request accepted by DamageBDD. Confirm the new job under your account’s Schedules tab.');
  } catch (error) { status(error.message, true); }
  finally { busy($('schedule'), false); }
});

// The dashboard hero submits an ordinary GET to /try?url=... . Only generate
// the draft on arrival: never run a live request without an explicit click.
function prefillFromDashboard() {
  if (typeof window === 'undefined') return;
  const value = new URLSearchParams(window.location?.search || '').get('url');
  if (!value || value.length > 2048) return;
  $('target').value = value;
  $('connect-form').requestSubmit();
}
prefillFromDashboard();
