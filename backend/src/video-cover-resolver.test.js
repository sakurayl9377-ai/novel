import assert from 'node:assert/strict';
import test from 'node:test';

import { selectBestCoverMatch, videoCoverResolverInternals } from './video-cover-resolver.js';

test('normalizes language and punctuation suffixes', () => {
  assert.equal(videoCoverResolverInternals.normalizeTitle('夫妻的博弈 国语版'), '夫妻的博弈');
  assert.equal(videoCoverResolverInternals.normalizeTitle('夫妻的博弈（粤语）'), '夫妻的博弈');
});

test('selects only a reliable catalog cover match', () => {
  const match = selectBestCoverMatch('夫妻的博弈国语', '2026', [
    { title: '夫妻的博弈 国语版', year: '2026', coverUrl: 'https://img.example/cover.jpg' },
    { title: '夫妻生活', year: '2026', coverUrl: 'https://img.example/wrong.jpg' },
  ]);
  assert.equal(match?.coverUrl, 'https://img.example/cover.jpg');
  assert.equal(selectBestCoverMatch('完全不同', '', [match]), null);
});
