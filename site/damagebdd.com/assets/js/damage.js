import * as wallet from "/assets/js/wallet.js";
import { showLightningQR } from '/assets/js/damage-lightning-ui.js';
import { initStepPicker } from '/assets/js/thumb-bdd-picker.js';
var recipient = "damagebdd.chain";

async function connectWalletSmart1(){
    await wallet.connectWalletSmart(
        "https://staging.damagebdd.com/use",
        "https://staging.damagebdd.com/use"
    );
	onConnect(wallet.getAddress());
}
async function getInvoice(msg, signature) {
    const res = await fetch("/tx/", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            message: msg,
            signature: signature,
            pubkey: wallet.getAddress()
        })
    });

    const data = await res.json();
    if (!data.payment_request) throw new Error("No invoice returned");
    return data;
}
async function buyDamage() {
    let logger = sk.cl();
    const amount = parseInt(document.getElementById("damage-amount").value);

    if (isNaN(amount) || amount <= 0) {
        alert("Enter a valid amount");
        return;
    }

    const msg = JSON.stringify({amount, date:`${Date.now()}`});
    let sigData = await signMessageSmart(msg,
        "https://staging.damagebdd.com/use",
        "https://staging.damagebdd.com/use"
                                  );

    console.log('signed message:', sigData);
    const data = await getInvoice(msg, sigData.result.signature);


    // Optionally auto-pay
    // const tx = await sk.pay(data.payment_request);

    // Show QR
    showLightningQR({containerId : "invoice",
                     paymentRequest:  data.payment_request,
                     address: wallet.getAddress()});
	const amountSelector = document.getElementById("amount-selector");
    amountSelector.style.display = 'none';
}

function onConnect() {
		const connectStatus = document.getElementById("connect-status");
		const amountSelector = document.getElementById("amount-selector");
		const connectBtn = document.getElementById('connect-button');
	if(connectBtn) {
		connectBtn.textContent = 'Connect Wallet';
		connectBtn.onclick = connectWalletSmart1;
	const address = wallet.getAddress();
		if(address){
			connectBtn.disabled = true;
			connectBtn.style.display = 'none';
			connectStatus.innerHTML = "Connected !";
			const signature = checkWalletSignature();
			if(signature){
			}else{
			}
		}else{
			connectBtn.disabled = false;
			amountSelector.style.display = 'none';
			connectStatus.innerHTML = "Disconnected !";
			//connectWalletSmart1();
		}
	}
}



function adjustAmount(delta) {
    const input = document.getElementById("damage-amount");
    const value = parseInt(input.value) || 0;
    input.value = Math.max(1, value + delta);
}

function setAmount(amount) {
    document.getElementById("damage-amount").value = amount;
}



document.addEventListener("DOMContentLoaded", () => {
	onConnect();


	if(document.getElementById("btn-plus")){
		document.getElementById("btn-plus").addEventListener("click", () => adjustAmount(100));

		document.querySelectorAll(".preset-amount").forEach(button => {
			button.addEventListener("click", () => {
				const amount = parseInt(button.dataset.amount);
				setAmount(amount);
			});
		});


		const buyBtn = document.getElementById('generate-invoice');
		buyBtn.onclick = buyDamage;

		initStepPicker({
			containerId: 'step-picker',
			featureContainerId: 'feature-steps',
			stepsDefinition: {
				'Given I am using server "{{Server}}"': 'Given I am using server "{{Server}}"',
				'When I make a GET request to "{{Path}}"': 'When I make a GET request to "{{Path}}"',
				'Then the response must contain text "{{Text}}"': 'Then the response must contain text "{{Text}}"'
			}
		});
	}
});
