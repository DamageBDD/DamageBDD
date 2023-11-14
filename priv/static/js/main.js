hljs.highlightAll();

function enableForm() {
    const difficulty = document.getElementById("difficulty").value;
    const damageForm = document.getElementById("damageForm");
    const message = document.getElementById("message");
    
    if (difficulty === "sk_baby") {
        damageForm.removeAttribute("disabled");
        message.innerHTML = "";
    } else {
        damageForm.setAttribute("disabled", true);
        message.innerHTML = "For concurrent testing options, please top up funds in your <a href='/accounts/topup'>account</a>. Current rate is 10 requests per Satoshi.";
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
function submitForm() {
    const inputText = document.getElementById("damageInput").value;
    const concurrencyText = document.getElementById("difficulty").value;
    const request = {
        method: 'POST',
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
            } else {
                throw new Error('Request failed with status ' + response.status);
            }
        })
        .then(data => {
            if (data.status === "ok") {
                alert("Success! The feature was executed.");
            } else {
                throw new Error('Response status was not "ok"');
            }
        })
        .catch(error => {
            alert("Error: " + error.message);
        });
}
