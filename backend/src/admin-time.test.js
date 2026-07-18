import assert from 'node:assert/strict';
import test from 'node:test';

await import('../public/admin-time.js');

const { formatTime, parseServerTime, timeZone } = globalThis.NOVEL_ADMIN_TIME;

test('treats timezone-less SQLite timestamps as UTC', () => {
  assert.equal(timeZone, 'Asia/Shanghai');
  assert.equal(
    parseServerTime('2026-07-18 09:31:00').toISOString(),
    '2026-07-18T09:31:00.000Z',
  );
  assert.equal(formatTime('2026-07-18 09:31:00'), '07/18 17:31');
});

test('formats explicit offsets in Beijing time without double shifting', () => {
  assert.equal(formatTime('2026-07-18T17:31:00+08:00'), '07/18 17:31');
  assert.equal(formatTime('2026-07-18T09:31:00.000Z'), '07/18 17:31');
  assert.equal(formatTime('invalid'), 'invalid');
  assert.equal(formatTime(''), '-');
});
