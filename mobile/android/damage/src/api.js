import { HttpError, joinUrl, requestJson } from './shared/http.js';

export async function getVersion(baseUrl) {
  const response = await requestJson(joinUrl(baseUrl, '/version/'));
  return response.data;
}

export async function authenticate(baseUrl, username, password) {
  const response = await requestJson(joinUrl(baseUrl, '/accounts/auth/'), {
    method: 'POST',
    data: { username, password }
  });

  return requireAuthResponse(response.data);
}

export async function authenticateWallet(baseUrl, address, signature, meta) {
  const response = await requestJson(joinUrl(baseUrl, '/accounts/auth/'), {
    method: 'POST',
    data: { address, signature, meta }
  });

  return requireAuthResponse(response.data);
}

function requireAuthResponse(data) {
  if (!data?.access_token || !data?.address) {
    throw new Error('Authentication response did not contain access_token and address.');
  }
  return data;
}

export async function getWalletSnapshot(baseUrl, token, address = '') {
  try {
    const response = await requestJson(joinUrl(baseUrl, '/accounts/wallet'), {
      token
    });
    return normalizeWalletSnapshot(response.data);
  } catch (error) {
    if (!(error instanceof HttpError) || ![404, 405, 501].includes(error.status)) {
      throw error;
    }

    return getLegacyWalletSnapshot(baseUrl, token, address);
  }
}

function normalizeWalletSnapshot(data) {
  if (!data || typeof data !== 'object' || !data.balances) {
    throw new Error('Wallet response did not contain a balances object.');
  }

  return {
    ...data,
    balances: {
      lightning: normalizeBalance(data.balances.lightning, 'sat'),
      ae: normalizeBalance(data.balances.ae, 'AE'),
      damage: normalizeBalance(data.balances.damage, 'DAMAGE')
    }
  };
}

function normalizeBalance(balance, fallbackSymbol) {
  const value = balance && typeof balance === 'object' ? balance : {};
  const hasAmount = value.amount !== undefined && value.amount !== null;
  const normalized = {
    ...value,
    available: value.available === true || (value.available === undefined && hasAmount),
    amount: String(value.amount ?? '0'),
    decimals: Number.isInteger(value.decimals) ? value.decimals : 0,
    symbol: value.symbol || fallbackSymbol,
    source: value.source || '',
    reason: value.reason || ''
  };

  if (value.amount_msat !== undefined) normalized.amount_msat = String(value.amount_msat);
  if (value.amount_sat !== undefined) normalized.amount_sat = String(value.amount_sat);
  return normalized;
}

async function getLegacyWalletSnapshot(baseUrl, token, address) {
  const suffix = address ? `?pubkey=${encodeURIComponent(address)}` : '';
  const [balanceResult, lightningResult] = await Promise.allSettled([
    requestJson(joinUrl(baseUrl, `/accounts/balance${suffix}`), { token }),
    getNwcSessions(baseUrl, token)
  ]);

  const balanceData = balanceResult.status === 'fulfilled'
    ? balanceResult.value.data
    : {};
  const lightningData = lightningResult.status === 'fulfilled'
    ? lightningResult.value
    : {};

  const lightningMsat = firstDefined(
    balanceData?.balance_msat,
    balanceData?.msats,
    balanceData?.ledger?.balance_msat,
    lightningData?.account_balance_msat
  );
  const lightningDisplay = firstDefined(
    balanceData?.sats_display,
    balanceData?.sats
  );

  const aeRaw = firstDefined(
    balanceData?.ae_raw,
    balanceData?.aettos,
    balanceData?.ae_amount,
    balanceData?.ae
  );
  const damageRaw = firstDefined(
    balanceData?.damage_raw,
    balanceData?.damage,
    balanceData?.amount,
    balanceData?.hits
  );

  const balances = {
    lightning: {
      available: lightningMsat !== undefined || lightningDisplay !== undefined,
      amount: String(lightningMsat ?? '0'),
      amount_msat: String(lightningMsat ?? '0'),
      amount_sat: String(lightningData?.account_balance_sat ?? '0'),
      display: lightningDisplay !== undefined ? String(lightningDisplay) : '',
      decimals: 3,
      symbol: 'sat',
      source: lightningMsat !== undefined ? 'accounts_balance' : 'nwc_sessions',
      session_count: Array.isArray(lightningData?.sessions)
        ? lightningData.sessions.length
        : undefined,
      reason: lightningMsat !== undefined || lightningDisplay !== undefined
        ? ''
        : settledReason(lightningResult)
    },
    ae: {
      available: aeRaw !== undefined || balanceData?.ae_display !== undefined,
      amount: String(aeRaw ?? '0'),
      display: balanceData?.ae_display !== undefined
        ? String(balanceData.ae_display)
        : '',
      decimals: integerOr(balanceData?.ae_decimals, 18),
      symbol: 'AE',
      source: 'accounts_balance',
      reason: aeRaw !== undefined || balanceData?.ae_display !== undefined
        ? ''
        : 'The selected node did not return an AE account balance.'
    },
    damage: {
      available: damageRaw !== undefined || balanceData?.damage_display !== undefined,
      amount: String(damageRaw ?? '0'),
      display: balanceData?.damage_display !== undefined
        ? String(balanceData.damage_display)
        : '',
      decimals: integerOr(balanceData?.damage_decimals, 8),
      symbol: 'DAMAGE',
      source: 'accounts_balance',
      reason: damageRaw !== undefined || balanceData?.damage_display !== undefined
        ? ''
        : settledReason(balanceResult)
    }
  };

  const availableCount = Object.values(balances).filter((item) => item.available).length;
  return {
    status: availableCount === 3 ? 'ok' : 'partial',
    legacy: true,
    address: balanceData?.address || balanceData?.id || address,
    updated_at: Math.floor(Date.now() / 1000),
    warning: availableCount === 3
      ? ''
      : 'This node returned only part of the wallet balance contract. Upgrade it to expose /accounts/wallet for a consistent snapshot.',
    balances
  };
}

function firstDefined(...values) {
  return values.find((value) => value !== undefined && value !== null && value !== '');
}

function integerOr(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
}

function settledReason(result) {
  if (!result || result.status !== 'rejected') return '';
  return result.reason?.message || String(result.reason || 'Unavailable');
}

export async function getNwcSessions(baseUrl, token, limit = 200) {
  const response = await requestJson(joinUrl(baseUrl, '/api/nwc/sessions'), {
    method: 'POST',
    token,
    data: { limit }
  });
  return response.data;
}

export async function mintNwcConnection(baseUrl, token, {
  maxSingleSat = 10000,
  maxTotalSat = 100000,
  expiresHeight = 0
} = {}) {
  const response = await requestJson(joinUrl(baseUrl, '/api/nwc/mint'), {
    method: 'POST',
    token,
    data: {
      max_single_sat: maxSingleSat,
      max_total_sat: maxTotalSat,
      expires_height: expiresHeight
    }
  });
  return response.data;
}

export async function revokeNwcConnection(baseUrl, token, clientPubkey) {
  const response = await requestJson(joinUrl(baseUrl, '/api/nwc/revoke'), {
    method: 'POST',
    token,
    data: { client_pubkey: clientPubkey }
  });
  return response.data;
}

export async function executeFeature(baseUrl, token, feature, concurrency = 1) {
  const response = await requestJson(joinUrl(baseUrl, '/execute_feature/'), {
    method: 'PUT',
    token,
    data: {
      feature,
      concurrency,
      stream: false
    }
  });
  return response.data;
}
