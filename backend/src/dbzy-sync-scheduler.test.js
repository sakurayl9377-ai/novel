import test from 'node:test';
import assert from 'node:assert/strict';
import { computeDbzySyncDelay } from './dbzy-sync-scheduler.js';

test('scheduled sync uses the configured interval after success', () => {
  assert.equal(computeDbzySyncDelay(30 * 60 * 1000, 0), 30 * 60 * 1000);
});

test('scheduled sync backs off after repeated failures and caps at six hours', () => {
  assert.equal(computeDbzySyncDelay(30 * 60 * 1000, 1), 60 * 60 * 1000);
  assert.equal(computeDbzySyncDelay(30 * 60 * 1000, 2), 2 * 60 * 60 * 1000);
  assert.equal(computeDbzySyncDelay(30 * 60 * 1000, 9), 6 * 60 * 60 * 1000);
});
