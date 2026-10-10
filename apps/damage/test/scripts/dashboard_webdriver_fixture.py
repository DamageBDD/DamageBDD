#!/usr/bin/env python3
"""Loopback-only by default: production templates/controller, simulated services.

This HTTP fixture is shared by Selenium and Appium. It is NOT the live OTP node,
not an auth/billing integration server, and never executes a feature. No Python
Selenium/Appium/Playwright package is needed to serve it.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
from urllib.parse import urlsplit
from bdd_composer_browser_test import build_preview


def fixture_html() -> str:
    page = build_preview()
    # Slow only the simulated request, not the production duplicate-submit guard.
    old = 'await new Promise(resolve => setTimeout(resolve, 250));'
    assert page.count(old) == 1, 'Execution fixture changed: review this adapter'
    page = page.replace(old, "await window.__dashboardTest.wait();")
    # Install before the actual composer module boots. Counters let assertions wait
    # for network completion, rather than declaring a stale-response test successful
    # before the old response has arrived.
    tracker = """<script>
window.__dashboardTest = {
  pending: 0, hold: false, releases: new Set(),
  release() {
    this.hold = false;
    for (const release of [...this.releases]) release();
  },
  wait(signal) {
    if (signal?.aborted) return Promise.reject(new DOMException('Aborted', 'AbortError'));
    if (!this.hold) return Promise.resolve();
    return new Promise((resolve, reject) => {
      let timer;
      const cleanup = () => {
        clearTimeout(timer);
        this.releases.delete(release);
        signal?.removeEventListener('abort', abort);
      };
      const release = () => { cleanup(); resolve(); };
      const abort = () => { cleanup(); reject(new DOMException('Aborted', 'AbortError')); };
      this.releases.add(release);
      signal?.addEventListener('abort', abort, {once: true});
      // A forgotten release must fail, not hang forever or accidentally pass.
      timer = setTimeout(() => { cleanup(); reject(Error('Fixture gate deadline exceeded')); }, 120000);
    });
  }
};
const fixtureFetch = window.fetch;
window.fetch = async (url, options = {}) => {
  window.__dashboardTest.pending++;
  try {
    const response = await fixtureFetch(url, options);
    if (['generate', 'validate'].includes(String(url).split('/').pop())) {
      await window.__dashboardTest.wait(options.signal);
    }
    return response;
  } finally { window.__dashboardTest.pending--; }
};
</script>"""
    marker = '<script type="module">'
    assert page.count(marker) == 1, 'Composer fixture changed: review tracker placement'
    return page.replace(marker, tracker + marker)


def server(bind: str = '127.0.0.1', port: int = 8765) -> ThreadingHTTPServer:
    content = fixture_html().encode('utf-8')

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            if path not in ('/', '/health'):
                self.send_error(404)
                return
            body = b'{"fixture":true,"ready":true}' if path == '/health' else content
            self.send_response(200)
            self.send_header('Content-Type', 'application/json' if path == '/health' else 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args) -> None:
            pass

    return ThreadingHTTPServer((bind, port), Handler)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', default='127.0.0.1', help='Use a trusted network only for remote device/Grid access')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    with server(args.bind, args.port) as httpd:
        print(f'Dashboard fixture: http://{args.bind}:{httpd.server_port}/ (SIMULATED SERVICES)', flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
