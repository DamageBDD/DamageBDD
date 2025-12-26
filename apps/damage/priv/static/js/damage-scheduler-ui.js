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
    const sched = root.querySelector('#scheduleSpec').value.trim();
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
    const sched = root.querySelector('#scheduleSpec').value.trim();
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

    // Schedule field toggle and generation
    window.toggleScheduleFields = function() {
      const frequency = root.querySelector('#scheduleFrequency').value;
      const weeklyFields = root.querySelector('#weeklyFields');
      const monthlyFields = root.querySelector('#monthlyFields');
      const datetimeFields = root.querySelector('#datetimeFields');
      const scheduleDate = root.querySelector('#scheduleDate');
      const scheduleTime = root.querySelector('#scheduleTime');
      
      // Hide all optional fields first
      weeklyFields.style.display = 'none';
      monthlyFields.style.display = 'none';
      
      // Show relevant fields based on frequency
      if (frequency === 'weekly') {
        weeklyFields.style.display = 'block';
        datetimeFields.style.display = 'block';
        scheduleDate.required = false;
        scheduleTime.required = true;
      } else if (frequency === 'monthly') {
        monthlyFields.style.display = 'block';
        datetimeFields.style.display = 'block';
        scheduleDate.required = false;
        scheduleTime.required = true;
      } else if (frequency === 'daily') {
        datetimeFields.style.display = 'block';
        scheduleDate.required = false;
        scheduleTime.required = true;
      } else if (frequency === 'once') {
        datetimeFields.style.display = 'block';
        scheduleDate.required = true;
        scheduleTime.required = true;
      } else {
        datetimeFields.style.display = 'none';
      }
      
      generateScheduleString();
    };
  
    function generateScheduleString() {
      const frequency = root.querySelector('#scheduleFrequency').value;
      const date = root.querySelector('#scheduleDate').value;
      const time = root.querySelector('#scheduleTime').value;
      const dayOfWeek = root.querySelector('#scheduleDayOfWeek').value;
      const dayOfMonth = root.querySelector('#scheduleDayOfMonth').value;
      const scheduleSpecInput = root.querySelector('#scheduleSpec');
      
      if (!frequency) {
        scheduleSpecInput.value = '';
        return;
      }
      
      let scheduleString = '';
      
      switch(frequency) {
        case 'once':
          if (date && time) {
            scheduleString = `once/${date}/${time}`;
          }
          break;
        case 'daily':
          if (time) {
            const [hours, minutes] = time.split(':');
            scheduleString = `daily/${hours}:${minutes}`;
          }
          break;
        case 'weekly':
          if (time && dayOfWeek) {
            const [hours, minutes] = time.split(':');
            scheduleString = `weekly/${dayOfWeek}/${hours}:${minutes}`;
          }
          break;
        case 'monthly':
          if (time && dayOfMonth) {
            const [hours, minutes] = time.split(':');
            scheduleString = `monthly/${dayOfMonth}/${hours}:${minutes}`;
          }
          break;
      }
      
      scheduleSpecInput.value = scheduleString;
    }
  
    // Update schedule string when fields change
    const scheduleInputs = root.querySelectorAll('#scheduleDate, #scheduleTime, #scheduleDayOfWeek, #scheduleDayOfMonth');
    scheduleInputs.forEach(input => {
      input.addEventListener('change', generateScheduleString);
    });
  
    // Update dryRunBtn and approveBtn to use hidden scheduleSpec field
    const originalDryBtnOnclick = dryBtn.onclick;
    const originalApproveBtnOnclick = approveBtn.onclick;
    
    dryBtn.onclick = async () => {
      generateScheduleString(); // Ensure schedule string is generated
      await originalDryBtnOnclick();
    };
    
    approveBtn.onclick = async () => {
      generateScheduleString(); // Ensure schedule string is generated
      await originalApproveBtnOnclick();
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
