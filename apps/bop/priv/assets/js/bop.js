export class LightningAuth {
  constructor(wsUrl, options = {}) {
    this.wsUrl = wsUrl;
    this.socket = null;
    this.maxTries = options.maxTries || 12;
    this.pollInterval = options.pollInterval || 5000;

    // Hooks for events
    this.onStatusUpdate = options.onStatusUpdate || (() => {});
    this.onInvoice = options.onInvoice || (() => {});
    this.onVerified = options.onVerified || (() => {});
    this.onError = options.onError || ((err) => console.error("Error:", err));
  }

  connect() {
    this.socket = new WebSocket(this.wsUrl);
    this.socket.onopen = () => {
      this.onStatusUpdate({ status: "connected" });
      this.requestInvoice();
    };
    this.socket.onmessage = this._handleMessage.bind(this);
    this.socket.onerror = (err) => this.onError(err);
    this.socket.onclose = () => this.onStatusUpdate({ status: "disconnected" });
  }

  _handleMessage(event) {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch (e) {
      return this.onError("Invalid JSON from server");
    }

    if (msg.status === "pending" && msg.invoice) {
      this.onInvoice(msg.invoice);
    } else if (msg.status === "authenticated") {
      this.onVerified();
    } else if (msg.error) {
      this.onError(msg.error);
    } else {
      this.onStatusUpdate(msg);
    }
  }

  requestInvoice() {
    const msg = {
      action: "auth_ln"
    };
    this.socket.send(JSON.stringify(msg));
    this.onStatusUpdate({ status: "invoice_requested" });
  }

  checkPayment() {
    const msg = {
      action: "check_payment"
    };
    this.socket.send(JSON.stringify(msg));
  }

}

// Example usage:

// const auth = new LightningAuth("wss://your-node/ws",  {
//   onInvoice: (invoice) => renderInvoiceQR(invoice),
//   onVerified: () => alert("Login successful!"),
//   onError: (err) => console.error("Lightning error:", err),
//   onStatusUpdate: (status) => console.log("Status:", status)
// });
// auth.connect();
