export class HttpError extends Error {
  constructor(message, { status = 0, data = null, url = '' } = {}) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.data = data;
    this.url = url;
  }
}

export function normalizeBaseUrl(value) {
  let url = String(value ?? '').trim();
  if (!url) return '';
  if (!/^https?:\/\//i.test(url)) url = `https://${url}`;
  return url.replace(/\/+$/, '');
}

export function joinUrl(baseUrl, path) {
  const base = normalizeBaseUrl(baseUrl);
  if (!base) throw new Error('Server URL is required.');

  const requestedPath = String(path ?? '').trim();
  if (/^https?:\/\//i.test(requestedPath)) return requestedPath;

  return new URL(requestedPath.replace(/^\/+/, ''), `${base}/`).toString();
}

function parseBody(raw, contentType) {
  if (!raw) return null;
  if (contentType.includes('application/json')) {
    try {
      return JSON.parse(raw);
    } catch {
      return raw;
    }
  }

  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

export async function requestJson(url, {
  method = 'GET',
  token = '',
  data,
  headers = {}
} = {}) {
  const requestHeaders = new Headers(headers);
  requestHeaders.set('accept', 'application/json, text/plain;q=0.9');

  if (token) requestHeaders.set('authorization', `Bearer ${token}`);

  let body;
  if (data !== undefined) {
    requestHeaders.set('content-type', 'application/json');
    body = JSON.stringify(data);
  }

  let response;
  try {
    // In the Android build this is patched by CapacitorHttp and uses the
    // native HTTP stack. In a browser it remains ordinary fetch.
    response = await fetch(url, {
      method,
      headers: requestHeaders,
      body
    });
  } catch (error) {
    throw new HttpError(error?.message || 'Network request failed.', { url });
  }

  const raw = await response.text();
  const contentType = response.headers.get('content-type') || '';
  const parsed = parseBody(raw, contentType);

  if (!response.ok) {
    const serverMessage =
      parsed?.message || parsed?.reason || parsed?.error?.message || raw;
    throw new HttpError(
      serverMessage ? String(serverMessage) : `HTTP ${response.status}`,
      { status: response.status, data: parsed, url }
    );
  }

  return {
    status: response.status,
    data: parsed,
    headers: Object.fromEntries(response.headers.entries()),
    url: response.url || url
  };
}

export function describeError(error) {
  if (error instanceof HttpError) {
    const prefix = error.status ? `HTTP ${error.status}: ` : '';
    return `${prefix}${error.message}`;
  }
  return error?.message || String(error);
}
