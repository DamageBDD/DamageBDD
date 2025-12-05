import * as wallet from "/static/js/wallet.js";
import { initDamageBDDPicker } from '/static/js/featurePicker.js';
import { showLightningQR } from '/static/js/damage-lightning-ui.js';
import { ensureChannel } from '/static/js/ensureChannel.js';

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

		document.getElementById("signup-modal").addEventListener("keydown", function(event){
			if (event.keyCode === 13) {
				submitSignUpForm(event);
			}
		});
		document.getElementById("signupForm").addEventListener("submit", (event) => {
			event.preventDefault();
		});
		document.getElementById("signup-username").addEventListener("keydown", (event) => {
			if (event.key === "Enter") {
				submitSignUpForm(event);
			}
		});
		document.getElementById("signupSubmitBtn").addEventListener("click", submitSignUpForm);
		document.getElementById("signupDialogBtn").addEventListener("click", (event) => {
			MicroModal.close("login-modal");
			MicroModal.show("signup-modal");
			event.preventDefault();
		});
		document.getElementById("loginResetPasswdBtn").addEventListener("click", submitForgotPasswordForm);
		document.getElementById("loginDialogBtn").addEventListener("click", (event) => {
			event.preventDefault();
			MicroModal.close("signup-modal");
			MicroModal.show("login-modal");
		});
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
		document.getElementById("historylink").addEventListener("click",(event) => {
			event.preventDefault();
			console.log("historytab");
			var tabs =Tabby('[data-tabs]');
			tabs.toggle('history');
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
			if (event.detail.tab.id === 'tabby-toggle_history-tab'){
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
		fetchVersion();


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
				alert("✅ Node password set successfully!");

				// Close modal if present
				if (window.MicroModal) {
					MicroModal.close("node-set-password-modal");
				}

				passwordInput.value = "";
				confirmInput.value  = "";

			} else {
				alert(`❌ Failed to set password: ${data.message || "Unknown error"}`);
			}

		} catch (err) {
			console.error("Set password error:", err);
			alert("⚠️ Error setting password. Check console for details.");
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
				alert("✅ Node unlocked successfully!");
				if (window.MicroModal) {
					MicroModal.close("node-unlock-modal");
				}
				passwordInput.value = "";
			} else {
				alert(`❌ Unlock failed: ${data.message || "Unknown error"}`);
			}
		} catch (err) {
			console.error("Unlock error:", err);
			alert("⚠️ Error unlocking node. Check console for details.");
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

	/**
	 * Build JSON headers with optional Bearer token.
	 */
	function buildJsonAuthHeaders(token) {
		const headers = new Headers();
		headers.set("Content-Type", "application/json");
		if (token) {
			headers.set("Authorization", "Bearer " + token);
		}
		return headers;
	}

	/**
	 * Try to parse an error response as JSON, falling back to plain text.
	 */
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

	/**
	 * Custodial / wallet-account path: POST to /execute_feature/
	 * and stream response.
	 */
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

	/**
	 * Non-custodial / on-chain path:
	 *  1. ensureChannel(...)
	 *  2. POST /tx to prepare unsigned tx
	 *  3. connect wallet and sign
	 *  4. POST /tx with signed_tx and stream result
	 */
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
	function fetchVersion() {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', '/version', true);
		xhr.setRequestHeader('Content-Type', 'application/json');

		xhr.onload = function() {
			var versionDom= document.getElementById('node-version');
			if (xhr.status === 200) {
				var versionData = JSON.parse(xhr.responseText);
				if(versionData.ok == true){
					versionDom.innerText = 'node version: ' + versionData.version
						+ '\n node $DAMAGE balance: ' + versionData.damage_balance
						+ '\n node $AE balance: ' + versionData.ae_balance;
					console.log("version: ");
					console.log( versionData);
					var nodePublicKeyDom= document.getElementById('node-public-key');
					nodePublicKeyDom.innerText = 'node public key: ' + versionData.public_key;
					window.nodePublicKey = versionData.public_key;
					document.getElementById("node-public-key").addEventListener("click",(event) => {
						event.preventDefault();
						MicroModal.show("node-public-key-modal");
					});
					document.getElementById("node-qrcode").innerText = "";
					var qrcode = new QRCode(
						document.getElementById("node-qrcode"),
						versionData.public_key
					);
				}else{
					versionDom.innerText = 'node not initialized: ' + versionData.error;
					MicroModal.close("login-modal");
					if(versionData.error == "decrypt_keypair"){
						MicroModal.show("node-unlock-modal");
					}else if (versionData.error == "keypair_not_initialized"){
						MicroModal.show("node-set-password-modal");
					}
				}
			}
		};
		
		xhr.onerror = function() {
			console.error('Error making the request.');
		};

		xhr.send();
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
