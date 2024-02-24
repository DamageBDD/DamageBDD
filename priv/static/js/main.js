const toasts = new Toasts();
let bearer_token = null;

function isAuthenticated() {
    if (bearer_token == null) {
        bearer_token = getSessionIdCookie();
        return (bearer_token == null) ? false : true;
    } else {
        return true;
    }
}

function showHideLoginButton(loginButton, logoutButton, settingsButton) {
    if (loginButton == undefined) {
        loginButton = document.getElementById("loginBtn");
    }
    if (logoutButton == undefined) {
        logoutButton = document.getElementById("logoutBtn");
    }
    if (settingsButton == undefined) {
        settingsButton = document.getElementById("settingsBtn");
    }
    if (isAuthenticated()) {
        loginButton.style.display = "none";
        logoutButton.style.display = "inline-block";
        settingsButton.style.display = "inline-block";
        updateBalance();
		generateInvoice();
		try{
			MicroModal.close('login-modal');
		}catch(e){console.log(e)}
    } else {
        logoutButton.style.display = "none";
        settingsButton.style.display = "none";
        loginButton.style.display = "inline-block";
		MicroModal.show('login-modal');
    }
}

function onLoad() {
    hljs.highlightAll();
    const loginButton = document.getElementById("loginBtn");
    const loginSubmitButton = document.getElementById("loginSubmitBtn");
    const logoutSubmitButton = document.getElementById("logoutSubmitBtn");
    const logoutButton = document.getElementById("logoutBtn");
    const balanceDiv = document.getElementById("balanceDiv");

    function handleLoginClick(event) {
        event.preventDefault();
		MicroModal.show("login-modal");
    };
    function handleLogoutClick(event) {
		bearer_token = null;
		clearSessionIdCookie();
		showHideLoginButton(loginButton, logoutButton);
		
    };
    //function handleBalanceClick(event) {
    //    event.preventDefault();
    //    showBalanceDialog();
    //};
    loginSubmitButton.addEventListener("click", submitLoginForm);
    logoutSubmitButton.addEventListener("click", handleLogoutClick);
	//balanceDiv.addEventListener("click", handleBalanceClick);
    showHideLoginButton(loginButton, logoutButton);
    updateHistoryTable();
	MicroModal.init({
	  onShow: modal => console.info(`${modal.id} is shown`), // [1]
	});
	var tabs =Tabby('[data-tabs]');

}

window.onload = onLoad;


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

function clearSessionIdCookie() {
    document.cookie = "sessionid=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;";
}
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
            } else if (response.status === 401) {
                MicroModal.show("login-modal");
            }
        })
        .then(data => {
            if (data && data.status === "ok") {
                toasts.push({
                    title: 'Success',
                    content: 'Feature execution successful.',
                    style: 'success'
                });
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


function submitLoginForm(event) {
    const username = document.getElementById("username").value;
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

    fetch("/auth/", {
        method: "POST",
        headers: headers,
        body: JSON.stringify(signupData)
    })
        .then(response => {
            if (response.ok) {
                return response.json();
            } else {
                toasts.push({
                    title: 'Login Failed',
                    content: 'Authentication Un-Successful.',
                    style: 'error'
                });
            }
        })
        .then(data => {
            if (data) {
                bearer_token = data.access_token;
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

function validateEmail(email) {
    const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return regex.test(email);
}

function updateHistoryTable() {
    const request = {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            since: "1day"
        })
    };

    fetch("/reports/", request)
        .then(response => {
            if (response.status === 200) {
                return response.json();
            } else if (response.status === 401) {
                MicroModal.show('login-modal');
            } else {
                console.error("Error reports fetching failed: ", data);
            }
        })
        .then(data => {
            if (data && data.status === "ok") {
                var historyDiv = document.getElementById("history");
                var table = document.createElement("table");
                var headerRow = document.createElement("tr");
                var headers = ["Feature Hash", "Report Hash", "Start Time", "Execution Time", "End Time", "Account"];
                headers.forEach(function(header) {
                    var th = document.createElement("th");
                    th.textContent = header;
                    headerRow.appendChild(th);
                });
                table.appendChild(headerRow);

                historyArray.forEach(function(obj) {
                    var row = document.createElement("tr");
                    var cells = ["feature_hash", "report_hash", "start_time", "execution_time", "end_time", "account"].map(function(prop) {
                        var td = document.createElement("td");
                        td.textContent = obj[prop];
                        return td;
                    });

                    cells.forEach(function(cell) {
                        row.appendChild(cell);
                    });

                    table.appendChild(row);
                });

                historyDiv.innerHTML = "";
                historyDiv.appendChild(table);
            } else {}
        })
        .catch(error => {
            console.error("Error reports fetching failed: ", error.message);
        });
}

function updateBalance() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/accounts/balance', true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.withCredentials = true;

    xhr.onload = function() {
        if (xhr.status === 200) {
            var balanceData = JSON.parse(xhr.responseText);
            var balanceDiv = document.getElementById('balanceDiv');
            balanceDiv.innerText = 'Balance: ' + balanceData.balance + '🧪';
        }
    };
    
    xhr.onerror = function() {
        console.error('Error making the request.');
    };

    xhr.send();
}

function generateInvoice() {
    const request = {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            amount: 4000
        })
    };

    fetch("/accounts/invoices/", request)
        .then(response => {
            if (response.status <= 200) {
                return response.json();
            } else if (response.status === 401) {
                MicroModal.show("login-modal");
            }
        })
        .then(data => {
            if (data && data.status === "ok") {
                var qrcode = new QRCode(document.getElementById("qrcode"), "lightning:" + data.message.payment_request);
            } else {
                console.error("Error Invoice fetching failed: ", data);
            }
        })
        .catch(error => {
            console.error("Error Invoice fetching failed: ", error.message);
        });
}

function generateToken() {
    var token = "Generated Token: ABC123";
    document.getElementById("generatedToken").innerText = token;
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
