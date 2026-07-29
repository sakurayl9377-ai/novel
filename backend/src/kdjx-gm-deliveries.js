import fs from 'node:fs';
import { createHmac, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { kdjxConfig } from './kdjx-config.js';

const catalogPath = fileURLToPath(
  new URL('../catalogs/kdjx-gm-item-catalog.json', import.meta.url),
);
const catalogItemFields = new Set([
  'id',
  'name',
  'description',
  'type',
  'quality',
  'maxQuantity',
]);
const knownRejectedDeliveryCodes = new Set([
  'gm_delivery_unavailable',
  'game_service_unavailable',
  'game_account_lookup_failed',
]);
let catalogCache;

export function getKdjxGmItemCatalog() {
  if (!catalogCache) {
    const document = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
    catalogCache = normalizeKdjxGmItemCatalog(document);
  }
  return catalogCache;
}

export function resetKdjxGmItemCatalogForTests() {
  catalogCache = undefined;
}

export function normalizeKdjxGmItemCatalog(document) {
  const source = document?.items;
  const sourceSha256 = safeCatalogSha256(document?.sourceSha256);
  if (
    !document ||
    Array.isArray(document) ||
    !Array.isArray(source) ||
    source.length === 0 ||
    source.length > 5000 ||
    document.schemaVersion !== 1 ||
    !Number.isSafeInteger(document.itemCount) ||
    document.itemCount !== source.length ||
    !Number.isSafeInteger(document.sourceItemCount) ||
    document.sourceItemCount < 1 ||
    !sourceSha256
  ) {
    throw new Error('Invalid KDJX GM item catalog metadata');
  }

  const items = [];
  const byId = new Map();
  for (const raw of source) {
    if (
      !raw ||
      Array.isArray(raw) ||
      typeof raw !== 'object' ||
      !hasExactFields(raw, catalogItemFields)
    ) {
      throw new Error('Invalid KDJX GM item');
    }
    const id = strictCatalogId(raw.id);
    const name = strictCatalogText(raw.name, 128);
    const description = strictCatalogDescription(raw.description, 240);
    const type = strictNonNegativeCatalogInteger(raw.type);
    const quality = strictNonNegativeCatalogInteger(raw.quality);
    const maximum = strictCatalogMaximum(raw.maxQuantity);
    if (
      !id ||
      !name ||
      type === null ||
      quality === null ||
      maximum === null ||
      byId.has(id)
    ) {
      throw new Error(`Invalid or duplicate KDJX GM item: ${id || '<empty>'}`);
    }
    const item = Object.freeze({
      id,
      name,
      description,
      type: String(type),
      quality: String(quality),
      maxQuantity: maximum,
      deliveryTypes: Object.freeze(['mail']),
    });
    items.push(item);
    byId.set(id, item);
  }
  if (items.length === 0) {
    throw new Error('KDJX GM item catalog is empty');
  }
  return Object.freeze({
    sourceSha256,
    items: Object.freeze(items),
    byId,
  });
}

export function kdjxGmDeliveryEndpointAllowed(value) {
  let endpoint;
  try {
    endpoint = new URL(String(value || ''));
  } catch {
    return false;
  }
  return endpoint.protocol === 'http:' &&
    ['127.0.0.1', '[::1]'].includes(endpoint.hostname) &&
    endpoint.port === '18080' &&
    endpoint.pathname === '/internal/sakura/gm/deliveries' &&
    !endpoint.username &&
    !endpoint.password &&
    !endpoint.search &&
    !endpoint.hash;
}

export async function deliverKdjxGmItem(input, options = {}) {
  const deliveryUrl = String(
    options.deliveryUrl ?? kdjxConfig.gmDeliveryUrl ?? '',
  ).trim();
  const hmacSecret = String(
    options.hmacSecret ?? kdjxConfig.gmDeliveryHmacSecret ?? '',
  ).trim();
  const timeoutMs = boundedTimeout(
    options.timeoutMs ?? kdjxConfig.gmDeliveryTimeoutMs ?? 20000,
  );
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const catalogSha256 = safeCatalogSha256(input.catalogSha256);
  if (
    !kdjxGmDeliveryEndpointAllowed(deliveryUrl) ||
    hmacSecret.length < 32 ||
    !catalogSha256 ||
    typeof fetchImpl !== 'function'
  ) {
    return failedOutcome('kdjx_gm_delivery_unavailable');
  }

  const payload = {
    requestId: input.requestId,
    gameOpenId: input.gameOpenId,
    accountId: input.accountId,
    roleId: input.roleId,
    serverKey: input.serverKey,
    itemId: Number(input.itemId),
    quantity: input.quantity,
    itemName: input.itemName,
    catalogSha256,
    mailSender: '\u6a31\u82b1 GM',
    mailSubject: '\u7cfb\u7edf\u8865\u53d1',
    mailContent: '\u7cfb\u7edf\u8865\u53d1\u7269\u54c1\uff0c' +
      `\u8bf7\u67e5\u6536\u3002\n\u8ffd\u8e2a\u7f16\u53f7\uff1a${input.requestId}`,
  };
  const request = signedDeliveryRequest(payload, hmacSecret);
  let response;
  try {
    response = await fetchImpl(deliveryUrl, {
      method: 'POST',
      body: request.body,
      signal: AbortSignal.timeout(timeoutMs),
      headers: request.headers,
    });
  } catch {
    return unknownOutcome('kdjx_gm_delivery_transport_unknown');
  }

  let body;
  try {
    body = await response.json();
  } catch {
    return unknownOutcome('kdjx_gm_delivery_response_invalid');
  }
  if (body?.ok === false) {
    const rawErrorCode = String(body?.errorCode || body?.error || '')
      .trim()
      .toLowerCase();
    if (rawErrorCode === 'delivery_outcome_unknown') {
      return unknownOutcome('kdjx_gm_delivery_response_unknown');
    }
    if (
      Number(response.status) < 500 ||
      knownRejectedDeliveryCodes.has(rawErrorCode)
    ) {
      return failedOutcome(normalizeRemoteErrorCode(rawErrorCode));
    }
    return unknownOutcome('kdjx_gm_delivery_response_unknown');
  }
  if (
    response.ok &&
    body?.ok === true &&
    String(body?.requestId || '') === input.requestId &&
    (body?.delivered === true || body?.status === 'succeeded')
  ) {
    const remoteReference = safeOutcomeText(
      body.reference ??
        body.deliveryReference ??
        body.remoteReference ??
        '',
      160,
    );
    if (!remoteReference.trim()) {
      return unknownOutcome('kdjx_gm_delivery_response_mismatch');
    }
    return {
      status: 'succeeded',
      remoteReference,
      errorCode: '',
    };
  }
  return unknownOutcome('kdjx_gm_delivery_response_unknown');
}

function signedDeliveryRequest(payload, hmacSecret) {
  const body = JSON.stringify(payload);
  const timestamp = String(Date.now());
  const nonce = randomUUID();
  const signature = createHmac('sha256', hmacSecret)
    .update(`${timestamp}\n${nonce}\n${body}`)
    .digest('hex');
  return {
    body,
    headers: {
      'content-type': 'application/json',
      'x-novel-timestamp': timestamp,
      'x-novel-nonce': nonce,
      'x-novel-signature': signature,
      'x-novel-signature-version': 'v1',
    },
  };
}

function hasExactFields(value, fields) {
  const keys = Object.keys(value);
  return keys.length === fields.size &&
    keys.every((key) => fields.has(key));
}

function safeCatalogSha256(value) {
  const result = String(value ?? '');
  return /^[0-9a-f]{64}$/.test(result) ? result : '';
}

function strictCatalogId(value) {
  return Number.isSafeInteger(value) &&
    value > 0 &&
    value <= 9_999_999_999
    ? String(value)
    : '';
}

function strictCatalogText(value, maximumLength) {
  if (typeof value !== 'string') return '';
  const result = value;
  if (
    !result ||
    result !== result.trim() ||
    result.length > maximumLength ||
    /[\u0000-\u001f\u007f]/.test(result)
  ) {
    return '';
  }
  return result;
}

function strictCatalogDescription(value, maximumLength) {
  if (typeof value !== 'string') {
    throw new Error('Invalid KDJX GM item description');
  }
  const result = value;
  if (
    result !== result.trim() ||
    result.length > maximumLength ||
    /[\u0000-\u001f\u007f]/.test(result)
  ) {
    throw new Error('Invalid KDJX GM item description');
  }
  return result;
}

function strictNonNegativeCatalogInteger(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function strictCatalogMaximum(value) {
  return Number.isSafeInteger(value) && value >= 1 && value <= 2_147_483_647
    ? value
    : null;
}

function boundedTimeout(value) {
  const result = Number(value);
  if (!Number.isFinite(result)) return 20000;
  return Math.max(1000, Math.min(30000, Math.trunc(result)));
}

function normalizeRemoteErrorCode(value) {
  const result = String(value || '').trim().toLowerCase();
  if (/^[a-z][a-z0-9_]{0,79}$/.test(result)) {
    return `game_${result}`;
  }
  return 'kdjx_gm_delivery_rejected';
}

function safeOutcomeText(value, maximumLength) {
  return String(value || '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .slice(0, maximumLength);
}

function failedOutcome(errorCode) {
  return {
    status: 'failed',
    remoteReference: '',
    errorCode,
  };
}

function unknownOutcome(errorCode) {
  return {
    status: 'unknown',
    remoteReference: '',
    errorCode,
  };
}
