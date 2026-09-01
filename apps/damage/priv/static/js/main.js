import * as wallet from "/static/js/wallet.js";
import * as nwc from "/static/js/nwc.js";
import { showLightningQR } from '/static/js/damage-lightning-ui.js';
import { ensureChannel } from '/static/js/ensureChannel.js';
import { updateSchedulesTable } from '/static/js/schedules.js';
import { initDamageBDDPicker, rememberRecentFeature } from "./featurePicker.js";
import "/static/js/balances.js";



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
function debounceAsync(fn, delay = 800) {
	let timeout = null;
	let inFlight = false;

	return async function (...args) {
		if (inFlight) return;

		clearTimeout(timeout);

		timeout = setTimeout(async () => {
			inFlight = true;
			try {
				await fn.apply(this, args);
			} finally {
				inFlight = false;
			}
		}, delay);
	};
}
function setButtonLoading(btn, isLoading) {
	if (!btn) return;

	if (isLoading) {
		btn.dataset.originalText = btn.innerHTML;
		btn.disabled = true;
		btn.innerHTML = '⏳';
		btn.classList.add('loading');
	} else {
		btn.disabled = false;
		if (btn.dataset.originalText) {
			btn.innerHTML = btn.dataset.originalText;
		}
		btn.classList.remove('loading');
	}
}
function wrapApiButton(btn, handler, delay = 800) {
	if (!btn) {
		return;
	}

	const wrapped = debounceAsync(async (e) => {
		try {
			setButtonLoading(btn, true);
			await handler(e);
		} finally {
			setButtonLoading(btn, false);
		}
	}, delay);

	btn.addEventListener('click', wrapped);
}

function wrapApiForm(form, button, handler) {
  if (!form) return;

  form.addEventListener("submit", async (event) => {
    if (button) {
      button.disabled = true;
      button.classList.add("loading");
    }

    try {
      await handler(event);
    } finally {
      if (button) {
        button.disabled = false;
        button.classList.remove("loading");
      }
    }
  });
}
function getCurrentDashboardAddress() {
	try {
		const address = window.TokenManager?.getAddress?.();
		if (address && address.startsWith("ak_")) return address;
	} catch (_e) {}

	const balanceAddress = document.getElementById("balanceAddress");
	const fromDataset = balanceAddress?.dataset?.pubkey;
	const fromTitle = balanceAddress?.title;

	if (fromDataset && fromDataset.startsWith("ak_")) return fromDataset;
	if (fromTitle && fromTitle.startsWith("ak_")) return fromTitle;

	return null;
}

async function refreshDashboardBalances() {
	const address = getCurrentDashboardAddress();

	if (!address) {
		console.debug("Dashboard balance refresh skipped: no ak_ address");
		return { ok: false, error: "missing_address" };
	}

	if (typeof window.updateAllBalances !== "function") {
		console.warn("balances.js not loaded: window.updateAllBalances missing");
		return { ok: false, error: "balances_js_missing" };
	}

	return window.updateAllBalances(address, {
		preserveAddressText: false
	});
}

window.refreshDashboardBalances = refreshDashboardBalances;

function restoreFeatureDraftFromShareLink() {
	const ta = document.getElementById("damageTextArea");
	if (!ta) return;

	let txt = localStorage.getItem("damagebdd_feature_draft");
	const autorun = localStorage.getItem("damagebdd_feature_autorun") === "1";

	localStorage.removeItem("damagebdd_feature_draft");
	localStorage.removeItem("damagebdd_feature_autorun");

	if (!txt || !txt.trim()) return;

	ta.value = txt.trim();

	if (autorun) {
		// defer so all handlers are bound
		setTimeout(() => {
			if (typeof submitDamageForm === "function") {
				submitDamageForm();
			}
		}, 0);
	}
}

