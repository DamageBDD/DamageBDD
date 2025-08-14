import * as sk from "./sidekick.js";
var logged_in = false;
var address ;
// Superhero Wallet Integration Utilities
function connect(logger) {
    return sk.connect(

        'ske-connect-1',
        {name: 'staging.damagebdd.com',
         version: 1},
        sk.TIMEOUT_DEF_CONNECT_MS,
        "failed to connect to wallet",
        logger
    );
}

function encodeParams(params) {
    return Object.entries(params)
        .map(([key, val]) => `${encodeURIComponent(key)}=${encodeURIComponent(val)}`)
        .join("&");
}

export function connectWallet(successURL, cancelURL) {
    const params = {
        "x-success": successURL + "?address={address}&networkId={networkId}",
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/address?${encodeParams(params)}`;
}

export function signMessage(message, successURL, cancelURL, encoding = "hex") {
    const params = {
        message,
        encoding,
        "x-success": `${successURL}?signature={signature}&address={address}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-message?${encodeParams(params)}`;
}

export function signTransaction(transaction, networkId, successURL, cancelURL, broadcast = true) {
    const params = {
        transaction,
        networkId,
        broadcast: broadcast.toString(),
        "x-success": `${successURL}?transaction-hash={transaction-hash}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-transaction?${encodeParams(params)}`;
}

export function signJWT(payload, successURL, cancelURL) {
    const params = {
        payload,
        "x-success": `${successURL}?signed-payload={signed-payload}&address={address}`,
        "x-cancel": cancelURL
    };
    window.location.href = `https://wallet.superhero.com/sign-jwt?${encodeParams(params)}`;
}



// Usage:
// connectWallet('https://yourapp.com/success', 'https://yourapp.com/cancel')
// signMessage('hello', 'https://yourapp.com/msg-ok', 'https://yourapp.com/msg-fail')
function isMobileDevice() {
    return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
}
export async function connectWalletSmart(successURL, cancelURL) {
    if (isMobileDevice()) {
        // Use Superhero mobile wallet deep link
        connectWallet(successURL, cancelURL);
    } else {
        // Use Sidekick browser wallet connection
        await connectButton();
    }
}
export function signMessageSmart(message, successURL, cancelURL) {
    if (isMobileDevice()) {
        signMessage(message, successURL, cancelURL);
    } else {
    //const sigData = await sk.msg_sign(msg); // Sidekick signs message
    let logger = sk.cl();
    return sk.msg_sign('sk-msg-sign-1', address, message, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
   // if(!sigData.ok){
   //     await connectWalletSmart1();
   //     sigData = await sk.msg_sign('sk-msg-sign-1', address, msg, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
   // }
        //sk.signMessage(message).then(({ signature, address }) => {
        //    window.location.href = `${successURL}?signature=${signature}&address=${address}`;
        //}).catch(() => {
        //    window.location.href = cancelURL;
        //});
    }
}
export function signTransactionSmart(message, successURL, cancelURL) {
	if (isMobileDevice()) {
		signTransaction(message, successURL, cancelURL);
	} else {
		//const sigData = await sk.msg_sign(msg); // Sidekick signs message
		let logger = sk.cl();
		return sk.tx_sign_noprop('sk-tx-sign-noprop-1', message, sk.TIMEOUT_DEF_MSG_SIGN_MS, 'message signing took too long', logger);
	}
}
export function checkWalletSignature(required = true) {
    const params = new URLSearchParams(window.location.search);
    const signature = params.get("signature");
    if (signature) {
        console.log("✅ Wallet signature found:", signature);
        return signature;
    }
    return null;
}
export function checkWalletAddress(required = true) {
    const params = new URLSearchParams(window.location.search);
    const user_address = params.get("address");
    const signature = params.get("signature");

    if (user_address) {
        console.log("✅ Wallet address found:", user_address);
        return user_address;
    }
    return null;
}
export function getAddress(){
    if(address)
        return address;
    else checkWalletAddress();
}

export async function fetchWalletBalance(publicKey) {
    const url = "https://mainnet.aeternity.io/mdw/v3/aex9/ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk/balances/" + publicKey;
    try {
        const response = await fetch(url);
        const data = await response.json();
        const balanceDiv = document.getElementById('wallet-balance');
        balanceDiv.innerHTML = ''; // Clear loading text

        if (!data.amount) {
            balanceDiv.innerHTML = '<blockquote>⚡ Your DAMAGE balance is too low to execute tests. Balance: 0. Please generate an lightning invoice to purchase DAMAGE tokens. Or transfer tokens to your wallet from an exchange.</blockquote>'; 
            const amountSelector = document.getElementById("amount-selector");
            amountSelector.style.display = 'block';

            return;
        }

        const ul = document.createElement('ul');
        const li = document.createElement('li');
        li.innerHTML = `
          Account: <code><strong>${data.account}</strong></code> <br>
          Amount: <code>${data.amount.toFixed(8)  }</Code> 
        `;
        ul.appendChild(li);
        balanceDiv.appendChild(ul);
        balanceDiv.style.display = 'block';
        const amountSelector = document.getElementById("amount-selector");
        amountSelector.style.display = 'none';
    } catch (error) {
        console.error('Error fetching balances:', error);
        document.getElementById('wallet-balance').innerHTML = "<blockquote>⚡ Error fetching DAMAGE balance.</blockquote>";
    }
}

async function connectButton() {
    let logger = sk.cl();

    await connect(logger);
    let wallet_info = await sk.address(
        'ske-address-1',
        {type: 'subscribe',
         value: 'connected'},
        10000,
        "failed to address to wallet",
        logger
    );
    if (!wallet_info.ok){
        console.log("wallet info:", wallet_info);
        if(wallet_info.error.code == 420){
            document.getElementById("connect-status").innerHTML = "Please install <a href='https://chrome.google.com/webstore/detail/superhero/mnhmmkepfddpifjkamaligfeemcbhdne'>superhero wallet</a> to connect" ;
        }else{
            document.getElementById("connect-status").innerHTML = "Error connecting wallet " + wallet_info.error.message;
        }
        return;
    }

    let maybe_address = Object.keys(wallet_info.result.address.current)[0];
    if (maybe_address === undefined) return;

    address = maybe_address;
    logged_in = true;
	document.getElementById("connect-button").disabled = true;
	document.getElementById("connect-button").style.display = 'none';
    //fetchWalletBalance(address);
}
