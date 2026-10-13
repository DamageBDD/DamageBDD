import { showLightningQR, hideLightningQR, renderConfirmation, showGreenTick } from '/assets/js/bop-lightning-ui.js';
const protocol = window.location.protocol === "https:" ? "wss://" : "ws://";
const wsUrl = protocol + window.location.host + "/bop/ws/";
var btcToAud;
class BopLightningWS {
	constructor() {
		this.serverUrl = wsUrl;
		this.socket = null;
		this.invoiceCallback = null;
		this.paymentCallback = null;
		this.listInvoicesCallback = null;
	}
	connect(retryCount = 0) {
		const maxRetries = 10;
		const retryDelay = Math.min(1000 * 2 ** retryCount, 30000); // max 30s

		this.socket = new WebSocket(this.serverUrl);

		this.socket.addEventListener('open', () => {
			console.log('[Bop] WebSocket connected.');
			retryCount = 0; // reset on successful connect
			this.requestPrice();
			this.listInvoices();
		});

		this.socket.addEventListener('message', (event) => {
			try {
				const data = JSON.parse(event.data);
				if (data.type === 'invoice' && this.invoiceCallback) {
					this.invoiceCallback(data.payment_request);
				} else if (data.type === 'price' && this.priceCallback) {
					this.prices = data;
					this.priceCallback(data);
				} else if (data.type === 'list_invoices' && this.listInvoicesCallback) {
					this.listInvoicesCallback(data);
				} else if (data.type === 'paid' && this.paymentCallback) {
					this.paymentCallback(data.payment_hash);
					this.listInvoices();
				} else if (data.type === 'ping') {
					this.socket.send(JSON.stringify({ action: 'pong' }));
				} else if (data.type === 'pong') {
					console.debug('[Bop] got pong');
				} else {
					console.warn('[Bop] Unknown message:', data);
				}
			} catch (err) {
				console.error('[Bop] Failed to parse message:', err);
			}
		});

		this.socket.addEventListener('close', () => {
			console.warn('[Bop] WebSocket disconnected. Retrying...');
			if (retryCount < maxRetries) {
				setTimeout(() => this.connect(retryCount + 1), retryDelay);
			} else {
				console.error('[Bop] Max reconnect attempts reached.');
			}
		});

		this.socket.addEventListener('error', (err) => {
			console.error('[Bop] WebSocket error:', err);
			this.socket.close(); // trigger close handler
		});
	}

	listInvoices(){
		this.socket.send(JSON.stringify({ action: 'list_invoices' }));
	}

	requestPrice() {
		if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
			console.error('[Bop] Socket not connected.');
			return;
		}
		this.socket.send(JSON.stringify({ action: 'get_price'}));
	}
	requestInvoice(amountSats) {
		if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
			console.error('[Bop] Socket not connected.');
			return;
		}
		this.socket.send(JSON.stringify({ action: 'request_invoice', amount: amountSats }));
	}

	onPrice(callback) {
		this.priceCallback = callback;
	}
	onInvoice(callback) {
		this.invoiceCallback = callback;
	}
	onListInvoices(callback) {
		this.listInvoicesCallback = callback;
	}

	onPayment(callback) {
		this.paymentCallback = callback;
	}

	close() {
		if (this.socket) {
			this.socket.close();
		}
	}
}