(function(window, document, undefined) {

	// code that should be taken care of right away
	window.dataLayer = window.dataLayer || [];

	document.addEventListener("DOMContentLoaded", function () {
		[
			"open-node-wallet-btn",
			"open-node-wallet-btn-auth",
		].forEach((id) => {
			const el = document.getElementById(id);
			if (!el) return;

			wrapApiButton(el, async (event) => {
				event.preventDefault();
				await openNodeWalletDialog(el);
			});
		});
	});

	document.addEventListener("auth:changed", async () => {
		try {
			const r = await fetch("/version", {
				method: "GET",
				credentials: "include",
				headers: { accept: "application/json" }
			});
			const data = await r.json();
			if (data && data.ok === true) {
				renderNodeFooter(data);
				if (typeof renderNodeWalletModal === "function") {
					renderNodeWalletModal(data);
				}
			}
		} catch (err) {
			console.warn("auth-changed version refresh failed:", err);
		}

		try {
			await refreshDashboardBalances();
		} catch (err) {
			console.warn("auth-changed balance refresh failed:", err);
		}
		try {
			if (window.TokenManager.getToken()) {
				updateSchedulesTable();
			}
		} catch (err) {
			console.warn("auth-changed schedules refresh failed:", err);
		}
	});
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
		wrapApiButton(
			document.getElementById("loginSubmitBtn"),
			submitLoginForm
		);

		document.getElementById("loginSubmitBtn").addEventListener("click",(event) => {
			event.preventDefault();
			});

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
			wrapApiButton(
				document.getElementById("signupSubmitBtn"),
				submitSignUpForm);
			wrapApiButton(
				document.getElementById("loginResetPasswdBtn"),
				submitForgotPasswordForm);
			//document.getElementById("loginDialogBtn").addEventListener("click", (event) => {
			//	event.preventDefault();
			//	MicroModal.close("signup-modal");
			//	MicroModal.show("login-modal");
			//});
			const logoutSubmitBtn = document.getElementById("logoutSubmitBtn");

			wrapApiButton(logoutSubmitBtn, async (event) => {
				event.preventDefault();

				try {
					if (typeof window.logoutActiveSession === "function") {
						await window.logoutActiveSession();
					} else {
						window.TokenManager.logout(window.TokenManager.getMode());
					}
				} finally {
					try { MicroModal.close("logout-modal"); } catch (_e) {}
					window.location.reload();
				}
			});


			const logoutBtn = document.getElementById("logoutBtn");

			if (logoutBtn) {
				logoutBtn.addEventListener("click", (event) => {
					event.preventDefault();
					MicroModal.show("logout-modal");
			});
		}

		showHideLoginButton();

		setTimeout(() => {
			refreshDashboardBalances();
			document.dispatchEvent(new CustomEvent("damage:dashboard-loaded", {
				detail: { address: getCurrentDashboardAddress() }
			}));
		}, 0);

		Tabby('[data-node-wallet-tabs]');
		MicroModal.init({
			onShow: modal => {
				console.info(`${modal.id} is shown`);

				if (typeof window.initInstallForm === 'function') window.initInstallForm();

				if(modal.id == 'wallet-modal'){
					var address = window.TokenManager.getAddress();
					generateDamageQR(address);
					var damageAddr = document.getElementById("damage-address");
					damageAddr.value = address;
				}
			}
		});


		const nodeUnlockForm = document.getElementById("node-unlock-password-form");
		const nodeUnlockSubmitBtn = document.getElementById("node-unlock-password-submit-btn");
		wrapApiForm(nodeUnlockForm, nodeUnlockSubmitBtn, async (event) => {
			event.preventDefault();
			await nodeUnlock();
		});


		const nodeUnlockPassword = document.getElementById("node-unlock-password");
		if (nodeUnlockPassword && nodeUnlockForm) {
			nodeUnlockPassword.addEventListener("keydown", (event) => {
				if (event.ctrlKey && event.key === "Enter") {
					event.preventDefault();
					nodeUnlockForm.requestSubmit();
				}
			});
		}

		const nodeSetPasswordSubmitBtn = document.getElementById("node-set-password-submit-btn");
		const nodeSetPasswordForm =
			nodeSetPasswordSubmitBtn?.closest("form") ||
			document.getElementById("node-password")?.closest("form");
		wrapApiForm(nodeSetPasswordForm, nodeSetPasswordSubmitBtn, async (event) => {
			event.preventDefault();
			await nodeSetPassword();
		});

		const nodePasswordConfirm = document.getElementById("node-password-confirm");
		if (nodePasswordConfirm && nodeSetPasswordForm) {
			nodePasswordConfirm.addEventListener("keydown", (event) => {
				if (event.ctrlKey && event.key === "Enter") {
					event.preventDefault();
					nodeSetPasswordForm.requestSubmit();
				}
			});
		}


		wrapApiForm(
			document.getElementById("invoice-form"),
			document.getElementById("generate-invoice-btn"),
			async (event) => {
				event.preventDefault();
				await generateInvoice();
				MicroModal.close("wallet-modal");
			}
		);
		wrapApiForm(
			document.getElementById("ledger-invoice-form"),
			document.getElementById("generate-ledger-invoice-btn"),
			async (event) => {
				event.preventDefault();
				await generateLedgerInvoice();
				MicroModal.close("wallet-modal");
			}
		);
		fetch("/version")
			.then(r => r.json())
			.then(data => {
				if (data.ok === true) {
					renderNodeFooter(data);
				}else{
					//versionDom.innerText = 'node not initialized: ' + versionData.error;
					MicroModal.close("login-modal");
					if(data.error === "node_locked"){
						MicroModal.show("node-unlock-modal");
					}else if (data.error === "keypair_not_initialized"){
						MicroModal.show("node-set-password-modal");
					}
				}})
			.catch(() => {});


        const addScheduleBtn = document.getElementById("addScheduleBtn");
        if (addScheduleBtn) {
            addScheduleBtn.addEventListener("click", (event) => {
                console.log("add schedule");
                event.preventDefault();
            });
        }

		var activityLink = document.getElementById("activity-link");
		if (activityLink) {
			document.getElementById("activity-link").addEventListener("click", (event) => {
				event.preventDefault();
				var tabs = Tabby('[data-tabs]');
				tabs.toggle('activity');
			});
		}

		// Sweep wallet button handler
		const sweepWalletBtn = document.getElementById("sweep-wallet-btn");
		wrapApiButton(sweepWalletBtn, async (event) => {
			event.preventDefault();
			await sweepWallet();
		});

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
				if (event.detail.tab.id === 'tabby-toggle_execution-tab') {
					initDamageBDDPicker({
						opener: "#open-feature-picker",
						mount: "#feature-picker-mount",
						editor: '#damageTextArea',
						gateway: "/features/",
						samplesIndexUrl: "/samples/features/index.json"
					});
					document.addEventListener("click", (e) => {
						const btn = e.target.closest("#open-feature-picker");
						if (!btn) return;

						e.preventDefault();
						console.log("feature picker clicked");
						MicroModal.show("feature-picker-modal");
					});
				}
				if (event.detail && event.detail.content && event.detail.content.id === 'seed-phrase-backup-tab') {
					// Check if seed phrase was already set
					const revealBtn = document.getElementById("reveal-seed-phrase-btn");
					if (revealBtn && revealBtn.dataset.seedPhrase) {
						// Seed phrase already loaded, nothing to do
					}
				}
				if (event.detail && event.detail.content && event.detail.content.id === 'sweep-wallet-tab') {
					//loadWalletBalance();
				}
			}, false);
		}
		const openWalletModalBtn = document.getElementById("open-wallet-modal-btn");
		if (openWalletModalBtn) {
			openWalletModalBtn.addEventListener("click", (event) => {
				event.preventDefault();
				MicroModal.show("wallet-modal");
			});
		}

		const balanceRefreshBtn = document.getElementById("balanceRefreshBtn");
		if (balanceRefreshBtn) {
			wrapApiButton(balanceRefreshBtn, async (event) => {
				event.preventDefault();
				await refreshDashboardBalances();
			}, 0);
		}

		
		const contentDiv = document.getElementById("content");
		if(!contentDiv){
			showLoginButton();
			return;
		}
		
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
		Tabby('[data-node-wallet-tabs]');
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
		// Execute feature (API → wrap)
		wrapApiButton(
			document.getElementById("execute-feature-btn"),
			async function (event) {
				event.preventDefault();
				await submitDamageForm();
			}
		);
		document.getElementById("damageForm").addEventListener("submit", async function (event) {
			event.preventDefault();
			await submitDamageForm();
		});


		// Toggle password (UI only → no debounce)
		document.querySelectorAll(".toggle-password").forEach((btn) => {
			btn.addEventListener("click", () => {
				const input = document.getElementById(btn.dataset.target) ||
					document.querySelector(`input[name='${btn.dataset.target}']`);
				if (!input) return;
				if (input.type === "password") {
					input.type = "text";
					btn.textContent = "🙈";
				} else {
					input.type = "password";
					btn.textContent = "👁️";
				}
			});
		});


		// Tabs (UI only → no debounce)
		var tabs = Tabby('[data-tabs]');
		tabs.toggle('execution');


		// Optional bridge (no change)
		window.rememberRecentFeature = rememberRecentFeature;



		// Job modal trigger (likely API → wrap dynamically)
		//document.addEventListener("click", (e) => {
		//	const btn = e.target.closest("[data-micromodal-trigger='ecai-job-details-modal']");
		//	if (!btn) return;

		//	// prevent rapid re-clicks
		//	if (btn.dataset.loading === "true") return;

		//	const jobId = btn.getAttribute("data-job-id");
		//	if (!jobId) return;

		//	btn.dataset.loading = "true";

		//	(async () => {
		//		try {
		//			setButtonLoading(btn, true);
		//			await loadJobIntoModal(jobId);
		//		} finally {
		//			setButtonLoading(btn, false);
		//			btn.dataset.loading = "false";
		//		}
		//	})();
		//});
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
		nwc.bindNwcUi();

		// Optional: bind a button somewhere to open the modal
		const openNwcBtn = document.getElementById("open-nwc-modal-btn");

		wrapApiButton(openNwcBtn, async (event) => {
			event.preventDefault();
			nwc.openNwcModal();
		}, 0);


		bindExecutionContextEditor();
		restoreFeatureDraftFromShareLink();

	}); // end DOMContentLoaded 


	function isAuthenticated() {
		if(window.TokenManager.getToken()) return true;
		return false;
	}
	async function nodeSetPassword() {
		const passwordInput = document.getElementById("node-password");
		const confirmInput  = document.getElementById("node-password-confirm");

		const password = passwordInput.value;
		const confirm  = confirmInput.value;

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
					} else {
						MicroModal.close("node-set-password-modal");
					}
				}
			};
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
		const passwordInput = document.getElementById("node-unlock-password");
		if (!passwordInput) return;
		const password = passwordInput.value;

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
				window.location.reload();
				return;
			} else {
				alert(`Unlock failed: ${data.message || "Unknown error"}`);
			}
		} catch (err) {
			console.error("Unlock error:", err);
			alert("Error unlocking node. Check console for details.");
		}
	}
	function showLoginButton(){
		const background = document.getElementById("background");

		background.style.display = "block";
		const content = document.getElementById("content");
		if(content)content.style.display = "none";
		MicroModal.show('login-modal');
	}
	function showHideLoginButton(){
		const content = document.getElementById("content");
		if(!content)return;
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

	function extractReportIpfsHashFromText(text) {
		if (!text) return null;
		const lines = String(text).trim().split(/\r?\n/);
		// Only look at the tail to avoid matching earlier unrelated hashes
		const tail = lines.slice(Math.max(0, lines.length - 50)).join("\n");

		// Prefer hashes that appear in the canonical reports URL
		const reportUrlRe = /\/reports\/(Qm[1-9A-HJ-NP-Za-km-z]{40,}|bafy[0-9a-z]{20,})/g;
		let m;
		let last = null;
		while ((m = reportUrlRe.exec(tail)) !== null) last = m[1];
		if (last) return last;

		// Fallback: any CID-looking token near the bottom
		const cidRe = /\b(Qm[1-9A-HJ-NP-Za-km-z]{40,}|bafy[0-9a-z]{20,})\b/g;
		while ((m = cidRe.exec(tail)) !== null) last = m[1];
		return last;
	}

	function extractFeatureIpfsHashFromText(text) {
		if (!text) return null;
		const lines = String(text).trim().split(/\r?\n/);

		// Look near the top + bottom (feature header is usually early)
		const scan = lines.slice(0, 20).concat(lines.slice(-20)).join("\n");

		// Matches: Feature: <CID>
		const featureRe = /Feature:\s*(Qm[1-9A-HJ-NP-Za-km-z]{40,}|bafy[0-9a-z]{20,})/;
		const m = scan.match(featureRe);
		return m ? m[1] : null;
	}

	function ensureReportLinkActions(reportElement) {
		// reportElement is the <code> element inside <pre>
		const root = reportElement.closest("div") || reportElement.parentElement;
		if (!root) return;

		// Don't duplicate
		const existing = root.querySelector(".report-actions");
		if (existing) existing.remove();

		const reportHash  = extractReportIpfsHashFromText(reportElement.textContent);
		const featureHash = extractFeatureIpfsHashFromText(reportElement.textContent);

		if (!reportHash && !featureHash) return;

		const actions = document.createElement("div");
		actions.className = "report-actions";
		actions.style.display = "flex";
		actions.style.gap = "0.5rem";
		actions.style.alignItems = "center";
		actions.style.marginTop = "0.75rem";
		actions.style.flexWrap = "wrap";

		/* ── Report link ───────────────────────────── */
		if (reportHash) {
			const reportUrl = `https://run.dev.damagebdd.com/reports/${reportHash}`;

			const reportBtn = document.createElement("button");
			reportBtn.type = "button";
			reportBtn.className = "btn";
			reportBtn.textContent = "Copy report link";
			reportBtn.addEventListener("click", async () => {
				const ok = await copyToClipboard(reportUrl);
				reportBtn.textContent = ok ? "Copied!" : "Copy failed";
				setTimeout(() => (reportBtn.textContent = "Copy report link"), 1200);
			});

			const reportA = document.createElement("a");
			reportA.href = reportUrl;
			reportA.target = "_blank";
			reportA.rel = "noopener noreferrer";
			reportA.textContent = reportHash;
			reportA.style.fontSize = "0.9em";

			actions.appendChild(reportBtn);
			actions.appendChild(reportA);
		}

		/* ── Feature link ──────────────────────────── */
		if (featureHash) {
			const featureUrl = `${window.location.origin}/features/${featureHash}`;

			const featureBtn = document.createElement("button");
			featureBtn.type = "button";
			featureBtn.className = "btn secondary";
			featureBtn.textContent = "Copy feature link";
			featureBtn.addEventListener("click", async () => {
				const ok = await copyToClipboard(featureUrl);
				featureBtn.textContent = ok ? "Copied!" : "Copy failed";
				setTimeout(() => (featureBtn.textContent = "Copy feature link"), 1200);
			});

			const featureA = document.createElement("a");
			featureA.href = featureUrl;
			featureA.target = "_blank";
			featureA.rel = "noopener noreferrer";
			featureA.textContent = featureHash;
			featureA.style.fontSize = "0.9em";

			actions.appendChild(featureBtn);
			actions.appendChild(featureA);
		}

		root.appendChild(actions);
	}


	async function streamResponseToDOM(response, reportElement) {
		reportElement.innerHTML = "";

		await response.body
			.pipeThrough(new TextDecoderStream())
			.pipeTo(appendToDOMStream(reportElement));

		Prism.highlightElement(reportElement);
		replaceMarkers(reportElement);

		if (reportElement.hasAttribute("data-highlighted")) {
			reportElement.removeAttribute("data-highlighted");
		}

		// Add a "copy report link" action at the end if we can detect a report hash
		ensureReportLinkActions(reportElement);
	}


	const EXECUTION_RUNTIME_CONTEXT_KEY = "damagebdd_execution_runtime_context";
	const EXECUTION_RUNTIME_RESERVED_KEYS = new Set([
		"feature", "feature_cid", "vars", "stream", "concurrency",
		"continue_on_fail", "color_formatter", "channel_id", "signed_tx",
		"unsigned_tx", "tx", "action", "payfor", "signature", "message",
		"pubkey", "address", "public_key", "private_key", "access_token",
		"auth_type", "username", "node_public_key", "token_contract",
		"run_id", "run_dir", "report_hash", "report_dir", "feature_hash",
		"context", "runtime_context", "context_scopes", "context_proofs",
		"context_redactions", "context_redaction_ref", "damage_context_effective",
		"account_context", "node_context", "context_ipfs_hash",
		"context_ipfs_uri", "context_ipfs_url", "context_url"
	]);
	let executionRuntimeContext = {};
	function validateRuntimeContextKeys(context) {
		for (const key of Object.keys(context)) {
			const normalized = String(key).toLowerCase();
			if (EXECUTION_RUNTIME_RESERVED_KEYS.has(normalized)) {
				throw new Error(`Runtime context key is reserved: ${key}`);
			}
		}
	}


	function executionContextStatus(id, message, error = false) {
		const el = document.getElementById(id);
		if (!el) return;
		el.textContent = message || "";
		el.className = error ? "error" : "success";
	}

	function parseTypedContextValue(raw, type) {
		switch (type) {
		case "integer":
			if (!/^-?\d+$/.test(raw.trim())) throw new Error("Value must be an integer.");
			return Number.parseInt(raw, 10);
		case "float": {
			const value = Number(raw);
			if (!Number.isFinite(value)) throw new Error("Value must be a number.");
			return value;
		}
		case "boolean":
			if (raw.trim().toLowerCase() === "true") return true;
			if (raw.trim().toLowerCase() === "false") return false;
			throw new Error('Boolean value must be "true" or "false".');
		case "json":
			return JSON.parse(raw);
		default:
			return raw;
		}
	}

	function loadRuntimeContextDraft() {
		const input = document.getElementById("runtime-context-json");
		let stored = sessionStorage.getItem(EXECUTION_RUNTIME_CONTEXT_KEY);
		if (!stored) stored = "{}";

		try {
			const parsed = JSON.parse(stored);
			executionRuntimeContext =
				parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
		} catch (_e) {
			executionRuntimeContext = {};
		}

		if (input) input.value = JSON.stringify(executionRuntimeContext, null, 2);
	}

	function applyRuntimeContextDraft() {
		const input = document.getElementById("runtime-context-json");
		if (!input) return {};

		const parsed = JSON.parse(input.value || "{}");
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			throw new Error("Runtime context must be a JSON object.");
		}
		validateRuntimeContextKeys(parsed);

		executionRuntimeContext = parsed;
		sessionStorage.setItem(
			EXECUTION_RUNTIME_CONTEXT_KEY,
			JSON.stringify(executionRuntimeContext)
		);
		input.value = JSON.stringify(executionRuntimeContext, null, 2);
		return executionRuntimeContext;
	}

	function currentRuntimeContext() {
		return {...executionRuntimeContext};
	}

	function accountContextHeaders() {
		const headers = buildJsonAuthHeaders(window.TokenManager?.getToken?.());
		headers.set("Accept", "application/json");
		return headers;
	}

	async function accountContextRequest(url, options = {}) {
		const response = await fetch(url, {
			credentials: "include",
			cache: "no-store",
			...options,
			headers: options.headers || accountContextHeaders()
		});

		const text = await response.text();
		let data = {};
		if (text) {
			try { data = JSON.parse(text); }
			catch (_e) { data = {message: text}; }
		}

		if (!response.ok) {
			throw new Error(data.message || data.error || `HTTP ${response.status}`);
		}
		return data;
	}

	function accountContextEntries(data) {
		if (data && data.entries && typeof data.entries === "object") return data.entries;
		if (data && data.result && data.result.entries &&
			typeof data.result.entries === "object") return data.result.entries;
		return {};
	}

	function renderExecutionAccountContext(data) {
		const body = document.getElementById("execution-account-context-rows");
		const version = document.getElementById("execution-account-context-version");
		if (!body) return;

		const entries = accountContextEntries(data);
		const currentVersion =
			Number.isInteger(data?.version) ? data.version :
			Number.isInteger(data?.result?.version) ? data.result.version : null;

		body.dataset.version = currentVersion === null ? "" : String(currentVersion);
		if (version) version.textContent = currentVersion === null ? "—" : String(currentVersion);

		body.replaceChildren();
		const keys = Object.keys(entries).sort();
		if (!keys.length) {
			const tr = document.createElement("tr");
			const td = document.createElement("td");
			td.colSpan = 5;
			td.textContent = "No account context configured.";
			tr.appendChild(td);
			body.appendChild(tr);
			return;
		}

		for (const key of keys) {
			const entry = entries[key] || {};
			const tr = document.createElement("tr");
			const values = [
				key,
				entry.sensitive === true ? "XX-REDACTED-XX" :
					(typeof entry.value === "string" ? entry.value : JSON.stringify(entry.value)),
				entry.sensitive === true ? "yes" : "no",
				entry.exposure || "template"
			];

			for (const value of values) {
				const td = document.createElement("td");
				td.textContent = value == null ? "" : String(value);
				tr.appendChild(td);
			}

			const actions = document.createElement("td");
			const edit = document.createElement("button");
			edit.type = "button";
			edit.className = "styled-btn";
			edit.textContent = "Edit";
			edit.addEventListener("click", () => editExecutionAccountContext(key, entry));
			actions.appendChild(edit);

			actions.appendChild(document.createTextNode(" "));

			const remove = document.createElement("button");
			remove.type = "button";
			remove.className = "styled-btn";
			remove.textContent = "Delete";
			remove.addEventListener("click", () => deleteExecutionAccountContext(key));
			actions.appendChild(remove);

			tr.appendChild(actions);
			body.appendChild(tr);
		}
	}

	async function loadExecutionAccountContext() {
		executionContextStatus("execution-account-context-status", "Loading account context…");
		try {
			const data = await accountContextRequest("/context");
			renderExecutionAccountContext(data);
			executionContextStatus("execution-account-context-status", "");
		} catch (err) {
			executionContextStatus(
				"execution-account-context-status",
				"Unable to load account context: " + err.message,
				true
			);
		}
	}

	function editExecutionAccountContext(key, entry) {
		const name = document.getElementById("execution-account-context-name");
		const value = document.getElementById("execution-account-context-value");
		const type = document.getElementById("execution-account-context-type");
		const sensitive = document.getElementById("execution-account-context-sensitive");
		const exposure = document.getElementById("execution-account-context-exposure");

		if (name) {
			name.value = key;
			name.readOnly = true;
		}
		if (sensitive) sensitive.checked = entry.sensitive === true;
		if (exposure) exposure.value = entry.exposure || "template";

		if (value) {
			if (entry.sensitive === true || entry.value === "XX-REDACTED-XX") {
				value.value = "";
				value.placeholder = "Enter replacement value";
				if (type) type.value = "string";
			} else {
				const v = entry.value;
				if (type) {
					type.value =
						typeof v === "boolean" ? "boolean" :
						Number.isInteger(v) ? "integer" :
						typeof v === "number" ? "float" :
						v && typeof v === "object" ? "json" : "string";
				}
				value.value =
					type?.value === "json" ? JSON.stringify(v, null, 2) : String(v ?? "");
			}
		}
	}

	function clearExecutionAccountContextEditor() {
		const name = document.getElementById("execution-account-context-name");
		const value = document.getElementById("execution-account-context-value");
		const type = document.getElementById("execution-account-context-type");
		const sensitive = document.getElementById("execution-account-context-sensitive");
		const exposure = document.getElementById("execution-account-context-exposure");

		if (name) {
			name.value = "";
			name.readOnly = false;
		}
		if (value) {
			value.value = "";
			value.placeholder = "https://api.example.com";
		}
		if (type) type.value = "string";
		if (sensitive) sensitive.checked = false;
		if (exposure) exposure.value = "template";
	}

	async function saveExecutionAccountContext() {
		const name = document.getElementById("execution-account-context-name");
		const value = document.getElementById("execution-account-context-value");
		const type = document.getElementById("execution-account-context-type");
		const sensitive = document.getElementById("execution-account-context-sensitive");
		const exposure = document.getElementById("execution-account-context-exposure");
		const rows = document.getElementById("execution-account-context-rows");

		const key = name?.value?.trim();
		if (!key) {
			executionContextStatus("execution-account-context-status", "Account context name is required.", true);
			return;
		}

		let typed;
		try {
			typed = parseTypedContextValue(value?.value || "", type?.value || "string");
		} catch (err) {
			executionContextStatus("execution-account-context-status", err.message, true);
			return;
		}

		const payload = {
			set: {
				[key]: {
					value: typed,
					sensitive: sensitive?.checked === true,
					exposure: exposure?.value || "template"
				}
			},
			delete: []
		};

		const version = Number.parseInt(rows?.dataset?.version || "", 10);
		if (Number.isInteger(version)) payload.expected_version = version;

		try {
			await accountContextRequest("/context", {
				method: "PATCH",
				headers: accountContextHeaders(),
				body: JSON.stringify(payload)
			});
			clearExecutionAccountContextEditor();
			executionContextStatus("execution-account-context-status", `${key} saved.`);
			await loadExecutionAccountContext();
		} catch (err) {
			executionContextStatus("execution-account-context-status", err.message, true);
			if (/409|VERSION_CONFLICT/i.test(err.message)) await loadExecutionAccountContext();
		}
	}

	async function deleteExecutionAccountContext(key) {
		if (!window.confirm(`Delete account context "${key}"?`)) return;
		const rows = document.getElementById("execution-account-context-rows");
		const payload = {set: {}, delete: [key]};
		const version = Number.parseInt(rows?.dataset?.version || "", 10);
		if (Number.isInteger(version)) payload.expected_version = version;

		try {
			await accountContextRequest("/context", {
				method: "PATCH",
				headers: accountContextHeaders(),
				body: JSON.stringify(payload)
			});
			clearExecutionAccountContextEditor();
			await loadExecutionAccountContext();
		} catch (err) {
			executionContextStatus("execution-account-context-status", err.message, true);
		}
	}

	function bindExecutionContextEditor() {
		const button = document.getElementById("edit-execution-context-btn");
		const panel = document.getElementById("execution-context-editor");
		if (!button || !panel || panel.dataset.bound === "true") return;
		panel.dataset.bound = "true";

		loadRuntimeContextDraft();

		button.addEventListener("click", async () => {
			const opening = panel.hidden;
			panel.hidden = !opening;
			button.setAttribute("aria-expanded", opening ? "true" : "false");
			if (opening) await loadExecutionAccountContext();
		});

		document.getElementById("save-runtime-context-btn")?.addEventListener("click", () => {
			try {
				const ctx = applyRuntimeContextDraft();
				executionContextStatus(
					"runtime-context-status",
					`Runtime context applied (${Object.keys(ctx).length} keys).`
				);
			} catch (err) {
				executionContextStatus("runtime-context-status", err.message, true);
			}
		});

		document.getElementById("clear-runtime-context-btn")?.addEventListener("click", () => {
			executionRuntimeContext = {};
			sessionStorage.removeItem(EXECUTION_RUNTIME_CONTEXT_KEY);
			const input = document.getElementById("runtime-context-json");
			if (input) input.value = "{}";
			executionContextStatus("runtime-context-status", "Runtime context cleared.");
		});

		document.getElementById("refresh-account-context-btn")?.addEventListener(
			"click", loadExecutionAccountContext
		);
		document.getElementById("save-account-context-btn")?.addEventListener(
			"click", saveExecutionAccountContext
		);
		document.getElementById("clear-account-context-editor-btn")?.addEventListener(
			"click", clearExecutionAccountContextEditor
		);
	}


	async function submitDamageForm() {
		const inputText = document.getElementById("damageTextArea").value.trim();
		const concurrency = 1;
		const reportElement = addReport();
		const mode = window.TokenManager.getMode();

		try {
			applyRuntimeContextDraft();
		} catch (err) {
			reportElement.innerText = "Invalid runtime context: " + err.message;
			return;
		}
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
		const res = await fetch(`/ecai/market/jobs/${jobId}`);
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

		claimBtn.onclick = () => fetch(`/ecai/market/jobs/${jobId}/claim`, {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({miner_ak: window.myMinerAk})}).then(()=>loadJobIntoModal(jobId));
		submitBtn.onclick = () => {/* open your submit flow */};
		payBtn.onclick = () => fetch(`/ecai/market/jobs/${jobId}/pay`, {method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({admin_ak: window.myAdminAk})}).then(()=>loadJobIntoModal(jobId));
	}

	async function handleCustodialExecution({ inputText, concurrency, headers, reportElement }) {
		const request = {
			method: "POST",
			credentials: "include",
			headers,
			body: JSON.stringify({
				feature: inputText,
				concurrency,
				stream: true,
				context: currentRuntimeContext()
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
			await refreshDashboardBalances();
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
				channel_id: channel.channel.id,
				context: currentRuntimeContext()
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
				signed_tx: signedTx,
				context: currentRuntimeContext()
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
			credentials: "include",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => response.json())
			.then(async data => {
				if (data.access_token) {
					window.TokenManager.on_custodial_login(data.address, data.email, data.access_token);
					window.TokenManager.activate("custodial");

					showConnectStatus("Login Success!", "success");
					showHideLoginButton();
					window.location.reload();
				} else {
					showConnectStatus("Login Failed!", "failed");
				}
			});
		event.preventDefault();
		return;
	}
	async function refreshPostLoginUi() {
		try {
			const r = await fetch("/version", {
				method: "GET",
				credentials: "include",
				headers: { accept: "application/json" }
			});
			const data = await r.json();
			if (data && data.ok === true) {
				renderNodeFooter(data);
				renderNodeWalletModal(data);
			}
			
			await refreshDashboardBalances();
		} catch (err) {
			console.warn("version refresh failed:", err);
		}
	}

	async function submitLogout() {
		const btn = document.getElementById("logoutSubmitBtn");
		const oldText = btn ? btn.textContent : "";

		try {
			if (btn) {
				btn.disabled = true;
				btn.textContent = "Logging out...";
			}

			const token = window.TokenManager?.getToken?.();
			const headers = new Headers();
			headers.set("Content-Type", "application/json");
			headers.set("Accept", "application/json");

			// Optional: send bearer too, though cookie clearing is the important part
			if (token) {
				headers.set("Authorization", "Bearer " + token);
			}

			const resp = await fetch("/accounts/logout", {
				method: "POST",
				credentials: "include",
				headers,
				body: JSON.stringify({})
			});

			let data = null;
			try {
				data = await resp.json();
			} catch (_e) {
				data = null;
			}

			// Always clear local state even if server reply is odd:
			// user intent is logout.
			try {
				window.TokenManager.logout(window.TokenManager.getMode());
			} catch (e) {
				console.warn("TokenManager logout failed:", e);
			}

			try {
				MicroModal.close("logout-modal");
			} catch (_e) {}

			try {
				MicroModal.close("wallet-modal");
			} catch (_e) {}

			try {
				MicroModal.close("node-wallet-modal");
			} catch (_e) {}

			showLoginButton();

			if (!resp.ok) {
				showNotification({
					title: "Logged out locally",
					content: (data && (data.message || data.error)) || "Server logout returned an unexpected response.",
					style: "info"
				});
				return;
			}

			showNotification({
				title: "Logged out",
				content: (data && data.message) || "You have been logged out.",
				style: "success"
			});
		} catch (err) {
			console.error("Logout failed:", err);

			// Still clear client-side auth as a fallback
			try {
				window.TokenManager.logout(window.TokenManager.getMode());
			} catch (_e) {}

			try {
				MicroModal.close("logout-modal");
			} catch (_e) {}

			showLoginButton();

			showNotification({
				title: "Logged out locally",
				content: "Network error while contacting the server, but local session data was cleared.",
				style: "info"
			});
		} finally {
			if (btn) {
				btn.disabled = false;
				btn.textContent = oldText || "Logout";
			}
		}
	}
	function resetPostLogoutUi() {
		const damageAmount = document.getElementById("balanceAmount");
		if (damageAmount) damageAmount.textContent = "";

		const aeBalance = document.getElementById("aeBalance");
		if (aeBalance) aeBalance.textContent = "";

		const balanceAddress = document.getElementById("balanceAddress");
		if (balanceAddress) balanceAddress.textContent = "ak_...";

		const nodeWalletPk = document.getElementById("node-wallet-public-key");
		if (nodeWalletPk) nodeWalletPk.value = "";

		const nodeWalletDamage = document.getElementById("node-wallet-damage-balance");
		if (nodeWalletDamage) nodeWalletDamage.textContent = "0";

		const nodeWalletAe = document.getElementById("node-wallet-ae-balance");
		if (nodeWalletAe) nodeWalletAe.textContent = "0";

		const nodeWalletBtcOnchain = document.getElementById("node-wallet-btc-onchain");
		if (nodeWalletBtcOnchain) nodeWalletBtcOnchain.textContent = "0 sats";

		const nodeWalletBtcChannels = document.getElementById("node-wallet-btc-channels");
		if (nodeWalletBtcChannels) nodeWalletBtcChannels.textContent = "0 sats";

		const nodeWalletBtcTotal = document.getElementById("node-wallet-btc-total");
		if (nodeWalletBtcTotal) nodeWalletBtcTotal.textContent = "0 sats";
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
		// schema:
		// {
		//   ok:true,
		//   public_key,
		//   damage_balance,
		//   ae_balance,
		//   btc_balance {
		//     onchain_sats,
		//     channel_sats,
		//     total_sats,
		//     onchain_msat,
		//     channel_msat,
		//     total_msat
		//   },
		//   version:{...}
		// }
		if (!resp || resp.ok !== true) return;

		const pk = resp.public_key ?? "unknown";
		const damage = Number(resp.damage_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const ae     = Number(resp.ae_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const btcObj = resp.btc_balance;

		const fmtInt = (n) => Number(n ?? 0).toLocaleString(undefined, { maximumFractionDigits: 0 });
		const fmtMsat = (msat) => {
			// show sats with 3 decimals from msat
			const sats = Number(msat ?? 0) / 1000;
			return sats.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 3 });
		};

		let btcLine = "";
		if (btcObj) {
			const onchainSats  = btcObj.onchain_sats  ?? (btcObj.onchain_msat != null ? Math.floor(Number(btcObj.onchain_msat) / 1000) : 0);
			const channelSats  = btcObj.channel_sats  ?? (btcObj.channel_msat != null ? Math.floor(Number(btcObj.channel_msat) / 1000) : 0);
			const totalSats    = btcObj.total_sats    ?? (btcObj.total_msat   != null ? Math.floor(Number(btcObj.total_msat)   / 1000) : (Number(onchainSats) + Number(channelSats)));

			// If you want some extra precision, also show sats from msat as decimals:
			const onchainSatsPrec = btcObj.onchain_msat != null ? fmtMsat(btcObj.onchain_msat) : fmtInt(onchainSats);
			const channelSatsPrec = btcObj.channel_msat != null ? fmtMsat(btcObj.channel_msat) : fmtInt(channelSats);
			const totalSatsPrec   = btcObj.total_msat   != null ? fmtMsat(btcObj.total_msat)   : fmtInt(totalSats);

			btcLine = `BTC — onchain ${onchainSatsPrec} sats | channels ${channelSatsPrec} sats | total ${totalSatsPrec} sats`;
		} else {
			const btcLegacy = fmtInt(resp.btc_balance ?? 0); // sats as provided
			btcLine = `BTC — total ${btcLegacy} sats`;
		}

		const build = resp.version ?? "unknown";

		const shaFull  = build.git_sha ?? "unknown";
		const shaShort = build.git_sha_short ?? (shaFull !== "unknown" ? shaFull.slice(0, 7) : "unknown");
		const time     = build.build_time ?? "unknown";
		const env      = build.build_env ?? "unknown";

		// Copyable public key
		const pkEl = document.getElementById("node-public-key");
		if (pkEl) {
			pkEl.textContent = pk; // copyToClipboard reads textContent
			pkEl.title = "Click 📋 to copy";
		}
		const auth_pkEl = document.getElementById("auth-modal-node-public-key");
		if (auth_pkEl) {
			auth_pkEl.textContent = pk; // copyToClipboard reads textContent
			auth_pkEl.title = "Click 📋 to copy";
		}

		// Balances + version (now with BTC details)
		const balEl = document.getElementById("node-balances");
		if (balEl) {
			balEl.textContent = `Balances — DAMAGE ${damage} | AE ${ae} | ${btcLine}`;
		}

		// Copyable commit hash target (copy full hash using existing helper)
		const shaEl = document.getElementById("node-build-sha");
		if (shaEl) {
			shaEl.textContent = shaFull;
			shaEl.title = `Commit: ${shaFull}`;
		}

		const metaEl = document.getElementById("node-build-meta");
		if (metaEl) {
			metaEl.textContent = `Build: ${env} · ${shaShort} · ${time}`;
		}
	}


	function generateInvoice() {
		var amount = document.getElementById('invoice-amount').value;
		try{
			MicroModal.close('wallet-modal');
		}catch(e){};
		MicroModal.show("invoice-modal");
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
	function getSessionId() {
		let sessionId = sessionStorage.getItem("damage_session_id");

		if (!sessionId) {
			sessionId = Math.random().toString(36).slice(2, 10);
			sessionStorage.setItem("damage_session_id", sessionId);
		}

		return sessionId;
	}
	async function generateLedgerInvoice() {
		const amount = parseInt(document.getElementById("ledger-invoice-amount")?.value || "0", 10);
		const walletAddress = window.TokenManager?.getAddress?.();

		if (!amount || amount <= 0) {
			alert("Enter a valid amount in sats.");
			return;
		}

		if (!walletAddress) {
			alert("Wallet not connected.");
			return;
		}

		const sessionId = getSessionId();
		const ts = Date.now();
		const label = `nwc:${walletAddress}:${sessionId}:${ts}`;

		try {
			MicroModal.show("invoice-modal");

			const resp = await fetch("/invoices/", {
				method: "POST",
				credentials: "include",
				headers: {
					"Content-Type": "application/json",
					"Authorization": "Bearer " + window.TokenManager.getToken()
				},
				body: JSON.stringify({
					amount_sats: amount,
					label
				})
			});

			if (resp.status === 401) {
				MicroModal.show("login-modal");
				return;
			}

			const data = await resp.json();

			if (data && data.status === "ok") {
				document.getElementById("qrcode-lightning").innerText = "";
				document.getElementById("lightning-invoice-input").value =
					"lightning:" + data.invoice.payment_request;

				showLightningQR({
					containerId: "qrcode-lightning",
					paymentRequest: data.invoice.payment_request,
					address: walletAddress
				});
			} else {
				throw new Error(data?.message || "Invoice generation failed");
			}
		} catch (err) {
			console.error("Ledger invoice error:", err);
			alert("Failed to generate invoice: " + err.message);
		}
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
	function renderNodeWalletModal(resp) {
		if (!resp || resp.ok !== true) return;

		const pk = resp.public_key ?? "unknown";
		const damage = Number(resp.damage_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const ae = Number(resp.ae_balance ?? 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
		const btcObj = resp.btc_balance || null;
		const build = resp.version ?? {};

		const fmtInt = (n) => Number(n ?? 0).toLocaleString(undefined, { maximumFractionDigits: 0 });
		const fmtMsat = (msat) => (Number(msat ?? 0) / 1000).toLocaleString(undefined, {
			minimumFractionDigits: 0,
			maximumFractionDigits: 3
		});

		let onchainText = "0 sats";
		let channelText = "0 sats";
		let totalText = "0 sats";
		let summaryText = "BTC wallet data unavailable.";

		if (btcObj) {
			const onchain = btcObj.onchain_msat != null ? fmtMsat(btcObj.onchain_msat) : fmtInt(btcObj.onchain_sats);
			const channel = btcObj.channel_msat != null ? fmtMsat(btcObj.channel_msat) : fmtInt(btcObj.channel_sats);
			const total = btcObj.total_msat != null ? fmtMsat(btcObj.total_msat) : fmtInt(btcObj.total_sats);

			onchainText = `${onchain} sats`;
			channelText = `${channel} sats`;
			totalText = `${total} sats`;
			summaryText = `BTC — onchain ${onchain} sats | channels ${channel} sats | total ${total} sats`;
		}

		const shaFull = build.git_sha ?? "unknown";
		const shaShort = build.git_sha_short ?? (shaFull !== "unknown" ? shaFull.slice(0, 7) : "unknown");
		const time = build.build_time ?? "unknown";
		const env = build.build_env ?? "unknown";

		const pkEl = document.getElementById("node-wallet-public-key");
		if (pkEl) pkEl.value = pk;

		const dmgEl = document.getElementById("node-wallet-damage-balance");
		if (dmgEl) dmgEl.textContent = damage;

		const aeEl = document.getElementById("node-wallet-ae-balance");
		if (aeEl) aeEl.textContent = ae;

		const btcOnchainEl = document.getElementById("node-wallet-btc-onchain");
		if (btcOnchainEl) btcOnchainEl.textContent = onchainText;

		const btcChannelsEl = document.getElementById("node-wallet-btc-channels");
		if (btcChannelsEl) btcChannelsEl.textContent = channelText;

		const btcTotalEl = document.getElementById("node-wallet-btc-total");
		if (btcTotalEl) btcTotalEl.textContent = totalText;

		const buildShaEl = document.getElementById("node-wallet-build-sha");
		if (buildShaEl) buildShaEl.value = shaFull;

		const buildMetaEl = document.getElementById("node-wallet-build-meta");
		if (buildMetaEl) buildMetaEl.textContent = `Build: ${env} · ${shaShort} · ${time}`;

		const summaryEl = document.getElementById("node-liquidity-summary");
		if (summaryEl) summaryEl.textContent = summaryText;
	}

	async function loadNodeLiquidityAddress() {
		const type = document.getElementById("node-liquidity-address-type")?.value || "bech32";
		const input = document.getElementById("node-liquidity-address");
		const raw = document.getElementById("node-liquidity-address-json");
		const qrWrap = document.getElementById("node-liquidity-address-qrcode");

		if (input) input.value = "Loading...";
		if (raw) raw.textContent = "";
		if (qrWrap) qrWrap.innerHTML = "";

		try {
			const r = await fetch(`/api/liquidity/address?type=${encodeURIComponent(type)}`, {
				method: "GET",
				headers: { accept: "application/json" }
			});

			const data = await r.json();

			const address =
						data?.bech32 ||
						data?.p2tr ||
						data?.all?.bech32 ||
						data?.all?.p2tr ||
						"";

			if (input) input.value = address || "No address returned";
			if (raw) raw.textContent = JSON.stringify(data, null, 2);

			if (address && qrWrap) {
				const qr = document.createElement("bitcoin-qr");
				qr.bitcoin = address;
				qr.width = 260;
				qr.height = 260;
				qr.setAttribute("aria-label", "Bitcoin deposit address QR code");
				qr.style.display = "block";
				qr.style.margin = "0.75rem auto 0";
				qrWrap.appendChild(qr);
			}
		} catch (err) {
			if (input) input.value = "Failed to load address";
			if (raw) raw.textContent = String(err);
			if (qrWrap) qrWrap.innerHTML = "";
		}
	}

	async function createNodeLiquidityInvoice() {
		const amount = Number(document.getElementById("node-liquidity-invoice-amount")?.value || 0);
		const description =
					document.getElementById("node-liquidity-invoice-description")?.value || "Inbound liquidity topup";
		const expiry = Number(document.getElementById("node-liquidity-invoice-expiry")?.value || 3600);

		const bolt11El = document.getElementById("node-liquidity-bolt11");
		const metaEl = document.getElementById("node-liquidity-invoice-meta");
		const rawEl = document.getElementById("node-liquidity-invoice-json");
		const qrContainer = document.getElementById("node-liquidity-qrcode");

		if (bolt11El) bolt11El.value = "";
		if (metaEl) metaEl.textContent = "Creating invoice...";
		if (rawEl) rawEl.textContent = "";
		if (qrContainer) qrContainer.innerHTML = "";

		try {
			const r = await fetch("/api/liquidity/invoice", {
				method: "POST",
				headers: {
					"content-type": "application/json",
					"accept": "application/json"
				},
				body: JSON.stringify({
					amount_sats: amount,
					description,
					expiry
				})
			});

			const data = await r.json();
			const bolt11 = data?.bolt11 || data?.payment_request || "";

			if (bolt11El) bolt11El.value = bolt11;

			if (metaEl) {
				if (bolt11) {
					metaEl.textContent =
						`Amount ${data.amount_sats ?? amount} sats | label ${data.label ?? "unknown"} | payment_hash ${data.payment_hash ?? "unknown"}`;

					showLightningQR({
						containerId: "node-liquidity-qrcode",
						paymentRequest: bolt11,
						address: window.TokenManager?.getAddress?.() || "node",
						expirySeconds: Number(data.expires_at)
							? Math.max(1, Number(data.expires_at) - Math.floor(Date.now() / 1000))
							: expiry,
						helpUrl: "/lightning"
					});
				} else {
					metaEl.textContent = data?.message || "Invoice creation failed";
				}
			}

			if (rawEl) rawEl.textContent = JSON.stringify(data, null, 2);
		} catch (err) {
			if (metaEl) metaEl.textContent = `Invoice request failed: ${err}`;
			if (rawEl) rawEl.textContent = String(err);
		}
	}

	document.addEventListener("DOMContentLoaded", function () {
		const refreshBtn = document.getElementById("refresh-node-liquidity-address-btn");
		if (refreshBtn) {
            wrapApiButton(refreshBtn, async (event) => {
                event.preventDefault();
				await loadNodeLiquidityAddress();
			});
		}

		const invoiceForm = document.getElementById("node-liquidity-invoice-form");
		if (invoiceForm) {
			invoiceForm.addEventListener("submit", function (e) {
				e.preventDefault();
				createNodeLiquidityInvoice();
			});
		}
	});

	function copyTextareaClipboard(id) {
		const el = document.getElementById(id);
		if (!el) return;
		navigator.clipboard.writeText(el.value || "").catch(() => {});
	}
	async function refreshNodeWalletModal() {
		const r = await fetch("/version", {
			method: "GET",
			headers: { "accept": "application/json" }
		});
		const resp = await r.json();
		renderNodeFooter(resp);
		renderNodeWalletModal(resp);
	}



	async function openNodeWalletDialog(triggerEl = null) {
		const btn = triggerEl || document.getElementById("open-node-wallet-btn");

		try {
			btn?.classList.add("is-loading");

			await refreshNodeWalletModal();
			//await loadNodeLiquidityAddress();

			if (window.MicroModal) {
				MicroModal.show("node-wallet-modal");
			}
		} catch (err) {
			console.error("Failed to open node wallet dialog:", err);
			showNotification?.({
				title: "Node Wallet",
				content: "Failed to load node wallet data.",
				style: "error"
			});
		} finally {
			btn?.classList.remove("is-loading");
		}
	}
})(window, document, undefined);
