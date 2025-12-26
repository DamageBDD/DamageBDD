import * as wallet from "/static/js/wallet.js";
import { initDamageBDDPicker } from '/static/js/featurePicker.js';
import { showLightningQR } from '/static/js/damage-lightning-ui.js';
import { ensureChannel } from '/static/js/ensureChannel.js';
import { updateSchedulesTable } from '/static/js/schedules.js';

const MDW_BASE = "https://mainnet.aeternity.io/mdw";
const NODE_BASE = "https://mainnet.aeternity.io";


function showConnectStatus(message, type = 'info') {
	const statusDiv = document.getElementById('connect-status');
	statusDiv.textContent = message;
	statusDiv.className = type; // e.g., 'success', 'error', 'info'
}
function showNotification(notification) {
	MicroModal.show("notification-modal");
	const notifyTitle = document.getElementById('modal-notification-title');
	notifyTitle.textContent = notification.title;
	const notifyContent = document.getElementById('modal-notification-content');
	notifyContent.textContent = notification.content;
}
function generateDamageQR(address){
	//showLightningQR({containerId:"qrcode-damage", address: address});
	document.getElementById("qrcode-damage").innerText = "";
	var qrcode = new QRCode(document.getElementById("qrcode-damage"), {
		text: window.TokenManager.getAddress(),
		colorDark : "#000000",
		colorLight : "#ffffff",
		correctLevel : QRCode.CorrectLevel.H
	});
}

