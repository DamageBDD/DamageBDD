import { joinUrl, requestJson } from './shared/http.js';

export async function getVersion(baseUrl) {
  const response = await requestJson(joinUrl(baseUrl, '/version/'));
  return response.data;
}

export async function authenticate(baseUrl, username, password) {
  const response = await requestJson(joinUrl(baseUrl, '/accounts/auth/'), {
    method: 'POST',
    data: { username, password }
  });

  const data = response.data;
  if (!data?.access_token || !data?.address) {
    throw new Error('Authentication response did not contain access_token and address.');
  }
  return data;
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
