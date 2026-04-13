// /static/js/fetch-cache.js

const DEFAULT_BACKOFF_MS = 250;

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

export const TTLCache = {
	get(key) {
		try {
			const raw = localStorage.getItem(key);
			if (!raw) return null;
			const { v, e } = JSON.parse(raw);
			if (e && Date.now() > e) {
				localStorage.removeItem(key);
				return null;
			}
			return v;
		} catch {
			return null;
		}
	},

	set(key, value, ttlMs) {
		try {
			localStorage.setItem(
				key,
				JSON.stringify({
					v: value,
					e: ttlMs ? Date.now() + ttlMs : null
				})
			);
		} catch {}
	},

	remove(key) {
		try {
			localStorage.removeItem(key);
		} catch {}
	}
};

// /static/js/fetch-cache.js

function isCrossOrigin(url) {
	try {
		return new URL(url, window.location.href).origin !== window.location.origin;
	} catch {
		return false;
	}
}

export async function fetchWithRetry(
	url,
	{
		method = "GET",
		headers,
		body,
		credentials,
		cache = "no-store",
		retries = 1,
		backoff = DEFAULT_BACKOFF_MS
	} = {}
) {
	const finalCredentials =
		credentials ??
		(isCrossOrigin(url) ? "omit" : "same-origin");

	for (let i = 0; ; i++) {
		try {
			const res = await fetch(url, {
				method,
				headers,
				body,
				credentials: finalCredentials,
				cache
			});
			if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
			return res;
		} catch (err) {
			if (i >= retries) throw err;
			await sleep(backoff * (i + 1));
		}
	}
}

export async function fetchJSON(url, opts = {}) {
	const res = await fetchWithRetry(url, {
		headers: {
			Accept: "application/json",
			"Cache-Control": "no-cache, no-store, max-age=0, must-revalidate",
			Pragma: "no-cache",
			Expires: "0",
			...(opts.headers || {})
		},
		...opts
	});
	return res.json();
}

export async function fetchText(url, opts = {}) {
	const res = await fetchWithRetry(url, opts);
	return res.text();
}

export async function fetchCachedTextFirstLine(
	url,
	{
		cacheKey,
		ttlMs,
		headers,
		retries = 1,
		backoff = DEFAULT_BACKOFF_MS,
		bypassCache = false
	} = {}
) {
	if (!bypassCache && cacheKey) {
		const cached = TTLCache.get(cacheKey);
		if (cached) return cached;
	}

	const text = await fetchText(url, { headers, retries, backoff });
	const firstLine = (text || "").split(/\r?\n/)[0] || "—";

	if (!bypassCache && cacheKey) {
		TTLCache.set(cacheKey, firstLine, ttlMs);
	}

	return firstLine;
}