(function(window, document, undefined) {

	// code that should be taken care of right away
	window.dataLayer = window.dataLayer || [];


	document.addEventListener("DOMContentLoaded", async function() {
		var kycForm = document.getElementById('kycForm');
		if (kycForm){
			kycForm.addEventListener('submit', function(event) {
				event.preventDefault(); // Prevent default form submission

				const formData = new FormData(this);
				const jsonData = Object.fromEntries(formData.entries());

				fetch('/accounts/create', {
					method: 'POST',
					headers: {
						'Content-Type': 'application/json',
						// Include CSRF Token if necessary
						'CSRF-Token': formData.get('csrf_token')
					},
					body: JSON.stringify(jsonData)
				})
					.then(response => response.json())
					.then(data => {
						showNotification({
							title: 'Success',
							content: data.message,
							style: 'success'
						});
					})
					.catch((error) => {
						showNotification({
							title: 'Request Failed',
							content: error.message,
							style: 'error'
						});
					});
			});
		}

		document.getElementById("login-modal").addEventListener("keydown", function(event){
			if (event.keyCode === 13) {
				submitLoginForm(event);
			}
		});
		document.getElementById("loginSubmitBtn").addEventListener("click", submitLoginForm);


		document.getElementById("loginResetPasswdBtn").addEventListener("click",(event) => {
			event.preventDefault();
		});

		/*document.getElementById("signup-modal").addEventListener("keydown", function(event){
			if (event.keyCode === 13) {
				submitSignUpForm(event);
			}
			});*/
		document.getElementById("signupForm").addEventListener("submit", (event) => {
			event.preventDefault();
		});
		document.getElementById("signup-username").addEventListener("keydown", (event) => {
			if (event.key === "Enter") {
				submitSignUpForm(event);
			}
		});
		document.getElementById("signupSubmitBtn").addEventListener("click", submitSignUpForm);
		//document.getElementById("signupDialogBtn").addEventListener("click", (event) => {
		//	MicroModal.close("login-modal");
		//	MicroModal.show("signup-modal");
		//	event.preventDefault();
		//});
		document.getElementById("loginResetPasswdBtn").addEventListener("click", submitForgotPasswordForm);
		//document.getElementById("loginDialogBtn").addEventListener("click", (event) => {
		//	event.preventDefault();
		//	MicroModal.close("signup-modal");
		//	MicroModal.show("login-modal");
		//});
		document.getElementById("logoutSubmitBtn").addEventListener("click", (event) => {
			window.TokenManager.logout(window.TokenManager.getMode());
			MicroModal.close('logout-modal');
			showLoginButton();

		});
		document.getElementById("generate-invoice-btn").addEventListener("click", (event) => {
			event.preventDefault();
			generateInvoice();
		});
		document.getElementById("logoutBtn").addEventListener("click",(event) => {
			event.preventDefault();
			MicroModal.show("logout-modal");
		});
		const balanceDiv = document.getElementById("balanceDiv");
		document.getElementById("addScheduleBtn").addEventListener("click",(event) => {
			console.log("add schedule");
			event.preventDefault();
		});
		document.getElementById("activity-link").addEventListener("click",(event) => {
			event.preventDefault();
			var tabs =Tabby('[data-tabs]');
			tabs.toggle('activity');
		});
		document.getElementById("node-unlock-password").addEventListener("keydown", async function(event) {
			if (event.ctrlKey && event.key === "Enter") {
				event.preventDefault();
				await nodeUnlock();
			}});
		document.getElementById("node-unlock-password-submit-btn").addEventListener("click", async (event) => {
			event.preventDefault();
			await nodeUnlock();
		});
		document.getElementById("node-password-confirm").addEventListener("keydown", async function(event) {
			if (event.ctrlKey && event.key === "Enter") {
				event.preventDefault();
				await nodeSetPassword();
			}});
		document.getElementById("node-set-password-submit-btn").addEventListener("click", async (event) => {
			event.preventDefault();
			await nodeSetPassword();
		});

		// Sweep wallet button handler
		const sweepWalletBtn = document.getElementById("sweep-wallet-btn");
		if (sweepWalletBtn) {
			sweepWalletBtn.addEventListener("click", async (event) => {
				event.preventDefault();
				await sweepWallet();
			});
		}

		// Skip sweep button handler
		const skipSweepBtn = document.getElementById("skip-sweep-btn");
		if (skipSweepBtn) {
			skipSweepBtn.addEventListener("click", (event) => {
				event.preventDefault();
				MicroModal.close("node-set-password-modal");
			});
		}

		// Initialize tabs for node setup
		if (typeof Tabby !== 'undefined') {
			const nodeSetupTabs = Tabby('[data-node-setup-tabs]');
			
			
			// Auth modal tabs (Email / Sign up / Wallet)
			if (document.querySelector('[data-auth-tabs]')) {
				Tabby('[data-auth-tabs]');
			}
// When seed phrase tab is shown, initialize reveal button if seed phrase is already available
			document.addEventListener('tabby', function(event) {
				if (event.detail && event.detail.content && event.detail.content.id === 'seed-phrase-backup-tab') {
					// Check if seed phrase was already set
					const revealBtn = document.getElementById("reveal-seed-phrase-btn");
					if (revealBtn && revealBtn.dataset.seedPhrase) {
						// Seed phrase already loaded, nothing to do
					}
				}
				if (event.detail && event.detail.content && event.detail.content.id === 'sweep-wallet-tab') {
					loadWalletBalance();
				}
			}, false);
		}

		showHideLoginButton();
		MicroModal.init({
			onShow: modal => {
				console.info(`${modal.id} is shown`);

				if (typeof window.initInstallForm === 'function') window.initInstallForm();

				if(modal.id == 'invoice-modal'){
					var address = window.TokenManager.getAddress();
					generateDamageQR(address);
					var damageAddr = document.getElementById("damage-address");
					damageAddr.value = address;
				}
			}
		});
		
		var tabs =Tabby('[data-tabs]');
		document.addEventListener('tabby', function (event) {
			var tab = event.target;
			var content = event.detail.content;
			if (event.detail.tab.id === 'tabby-toggle_activity-tab'){
				const address = TokenManager.getAddress();
				Reports.renderRunReports(address, { limit: 10 });
			}else if (event.detail.tab.id === 'tabby-toggle_schedules-tab'){
				if(window.TokenManager.getToken() != undefined){
					updateSchedulesTable();}
			}
		}, false);
		var tabs =Tabby('[data-token-tabs]');
		document.addEventListener('tabby', function (event) {
			var tab = event.target;
			var content = event.detail.content;
			console.log("switch tab");
			console.log(event);
		}, false);

		document.getElementById("damageTextArea").addEventListener("keydown", async function(event) {
			if (event.ctrlKey && event.key === "Enter") {
				event.preventDefault();
				await submitDamageForm();
			}});
		document.getElementById("execute-feature-btn").addEventListener("click", async function(event) {
			event.preventDefault();
			await submitDamageForm();
		});
		fetch("/version")
			.then(r => r.json())
			.then(renderNodeFooter)
			.catch(() => {});



        document.querySelectorAll(".toggle-password").forEach((btn) => {
            btn.addEventListener("click", () => {
                const input = document.querySelector(`input[name='${btn.dataset.target}']`);
                if (input.type === "password") {
                    input.type = "text";
                    btn.textContent = "🙈"; // Eye with slash
                } else {
                    input.type = "password";
                    btn.textContent = "👁️"; // Eye
                }
            });
        });
		var tabs =Tabby('[data-tabs]');
		tabs.toggle('execution');
		const hashes = [
			{ cid: 'QmSaePitmi9NaZmZ2DmbtC7sSMSQBBsz113qVvpY2Wd9K3', label: 'CDP Demo' },
			'QmWnbqr8j7G7Wh9ZW7XvAvagSGEg9mThBVnhzicSNxsW9U',
			'QmXAwxg4Hnb4uEYr55XFrAv6e7GEJfG2y16RaSyVgAcTxG',
			'QmcLedvbu4jXNcyJSDXNKPrhmK6iM4Ff2SwVkXi2AX3prP',
			'QmXRbJWPcq8DXniHcJzkuhwGuRvzf86kZcwkvUbx9nsDcQ',
			'QmYJF7LbpHvuUXVpjWAksht3ypGvzPbViCo16gFmiCUa1D'
		];

		initDamageBDDPicker({
			opener: '#picker-dialog-btn',
			mount: '#picker',
			editor: '#damageTextArea',
			hashes,
			gateway: window.location.origin + '/features/', // swap for your private gateway if needed
			title: 'Pick a DamageBDD Feature',
		});
		document.addEventListener("click", (e) => {
			const btn = e.target.closest("[data-micromodal-trigger='ecai-job-details-modal']");
			if (!btn) return;
			const jobId = btn.getAttribute("data-job-id");
			if (jobId) loadJobIntoModal(jobId);
		});
		// Live Coinstore quote under invoice amount (sats -> USD -> DAMAGE)
		const invoiceAmountEl = document.getElementById("invoice-amount");
		const invoiceForm = document.getElementById("invoice-form");

		if (invoiceAmountEl && invoiceForm) {
			let hint = document.getElementById("invoice-price-hint");
			if (!hint) {
				hint = document.createElement("div");
				hint.id = "invoice-price-hint";
				invoiceForm.appendChild(hint);
			}

			let t = null;
			const render = async () => {
				const v = parseFloat(invoiceAmountEl.value);
				if (!Number.isFinite(v) || v <= 0) {
					hint.textContent = "";
					return;
				}

				// Pricing.js may not be loaded yet
				if (!window.CoinstorePricing || !window.CoinstorePricing.quoteFromSats) {
					hint.textContent = "Price feed unavailable.";
					return;
				}

				hint.textContent = "Fetching live Coinstore price…";

				try {
					const q = await window.CoinstorePricing.quoteFromSats(v);
					if (!q) { hint.textContent = ""; return; }

					const usd = q.usd.toLocaleString(undefined, { maximumFractionDigits: 2 });
					const dmg = q.damage.toLocaleString(undefined, { maximumFractionDigits: 2 });
					const dmgPx = q.damage_usdt.toLocaleString(undefined, { maximumFractionDigits: 8 });
					const btcPx = q.btc_usdt.toLocaleString(undefined, { maximumFractionDigits: 2 });

					hint.textContent =
						`≈ $${usd} USD • ≈ ${dmg} DAMAGE  (DAMAGE/USDT ${dmgPx}, BTC/USDT ${btcPx})`;
				} catch (e) {
					console.warn("Coinstore quote failed", e);
					hint.textContent = "Live price fetch failed (Coinstore).";
				}
			};

			// debounce on typing
			const onInput = () => {
				if (t) clearTimeout(t);
				t = setTimeout(render, 200);
			};

			invoiceAmountEl.addEventListener("input", onInput);
			invoiceAmountEl.addEventListener("change", render);
		}

	}); // end DOMContentLoaded 


	function isAuthenticated() {
		if(window.TokenManager.getToken()) return true;
		return false;
	}
	async function nodeSetPassword() {
		const passwordInput = document.getElementById("node-password");
		const confirmInput  = document.getElementById("node-password-confirm");

		const password = passwordInput.value.trim();
		const confirm  = confirmInput.value.trim();

		if (!password || !confirm) {
			alert("Please enter and confirm your node password.");
			return;
		}

		if (password !== confirm) {
			alert("Passwords do not match.");
			return;
		}

		if (password.length < 8) {
			alert("Password must be at least 8 characters long.");
			return;
		}

		try {
			const resp = await fetch("/secrets/set_password", {
				method: "POST",
				headers: {
					"Content-Type": "application/json"
				},
				body: JSON.stringify({
					password: password,
					password_confirm: confirm
				})
			});

			const data = await resp.json();

			if (data.status === "ok") {
				// Show seed phrase backup tab
				const seedPhraseTabLink = document.getElementById("seed-phrase-tab-link");
				const sweepWalletTabLink = document.getElementById("sweep-wallet-tab-link");
				
				if (seedPhraseTabLink) seedPhraseTabLink.style.display = "";
				if (sweepWalletTabLink) sweepWalletTabLink.style.display = "";

				// Initialize tabs if not already done
				if (typeof Tabby !== 'undefined') {
					// Wait a bit for DOM to update
					setTimeout(() => {
						const tabs = Tabby('[data-node-setup-tabs]');
						
						// Switch to seed phrase backup tab
						if (data.seed_phrase || data.mnemonic) {
							const seedPhrase = data.seed_phrase || data.mnemonic;
							showSeedPhraseBackup(seedPhrase);
						} else {
							// Try to fetch seed phrase from server
							fetchSeedPhrase().then(seedPhrase => {
								if (seedPhrase) {
									showSeedPhraseBackup(seedPhrase);
								} else {
									// If no seed phrase available, go to sweep wallet tab
									tabs.toggle('sweep-wallet-tab');
									loadWalletBalance();
								}
							});
						}
					}, 100);
				}

			} else {
				alert(`Failed to set password: ${data.message || "Unknown error"}`);
			}

		} catch (err) {
			console.error("Set password error:", err);
			alert("Error setting password. Check console for details.");
		}
	}

	async function fetchSeedPhrase() {
		try {
			const resp = await fetch("/secrets/get_seed_phrase", {
				method: "GET",
				headers: { "Content-Type": "application/json" }
			});
			const data = await resp.json();
			if (data.status === "ok" && (data.seed_phrase || data.mnemonic)) {
				return data.seed_phrase || data.mnemonic;
			}
			return null;
		} catch (err) {
			console.error("Fetch seed phrase error:", err);
			return null;
		}
	}

	function showSeedPhraseBackup(seedPhrase) {
		const tabs = Tabby('[data-node-setup-tabs]');
		const seedPhraseTabLink = document.getElementById("seed-phrase-tab-link");
		const placeholder = document.getElementById("seed-phrase-placeholder");
		const display = document.getElementById("seed-phrase-display");
		const wordsDiv = document.getElementById("seed-phrase-words");
		const revealBtn = document.getElementById("reveal-seed-phrase-btn");
		const copyBtn = document.getElementById("copy-seed-phrase-btn");
		const confirmation = document.getElementById("seed-phrase-confirmation");
		const okBtn = document.getElementById("seed-phrase-ok-btn");
		const confirmedCheckbox = document.getElementById("seed-phrase-confirmed");
		
		// Switch to seed phrase tab
		if (seedPhraseTabLink) {
			seedPhraseTabLink.style.display = "";
			tabs.toggle('seed-phrase-backup-tab');
		}
		
		// Store seed phrase for reveal
		if (revealBtn && !revealBtn.dataset.seedPhrase) {
			revealBtn.dataset.seedPhrase = seedPhrase;
			
			revealBtn.onclick = () => {
				if (wordsDiv && seedPhrase) {
					// Split seed phrase into words and display nicely
					const words = seedPhrase.trim().split(/\s+/);
					wordsDiv.innerHTML = words.map((word, idx) => 
						`<span class="seed-word"><span class="seed-word-number">${idx + 1}</span>${word}</span>`
					).join('');
					
					if (placeholder) placeholder.style.display = "none";
					if (display) display.style.display = "block";
					if (copyBtn) copyBtn.style.display = "block";
					if (confirmation) confirmation.style.display = "block";
					revealBtn.style.display = "none";
				}
			};
		}
		
		// Copy to clipboard
		if (copyBtn) {
			copyBtn.onclick = () => {
				if (seedPhrase) {
					navigator.clipboard.writeText(seedPhrase).then(() => {
						copyBtn.textContent = "Copied!";
						setTimeout(() => {
							copyBtn.textContent = "Copy to Clipboard";
						}, 2000);
					}).catch(err => {
						console.error("Copy failed:", err);
						alert("Failed to copy. Please select and copy manually.");
					});
				}
			};
		}
		
		// Enable OK button when checkbox is checked
		if (confirmedCheckbox && okBtn) {
			confirmedCheckbox.onchange = () => {
				okBtn.disabled = !confirmedCheckbox.checked;
			};
			
			okBtn.onclick = () => {
				if (confirmedCheckbox.checked) {
					// Move to sweep wallet tab or close modal
					const sweepWalletTabLink = document.getElementById("sweep-wallet-tab-link");
					if (sweepWalletTabLink && sweepWalletTabLink.style.display !== "none") {
						tabs.toggle('sweep-wallet-tab');
						loadWalletBalance();
					} else {
						MicroModal.close("node-set-password-modal");
					}
				}
			};
		}
	}

	async function loadWalletBalance() {
		const balanceDisplay = document.getElementById("wallet-balance-display");
		if (!balanceDisplay) return;
		
		try {
			// Try to get node public key/address
			const resp = await fetch("/node/public_key", {
				method: "GET",
				headers: { "Content-Type": "application/json" }
			});
			const data = await resp.json();
			
			if (data.status === "ok" && data.public_key) {
				// Fetch balance using existing wallet balance function if available
				if (typeof fetchWalletBalance === 'function') {
					await fetchWalletBalance(data.public_key);
					const balanceDiv = document.getElementById('wallet-balance');
					if (balanceDiv && balanceDiv.innerHTML) {
						balanceDisplay.innerHTML = balanceDiv.innerHTML;
					} else {
						balanceDisplay.innerHTML = `<p>Wallet Address: <code>${data.public_key}</code></p>`;
					}
				} else {
					balanceDisplay.innerHTML = `<p>Wallet Address: <code>${data.public_key}</code></p>`;
				}
			} else {
				balanceDisplay.innerHTML = `<p class="warning-text">Unable to load wallet balance. You can still sweep funds if you know the address.</p>`;
			}
		} catch (err) {
			console.error("Load wallet balance error:", err);
			balanceDisplay.innerHTML = `<p class="warning-text">Unable to load wallet balance. You can still sweep funds if you know the address.</p>`;
		}
	}

	async function sweepWallet() {
		const addressInput = document.getElementById("sweep-wallet-address");
		const passwordInput = document.getElementById("sweep-wallet-password");
		
		if (!addressInput || !passwordInput) {
			alert("Form elements not found.");
			return;
		}
		
		const address = addressInput.value.trim();
		const password = passwordInput.value.trim();
		
		if (!address) {
			alert("Please enter a recipient address.");
			return;
		}
		
		if (!password) {
			alert("Please enter your node password.");
			return;
		}
		
		// Validate address format (basic check for ak_ prefix)
		if (!address.startsWith('ak_')) {
			if (!confirm("The address doesn't start with 'ak_'. Are you sure this is correct?")) {
				return;
			}
		}
		
		if (!confirm("Are you sure you want to sweep ALL funds from this wallet? This action cannot be undone.")) {
			return;
		}
		
		try {
			const btn = document.getElementById("sweep-wallet-btn");
			if (btn) {
				btn.disabled = true;
				btn.textContent = "Sweeping...";
			}
			
			const resp = await fetch("/wallet/sweep", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					recipient_address: address,
					password: password
				})
			});
			
			const data = await resp.json();
			
			if (data.status === "ok") {
				alert("Funds swept successfully! Transaction: " + (data.tx_hash || "pending"));
				MicroModal.close("node-set-password-modal");
			} else {
				alert(`Failed to sweep funds: ${data.message || "Unknown error"}`);
			}
		} catch (err) {
			console.error("Sweep wallet error:", err);
			alert("Error sweeping wallet. Check console for details.");
		} finally {
			const btn = document.getElementById("sweep-wallet-btn");
			if (btn) {
				btn.disabled = false;
				btn.textContent = "Sweep All Funds";
			}
		}
	}


	async function nodeUnlock(){
		const form = document.getElementById("node-unlock-password-form");
		const passwordInput = document.getElementById("node-unlock-password");
		const password = passwordInput.value.trim();

		if (!password) {
			alert("Please enter your node password.");
			return;
		}

		try {
			const resp = await fetch("/secrets/unlock", {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
				},
				body: JSON.stringify({
					password: password
				})
			});

			const data = await resp.json();

			if (data.status === "ok") {
				alert("Node unlocked successfully!");
				if (window.MicroModal) {
					MicroModal.close("node-unlock-modal");
				}
				passwordInput.value = "";
			} else {
				alert(`Unlock failed: ${data.message || "Unknown error"}`);
			}
		} catch (err) {
			console.error("Unlock error:", err);
			alert("Error unlocking node. Check console for details.");
		}
	}
	function showLoginButton(){
		const content = document.getElementById("content");
		const background = document.getElementById("background");

		content.style.display = "none";
		background.style.display = "block";
		MicroModal.show('login-modal');
	}
	function showHideLoginButton(){
		const content = document.getElementById("content");
		const background = document.getElementById("background");
		if (isAuthenticated()) {
			try{
				MicroModal.close('login-modal');
			}catch(e){};
			content.style.display = "block";
		} else {

			content.style.display = "none";
			background.style.display = "block";
			MicroModal.show('login-modal');
		}
	}
	window.showHideLoginButton = showHideLoginButton;

	function upperCaseStream() {
		return new TransformStream({
			transform(chunk, controller) {
				controller.enqueue(chunk.toUpperCase());
			},
		});
	}

	function appendToDOMStream(el) {
		return new WritableStream({
			write(chunk) {
				el.append(chunk);
			},
		});
	}

	function addReport(){
		const runDateTime = Date.now();
		const label = `Run-${runDateTime}`;
		const tabId =`tab-${runDateTime}`;
		const options = {
			year: "2-digit",
			month: "2-digit",
			day: "2-digit",
			hour: "2-digit",
			minute: "2-digit",
			timeZoneName: "short",
		};
		const reportDateTime = new Intl.DateTimeFormat("en-US", options).format;

		const ulEl = document.getElementById('run-reports-ul');
		ulEl.role='tablist';
		const liEl = document.createElement('li');
		const aEl = document.createElement('a');
		aEl.href=`#run-${runDateTime}`;
	    aEl.innerHTML = label;
		liEl.role = "presentation";
		liEl.appendChild(aEl);
		ulEl.appendChild(liEl);


		const runreportsTabPanels = document.getElementById('run-reports');
		const div = document.createElement('div');
		div.id = `run-${runDateTime}`;
		div.setAttribute('aria-selected', true);
		const pre = document.createElement('pre');
		pre.className = 'snippet';
		const code = document.createElement('code');
		code.className = 'language-gherkin report';
		pre.appendChild(code);
		code.innerHTML='Waiting for execution results ...';
		div.appendChild(pre);
		runreportsTabPanels.appendChild(div);
		var tabs = Tabby('[data-tabs-reports]');
		tabs.setup();
		tabs.toggle(div.id);



		return code;

	}
	function replaceMarkers(el) {
		const html = el.innerHTML
			  .replace(/line:(\d+)/g, '<span class="gherkin-line">line:$1</span>')
			  .replace(/\bsuccess\b/g, '<span class="gherkin-success">success</span>')
			  .replace(/\bfail:(.+)\b/g, '<span class="gherkin-fail">fail:$1</span>')
			  .replace(/\bskip\b/g, '<span class="gherkin-skip">skip</span>')
		;

		el.innerHTML = html;
	}

	async function streamResponseToDOM(response, reportElement) {
		reportElement.innerHTML = "";

		await response.body
			.pipeThrough(new TextDecoderStream())
			.pipeTo(appendToDOMStream(reportElement));

		Prism.highlightElement(reportElement);
		replaceMarkers(reportElement);

		if (reportElement.hasAttribute('data-highlighted')) {
			reportElement.removeAttribute('data-highlighted');
		}
	}

	async function submitDamageForm() {
		const inputText = document.getElementById("damageTextArea").value.trim();
		const concurrency = 1;
		const reportElement = addReport();
		const mode = window.TokenManager.getMode();

		if (!inputText) {
			reportElement.innerText = "Please enter a feature before executing.";
			return;
		}

		try {
			const token = TokenManager.getToken();
			const headers = buildJsonAuthHeaders(token);

			if (!token && mode === "custodial") {
				// No token in custodial mode => force login
				MicroModal.show("login-modal");
				reportElement.innerText = "You need to log in to execute tests.";
				return;
			}

			if (mode === "custodial") {
				await handleCustodialExecution({ inputText, concurrency, headers, reportElement });
			} else if (mode === "noncustodial" || mode === "onchain" || mode === "channel" || mode === "extension" ||!mode) {
				await handleNonCustodialExecution({ inputText, concurrency, headers, reportElement });
			} else {
				reportElement.innerText = `Unknown execution mode: ${mode}`;
			}
		} catch (err) {
			console.error("submitDamageForm unexpected error:", err);
			reportElement.innerText =
				"Unexpected error executing feature: " + (err && err.message ? err.message : String(err));
		}
	}
	
	function buildJsonAuthHeaders(token) {
		const headers = new Headers();
		headers.set("Content-Type", "application/json");
		if (token) {
			headers.set("Authorization", "Bearer " + token);
		}
		return headers;
	}

	async function extractErrorMessage(response) {
		try {
			const contentType = response.headers.get("Content-Type") || "";
			if (contentType.includes("application/json")) {
				const j = await response.json();
				if (j && (j.message || j.error)) {
					return j.message || j.error;
				}
				return JSON.stringify(j);
			}
		} catch (e) {
			// ignore and fall back to text
		}

		try {
			return await response.text();
		} catch (e) {
			return `HTTP ${response.status} ${response.statusText}`;
		}
	}

	async function loadJobIntoModal(jobId) {
		const res = await fetch(`/ecai/jobs/${jobId}`);
		const data = await res.json();
		const job = data.job || {};

		const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = (val ?? "—"); };

		set("job-id", job.id);
		set("job-status", job.status);
		set("job-reward", job.reward_damage != null ? `${job.reward_damage} DAMAGE` : "—");
		set("job-owner", job.owner_ak);
		set("job-miner", job.miner_ak);
		set("job-chunk-hash", job.chunk_hash);
		set("job-chunk-ref", job.chunk_path || job.chunk_ref);
		set("job-attestation", job.attestation);

		const link = document.getElementById("job-evidence-link");
		const empty = document.getElementById("job-evidence-empty");
		if (job.evidence_ref) {
			link.style.display = "";
			link.href = job.evidence_ref;
			link.textContent = job.evidence_ref;
			empty.style.display = "none";
		} else {
			link.style.display = "none";
			empty.style.display = "";
		}

		// Show/hide action buttons based on status (simple client-side policy)
		const claimBtn = document.getElementById("job-claim-btn");
		const submitBtn = document.getElementById("job-submit-btn");
		const payBtn = document.getElementById("job-pay-btn");

		const st = (job.status || "").toLowerCase();
		claimBtn.style.display  = (st === "open") ? "" : "none";
		submitBtn.style.display = (st === "claimed") ? "" : "none";
		payBtn.style.display    = (st === "submitted") ? "" : "none";

		claimBtn.onclick = () => fetch(`/ecai/jobs/${jobId}/claim`, {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({miner_ak: window.myMinerAk})}).then(()=>loadJobIntoModal(jobId));
		submitBtn.onclick = () => {/* open your submit flow */};
		payBtn.onclick = () => fetch(`/ecai/jobs/${jobId}/pay`, {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({admin_ak: window.myAdminAk})}).then(()=>loadJobIntoModal(jobId));
	}

	async function handleCustodialExecution({ inputText, concurrency, headers, reportElement }) {
		const request = {
			method: "POST",
			credentials: "include",
			headers,
			body: JSON.stringify({
				feature: inputText,
				concurrency,
				stream: true
			})
		};

		let response;
		try {
			response = await fetch("/execute_feature/", request);
		} catch (err) {
			console.error("Network error calling /execute_feature/:", err);
			reportElement.innerText =
				"Network error while executing feature: " + (err.message || String(err));
			return;
		}

		if (response.status === 401) {
			MicroModal.show("login-modal");
			reportElement.innerText = "You are not authorized. Please log in.";
			return;
		}

		if (!response.ok) {
			const errText = await extractErrorMessage(response);
			reportElement.innerText = "Error executing feature:\n" + errText;
			return;
		}

		try {
			await streamResponseToDOM(response, reportElement);
		} catch (err) {
			console.error("Error streaming response to DOM:", err);
			reportElement.innerText =
				"Error while streaming execution output: " + (err.message || String(err));
		}
	}

	async function handleNonCustodialExecution({ inputText, concurrency, headers, reportElement }) {
		const address = window.TokenManager.getAddress();
		if (!address) {
			reportElement.innerText = "No wallet address found. Please connect your wallet.";
			return;
		}

		var channel;
		try {
			channel = await ensureChannel({
				nodeUrl: NODE_BASE,
				mdwUrl: NODE_BASE,
				responderId: window.nodePublicKey,
				initiatorId: address
			});
		} catch (err) {
			console.error("ensureChannel failed:", err);
			reportElement.innerText =
				"Failed to ensure payment channel: " + (err.message || String(err));
			return;
		}

		const prepareReq = {
			method: "POST",
			credentials: "include",
			headers,
			body: JSON.stringify({
				feature: inputText,
				address,
				concurrency,
				channel_id: channel.channel.id
			})
		};

		let txPrepareResp;

		try {
			txPrepareResp = await fetch("/tx/", prepareReq);
			try {
				await streamResponseToDOM(txPrepareResp, reportElement);
			} catch (err) {
				console.error("Error streaming signed response to DOM:", err);
				reportElement.innerText =
					"Error while streaming execution output: " + (err.message || String(err));
			}
		} catch (err) {
			console.error("Network error calling /tx/ (prepare):", err);
			reportElement.innerText =
				"Network error while preparing transaction: " + (err.message || String(err));
			return;
		}
		return;

		if (!txPrepareResp.ok) {
			const msg = await extractErrorMessage(txPrepareResp);
			reportElement.innerText = "Failed to prepare transaction: " + msg;
			return;
		}

		let data;
		try {
			data = await txPrepareResp.json();
		} catch (err) {
			console.error("JSON parse error for /tx/ (prepare):", err);
			reportElement.innerText = "Invalid JSON from server while preparing transaction.";
			return;
		}

		if (data.status !== "ok" || !data.tx) {
			reportElement.innerText =
				"Failed to prepare transaction: " + (data.message || "Unknown error");
			return;
		}

		const message = data.tx;

		try {
			await window.connectWalletUnified();
		} catch (err) {
			console.error("connectWalletUnified failed:", err);
			reportElement.innerText =
				"Failed to connect wallet: " + (err.message || String(err));
			return;
		}

		let signature;
		try {
			signature = await wallet.signTransactionSmart(
				message,
				"ae_mainnet",
				window.location.origin,
				window.location.origin
			);
		} catch (err) {
			console.error("signTransactionSmart threw error:", err);
			reportElement.innerText =
				"Failed to sign transaction: " + (err.message || String(err));
			return;
		}

		if (!signature || !signature.ok) {
			const errorMsg =
				  (signature && signature.error && signature.error.message) ||
				  "Unknown signing error";
			reportElement.innerText = "Failed to sign: " + errorMsg;
			return;
		}

		const signedTx = signature.result && signature.result.signedTransaction;
		if (!signedTx) {
			reportElement.innerText = "Wallet did not return a signed transaction.";
			return;
		}

		const signedRequest = {
			method: "POST",
			credentials: "include",
			headers,
			body: JSON.stringify({
				feature: inputText,
				address,
				concurrency,
				signed_tx: signedTx
			})
		};

		let signedResponse;
		try {
			signedResponse = await fetch("/tx/", signedRequest);
		} catch (err) {
			console.error("Network error calling /tx/ (signed):", err);
			reportElement.innerText =
				"Network error after signing transaction: " + (err.message || String(err));
			return;
		}

		if (!signedResponse.ok) {
			const errText = await extractErrorMessage(signedResponse);
			reportElement.innerText = "Error after signing: " + errText;
			return;
		}

		try {
			await streamResponseToDOM(signedResponse, reportElement);
		} catch (err) {
			console.error("Error streaming signed response to DOM:", err);
			reportElement.innerText =
				"Error while streaming execution output: " + (err.message || String(err));
		}
	}




	function submitSignUpForm(event) {
		const username = document.getElementById("signup-username").value;
		if (!validateEmail(username)) {
			showNotification({title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
			return;
		}

		const signupData = {
			email: username
		};

		const headers = new Headers();
		headers.append("Content-Type", "application/json");
		fetch("/accounts/create/", {
			method: "POST",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => {
				return response.json();
			})
			.then(data => {
				if (data.status == "ok") {
					showNotification({
						title: 'Success - Confirmation Required',
						content: data.message,
						style: 'success'
					});
				} else {
					showNotification({
						title: 'Signup Failed',
						content: 'Signup Error.',
						style: 'error'
					});
				}
			})
			.catch(error => {
				console.error("Error:", error);
			});
		event.preventDefault();
		return;
	}
	function submitLoginForm(event) {
		const username = document.getElementById("login-username").value;
		const password = document.getElementById("password").value;

		if (!validateEmail(username)) {
			showNotification({
				title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
			return;
		}

		const signupData = {
			grant_type: "password",
			scope: "basic",
			username: username,
			password: password
		};

		const headers = new Headers();
		headers.append("Content-Type", "application/json");

		fetch("/accounts/auth/", {
			method: "POST",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => {
				return response.json();
			})
			.then(data => {
				if (data.access_token) {

					window.TokenManager.on_custodial_login(data.address, data.email, data.access_token);
					showConnectStatus("Login Success!", "success");
					showHideLoginButton();

				} else {
					showConnectStatus("Login Failed!", "failed");
				}
			})
			.catch(error => {
				console.error("Error:", error);
			});
		event.preventDefault();
		return;
	}
	function submitForgotPasswordForm(event) {
		const username = document.getElementById("login-username").value;

		if (!validateEmail(username)) {
			showNotification({title:"Invalid email", content: "Please enter a valid email address.",  style:"error"});
			return;
		}


		const headers = new Headers();
		headers.append("Content-Type", "application/json");
		headers.append("Authorization", "Bearer "+ window.TokenManager.getToken());

		fetch("/accounts/reset_password/", {
			method: "POST",
			headers: headers,
			body: JSON.stringify({email : username})
		})
			.then(response => {
				return response.json();
			})
			.then(data => {
				if (data.status === "ok") {
					showNotification({
						title: 'Reset Password Success',
						content: data.message,
						style: 'success'
					});
				} else {
					showNotification({
						title: 'Login Failed',
						content: 'Authentication Un-Successful.',
						style: 'error'
					});
				}
			})
			.catch(error => {
				console.error("Error:", error);
			});
		event.preventDefault();
		return;
	}


	function validateEmail(email) {
		const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
		return regex.test(email);
	}
	function satsToBtc(sats) {
		// Ensure input is treated as a number
		const satoshiAmount = Number(sats);
		// 1 BTC = 100,000,000 satoshis
		const btcAmount = satoshiAmount / 100000000;
		return btcAmount;
	}
	function renderNodeFooter(resp) {
		// schema: { ok:true, version, public_key, damage_balance, ae_balance, btc_balance, verson:{...} }
		if (!resp || resp.ok !== true) return;

		const pk = resp.public_key ?? "unknown";

		const damage = Number(resp.damage_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const ae     = Number(resp.ae_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const btc    = Number(resp.btc_balance ?? 0).toLocaleString(); // sats, as provided

		const version = resp.version ?? "unknown";

		const build = version;

		const shaFull  = build.git_sha ?? "unknown";
		const shaShort = build.git_sha_short ?? (shaFull !== "unknown" ? shaFull.slice(0, 7) : "unknown");
		const time     = build.build_time ?? "unknown";
		const env      = build.build_env ?? "unknown";

		// Copyable public key
		const pkEl = document.getElementById("node-public-key");
		if (pkEl) {
			pkEl.textContent = pk;              // copyToClipboard reads textContent
			pkEl.title = "Click 📋 to copy";
		}

		// Balances + version
		const balEl = document.getElementById("node-balances");
		if (balEl) {
			balEl.textContent = `Balances — DAMAGE ${damage} | AE ${ae} | BTC(sats) ${btc}`;
		}

		// Copyable commit hash target (display short, copy same element text unless you choose hidden full)
		const shaEl = document.getElementById("node-build-sha");
		if (shaEl) {
			shaEl.textContent = shaFull;        // ✅ copy full hash using existing helper
			shaEl.title = `Commit: ${shaFull}`;
			// If you want UI to show short but still copy full, see note below.
		}

		const metaEl = document.getElementById("node-build-meta");
		if (metaEl) {
			metaEl.textContent = `Build: ${env} · ${shaShort} · ${time}`;
		}
	}






	function generateInvoice() {
		var amount = document.getElementById('invoice-amount').value;
		const request = {
			method: 'POST',
			credentials: 'include',
			headers: { 'Content-Type': 'application/json',
					   'Authorization': 'Bearer ' + window.TokenManager.getToken()
					 },
			body: JSON.stringify({
				amount_sats: parseInt(amount)
			})
		};

		fetch("/invoices/", request)
			.then(response => {
				if (response.status === 201) {
					return response.json();
				} else if (response.status === 401) {
					MicroModal.show("login-modal");
				}
			})
			.then(data => {
				if (data && data.status === "ok") {
					document.getElementById("qrcode-lightning").innerText = "";
					document.getElementById("lightning-invoice-input").value = "lightning:" + data.invoice.payment_request;
					showLightningQR({containerId : "qrcode-lightning",
									 paymentRequest:  data.invoice.payment_request,
									 address: window.TokenManager.getAddress(),
									 logo: "/static/img/logo.png"
									});
				} else {
					console.error("Error Invoice fetching failed: ", data);
					showDialog({
						title: 'Request Failed',
						content: data.message,
						style: 'error'
					});
				}
			})
			.catch(error => {
				console.error("Error Invoice fetching failed: ", error.message);
				showDialog({
					title: 'Request Failed',
					content: error.message,
					style: 'error'
				});
			});
	}


	function addVariable() {
		var variableName = document.getElementById("variableName").value;
		var variableType = document.getElementById("variableType").value;

		var variableText = document.createElement("p");
		variableText.innerText = "Variable Name: " + variableName + " - Type: " + variableType;
		document.getElementById("contextVariables").appendChild(variableText);

		document.getElementById("variableName").value = "";
		document.getElementById("variableType").selectedIndex = 0;
	}

})(window, document, undefined);

function copyInvoiceToClipboard(){
	// Copy the text inside the text field
	navigator.clipboard.writeText(document.getElementById("lightning-invoice-input").value);
	var copyIcon = document.getElementById("copyInvoiceIcon");
	copyIcon.textContent = '✔️ Copied!'; // Change icon to tick
	copyIcon.style.color = 'green'; // Change color to green
}

function copyAddressToClipboard(){
	// Copy the text inside the text field
	navigator.clipboard.writeText(document.getElementById("damage-address").value);
	var copyIcon = document.getElementById("copyAddressIcon");
	copyIcon.textContent = '✔️ Copied!'; // Change icon to tick
	copyIcon.style.color = 'green'; // Change color to green
}

function copyToClipboard(elementId) {
	const el = document.getElementById(elementId);
	if (!el) return;

	const icon = el.parentElement?.querySelector(".copy-icon");
	const text = el.value || el.textContent;

	const showSuccess = () => {
		if (icon) {
			const original = icon.textContent;
			icon.textContent = "✅";
			icon.style.color = "#00ff88";
			setTimeout(() => {
				icon.textContent = original;
				icon.style.color = "";
			}, 1500);
		}
	};

	if (navigator.clipboard && window.isSecureContext) {
		navigator.clipboard.writeText(text)
			.then(() => {
				console.log("Copied to clipboard:", text);
				showSuccess();
			})
			.catch(err => {
				console.error("Clipboard copy failed:", err);
			});
	} else {
		let range, selection;

		if (el.nodeName === "INPUT" || el.nodeName === "TEXTAREA") {
			el.select();
			el.setSelectionRange(0, text.length);
		} else {
			range = document.createRange();
			range.selectNodeContents(el);
			selection = window.getSelection();
			selection.removeAllRanges();
			selection.addRange(range);
		}

		try {
			document.execCommand("copy");
			console.log("Copied (fallback):", text);
			showSuccess();
		} catch (err) {
			console.error("Fallback copy failed:", err);
		}

		if (selection) selection.removeAllRanges();
		if (el.blur) el.blur();
	}
}

// ⬅️ Make it accessible from HTML inline
window.copyToClipboard = copyToClipboard;
