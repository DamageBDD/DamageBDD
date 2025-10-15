// damage-scheduler-ui.js
const headers = new Headers();
headers.append("Content-Type", "application/json");

if (localStorage.access_token) {
	headers.append("Authorization", "Bearer " + localStorage.access_token);
}
export function initDamageScheduler(config = {}) {
  const defaults = {
    apiBase: '/schedules/',
    ipfsGateway: 'https://ipfs.io/ipfs',
    defaultConcurrency: 1,
    containerSelector: '#schedules-tab #schedules'
  };
  const opts = { ...defaults, ...config };

  // create UI root if missing
  let root = document.querySelector(opts.containerSelector);
  if (!root) {
    root = document.createElement('div');
    root.id = 'schedules';
    document.body.appendChild(root);
  }

  // --- simple UI form
  root.innerHTML = `
    <div class="damage-scheduler">
      <h3>Schedule a Feature Run</h3>
      <label>Feature IPFS CID <input id="featureCid" type="text" placeholder="Qm..." /></label>
      <label>Schedule <input id="scheduleSpec" type="text" placeholder="once/12/30/pm" /></label>
      <button id="dryRunBtn">Dry-Run</button>
      <div id="dryRunResult"></div>
      <button id="approveBtn" disabled>Approve & Schedule</button>
      <div id="scheduleList"></div>
    </div>
  `;

  const cidEl = root.querySelector('#featureCid');
  const schedEl = root.querySelector('#scheduleSpec');
  const dryBtn = root.querySelector('#dryRunBtn');
  const approveBtn = root.querySelector('#approveBtn');
  const dryOut = root.querySelector('#dryRunResult');
  const listEl = root.querySelector('#scheduleList');

  async function fetchSchedules() {
      const r = await fetch(opts.apiBase,{
		headers: headers,
		  credentials: 'include'}

						   );
    const data = await r.json();
    listEl.innerHTML = `<pre>${JSON.stringify(data, null, 2)}</pre>`;
  }

  dryBtn.onclick = async () => {
    const cid = cidEl.value.trim();
    const sched = schedEl.value.trim();
    if (!cid || !sched) return;

    // dry run call (using ae dry-run path)
    const res = await fetch(`${opts.apiBase}/${sched}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-damage-concurrency': opts.defaultConcurrency },
      body: JSON.stringify({ feature: cid, dry_run: true })
    });
    const data = await res.json();
    dryOut.textContent = `Dry-Run Result: ${JSON.stringify(data)}`;
    approveBtn.disabled = false;
  };

  approveBtn.onclick = async () => {
    const cid = cidEl.value.trim();
    const sched = schedEl.value.trim();
    if (!cid || !sched) return;

    const res = await fetch(`${opts.apiBase}/${sched}`, {
		method: 'POST',
		headers: headers,
		credentials: 'include',
		method: 'POST',
      body: JSON.stringify({ feature: cid })
    });
    const data = await res.json();
    dryOut.textContent = `Scheduled! ${JSON.stringify(data)}`;
    approveBtn.disabled = true;
    fetchSchedules();
  };

}

// auto-init if loaded directly as a <script type="module">
if (typeof window !== 'undefined') {
  window.addEventListener('DOMContentLoaded', () => {
	  const DamageSchedulerConfig = {
		  apiBase: '/schedules',
		  ipfsGateway: window.origin + '/ipfs'
	  };
      initDamageScheduler(DamageSchedulerConfig || {});
  });
}
