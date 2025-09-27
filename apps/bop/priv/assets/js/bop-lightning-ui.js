// bop-lightning-ui.js
// Professional Lightning Payment UI for BopBDD
// Accessible, modular, and easy to integrate

var current_invoice ;
var qrCanvas;
function invoicePolling() {

    // Fetch current invoice status from your backend
    console.log("poling");
}


export function showLightningQR({ containerId, paymentRequest, expirySeconds = 600, helpUrl, title, instructions }) {
    const container = document.getElementById(containerId);
    if (!container) {
        console.error(`Container with id '${containerId}' not found.`);
        return;
    }
  container.style.display = "block";
    // Clear existing QR section if present
    const oldQR = document.getElementById("lnqr");
    if (oldQR) oldQR.remove();

    // Create QR section
    const qrSection = document.createElement("section");
    qrSection.id = "lnqr";
    qrSection.setAttribute("role", "region");
    qrSection.setAttribute("aria-label", title);
    qrSection.style.marginTop = "1em";
    qrSection.style.textAlign = "center";

    // Title
    const titleH2 = document.createElement("h2");
    titleH2.textContent = "⚡ " + title;
    qrSection.appendChild(titleH2);


    // Generate QR after small delay
    qrCanvas = document.createElement("bitcoin-qr");
    qrCanvas.lightning = paymentRequest;
    current_invoice = paymentRequest;
    qrCanvas.width = 400;
    qrCanvas.height = 400;
    qrCanvas.style.display = "block";
    qrCanvas.style.marginLeft = "auto";
    qrCanvas.style.marginRight = "auto";
    qrCanvas.setAttribute("aria-hidden", "false");
    qrCanvas.image = "/assets/img/bop-logo.png";
    qrCanvas.imageEmbedded = true;
    qrCanvas.isPolling = false;
    //qrCanvas.imageSize = 100;
    qrSection.appendChild(qrCanvas);
    qrCanvas.callback = invoicePolling;
    qrCanvas.pollInterval = 2000;
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
        navigator.clipboard.writeText(paymentRequest).then(() => {
            copyButton.textContent = "✅ Copied!";
            setTimeout(() => copyButton.textContent = "📋 Copy Invoice", 2000);
        });
    };
    qrSection.appendChild(copyButton);

    // Payment Instructions
    const instructionsP = document.createElement("p");
    instructionsP.style.marginTop = "1em";
    instructionsP.style.fontSize = "1em";
    instructionsP.innerHTML = instructions;
    qrSection.appendChild(instructionsP);

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
export function hideLightningQR(containerId) {
  const container = document.getElementById(containerId);
  if (container) {
    container.innerHTML = ""; // Clear out the QR display
    container.style.display = "none"; // Optionally hide the element
  }
}
export function renderConfirmation({ message, onConfirm, onCancel }) {
  // Remove existing confirmation if any
  const existing = document.getElementById("confirmation-dialog");
  if (existing) existing.remove();

  const dialog = document.createElement("div");
  dialog.id = "confirmation-dialog";
  dialog.style.position = "fixed";
  dialog.style.top = "30%";
  dialog.style.left = "50%";
  dialog.style.transform = "translate(-50%, -50%)";
  dialog.style.background = "#fff";
  dialog.style.border = "2px solid #444";
  dialog.style.borderRadius = "10px";
  dialog.style.boxShadow = "0 0 20px rgba(0,0,0,0.2)";
  dialog.style.padding = "20px";
  dialog.style.zIndex = "9999";
  dialog.style.textAlign = "center";
  dialog.style.maxWidth = "400px";

  const msg = document.createElement("p");
  msg.innerText = message;
  msg.style.marginBottom = "20px";

  const yesBtn = document.createElement("button");
  yesBtn.innerText = "✅ Yes";
  yesBtn.style.margin = "0 10px";
  yesBtn.onclick = () => {
    dialog.remove();
    onConfirm();
  };

  const noBtn = document.createElement("button");
  noBtn.innerText = "❌ No";
  noBtn.onclick = () => {
    dialog.remove();
    if (onCancel) onCancel();
  };

  dialog.appendChild(msg);
  dialog.appendChild(yesBtn);
  dialog.appendChild(noBtn);
  document.body.appendChild(dialog);
}

export function showGreenTick(containerId) {
  const tick = document.createElement("div");
  tick.innerHTML = "✅";
  tick.id = "green-tick";

  const container = document.getElementById(containerId) || document.body;
  container.innerHTML = ""; // Clear previous content like QR
  container.appendChild(tick);
}
/*
  Usage Example:

  import { showLightningQR } from './bop-lightning-ui.js';

  showLightningQR({
  containerId: 'bop-wallet',
  paymentRequest: 'lnbc1...',
  address: 'ak_...',
  expirySeconds: 60,
  helpUrl: 'https://bitcoinparty.com.au/help/lightning-payments'
  });
*/

