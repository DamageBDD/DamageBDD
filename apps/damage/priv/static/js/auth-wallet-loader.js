// Wallet integration is optional at auth startup. Load it only on user action.
// This release key bypasses the old unversioned HTTP cache entry; it is NOT
// a checksum enforced by the server. Deploy matching assets to every node.
const importWallet = () => import('./wallet.js?v=9a8aa9058a0e5966');
const unavailableMessage = 'Browser wallet support could not be loaded. Reload this page and retry, or use email sign-in.';
const mismatchMessage = 'The server is serving an outdated wallet module. Reload this page; if it persists, deploy the matching wallet.js. Email sign-in is still available.';

function abortIfNeeded(signal) {
  if (signal?.aborted) throw new DOMException('Wallet sign-in cancelled.', 'AbortError');
}

export function createAuthWalletLoader(load = importWallet) {
  let pending;
  const resolve = () => {
    if (!pending) {
      // Convert import/network/link/evaluation failures to a recoverable UI error.
      // Never fall back to legacy connectWalletSmart or signing/transaction APIs.
      pending = Promise.resolve().then(load).then(module => {
        if (typeof module?.connectBrowserForAuth !== 'function' ||
            typeof module?.signBrowserForAuth !== 'function') {
          const error = new Error(mismatchMessage);
          error.code = 'WALLET_MODULE_MISMATCH';
          throw error;
        }
        return module;
      }).catch(error => {
        pending = undefined; // Retry the same URL, never generate unbounded URLs.
        if (error?.code === 'WALLET_MODULE_MISMATCH') throw error;
        const failure = new Error(unavailableMessage);
        failure.code = 'WALLET_MODULE_UNAVAILABLE';
        throw failure;
      });
    }
    return pending;
  };
  return Object.freeze({
    async connect({signal} = {}) {
      abortIfNeeded(signal);
      const module = await resolve();
      // Cancellation while downloading must not open a delayed wallet prompt.
      abortIfNeeded(signal);
      return module.connectBrowserForAuth();
    },
    async sign(message, expectedAddress, {signal} = {}) {
      abortIfNeeded(signal);
      const module = await resolve();
      abortIfNeeded(signal);
      return module.signBrowserForAuth(message, expectedAddress);
    }
  });
}

export const authWallet = createAuthWalletLoader();
