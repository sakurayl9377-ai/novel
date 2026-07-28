import assert from 'node:assert/strict';
import test from 'node:test';
import {
  isKdjxDeviceAuthorizationUrl,
  isKdjxPaymentEndpoint,
  kdjxProductionEndpoints,
} from './kdjx-url-policy.js';

test('KDJX production URL policy admits only owned endpoints', () => {
  assert.equal(isKdjxDeviceAuthorizationUrl(
    kdjxProductionEndpoints.deviceAuthorization,
    { production: true },
  ), true);
  assert.equal(isKdjxPaymentEndpoint(
    kdjxProductionEndpoints.paymentVerify,
    'verify',
    { production: true },
  ), true);
  assert.equal(isKdjxPaymentEndpoint(
    kdjxProductionEndpoints.paymentFulfillment,
    'fulfill',
    { production: true },
  ), true);
});

test('KDJX production URL policy rejects legacy, remote payment, and unsafe URLs', () => {
  assert.equal(isKdjxDeviceAuthorizationUrl(
    'https://49.232.137.85/game/kdjx/authorize',
    { production: true },
  ), false);
  assert.equal(isKdjxPaymentEndpoint(
    'https://192.168.0.102/internal/sakura/payments/verify',
    'verify',
    { production: true },
  ), false);
  assert.equal(isKdjxPaymentEndpoint(
    'http://127.0.0.1:18080/internal/sakura/payments/fulfill',
    'verify',
    { production: true },
  ), false);
});

test('KDJX development payment policy retains isolated loopback support', () => {
  assert.equal(isKdjxPaymentEndpoint(
    'http://127.0.0.1:18080/internal/sakura/payments/verify',
    'verify',
  ), true);
  assert.equal(isKdjxPaymentEndpoint(
    'https://game.example.test/internal/sakura/payments/verify',
    'verify',
  ), true);
  assert.equal(isKdjxPaymentEndpoint(
    'http://game.example.test/internal/sakura/payments/verify',
    'verify',
  ), false);
});
