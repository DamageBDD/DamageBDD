hljs.highlightAll();
const toasts = new Toasts();

let bearer_token = null;
function isAuthenticated(){
	
	if (bearer_token == null) {
		bearer_token = getSessionIdCookie();
		return (bearer_token == null)? false: true;
	}else{
		return true;
	}
}
function showHideLoginButton(loginButton){
	if(loginButton==undefined){
		loginButton= document.getElementById("loginBtn");
	}
	if(isAuthenticated()){
		loginButton.style.display = "none";
		updateBalance();
	}else{
		toasts.push({
			title: 'Please login',
			content: 'Click the login button to authenticate.',
			dismissAfter: '3s', // s = seconds
			style: 'verified'

		});
		loginButton.style.display = "block";
	}
}
function onLoad(){
	const loginButton = document.getElementById("loginBtn");
	function handleClick(event) {
		event.preventDefault(); // Prevent the form from submitting (optional)
		showLoginSignupDialog();
	};
	loginButton.addEventListener("click", handleClick);
	showHideLoginButton(loginButton);
	updateBalance();
}
window.onload = onLoad;
function enableForm() {
	const difficulty = document.getElementById("difficulty").value;
	const damageForm = document.getElementById("damageForm");
	const message = document.getElementById("message");
	
	if (difficulty === "sk_baby") {
		damageForm.removeAttribute("disabled");
		message.innerHTML = "";
	} else {
		damageForm.setAttribute("disabled", true);
		message.innerHTML = "For concurrent testing options, please top up funds in your <a href='https://damagebdd.com/register-individual.html'>account</a>. Current rate is 10 requests per Satoshi.";
	}
}

document.getElementById("damageForm").addEventListener("submit", function(event) {
	event.preventDefault();
	submitForm();
});

document.getElementById("damageInput").addEventListener("keydown", function(event) {
	if (event.ctrlKey && event.key === "Enter") {
		event.preventDefault();
		submitForm();
	}
});
function getSessionIdCookie() {
	const name = "sessionid=";
	const cookies = document.cookie.split(';');
	for (let i = 0; i < cookies.length; i++) {
		let cookie = cookies[i].trim();
		if (cookie.indexOf(name) === 0) {
			return cookie.substring(name.length, cookie.length);
		}
	}
	return;
}

function submitForm() {
	
	//if (bearer_token == null) {
	//	bearer_token = showLoginSignupDialog();
	//	if (bearer_token == null) {
	//		event.preventDefault();
	//		return;}
	//}
	const inputText = document.getElementById("damageInput").value;
	const concurrencyText = document.getElementById("difficulty").value;
	const request = {
		method: 'POST',
		credentials: 'include',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			feature: inputText,
			account: "guest",
			host: "damagebdd.com",
			port: 443,
			concurrency: concurrencyText
		})
	};

	fetch("/execute_feature/", request)
		.then(response => {
			if (response.status === 200) {
				return response.json();
			}else	if (response.status === 401) {
				showLoginSignupDialog();
			} else {
				toasts.push({
					title: 'Request Failed',
					content: 'Feature execution failed.',
					style: 'error'
				});
			}
		})
		.then(data => {
			if (data && data.status === "ok") {
				toasts.push({
					title: 'Success',
					content: 'Feature execution successful.',
					style: 'success'
				});
				updateHistoryTable([data]);
			} else {
				toasts.push({
					title: 'Request Failed',
					content: 'Feature execution failed.',
					style: 'error'
				});
			}
		})
		.catch(error => {
			alert("Error: " + error.message);
		});
	event.preventDefault();
	return;
}


function showLoginSignupDialog() {
	// Code to show the login/signup form
	document.getElementById("loginSignupForm").style.display = "block";
}

