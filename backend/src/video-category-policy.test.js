import test from 'node:test';
import assert from 'node:assert/strict';
import { all, migrate, run } from './db.js';
import { categoryPolicy, evaluateCategoryPolicy } from './video-category-policy.js';

test('hidden policy is never available', () => {
  assert.equal(evaluateCategoryPolicy({ mode: 'hidden', timezone: 'Asia/Hong_Kong' }).available, false);
});

test('scheduled policy evaluates in its configured timezone', () => {
  const policy = { mode: 'scheduled', dailyStart: '08:00', dailyEnd: '09:00', timezone: 'Asia/Hong_Kong' };
  assert.equal(evaluateCategoryPolicy(policy, new Date('2026-07-13T00:30:00Z')).available, true);
  assert.equal(evaluateCategoryPolicy(policy, new Date('2026-07-13T02:30:00Z')).available, false);
});

test('scheduled windows can cross midnight', () => {
  const policy = { mode: 'scheduled', dailyStart: '22:00', dailyEnd: '06:00', timezone: 'Asia/Hong_Kong' };
  assert.equal(evaluateCategoryPolicy(policy, new Date('2026-07-12T15:00:00Z')).available, true);
  assert.equal(evaluateCategoryPolicy(policy, new Date('2026-07-12T21:30:00Z')).available, true);
  assert.equal(evaluateCategoryPolicy(policy, new Date('2026-07-13T04:00:00Z')).available, false);
});

test('adult category defaults to age-restricted midnight schedule', () => {
  migrate();
  const policy = categoryPolicy('dbzy', 34);
  assert.equal(policy.mode, 'scheduled');
  assert.equal(policy.dailyStart, '00:00');
  assert.equal(policy.dailyEnd, '06:00');
  assert.equal(policy.timezone, 'Asia/Hong_Kong');
  assert.equal(policy.ageRestricted, true);
});

test('migration removes administration rows for unsupported video sources', () => {
  migrate();
  run(
    `INSERT OR REPLACE INTO video_category_policies
     (source_key, category_id, mode, daily_start, daily_end, timezone, age_restricted)
     VALUES ('removed-provider', 999, 'always', '00:00', '23:59', 'Asia/Hong_Kong', 0)`,
  );
  run(
    `INSERT OR REPLACE INTO video_content_overrides
     (source_key, source_item_id, visibility, note)
     VALUES ('removed-provider', 'legacy-item', 'hidden', '')`,
  );

  migrate();

  assert.deepEqual(
    all("SELECT source_key FROM video_category_policies WHERE source_key = 'removed-provider'"),
    [],
  );
  assert.deepEqual(
    all("SELECT source_key FROM video_content_overrides WHERE source_key = 'removed-provider'"),
    [],
  );
});
