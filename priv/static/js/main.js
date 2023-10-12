import * as sk from "./sidekick.js";


var logged_in = false;
var address;
var recipient = "damagebdd.chain";

function connect(logger) {
    return sk.connect(
        'ske-connect-1',
        {name: 'sidekick examples',
            version: 1},
        sk.TIMEOUT_DEF_CONNECT_MS,
        "failed to connect to wallet",
        logger
    );
}

function sign_tx(logger, tx) {
    let sign_params = {
        tx: tx,
        returnSigned: true,
        networkId: "ae_uat"
    };
    return sk.tx_sign_noprop('sk-tx-sign-1', sign_params, sk.TIMEOUT_DEF_TX_SIGN_NOPROP_MS, 'sign transaction timed out', logger);
}

async function fund(amount) {
    if (!logged_in) return;

    let logger = sk.cl();

    // spend https://github.com/aeternity/protocol/blob/master/serializations.md#spend-transaction
    let tx = {
        sender : address
        , recipient : recipient
        , amount : amount
        , fee : 0
        , ttl : 0
        , nonce : 0
        , payload : "message"
    };

    // sign tx
    let signed_result = await sign_tx(logger, tx);
    if (!signed_result.ok) return;

    let signed_tx = signed_result.result.signedTransaction;

    // post tx
    let post_req_body = {
        poll_id: poll_id,
        option_id: option_id,
        address: address,
        signed_tx: signed_tx
    };
    let post_resp = await post_json("/api/postVoteTX", post_req_body);

    if (post_resp.ok) setButtonsPending();
}
async function login() {
    let logger = sk.cl();

    await connect(logger);
    let wallet_info = await sk.address(
        'ske-address-1',
        {type: 'subscribe',
            value: 'connected'},
        1000,
        "failed to address to wallet",
        logger
    );
    if (!wallet_info.ok){
        console.log("wallet info:"+ wallet_info);
        if(wallet_info.error.code == 420){
            document.getElementById("login_status").innerHTML = "Please install superhero wallet to connect <a href='https://chrome.google.com/webstore/detail/superhero/mnhmmkepfddpifjkamaligfeemcbhdne'></a> " ;
        }else{
        document.getElementById("login_status").innerHTML = "Error connecting wallet " + wallet_info.error.message;
        }
        return;
    }

    let maybe_address = Object.keys(wallet_info.result.address.current)[0];
    if (maybe_address === undefined) return;

    address = maybe_address;
    logged_in = true;
    document.getElementById("login_status").innerHTML = "Viewing as " + address;
    document.getElementById("login_button").innerText = "Change account";

    /*let status_response = await fetch("/api/poll/" + getID() + "/user/" + address);
    if (!status_response.ok) return;
    let vote_status = await status_response.json();
    let current = vote_status.current_vote;
    let pending = vote_status.pending_vote;

    if (pending == "none") {
        let rows = document.querySelector("table").tBodies[0].rows;
        for (let row of rows) {
            let button = row.cells[2].children[0];
            let option_id = Number(row.id.slice(6)); // Lord forgive me.
            if (row.id == "option" + current) {
                button.innerText = "Revoke";
                button.onclick = revoke;
            } else {
                button.innerText = "Vote";
                button.onclick = makeVoteClosure(option_id);
            }
            }
    } else {
        setButtonsPending();
    }*/
}

function setButtonsPending() {
    let rows = document.querySelector("table").tBodies[0].rows;
    for (let row of rows) {
        let button = row.cells[2].children[0];
        button.innerText = "Pending...";
        button.onclick = null;
    }
}

async function post_json(url, body) {
    let response = await fetch(
        url,
        {
            method: "post",
            headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(body)
        }
    );

    if (response.ok) {
        let body = await response.json();
        return {ok: true, body: body};
    } else {
        return response;
    }
}

async function vote(option_id) {
    if (!logged_in) return;

    let logger = sk.cl();

    let poll_id = Number(getID());

    // form tx

    let tx_req_body = {
        poll_id: poll_id,
        option_id: option_id,
        address: address
    };
    let tx_resp = await post_json("/api/formVoteTX", tx_req_body);
    if (!tx_resp.ok) return;

    let tx = tx_resp.body.tx;

    // sign tx
    let signed_result = await sign_tx(logger, tx);
    if (!signed_result.ok) return;

    let signed_tx = signed_result.result.signedTransaction;

    // post tx
    let post_req_body = {
        poll_id: poll_id,
        option_id: option_id,
        address: address,
        signed_tx: signed_tx
    };
    let post_resp = await post_json("/api/postVoteTX", post_req_body);

    if (post_resp.ok) setButtonsPending();
}

async function revoke() {
    if (!logged_in) return;

    let logger = sk.cl();

    let poll_id = Number(getID());

    // form tx

    let tx_req_body = {
        poll_id: poll_id,
        address: address
    };
    let tx_resp = await post_json("/api/formRevokeVoteTX", tx_req_body);
    if (!tx_resp.ok) return;

    let tx = tx_resp.body.tx;

    // sign tx
    let signed_result = await sign_tx(logger, tx);
    if (!signed_result.ok) return;

    let signed_tx = signed_result.result.signedTransaction;

    // post tx
    let post_req_body = {
        poll_id: poll_id,
        address: address,
        signed_tx: signed_tx
    };
    let post_resp = await post_json("/api/postRevokeVoteTX", post_req_body);

    if (post_resp.ok) setButtonsPending();
}

function makeVoteClosure(option_id) {
    function it() {
        return vote(option_id);
    }
    return it;
}

function generateTable(data) {
    let table = document.querySelector("table");

    for (let element of data) {
        let row = table.insertRow();
        row.id = "option" + element.id;

        row.insertCell()
            .appendChild(document.createTextNode(element.name));
        row.insertCell()
            .appendChild(document.createTextNode(element.score));

        let button = document.createElement('button');
        button.innerText = "Vote";
        button.onclick = makeVoteClosure(element.id);
        row.insertCell()
            .appendChild(button);
    }

    // Generate the head AFTER the body, because of course.
    let thead = table.createTHead();
    let row = thead.insertRow();

    let th1 = document.createElement("th");
    th1.appendChild(document.createTextNode("Option"));
    row.appendChild(th1);

    let th2 = document.createElement("th");
    th2.appendChild(document.createTextNode("Score"));
    row.appendChild(th2);
}

async function windowOnLoad() {
    let login_button = document.getElementById("login_button");
    login_button.innerText = "Connect Wallet";
    login_button.onclick = login;
    let fund_button = document.getElementById("fund_button");
    fund_button.innerText = "Fund Me";
    fund_button.onclick = fund;

    /*
    let id = getID();
    document.getElementById("title").innerHTML = "Poll " + id;

    let response = await fetch("/api/poll/" + id);
    if (response.ok) {
        let object = await response.json();

        document.getElementById("title").innerHTML = object.title;
        document.getElementById("description").innerHTML = object.description;

        generateTable(object.options);
    } else if (response.status == 404) {
        document.getElementById("description").innerHTML = "Not found.";
    } else if (response.status == 500) {
        document.getElementById("description").innerHTML = "Server error.";
        }*/
}

function getID() {
    let text = document.getElementById("text");
    let path = window.location.pathname.split("/");
    let id_str = path[path.length - 1];
    return id_str; // We could convert this to a number, but it only ever gets used to build HTTP request URLs, so there is no need.
}

window.onload = windowOnLoad;
