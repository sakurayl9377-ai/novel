import path from 'node:path';
import { config } from './config.js';
import {
  isKdjxDeviceAuthorizationUrl,
  isKdjxPaymentEndpoint,
} from './kdjx-url-policy.js';

const catalogFile = config.kdjxPaymentCatalogFile.trim();

export const kdjxConfig = {
  deviceAuthorizationUrl: config.kdjxDeviceAuthorizationUrl.trim(),
  ssoSharedSecret: config.kdjxSsoSharedSecret,
  sessionTtlDays: config.kdjxSessionTtlDays,
  sessionMaxPerUser: config.kdjxSessionMaxPerUser,
  deviceCodeTtlSeconds: config.kdjxDeviceCodeTtlSeconds,
  devicePollIntervalSeconds: config.kdjxDevicePollIntervalSeconds,
  paymentCatalogFile: catalogFile
    ? path.resolve(config.rootDir, catalogFile)
    : '',
  paymentCatalogJson: config.kdjxPaymentCatalogJson,
  paymentVerifyUrl: config.kdjxPaymentVerifyUrl.trim(),
  paymentFulfillmentUrl: config.kdjxPaymentFulfillmentUrl.trim(),
  paymentHmacSecret: config.kdjxPaymentHmacSecret,
  paymentMaxAttempts: config.kdjxPaymentMaxAttempts,
  paymentTimeoutMs: config.kdjxPaymentTimeoutMs,
  paymentClaimTtlMs: config.kdjxPaymentClaimTtlMs,
};

export const kdjxProductionMode = config.nodeEnvironment === 'production';

export function kdjxDeviceAuthorizationUrlAllowed(
  value = kdjxConfig.deviceAuthorizationUrl,
) {
  return isKdjxDeviceAuthorizationUrl(value, { production: kdjxProductionMode });
}

export function kdjxPaymentEndpointAllowed(
  value,
  endpoint,
) {
  return isKdjxPaymentEndpoint(value, endpoint, {
    production: kdjxProductionMode,
  });
}
