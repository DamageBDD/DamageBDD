export function initNostrScroll({ containerId, pubkey, limit = 50, hashtags = null, excludeContent = [] }) {
	const relay = new WebSocket("wss://relay.damus.io");
	const contentEl = document.getElementById(containerId);
	const container = findScrollableAncestor(contentEl);

	let since = Date.now();
	let loading = false;

	// Normalize and separate include/exclude sets
	const allTags = Array.isArray(hashtags)
		  ? hashtags
		  : hashtags ? [hashtags] : [];

	const includeTags = allTags
		  .filter(h => !h.startsWith("-"))
		  .map(h => h.toLowerCase().trim());

	const excludeTags = allTags
		  .filter(h => h.startsWith("-"))
		  .map(h => h.slice(1).toLowerCase().trim()); // remove "-" prefix

	const contentExclusions = (Array.isArray(excludeContent) ? excludeContent : [])
		  .map(x => x.toLowerCase().trim());



	function parseMarkdown(text) {
		// basic markdown and image embedding
		text = text.replace(/</g, "&lt;").replace(/>/g, "&gt;");
		text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
		text = text.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
		text = text.replace(/\*([^*]+)\*/g, '<i>$1</i>');
		text = text.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank">$1</a>');
		text = text.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank">$1</a>');
		text = text.replace(/(https?:\/\/[^\s]+?\.(png|jpg|jpeg|gif|webp))/g,
							'<img src="$1" style="max-width: 100%; margin-top: 0.5rem;" />');
		return text;
	}
	function preprocessMarkdown(content) {
		return content
			.split('\n')
			.map(line => {
				if (/^(https?:\/\/[^\s]+\.(?:png|jpe?g|gif|webp))$/.test(line.trim())) {
					return `![](${line.trim()})`;
				}
				return line;
			})
			.join('\n');
	}


	function loadPosts() {
		if (loading) return;
		loading = true;

		const subId = "sub" + Math.random().toString(36).slice(2);
		relay.send(JSON.stringify(["REQ", subId, {
			kinds: [1],
			authors: pubkey,
			until: since,
			limit: limit
		}]));

		relay.addEventListener("message", function handler(event) {
			const data = JSON.parse(event.data);
			if (data[0] === "EVENT" && data[1] === subId) {
				const ev = data[2];
				since = ev.created_at - 1;
				// 🔥 Exclude replies
				const isReply = ev.tags?.some(tag => tag[0] === "e");
				if (isReply) return;


				// Filter by hashtags
				if (includeTags.length > 0 || excludeTags.length > 0) {
					const contentLower = ev.content.toLowerCase();

					const hasInclude = includeTags.length === 0 || includeTags.some(tag => contentLower.includes(`#${tag}`));
					const hasExclude = excludeTags.some(tag => contentLower.includes(`#${tag}`));

					if (!hasInclude || hasExclude) return; // 💥 skip
				}
				const contentLower = ev.content.toLowerCase();

				// 🚫 Content exclusions
				const hasBlockedString = contentExclusions.some(str => contentLower.includes(str));
				if (hasBlockedString) return;


				const div = document.createElement("div");
				div.className = "nostr-post";
				div.innerHTML = marked.parse(preprocessMarkdown(ev.content));

				contentEl.appendChild(div);
			} else if (data[0] === "EOSE" && data[1] === subId) {
				relay.removeEventListener("message", handler);
				loading = false;
			}
		});
	}

	container.addEventListener("scroll", () => {
		const nearBottom = container.scrollTop + container.clientHeight >= container.scrollHeight - 100;
		if (nearBottom) loadPosts();
	});

	relay.addEventListener("open", () => {
		loadPosts();
	});
}

// 👇 include scroll parent helper too
function findScrollableAncestor(el) {
	while (el.parentNode && el.tagName != "BODY") {
		el = el.parentNode;
		const style = getComputedStyle(el);
		const overflowY = style.overflowY;
		const isScrollable = (overflowY === 'auto' || overflowY === 'scroll') && el.scrollHeight > el.clientHeight;
		if (isScrollable) return el;
	}
	return window;
}

