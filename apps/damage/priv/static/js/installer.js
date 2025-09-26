// installer.js — Install Node flow with Android/Termux + signed URLs
// Exposes window.initInstallForm so main.js can call it when the modal opens.

(function () {
  const $ = (s) => document.querySelector(s);
  const once = (el, type, handler) => {
    if (!el) return;
    const key = `__once_${type}`;
    if (el[key]) return;
    el.addEventListener(type, handler);
    el[key] = true;
  };

  // Elements (resolved lazily inside initInstallForm as modal DOM is injected)
  let domainI, emailI, osSel, varSel, portI, repoI, branchI, status;
  let prevBash, prevPs1, prevAndroid, cmdBash, cmdPs1, cmdTermux;

  // Idempotent global initializer – called every time the modal opens
  function initInstallForm() {
    // Resolve fields each open (modal markup is inside the dialog)
    domainI = $('#inst-domain');
    emailI  = $('#inst-email');
    osSel   = $('#inst-os');
    varSel  = $('#inst-variant');
    portI   = $('#inst-port');
    repoI   = $('#inst-repo');
    branchI = $('#inst-branch');
    status  = $('#installStatus');

    prevBash    = $('#preview-linux-macos');
    prevPs1     = $('#preview-windows');
    prevAndroid = $('#preview-android');

    cmdBash   = $('#cmd-bash');
    cmdPs1    = $('#cmd-ps1');
    cmdTermux = $('#cmd-termux');

    // Prefill domain
    try {
      if (domainI && !domainI.value) domainI.value = window.location.hostname || '';
    } catch (_) {}

    // Auto-detect OS
    const os = detectOS();
    if (osSel) osSel.value = os;
    populateVariant(os);
    showPreviewFor(os);

    // Copy buttons (attach once)
    document.querySelectorAll('[data-copy]').forEach((btn) => {
      once(btn, 'click', () => {
        const target = btn.getAttribute('data-copy');
        const el = document.querySelector(target);
        const text = el ? el.textContent : '';
        if (!text) return;
        navigator.clipboard.writeText(text).then(() => {
          if (status) {
            status.textContent = 'Copied!';
            setTimeout(() => (status.textContent = ''), 1200);
          }
        });
      });
    });

    // OS selection changes variants + previews
    if (osSel) {
      once(osSel, 'change', () => {
        populateVariant(osSel.value);
        showPreviewFor(osSel.value);
      });
    }

    // Generate signed URLs
    const genBtn = $('#generateSignedInstallBtn');
    if (genBtn) {
      once(genBtn, 'click', generateSignedLinks);
    }
  }

  function detectOS() {
    const ua = navigator.userAgent || '';
    if (/Android/i.test(ua)) return 'android';
    if (/Windows/i.test(ua)) return 'windows';
    if (/Macintosh|Mac OS X/i.test(ua)) return 'macos';
    if (/Linux/i.test(ua)) return 'linux';
    return 'linux';
  }

  function populateVariant(os) {
    if (!varSel) return;
    varSel.innerHTML = '';
    const add = (val, label) => {
      const o = document.createElement('option');
      o.value = val;
      o.textContent = label;
      varSel.appendChild(o);
    };
    if (os === 'linux') {
      add('debian', 'Ubuntu / Debian (bash)');
      add('rhel',   'Fedora / RHEL (bash)');
      add('arch',   'Arch / Manjaro (bash)');
    } else if (os === 'macos') {
      add('macos-bash', 'macOS (Homebrew + nginx, bash)');
    } else if (os === 'windows') {
      add('windows-ps1', 'Windows (PowerShell + WSL2)');
    } else if (os === 'android') {
      add('android-termux', 'Android (Termux bash)');
    }
  }

  function showPreviewFor(os) {
    if (prevBash)    prevBash.style.display    = (os === 'linux' || os === 'macos') ? 'block' : 'none';
    if (prevPs1)     prevPs1.style.display     = (os === 'windows') ? 'block' : 'none';
    if (prevAndroid) prevAndroid.style.display = (os === 'android') ? 'block' : 'none';
  }

  async function generateSignedLinks() {
    if (!domainI || !emailI) return;
    status && (status.textContent = 'Generating…');

    const payload = {
      domain: (domainI.value || '').trim(),
      email:  (emailI.value || '').trim(),
      port:   ((portI && portI.value) || '8080').trim(),
      repo:   ((repoI && repoI.value) || 'https://github.com/DamageBDD/DamageBDD.git').trim(),
      branch: ((branchI && branchI.value) || 'main').trim()
    };

    try {
		const headers = new Headers();
		headers.append("Content-Type", "application/json");

		if (localStorage.access_token) {
			headers.append("Authorization", "Bearer " + localStorage.access_token);
		}
      const res = await fetch('/install/request', {
        method: 'POST',
          headers: headers,
        credentials: 'same-origin',
        body: JSON.stringify(payload)
      });

      if (!res.ok) {
        const t = await res.text();
        throw new Error(t || ('HTTP ' + res.status));
      }

      const data = await res.json();
      const urlSh = data.signed_url_sh;
      const urlPs = data.signed_url_ps1;
      const urlTx = data.signed_url_termux ||
                    (urlSh ? urlSh.replace('/secure/install.sh', '/secure/install.termux.sh') : null);

      const os = (osSel && osSel.value) || detectOS();
      if (os !== 'windows' && cmdBash && urlSh) {
        cmdBash.textContent = `curl -fsSL "${urlSh}" | bash`;
      }
      if (os === 'windows' && cmdPs1 && urlPs) {
        cmdPs1.textContent = `iwr "${urlPs}" | iex`;
      }
      if (os === 'android' && cmdTermux && urlTx) {
        cmdTermux.textContent = `curl -fsSL "${urlTx}" | bash`;
      }

      showPreviewFor(os);
      status && (status.textContent = 'Signed link ready.');
      // Optionally, advance the wizard to final step: emit click on "Next" if your Wizard exposes it.
      // document.querySelector('.wizard .next')?.click();
    } catch (err) {
      status && (status.textContent = 'Error: ' + (err && err.message ? err.message : err));
    }
  }

  // Expose to main.js (called when modal opens)
  window.initInstallForm = initInstallForm;
})();
