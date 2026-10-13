const relays = ['wss://relay.damus.io'];
const pubkeys = [
	'npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc',  // replace with real pubkeys
];

function decodeNpub(npub) {
    return window.NostrTools.nip19.decode(npub).data;
}

async function fetchProfiles(pubkeys) {
    const subId = Math.random().toString(36).slice(2);
    const req = ["REQ", subId, { kinds: [0], authors: pubkeys.map(decodeNpub) }];
    const socket = new WebSocket(relays[0]);
    const tbody = document.querySelector("#candidates tbody");

    socket.onopen = () => socket.send(JSON.stringify(req));
    socket.onmessage = e => {
        const [type, , event] = JSON.parse(e.data);
        if (type === "EVENT") {
			const pk = event.pubkey;
			const profile = JSON.parse(event.content);
			const display = profile.display_name || profile.name || pk.slice(0, 12);
			const ln = profile.lud16 || profile.lud06 || "—";
			const row = document.createElement("tr");

			row.innerHTML = `
            <td>${display}</td>
            <td>${ln}</td>
            <td><a href="/fundraise/${pk}" target="_blank">Fund</a></td>
          `;
			tbody.appendChild(row);
        }
    };
}

document.addEventListener("DOMContentLoaded", () => {
fetchProfiles(pubkeys);
});