function submitLoginForm(event) {
	
	const username = document.getElementById("username").value;
	const password = document.getElementById("password").value;
	//const confirmPassword = document.getElementById("confirmPassword").value;
	
	// Check if username is a valid email
	if (!validateEmail(username)) {
		alert("Please enter a valid email address for username");
		return;
	}
	
	// Check if password is a strong password
	//if (!validatePassword(password)) {
	//	alert("Please enter a valid strong password");
	//	return;
	//}
	
	// Check if confirmPassword matches password
	//if (password !== confirmPassword) {
	//	alert("Password and Confirm Password do not match");
	//	return;
	//}
	
	// Perform signup request
	const signupData = {
		grant_type: "password",
		scope: "basic",
		username: username,
		password: password

	};
	
	const headers = new Headers();
	headers.append("Content-Type", "application/json");
	
	fetch("/auth/", {
		method: "POST",
		headers: headers,
		body: JSON.stringify(signupData)
	})
		.then(response => {
			if (response.ok) {
				return response.json();
			} else {
				// Signup failed
				toasts.push({
					title: 'Login Failed',
					content: 'Authentication Un-Successful.',
					style: 'error'
				});
			}
		})
		.then(data => {
			if(data){
				bearer_token = data.access_token;
				// Signup successful, send email instructions here
				document.getElementById("loginSignupForm").style.display = "none";
				toasts.push({
					title: 'Login Success',
					content: 'Authentication Successful.',
					style: 'success'
				});
				showHideLoginButton();
			}else{
				toasts.push({
					title: 'Login Failed',
					content: 'Authentication Un-Successful.',
					style: 'error'
				});
			}})
		.catch(error => {
			console.error("Error:", error);
		});
	event.preventDefault();
	return;
}

// Helper function to validate email address
function validateEmail(email) {
	const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
	return regex.test(email);
}

// Helper function to validate strong password
function validatePassword(password) {
	// Password validation logic here
	// Replace this with your own password validation logic
	
	// For example, minimum 8 characters with at least one uppercase letter, 
	// one lowercase letter, one digit, and one special character
	
	const regex = /^(?=.*\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]).{8,}$/;
	return regex.test(password);
}
function updateHistoryTable(historyArray) {
  // Get the div element with id "history"
  var historyDiv = document.getElementById("history");

  // Create a table element
  var table = document.createElement("table");
  
  // Create table headers
  var headerRow = document.createElement("tr");
  var headers = ["Feature Hash", "Report Hash", "Start Time", "Execution Time", "End Time", "Account"];
  headers.forEach(function(header) {
    var th = document.createElement("th");
    th.textContent = header;
    headerRow.appendChild(th);
  });
  table.appendChild(headerRow);
  
  // Create table rows for each object in the history array
  historyArray.forEach(function(obj) {
    var row = document.createElement("tr");

    // Create cells for each property in the object
    var cells = ["feature_hash", "report_hash", "start_time", "execution_time", "end_time", "account"].map(function(prop) {
      var td = document.createElement("td");
      td.textContent = obj[prop];
      return td;
    });

    // Append the cells to the row
    cells.forEach(function(cell) {
      row.appendChild(cell);
    });

    // Append the row to the table
    table.appendChild(row);
  });

  // Clear the existing content of the history div
  historyDiv.innerHTML = "";

  // Append the table to the history div
  historyDiv.appendChild(table);
}

function updateBalance() {
  var xhr = new XMLHttpRequest();
  xhr.open('GET', '/accounts/balance', true);
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.withCredentials = true; // Enable sending cookies in the request
  
  xhr.onload = function() {
    if (xhr.status === 200) {
      var balanceData = JSON.parse(xhr.responseText);
      var balanceDiv = document.getElementById('balanceDiv'); // Replace 'balanceDiv' with the ID of your <div>
      
      // Update the contents of the div with the received data
      balanceDiv.innerText = 'Balance: ' + balanceData.btc_refund_balance;
    }
  };
  
  xhr.onerror = function() {
    console.error('Error making the request.');
  };
  
  xhr.send();
}
