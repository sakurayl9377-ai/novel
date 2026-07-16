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

test('prefers the matching language and rejects a different numbered season', () => {
  const languageMatch = selectBestCoverMatch('非份之罪国语', '', [
    { title: '非份之罪 粤语版', coverUrl: 'https://img.example/yue.jpg' },
    { title: '非份之罪 国语版', coverUrl: 'https://img.example/mandarin.jpg' },
  ]);
  assert.equal(languageMatch?.coverUrl, 'https://img.example/mandarin.jpg');

  const seasonMismatch = selectBestCoverMatch('文豪野犬汪！第二季', '', [
    { title: '文豪野犬 汪！第一季', coverUrl: 'https://img.example/season-1.jpg' },
  ]);
  assert.equal(seasonMismatch, null);
});

test('accepts persisted covers only from the active catalog provider', () => {
  const supported = videoCoverResolverInternals.isSupportedCachedCover;
  assert.equal(supported({ provider: 'dbzy', coverUrl: 'https://img.example/cover.jpg' }), false);
  assert.equal(supported({ provider: 'dbzy', coverUrl: '/video-covers/files/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg' }), true);
  assert.equal(supported({ provider: 'douban', coverUrl: '/video-covers/files/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.webp' }), true);
  assert.equal(supported({ provider: 'removed-provider', coverUrl: 'https://img.example/cover.jpg' }), false);
  assert.equal(supported({ provider: 'dbzy', coverUrl: 'not-a-url' }), false);
});

test('canonicalizes source item keys and only accepts allowlisted source covers', () => {
  assert.equal(
    videoCoverResolverInternals.canonicalItemKey(
      'wuhandky',
      'https://mirror.example/album/123.html?from=home',
    ),
    '/album/123.html?from=home',
  );
  assert.equal(
    videoCoverResolverInternals.normalizeSourceCandidate(
      'wuhandky',
      'http://pic.fzmmx.com/uploads/vod/poster.jpg',
    ),
    'https://pic.fzmmx.com/uploads/vod/poster.jpg',
  );
  assert.equal(
    videoCoverResolverInternals.normalizeSourceCandidate(
      'wuhandky',
      'https://evil.example/uploads/vod/poster.jpg',
    ),
    '',
  );
});