// --- UI + Interaction ---
document.addEventListener("DOMContentLoaded", () => {
	const output = document.getElementById('output');

	const bop = new BopLightningWS();
	bop.connect();

	bop.onInvoice((invoice) => {
		output.textContent = `Invoice received:\n${invoice}`;
        showLightningQR({containerId : "stack-invoice",
                         paymentRequest:  invoice,
						 title: "Stack the cause with Lightning Wallet",
						 instructions:  `
    🛡️ Scan the QR code with your Lightning wallet to contribute.<br>`
						});
	});

	bop.onPayment((paymentHash) => {
		output.textContent += `\n✅ Paid! Hash: ${paymentHash}`;
		showGreenTick("stack-invoice");


	});
	bop.onListInvoices((data) => {
		const tbody = document.querySelector("#registration-stack-recents tbody");
		tbody.innerHTML = ""; // Clear loading row

		let totalMsats = 0;
		let totalAUDm = 0;


		data.invoices.forEach(inv => {
			const row = document.createElement("tr");

			const hash = inv.payment_hash;
			const sats = Math.floor(inv.msats / 1000);
			const aud = (inv.audm / 1000).toFixed(2);
			const time = new Date(inv.block_time).toLocaleString();
			const explorerURL = `https://mempool.space/lightning/invoice/${hash}`;

			row.innerHTML = `
  <td>${hash.slice(0, 8)}…</td>
  <td>${time}</td>
  <td>${sats} sats</td>
  <td>$${aud}</td>
  <td>
    <button class="qr-btn" data-hash="${hash}">🔍</button>
    <div id="qr-${hash.slice(0, 8)}" class="qr-container" style="display:none; margin-top:4px;"></div>
  </td>
`;

			tbody.appendChild(row);

			totalMsats += inv.msats;
			totalAUDm += inv.audm;
		});

		const goal_total_funds_sats = satsFromAud( data.goal_total_funds, bop.pricesbtc);
		document.getElementById("fund_goal_sats").textContent = `$${(goal_total_funds_sats).toFixed(2)}`;
		document.getElementById("fund_goal_aud").textContent = `$${(data.goal_total_funds).toFixed(2)}`;
		document.getElementById("total_funded_sats").textContent = Math.floor(totalMsats/ 1000).toLocaleString();
		document.getElementById("total_funded_aud").textContent = `$${(totalAUDm / 1000).toFixed(2)}`;

		document.querySelectorAll('.qr-btn').forEach(btn => {
			btn.addEventListener('click', (e) => {
				const hash = e.currentTarget.dataset.hash;
				const explorerURL = `https://mempool.space/lightning/invoice/${hash}`;
				window.open(explorerURL, '_blank');
			});
		});
		
	});


    const AUD_AMOUNTS = [5, 10, 25, 50, 100];
    const buttonsContainer = document.getElementById("preset-buttons");
    const btcValueSpan = document.getElementById("btc-value");
    const audInput = document.getElementById("aud-amount");
    const stackBtn = document.getElementById("stack-btn");

    const complianceWarning = document.createElement("p");
    complianceWarning.id = "compliance-warning";
    complianceWarning.style.color = "#d00";
    complianceWarning.style.fontWeight = "bold";
    audInput.parentElement.appendChild(complianceWarning);



    function satsFromAud(aud, btcToAud) {
		const btcAmount = aud / btcToAud;
		return Math.round(btcAmount * 100_000_000);
    }

    function updateBtcEquivalent(audAmount, btcToAud) {
		const btcAmount = audAmount / btcToAud;
		btcValueSpan.textContent = btcAmount.toFixed(8);
    }

    function setInputAndUpdate(aud, btcToAud) {
		audInput.value = aud;
		updateBtcEquivalent(aud, btcToAud);
    }

	async function stackBtnOnClick() {
		const aud = parseFloat(audInput.value);
		if (isNaN(aud) || aud <= 0) {
			alert("Please enter a valid AUD amount.");
			return;
		}

		if (aud > 100) {
			alert("Donation does not meet AEC compliance requirements. Anonymous amount should be less than $100 AUD");
			return;
		}

		console.log(`Proceeding to send sats for ${aud} AUD`);
		const btcAmount = satsFromAud(aud, bop.prices.btc);
        bop.requestInvoice(btcAmount); // 1000 sats
    };
    stackBtn.onclick = stackBtnOnClick;

    audInput.addEventListener('input', async (e) => {
		const value = parseFloat(e.target.value);
		if (!isNaN(value)) {
			updateBtcEquivalent(value, bop.prices.btc);
		}
    });

    async function generateButtons(btcToAud) {
		buttonsContainer.innerHTML = "";
		AUD_AMOUNTS.forEach(aud => {
			const sats = satsFromAud(aud, btcToAud);
			const button = document.createElement('button');
			button.type = "button";
			button.innerText = `$${aud} AUD ≈ ${sats.toLocaleString()} sats`;
			button.onclick = () => setInputAndUpdate(aud, btcToAud);
			buttonsContainer.appendChild(button);
		});
	}

	bop.onPrice((prices) => {
		generateButtons(prices.btc);
	});
});
