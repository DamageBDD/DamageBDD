// damage-lightning-ui.js
// Professional Lightning Payment UI for DamageBDD
// Accessible, modular, and easy to integrate

var qrCanvas;

export function showDamageQR({ containerId, address,  expirySeconds = 600, helpUrl, logo }) {
    const container = document.getElementById(containerId);
    if (!container) {
        console.error(`Container with id '${containerId}' not found.`);
        return;
    }

    // Clear existing QR section if present
    const oldQR = document.getElementById("lnqr");
    if (oldQR) oldQR.remove();

    // Create QR section
    const qrSection = document.createElement("section");
    qrSection.id = "lnqr";
    qrSection.setAttribute("role", "region");
    qrSection.setAttribute("aria-label", "Lightning Payment Request");
    qrSection.style.marginTop = "1em";
    qrSection.style.textAlign = "center";

    // Title
    const title = document.createElement("h2");
    title.textContent = "⚡ Lightning Payment Request";
    qrSection.appendChild(title);


    // Generate QR after small delay
    qrCanvas = document.createElement("bitcoin-qr");
    qrCanvas.lightning = address;
    qrCanvas.width = 400;
    qrCanvas.height = 400;
    qrCanvas.style.display = "block";
    qrCanvas.style.marginLeft = "auto";
    qrCanvas.style.marginRight = "auto";
    qrCanvas.setAttribute("aria-hidden", "false");

	const configuredLogo = document.body?.dataset.logoImage;
	qrCanvas.image =
		logo || configuredLogo || "/static/img/logo.png";

    qrCanvas.imageEmbedded = true;
    qrSection.appendChild(qrCanvas);

    // Wait for shadow DOM to be populated, then style
    setTimeout(() => {
        const link = qrCanvas.shadowRoot?.getElementById("bitcoin-qr-container");
        if (link) {
            link.style.margin = "0 auto";
            link.style.display = "block";
            link.style.textAlign = "center"; // Just in case
        }
    }, 300);

    // Copy Invoice Button
    const copyButton = document.createElement("button");
    copyButton.textContent = "📋 Copy Invoice";
    copyButton.style.marginTop = "1em";
    copyButton.style.padding = "0.5em 1em";
    copyButton.style.fontSize = "1em";
    copyButton.style.borderRadius = "0.5em";
    copyButton.style.border = "none";
    copyButton.style.cursor = "pointer";
    copyButton.style.background = "#333";
    copyButton.style.color = "white";
    copyButton.style.display = "none";
    copyButton.setAttribute("aria-label", "Copy Lightning Invoice");
    copyButton.onclick = () => {
        navigator.clipboard.writeText(address).then(() => {
            copyButton.textContent = "✅ Copied!";
            setTimeout(() => copyButton.textContent = "📋 Copy Invoice", 2000);
        });
    };
    qrSection.appendChild(copyButton);

    // Payment Instructions
    const instructions = document.createElement("p");
    instructions.style.marginTop = "1em";
    instructions.style.fontSize = "1em";
    instructions.innerHTML = `
    🛡️ Scan the QR code with your Lightning wallet or paste the invoice manually.<br>
    💸 After payment, your Damage Tokens will arrive within seconds.
  `;
    qrSection.appendChild(instructions);

    // Help Link
    if (helpUrl) {
        const helpLink = document.createElement("a");
        helpLink.href = helpUrl;
        helpLink.target = "_blank";
        helpLink.rel = "noopener noreferrer";
        helpLink.style.display = "block";
        helpLink.style.marginTop = "1em";
        helpLink.style.fontSize = "0.9em";
        helpLink.style.color = "#88f";
        helpLink.textContent = "❓ Need Help? View Payment Instructions";
        qrSection.appendChild(helpLink);
    }

    // Countdown Timer
    const timer = document.createElement("p");
    timer.style.marginTop = "1em";
    timer.style.fontSize = "1em";
    timer.style.fontWeight = "bold";
    qrSection.appendChild(timer);

    container.appendChild(qrSection);


    // Start Countdown Timer
    let secondsLeft = expirySeconds;
    timer.textContent = `⏳ Expires in ${secondsLeft} seconds`;
    const countdown = setInterval(() => {
        secondsLeft--;
        if (secondsLeft > 0) {
            timer.textContent = `⏳ Expires in ${secondsLeft} seconds`;
        } else {
            clearInterval(countdown);
            timer.textContent = "⚠️ Invoice expired. Please generate a new one.";
            qrCanvas.style.opacity = "0.5";
            copyButton.disabled = true;
            copyButton.style.background = "#777";
        }
    }, 1000);
}

/*
  Usage Example:

  import { showLightningQR } from './damage-lightning-ui.js';

  showLightningQR({
  containerId: 'damage-wallet',
  paymentRequest: 'lnbc1...',
  address: 'ak_...',
  expirySeconds: 60,
  helpUrl: 'https://damagebdd.com/help/lightning-payments'
  });
*/

