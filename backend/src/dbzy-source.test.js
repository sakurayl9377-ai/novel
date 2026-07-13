import test from 'node:test';
import assert from 'node:assert/strict';
import { dbzyInternals, normalizeVod, parsePlaylists, redactPlaybackCandidate } from './dbzy-source.js';

test('MacCMS $$$/#/$ playlists merge matching episodes and keep HTTPS HLS only', () => {
  const episodes = parsePlaylists(
    'dbm3u8$$$backup',
    '第1集$https://a.example/1.m3u8#第2集$http://a.example/2.m3u8$$$第1集$https://b.example/1.m3u8?token=x#坏地址$https://b.example/video.mp4',
  );
  assert.deepEqual(episodes, [{
    index: 0,
    title: '第1集',
    candidates: [
      { name: 'dbm3u8', hlsUrl: 'https://a.example/1.m3u8' },
      { name: 'backup', hlsUrl: 'https://b.example/1.m3u8?token=x' },
    ],
  }]);
});

test('vod detail is normalized for the app and insecure artwork is upgraded', () => {
  const item = normalizeVod({
    vod_id: 123,
    type_id: 45,
    type_name: '反转爽剧',
    vod_name: ' 测试短剧 ',
    vod_pic: 'http://img.example/cover.jpg',
    vod_pic_thumb: 'https://img.example/thumb.jpg',
    vod_content: '<p>剧情 <b>简介</b></p>',
    vod_class: '短剧,反转',
    vod_play_from: 'dbm3u8',
    vod_play_url: '全集$https://video.example/index.m3u8',
  });
  assert.equal(item.id, 'dbzy:123');
  assert.equal(item.category, 'short');
  assert.equal(item.coverUrl, 'https://img.example/cover.jpg');
  assert.equal(item.summary, '剧情 简介');
  assert.equal(item.episodes[0].candidates[0].hlsUrl, 'https://video.example/index.m3u8');
});

test('category visibility is policy-driven and short categories remain identified', () => {
  assert.deepEqual([...dbzyInternals.HIDDEN_CATEGORY_IDS], []);
  assert.deepEqual([...dbzyInternals.SHORT_CATEGORY_IDS], [37, 43, 44, 45, 46, 47, 48, 49]);
});

test('admin playback candidates expose the host but never the URL or token', () => {
  const candidate = redactPlaybackCandidate({
    name: '蓝光-2',
    hlsUrl: 'https://video.example/episode/index.m3u8?token=secret-value',
  });
  assert.deepEqual(candidate, {
    name: '蓝光-2', host: 'video.example', protocol: 'https', format: 'HLS', health: 'ready',
  });
  assert.equal(JSON.stringify(candidate).includes('secret-value'), false);
});
