const loopbackHost = '127.0.0.1';

export const kdjxProductionEndpoints = Object.freeze({
  deviceAuthorization: 'sakura-novel://game/kdjx/authorize',
  paymentVerify:
    `http://${loopbackHost}:18080/internal/sakura/payments/verify`,
  paymentFulfillment:
    `http://${loopbackHost}:18080/internal/sakura/payments/fulfill`,
});

export function isKdjxDeviceAuthorizationUrl(
  value,
  { production = false } = {},
) {
  const url = parseUrl(value);
  if (!url) return false;
  if (!production) {
    return url.protocol === 'sakura-novel:' &&
      url.hostname === 'game' &&
      url.pathname === '/kdjx/authorize';
  }
  return url.href === kdjxProductionEndpoints.deviceAuthorization;
}

export function isKdjxPaymentEndpoint(
  value,
  endpoint,
  { production = false } = {},
) {
  const url = parseUrl(value);
  if (!url) return false;
  const expectedPath = endpoint === 'verify'
    ? '/internal/sakura/payments/verify'
    : endpoint === 'fulfill'
      ? '/internal/sakura/payments/fulfill'
      : '';
  if (!expectedPath) return false;
  if (!production) {
    return (url.protocol === 'https:' ||
      (url.protocol === 'http:' && isLoopback(url.hostname))) &&
      url.pathname === expectedPath;
  }
  return url.href === (endpoint === 'verify'
    ? kdjxProductionEndpoints.paymentVerify
    : kdjxProductionEndpoints.paymentFulfillment);
}

function parseUrl(value) {
  try {
    const url = new URL(String(value || '').trim());
    if (url.username || url.password || url.search || url.hash) return null;
    return url;
  } catch {
    return null;
  }
}

function isLoopback(hostname) {
  return hostname === '127.0.0.1' || hostname === '::1' || hostname === 'localhost';
}
