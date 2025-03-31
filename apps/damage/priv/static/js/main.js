(function(window, document, undefined) {

	// code that should be taken care of right away
	window.dataLayer = window.dataLayer || [];

	//https://codeshack.io/elegant-toast-notifications-javascript/
	const toasts = new Toasts({
		offsetX: 20, // 20px
		offsetY: 20, // 20px
		gap: 20, // The gap size in pixels between toasts
		width: 300, // 300px
		timing: 'ease', // See list of available CSS transition timings
		duration: '.5s', // Transition duration
		dimOld: true, // Dim old notifications while the newest notification stays highlighted
		position: 'top-center' // top-left | top-center | top-right | bottom-left | bottom-center | bottom-right
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
						toasts.push({
							title: 'Success',
							content: data.message,
							style: 'success'
						});
					})
					.catch((error) => {
						toasts.push({
							title: 'Request Failed',
							content: error.message,
							style: 'error'
						});
					});
			});
		}
		hljs.highlightAll();

		document.getElementById("login-modal").addEventListener("keydown", function(event){
			if (event.keyCode === 13) {
				submitLoginForm(event);
			}
		});
		document.getElementById("signup-modal").addEventListener("keydown", function(event){
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
		document.getElementById("signupSubmitBtn").addEventListener("click", submitSignUpForm);
		document.getElementById("signupDialogBtn").addEventListener("click", (event) => {
			event.preventDefault();
			MicroModal.close("login-modal");
			MicroModal.show("signup-modal");
		});
		document.getElementById("loginDialogBtn").addEventListener("click", (event) => {
			event.preventDefault();
			MicroModal.close("signup-modal");
			MicroModal.show("login-modal");
		});
		document.getElementById("logoutSubmitBtn").addEventListener("click", (event) => {
			localStorage.removeItem("access_token");
			localStorage.removeItem("address");
			MicroModal.close('logout-modal');
			showHideLoginButton();

		});
		document.getElementById("generate-invoice-btn").addEventListener("click", (event) => {
			event.preventDefault();
			generateInvoice();
		});
		const logoutButton = document.getElementById("logoutBtn");
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

		showHideLoginButton();
		MicroModal.init({
			onShow: modal => console.info(`${modal.id} is shown`), // [1]
		});
		var tabs =Tabby('[data-tabs]');
		document.addEventListener('tabby', function (event) {
			var tab = event.target;
			var content = event.detail.content;
			if (event.detail.tab.id === 'tabby-toggle_history-tab'){
				updateHistoryTable();
			}else if (event.detail.tab.id === 'tabby-toggle_schedules-tab'){
				updateSchedulesTable();
			}
		}, false);
		var tabs =Tabby('[data-token-tabs]');
		document.addEventListener('tabby', function (event) {
			var tab = event.target;
			var content = event.detail.content;
			console.log("switch tab");
			console.log(event);
		}, false);
		document.getElementById("damageForm").addEventListener("submit", async function(event) {
			event.preventDefault();
			await submitDamageForm();
		});

		document.getElementById("damageTextArea").addEventListener("keydown", async function(event) {
			if (event.ctrlKey && event.key === "Enter") {
				event.preventDefault();
				await submitDamageForm();
			}
		});
		var address = localStorage.getItem("address");
		if(address){
			document.getElementById("damage-address").value = address;
					generateAddressQrcode();
		}
	});


	function removeBackground(){
		const background = document.getElementById("background");
		background.innerHTML = "";
	}
	function addBackround(){ 
		let vw = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0)
		let vh = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 0)

		try{
			VANTA.GLOBE({
				el: "#background",
				mouseControls: true,
				touchControls: true,
				gyroControls: false,
				minHeight: vh,
				minWidth: vw,
				scale: 1.00,
				size: 1.50,
				scaleMobile: 1.00,
				color: 0x2b04,
				color2: 0x2d6e45,
				backgroundColor: 0xffffff
			});
		} catch(e) {
			console.log(e);
			console.log("Failed to initialize vanta.");
		}
	}

	function isAuthenticated() {
			return (localStorage.access_token == null) ? false : true;
	}

	function showHideLoginButton(){
		const content = document.getElementById("content");
		const background = document.getElementById("background");
		loginButton = document.getElementById("loginBtn");
		logoutButton = document.getElementById("logoutBtn");
		if (isAuthenticated()) {
			loginButton.style.display = "none";
			content.style.display = "block";
			removeBackground();
			logoutButton.style.display = "inline-block";
			updateBalance();
			try{
				MicroModal.close('login-modal');
			}catch(e){}
		} else {
			logoutButton.style.display = "none";
			loginButton.style.display = "inline-block";
			content.style.display = "none";
			background.style.display = "block";
			addBackround();
			MicroModal.show('login-modal');
		}
	}

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

		const ulEl = document.getElementById('runreports-ul');
		ulEl.role='tablist';
		const liEl = document.createElement('li');
		const aEl = document.createElement('a');
		aEl.href=`#run-${runDateTime}`;
	    aEl.innerHTML = label;
		liEl.role = "presentation";
		liEl.appendChild(aEl);
		ulEl.appendChild(liEl);


		const runreportsTabPanels = document.getElementById('runreports');
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
	async function submitDamageForm() {
		const inputText = document.getElementById("damageTextArea").value;
		const concurrencyText = document.getElementById("difficulty").value;
		const headers = new Headers();
		headers.append("Content-Type", "application/json");
		headers.append("Authorization", "Bearer "+ localStorage.access_token);
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
		const reportElement = addReport();
		const response = await fetch("/execute_feature/", request);

		if (response.status === 200 /*&& response.headers.get('content-type') ===
									  'application/octet-stream'*/) {
			reportElement.innerHTML ="";

			await response.body
				.pipeThrough(new TextDecoderStream())
			//.pipeThrough(upperCaseStream())
				.pipeTo(appendToDOMStream(reportElement));

		} else if (response.status === 401) {
			MicroModal.show("login-modal");
		}
		if (reportElement.hasAttribute('data-highlighted')) { // check if the attribute exists
			reportElement.removeAttribute('data-highlighted'); // remove the specified attribute
		}
		hljs.highlightAll();
	}


	function submitSignUpForm(event) {
		const username = document.getElementById("signup-username").value;
		if (!validateEmail(username)) {
			Toasts.push({title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
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
					toasts.push({
						title: 'Success - Confirmation Required',
						content: data.message,
						style: 'success'
					});
				} else {
					toasts.push({
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
	function submitLoginForm(event) {
		const username = document.getElementById("login-username").value;
		const password = document.getElementById("password").value;

		if (!validateEmail(username)) {
			Toasts.push({title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
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
					localStorage.setItem("access_token", data.access_token);
					localStorage.setItem("address", data.address);
					generateAddressQrcode();
					toasts.push({
						title: 'Login Success',
						content: 'Authentication Successful.',
						style: 'success'
					});
					showHideLoginButton();
				} else {
					toasts.push({
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
	function submitForgotPasswordForm(event) {
		const username = document.getElementById("username").value;

		if (!validateEmail(username)) {
			Toasts.push({title:"Invalid email", content: "Please enter a valid email address for username",  style:"error"});
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
		headers.append("Authorization", "Bearer "+ localStorage.access_token);

		fetch("/accounts/reset_password/", {
			method: "POST",
			headers: headers,
			body: JSON.stringify(signupData)
		})
			.then(response => {
				return response.json();
			})
			.then(data => {
				if (data.access_token) {
					localStorage.setItem("access_token" , data.access_token);
					toasts.push({
						title: 'Reset Password Success',
						content: 'Authentication Successful.',
						style: 'success'
					});
					showHideLoginButton();
				} else {
					toasts.push({
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


	function updateBalance() {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', '/accounts/balance', true);
		xhr.setRequestHeader('Content-Type', 'application/json');
		xhr.setRequestHeader('Authorization', 'Bearer ' + localStorage.access_token);
		xhr.withCredentials = true;

		xhr.onload = function() {
			if (xhr.status === 200) {
				var balanceData = JSON.parse(xhr.responseText);
				var balanceDiv = document.getElementById('balanceDiv');
				balanceDiv.innerText = 'Damage Tokens: ' + Math.round(balanceData.amount/100000000) + ' 🧪';
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
				amount: parseInt(amount)
			})
		};

		fetch("/accounts/invoices/", request)
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
					var qrcode = new QRCode(
						document.getElementById("qrcode-lightning"),
						"lightning:" + data.invoice.payment_request
					);
					document.getElementById("lightning-invoice-input").value = "lightning:" + data.invoice.payment_request
				} else {
					console.error("Error Invoice fetching failed: ", data);
					toasts.push({
						title: 'Request Failed',
						content: data.message,
						style: 'error'
					});
				}
			})
			.catch(error => {
				console.error("Error Invoice fetching failed: ", error.message);
				toasts.push({
					title: 'Request Failed',
					content: error.message,
					style: 'error'
				});
			});
	}
	function generateAddressQrcode(){
		document.getElementById("qrcode-damage").innerText = "";
		var qrcode = new QRCode(
			document.getElementById("qrcode-damage"),
			localStorage.getItem("address")
		);
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
