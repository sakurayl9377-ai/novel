import assert from 'node:assert/strict';
import test from 'node:test';

import { removeRetiredVideoEnvironment } from '../scripts/retire-video-environment.js';

test('removes only retired video environment keys without exposing values', () => {
  const result = removeRetiredVideoEnvironment([
    'TOKEN_SECRET=keep-me',
    'DBZY_ENABLED=true',
    ' export DBZY_BASE_URL=https://collector.example/api',
    'SUIBIAN_CATALOG_TOKEN=private',
    'VIDEO_POLICY_TIMEZONE=Asia/Hong_Kong',
    '# DBZY_ENABLED=documentation is not an assignment',
    'VIDEO_COVER_DIR=./data/video-covers',
    '',
  ].join('\n'));

  assert.equal(result.removed, 4);
  assert.equal(
    result.output,
    [
      'TOKEN_SECRET=keep-me',
      '# DBZY_ENABLED=documentation is not an assignment',
      'VIDEO_COVER_DIR=./data/video-covers',
      '',
    ].join('\n'),
  );
});
