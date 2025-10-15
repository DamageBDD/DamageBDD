import * as wallet from "/static/js/wallet.js";
import { initDamageBDDPicker } from '/static/js/featurePicker.js';
import { showLightningQR } from '/static/js/damage-lightning-ui.js';



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
		text: localStorage.getItem("address"),
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
		document.getElementById("loginBtn").addEventListener("click",(event) => {
			event.preventDefault();
			MicroModal.show("login-modal");
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
			MicroModal.show("logout-modal");
			event.preventDefault();
		});
		const balanceDiv = document.getElementById("balanceDiv");
		document.getElementById("addScheduleBtn").addEventListener("click",(event) => {
			console.log("add schedule");
			event.preventDefault();
		});
		document.getElementById("historylink").addEventListener("click",(event) => {
			console.log("historytab");
			var tabs =Tabby('[data-tabs]');
			tabs.toggle('history');
			event.preventDefault();
		});
		document.getElementById("node-unlock-password").addEventListener("keydown", async function(event) {
			if (event.ctrlKey && event.key === "Enter") {
				await nodeUnlock();
				event.preventDefault();
			}});
		document.getElementById("node-unlock-password-submit-btn").addEventListener("click", async (event) => {
			event.preventDefault();
			await nodeUnlock();
		});

		showHideLoginButton();
		MicroModal.init({
			onShow: modal => {
				console.info(`${modal.id} is shown`);

				if (typeof window.initInstallForm === 'function') window.initInstallForm();

				if(modal.id == 'invoice-modal'){
					var address = localStorage.getItem("address");
					generateDamageQR(address);
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
			{ cid: 'Qmb4MG3F6W8P7Xe64snfpmfgTCURoq6ZjSMRLvFxW1W9DP', label: 'Echo Test' },
			'QmYv9TtWt38aXY4AGiqM4H4myF8UCp6TE8SWtDVK7PoA4i',
			'QmcN6mqiVCdp5ZGarWVXwKT3UPwbFgzRoGgjaNcP9vXB1a',
			'QmWnbqr8j7G7Wh9ZW7XvAvagSGEg9mThBVnhzicSNxsW9U',
			'QmS1RRvJ2Y6SyvDUZNELsvBSefov4SisUQG97xH2vybxqu',
			'QmdvmxqusyjGDPDXni2nMAAthBxrXUuoJmR2whsRmVo8CL',
			'QmcLedvbu4jXNcyJSDXNKPrhmK6iM4Ff2SwVkXi2AX3prP',
			'QmeTPPWN5c5ZBq6mteX6k6inZhVTm9kf27KkTPVbsYPFGb',
			'QmXRbJWPcq8DXniHcJzkuhwGuRvzf86kZcwkvUbx9nsDcQ',
			'QmWy67JWeujue9jLhnPJe9xHUSjjrSB41KtSGepR2K77R8',
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
		if(window.TokenManager.getMode() == "extension") return true;
		return (localStorage.access_token == null || localStorage.access_token == "") ? false : true;
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
		const loginButton = document.getElementById("loginBtn");
		const logoutButton = document.getElementById("logoutBtn");
			logoutButton.style.display = "none";

			loginButton.style.display = "inline-block";
			content.style.display = "none";
			background.style.display = "block";
			MicroModal.show('login-modal');
	}
	function showHideLoginButton(){
		const content = document.getElementById("content");
		const background = document.getElementById("background");
		const loginButton = document.getElementById("loginBtn");
		const logoutButton = document.getElementById("logoutBtn");
		if (isAuthenticated()) {
			loginButton.style.display = "none";
			content.style.display = "block";
			logoutButton.style.display = "inline-block";
			try{
				MicroModal.close('login-modal');
			}catch(e){}
		} else {
			logoutButton.style.display = "none";

			loginButton.style.display = "inline-block";
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
			  .replace(/\bfail:([^\s]+)/g, '<span class="gherkin-fail">fail:$1</span>');

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
		const inputText = document.getElementById("damageTextArea").value;
		const concurrencyText = 1;

		const headers = new Headers();
		headers.append("Content-Type", "application/json");

		headers.append("Authorization", "Bearer " + TokenManager.getToken());


		const reportElement = addReport();
		const mode = window.TokenManager.getMode();
		if(mode == "custodial"){
			const username = localStorage.getItem("email_auth");
			const request = {
				method: 'POST',
				credentials: 'include',
				headers: headers,
				body: JSON.stringify({
					feature: inputText,
					concurrency: concurrencyText,
					stream: true
				})
			};
			const response = await fetch("/execute_feature/", request);

			if (response.status === 200) {
				await streamResponseToDOM(response, reportElement);
			} else if (response.status === 401) {
				MicroModal.show("login-modal");
			} else {
				const errText = await response.text();
				reportElement.innerText = "Error: " + errText;
			}
		}
		else {
			const address = window.TokenManager.getAddress();
			const request = {
				method: 'POST',
				credentials: 'include',
				headers: headers,
				body: JSON.stringify({
					feature: inputText,
					address: address,
					concurrency: concurrencyText
				})
			};
			const response = await fetch("/tx/", request);
			// Optional: handle server asking for a signature
			const data = await response.json();
			const message = data.tx;

			await window.connectWalletUnified();
			const signature = await wallet.signTransactionSmart(
				message,
				"ae_mainnet",
				window.location.origin,
				window.location.origin
			);
			if(signature.ok) {

				const signedRequest = {
					method: 'POST',
					credentials: 'include',
					headers: headers,
					body: JSON.stringify({
						feature: inputText,
						address: address,
						concurrency: concurrencyText,
						signed_tx: signature.result.signedTransaction
					})
				};

				const signedResponse = await fetch("/tx/", signedRequest);

				if (signedResponse.status === 200) {
					await streamResponseToDOM(signedResponse, reportElement);
				} else {
					const errText = await signedResponse.text();
					reportElement.innerText = "Error after signing: " + errText;
				}
			} else {
				reportElement.innerText = "Failed to sign: " + signature.error.message;
			}
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
		headers.append("Authorization", "Bearer "+ localStorage.access_token);

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
						+ '\n node balance: ' + versionData.node_balance
						+ '\n node ae balance: ' + versionData.node_ae_balance;
					console.log("version: ");
					console.log( versionData);
					var nodePublicKeyDom= document.getElementById('node-public-key');
					nodePublicKeyDom.innerText = 'node public key: ' + versionData.public_key;
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
					   'Authorization': 'Bearer ' + localStorage.access_token
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
									 address: localStorage.getItem("address"),
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
