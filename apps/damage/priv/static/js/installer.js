(function () {
	const $  = (s) => document.querySelector(s);
	const on = (el, t, h) => el && el.addEventListener(t, h);

	// Refs
	let domainI, emailI, osSel, varSel, portI, repoI, branchI, status;
	let localhostCk, remoteWrap;
	let prevBash, prevPs1, prevAndroid, cmdBash, cmdPs1, cmdTermux;
	let detectedOsEl, dlAuto, dlAutoNote, dlDeb, dlDebNote;

	const IPFS_GATEWAY = "https://ipfs.damagebdd.com/ipfs/";
	const ipfsHash = "QmUMYUsNdtKw34V3dUbe9PVqZCjRePoQkzzcuWpteUqCNi";

	// Very light client-side guess (good enough to show the Debian button first).
	function guessLinuxDistroFromUA() {
		const ua = (navigator.userAgent || "").toLowerCase();
		// Debian-like (Ubuntu, Debian, Mint…)
		if (ua.includes("ubuntu") || ua.includes("debian") || ua.includes("mint")) return "debian";
		// Fedora/RHEL/CentOS
		if (ua.includes("fedora") || ua.includes("centos") || ua.includes("rhel")) return "rpm";
		// Arch-ish
		if (ua.includes("arch")) return "arch";
		return "unknown";
	}


	// Build a direct .deb download command if we know the IPFS hash
	function buildDebInstallCmd({ ipfsHash }) {
		const debUrl = `${IPFS_GATEWAY}${ipfsHash}`;
		// Download + install locally (apt handles local files)
		return [
			`set -e`,
			`echo "Detected Debian/Ubuntu. Fetching .deb from IPFS..."`,
			`curl -fL "${debUrl}" -o damagebdd.deb`,
			`sudo apt-get update || true`,
			`sudo apt-get install -y ./damagebdd.deb`
		].join("\n");
	}

	// Detect OS
	function detectOS() {
		const ua = navigator.userAgent || '';
		const p  = navigator.platform || '';
		if (/Windows/i.test(ua)) return 'windows';
		if (/Android/i.test(ua)) return 'android';
		if (/Mac/i.test(ua) || /MacIntel|MacPPC|Mac68K|Macintosh/i.test(p)) return 'macos';
		return 'linux';
	}

	// Variants list (kept minimal)
	const VARIANTS = {
		linux:   [
			{ value: 'bash',   label: 'Bash / systemd' },
			{ value: 'debian',   label: 'Debian Package' },
			{ value: 'mint',   label: 'LinuxMint Package' },
		],
		macos:   [{ value: 'zsh',    label: 'zsh' }],
		windows: [{ value: 'ps',     label: 'PowerShell' }],
		android: [{ value: 'termux', label: 'Termux' }],
	};
	function populateVariants(os) {
		if (!varSel) return;
		varSel.innerHTML = '';
		(VARIANTS[os] || []).forEach(o => varSel.appendChild(new Option(o.label, o.value)));

		if (varSel.options.length) varSel.value = varSel.options[0].value;
	}

	// Preview visibility
	function showPreviewFor(os) {
		if (!prevBash || !prevPs1 || !prevAndroid) return;
		prevBash.style.display    = (os === 'linux' || os === 'macos') ? 'block' : 'none';
		prevPs1.style.display     = (os === 'windows') ? 'block' : 'none';
		prevAndroid.style.display = (os === 'android') ? 'block' : 'none';
	}
	// Somewhere in your installer state builder:
	function getPlatformDownloads({ ipfsHash }) {
		const uaDistro = guessLinuxDistroFromUA();
		const debUrl = ipfsHash ? `${IPFS_GATEWAY}${ipfsHash}` : null;
		return { uaDistro, debUrl };
	}

	// Localhost progressive UI
	function applyLocalhostState() {
		const useLocal = !!localhostCk?.checked;
		if (!domainI || !emailI || !remoteWrap) return;
		if (useLocal) {
			remoteWrap.style.display = 'none';
			domainI.value = ''; emailI.value = '';
			domainI.disabled = true; emailI.disabled = true;
			domainI.removeAttribute('required'); emailI.removeAttribute('required');
		} else {
			remoteWrap.style.display = 'block';
			domainI.disabled = false; emailI.disabled = false;
			domainI.setAttribute('required',''); emailI.setAttribute('required','');
		}
	}

	function buildCommands({ os, variant, repo, branch, host, port, tls, email, domain }) {
		const tlsFlags = tls === 'on'
			  ? `--tls on --domain "${domain}" --email "${email}"`
			  : `--tls off`;
		const baseFlags = `--host "${host}" --port "${port}" ${tlsFlags}`;

		const signedUrl = `/api/install?repo=${encodeURIComponent(repo||'')}`
			  + `&branch=${encodeURIComponent(branch||'develop')}`
			  + `&host=${encodeURIComponent(host)}&port=${encodeURIComponent(port)}`
			  + `&tls=${encodeURIComponent(tls)}&email=${encodeURIComponent(email||'')}`
			  + `&domain=${encodeURIComponent(domain||'')}&platform=${os}&shell=${variant}`;

		const bashCmd   = `curl -fsSL "${signedUrl}" | bash -s -- ${baseFlags}`.replace(/\s+/g,' ').trim();
		const termuxCmd = `pkg install -y curl && curl -fsSL "${signedUrl}" | bash -s -- ${baseFlags}`;

		// --- Windows PowerShell one-liner (Bootstrap-Erlang.ps1, robust byte->text) ---
		const BOOTSTRAP_PS_URL = 'https://run.dev.damagebdd.com/static/Bootstrap-Erlang.ps1';
		const isLocal = host === '127.0.0.1' || domain === 'localhost';
		const psFlags = [
			'-Start',
			isLocal ? '-Localhost' : '',
			port ? `-Port ${Number(port)}` : '',
			branch && branch !== 'develop' ? `-Branch '${String(branch).replace(/'/g, "''")}'` : ''
		].filter(Boolean).join(' ');

		const psCmd =
			  'powershell -NoProfile -ExecutionPolicy Bypass -Command ' +
			  '"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;' +
			  '$base=Join-Path $env:LOCALAPPDATA \\\"DamageBDD\\\"; $null=New-Item -ItemType Directory -Force -Path $base;' +
			  '$logDir=Join-Path $base \\\"logs\\\"; $null=New-Item -ItemType Directory -Force -Path $logDir;' +
			  '$ts=Get-Date -Format yyyyMMdd-HHmmss; $log=Join-Path $logDir (\\\"install-$ts.log\\\");' +
			  '$boot=Join-Path $base \\\"Bootstrap-Erlang.ps1\\\";' +
			  `Invoke-WebRequest -UseBasicParsing -Uri '${BOOTSTRAP_PS_URL}' -OutFile $boot;` +
			  `& $boot ${psFlags} *> $log;` + // capture stdout+stderr
			  'if ($LASTEXITCODE -ne 0){ Write-Host \\\"Failed. See: $log\\\"; exit $LASTEXITCODE } ' +
			  'else { Write-Host \\\"Done. Log: $log\\\" }"';



		return { bashCmd, psCmd, termuxCmd };
	}


	// Downloadable script builders
	function buildUnixSh({ signedUrl, host, domain, port, tls, email }) {
		const tlsFlags = (tls === 'on')
			  ? `--tls on --domain "${domain}" --email "${email}"`
			  : `--tls off`;
		const baseFlags = `--host "${host}" --port "${port}" ${tlsFlags}`;
		return [
			'#!/usr/bin/env bash',
			'set -euo pipefail',
			'command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }',
			`curl -fsSL "${signedUrl}" | bash -s -- ${baseFlags}`
		].join('\n');
	}
	function buildTermuxSh(args) {
		const body = buildUnixSh(args).split('\n');
		body[0] = '#!/data/data/com.termux/files/usr/bin/bash';
		body.splice(2, 0, 'pkg install -y curl');
		return body.join('\n');
	}
	

	const EOL_CRLF = '\r\n';

	function buildWindowsBat({ host, domain, port, branch }) {
		const BOOTSTRAP_PS_URL = 'https://run.dev.damagebdd.com/static/Bootstrap-Erlang.ps1';
		const isLocal = host === '127.0.0.1' || domain === 'localhost';
		const psFlags = [
			'-Start',
			isLocal ? '-Localhost' : '',
			port ? `-Port ${Number(port)}` : '',
			branch && branch !== 'develop' ? `-Branch '${String(branch).replace(/'/g, "''")}'` : ''
		].filter(Boolean).join(' ');

		const lines = [
			'@echo off',
			'setlocal ENABLEDELAYEDEXECUTION',
			'title DamageBDD Windows Installer',

			'rem --- pick a writable base dir (LocalAppData -> Temp -> Downloads -> CWD) ---',
			'set "BASE1=%LOCALAPPDATA%\\DamageBDD"',
			'set "BASE2=%TEMP%\\DamageBDD"',
			'set "BASE3=%USERPROFILE%\\Downloads\\DamageBDD"',
			'set "BASE="',
			'for %%D in ("%BASE1%" "%BASE2%" "%BASE3%") do (',
			'  if not defined BASE ( 2>nul mkdir "%%~D" && ( set "BASE=%%~D" ) )',
			')',
			'if not defined BASE set "BASE=%CD%\\DamageBDD" & 2>nul mkdir "%BASE%"',

			'set "LOGDIR=%BASE%\\logs"',
			'2>nul mkdir "%LOGDIR%"',
			'for /f %%i in (\'powershell -NoP -C "(Get-Date).ToString(\\"yyyyMMdd-HHmmss\\")"\') do set "TS=%%i"',
			'set "LOG=%LOGDIR%\\install-%TS%.log"',
			'set "BOOT=%BASE%\\Bootstrap-Erlang.ps1"',

			'echo [INFO] Writing logs to: "%LOG%"',
			'echo === DamageBDD installer started %DATE% %TIME% ===>> "%LOG%"',

			'echo [INFO] Downloading bootstrap to "%BOOT%"...',
			'powershell -NoProfile -ExecutionPolicy Bypass -Command ' +
				'"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; ' +
				`Invoke-WebRequest -UseBasicParsing -Uri '${BOOTSTRAP_PS_URL}' -OutFile \\"%BOOT%\\""`,

			'if errorlevel 1 (',
			'  echo [ERROR] Failed to download bootstrap. >> "%LOG%"',
			'  echo Failed to download bootstrap. See log: "%LOG%"',
			'  pause',
			'  exit /b 1',
			')',

			'echo [INFO] Running bootstrap... >> "%LOG%"',
			'powershell -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" ' + psFlags + ' >> "%LOG%" 2>&1',
			'set "CODE=%ERRORLEVEL%"',

			'if "%CODE%"=="0" (',
			'  echo === SUCCESS %DATE% %TIME% ===>> "%LOG%"',
			'  echo Install completed. Log: "%LOG%"',
			') else (',
			'  echo === FAILED with code %CODE% %DATE% %TIME% ===>> "%LOG%"',
			'  echo Installer failed with code %CODE%. See log: "%LOG%"',
			'  pause',
			')',
			'exit /b %CODE%'
		];

		return lines.join(EOL_CRLF); // <-- real CRLF
	}





	function setDownloadBlob(aEl, content, filename, mime) {
		if (!aEl) return;
		const blob = new Blob([content], { type: mime || 'application/octet-stream' });
		const url  = URL.createObjectURL(blob);
		aEl.href = url;
		aEl.download = filename;
	}

	// Generate everything (one link + one-liner for selected/detected OS)
	function generateInstructions() {
		try {
			const os      = (osSel?.value || detectOS());
			const variant = (varSel?.value || (VARIANTS[os] && VARIANTS[os][0]?.value) || 'bash');
			const useLocal = !!localhostCk?.checked;

			const repo   = (repoI?.value || '').trim();
			const branch = (branchI?.value || 'develop').trim();
			const port   = (portI?.value || '8080').trim();

			const domain = useLocal ? 'localhost' : (domainI?.value || '').trim();
			const email  = useLocal ? '' : (emailI?.value || '').trim();
			const host   = useLocal ? '127.0.0.1' : domain;
			const tls    = useLocal ? 'off' : 'on';

			if (!useLocal) {
				if (!domain) throw new Error('Domain is required for TLS installs.');
				if (!email)  throw new Error('Admin email is required for Let’s Encrypt.');
			}

			// Signed URL for streamed installers (bash/termux one-liners)
			const params = { repo, branch, host, port, tls, email, domain, platform: os, shell: variant };
			const qs = new URLSearchParams(params).toString();
			const signedUrl = `/api/install?${qs}`;

			// 1) Copy-paste one-liner (only the matching preview is filled)
			const cmds = buildCommands({ os, variant, host, port, tls, email, domain, signedUrl, branch });
			cmdBash.textContent   = (os === 'linux' || os === 'macos') ? cmds.bashCmd   : '';
			cmdPs1.textContent    = (os === 'windows')                ? cmds.psCmd     : '';
			cmdTermux.textContent = (os === 'android')                ? cmds.termuxCmd : '';
			showPreviewFor(os);

			// 2) ONE auto-detected download link
			let fname, mime, content, label;
			if (os === 'windows') {
				content = buildWindowsBat({ host, domain, port, branch });
				fname   = `Install-DamageBDD${useLocal?'-Localhost':''}-${port}.bat`;
				mime    = 'application/x-bat';
				label   = 'Download for Windows (.bat)';
			} else if (os === 'android') {
				content = buildTermuxSh({ signedUrl, host, domain, port, tls, email });
				fname   = `Install-DamageBDD-Termux${useLocal?'-Localhost':''}-${port}.sh`;
				mime    = 'text/x-shellscript';
				label   = 'Download for Android (Termux) .sh';
			} else { // linux, macos
				content = buildUnixSh({ signedUrl, host, domain, port, tls, email });
				fname   = `Install-DamageBDD${useLocal?'-Localhost':''}-${port}.sh`;
				mime    = 'text/x-shellscript';
				label   = 'Download for Linux/macOS (.sh)';
			}
			setDownloadBlob(dlAuto, content, fname, mime);
			dlAuto.textContent = label;
			if (dlAutoNote) {
				dlAutoNote.textContent = `Detected platform: ${os[0].toUpperCase()}${os.slice(1)}. Change options in Advanced and re-download.`;
			}

			if (status) status.textContent = 'Instructions ready.';
		} catch (err) {
			if (status) status.textContent = 'Error: ' + (err?.message || String(err));
		}
	}

	// Copy buttons
	function wireCopyButtons() {
		document.querySelectorAll('#install-modal [data-copy]').forEach(btn => {
			on(btn, 'click', () => {
				const sel = btn.getAttribute('data-copy');
				const el  = document.querySelector(sel);
				const txt = el ? (el.textContent || el.innerText || '') : '';
				navigator.clipboard.writeText(txt).then(() => {
					const old = btn.textContent; btn.textContent = 'Copied!';
					setTimeout(() => (btn.textContent = old), 1200);
				});
			});
		});
	}

	// Init
	function initInstallForm () {
		domainI   = $('#inst-domain');
		emailI    = $('#inst-email');
		osSel     = $('#inst-os');
		varSel    = $('#inst-variant');
		portI     = $('#inst-port');
		repoI     = $('#inst-repo');
		branchI   = $('#inst-branch');
		status    = $('#installStatus');
		localhostCk = $('#inst-localhost');
		remoteWrap  = $('#inst-remote-fields');

		prevBash    = $('#preview-linux-macos');
		prevPs1     = $('#preview-windows');
		prevAndroid = $('#preview-android');
		cmdBash     = $('#cmd-bash');
		cmdPs1      = $('#cmd-ps1');
		cmdTermux   = $('#cmd-termux');

		detectedOsEl= $('#detected-os');
		dlAuto      = $('#dl-auto');
		dlAutoNote  = $('#dl-auto-note');
		dlDeb      = $('#dl-deb');
		dlDebNote  = $('#dl-deb-note');

		// Defaults
		if (localhostCk) localhostCk.checked = true;
		applyLocalhostState();

		const distro =  guessLinuxDistroFromUA();
		const os = detectOS();
		if (detectedOsEl) detectedOsEl.textContent = `Detected platform: ${os[0].toUpperCase()}${os.slice(1)} Distro: ${distro}.`;
		if (osSel) osSel.value = os;
		populateVariants(os);
		if(os == "linux"){
			const debUrl = `${IPFS_GATEWAY}${ipfsHash}`;
			dlDeb.href = debUrl;
		}

		// Events -> regenerate
		on(localhostCk, 'change', () => { applyLocalhostState(); generateInstructions(); });
		on(domainI, 'input', generateInstructions);
		on(emailI,  'input', generateInstructions);
		on(portI,   'input', generateInstructions);
		on(branchI, 'input', generateInstructions);
		on(repoI,   'input', generateInstructions);
		on(osSel,   'change', () => { populateVariants(osSel.value); showPreviewFor(osSel.value); generateInstructions(); });
		on(varSel,  'change', generateInstructions);

		wireCopyButtons();
		generateInstructions();
	}

	window.initInstallForm = initInstallForm;
})();

