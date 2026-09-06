import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/wuhandky_service.dart';

void main() {
  final service = WuhandkyService();

  test('parses and deduplicates native video cards', () {
    const html = '''
      <a class="video-pic" href="/album/demo.html" title="示例影片"
         data-original="https://img.example/demo.jpg">
        <span class="score">8.8</span><span class="note">更新至12集</span>
      </a>
      <a class="video-pic" href="/album/demo.html" title="示例影片"></a>
    ''';

    final items = service.parseList(html);

    expect(items, hasLength(1));
    expect(items.single.title, '示例影片');
    expect(
      items.single.detailUrl,
      'https://www.xinyegdchina.com/album/demo.html',
    );
    expect(items.single.coverUrl, 'https://img.example/demo.jpg');
    expect(items.single.note, '更新至12集');
    expect(items.single.score, '8.8');
  });

  test('uses the compatible scheme for known cover hosts', () {
    const html = '''
      <a class="video-pic" href="/album/demo.html" title="示例影片"
         data-original="https://pic.fzmmx.com/cover.jpg"></a>
    ''';

    final item = service.parseList(html).single;

    expect(item.coverUrl, 'http://pic.fzmmx.com/cover.jpg');
  });

  test('parses detail sources and restores episode order', () {
    const html = '''
      <meta property="og:title" content="示例剧集">
      <meta property="og:image" content="https://img.example/cover.jpg">
      <ul class="info clearfix">
        <li><span>清晰：</span>完结</li>
        <li><span>类型：</span>国产剧</li>
        <li><span>主演：演员甲,演员乙</span></li>
        <li><span>导演：导演甲</span></li>
        <li><span>国家/地区：</span>中国</li>
        <li><span>上映时间：</span>2026</li>
        <li><span class="details-content-all">完整剧情简介</span></li>
      </ul>
      <ul id="playTab"><li><a href="#con_playlist_1">高清线路</a></li></ul>
      <ul id="con_playlist_1">
        <li><a href="/album/demo-1-2.html">第02集</a></li>
        <li><a href="/album/demo-1-1.html">第01集</a></li>
      </ul>
    ''';

    final detail = service.parseDetail(
      html,
      Uri.parse('https://www.xinyegdchina.com/album/demo.html'),
    );

    expect(detail.title, '示例剧集');
    expect(detail.status, '完结');
    expect(detail.category, '国产剧');
    expect(detail.year, '2026');
    expect(detail.description, '完整剧情简介');
    expect(detail.sources.single.name, '高清线路');
    expect(detail.sources.single.episodes.map((episode) => episode.title), [
      '第01集',
      '第02集',
    ]);
    expect(
      detail.sources.single.episodes.first.pageUrl,
      'https://www.xinyegdchina.com/album/demo-1-1.html',
    );
  });

  test('routes current CDN playback through the backend proxy', () {
    const sourceUrl =
        'https://v9.ppqrrs.com/wjv9/202609/06/demo/video/index.m3u8';

    final proxied = WuhandkyService.playbackProxyUrl(sourceUrl);
    final proxyUri = Uri.parse(proxied);

    expect(proxyUri.path, '/novel-api/video-playback');
    expect(proxyUri.queryParameters['url'], sourceUrl);
  });

  test('routes source pages through the backend using only their path', () {
    final proxyUri = Uri.parse(
      WuhandkyService.sourceProxyUrl(
        'https://www.wuhandky.com/album/demo-1-2.html',
      ),
    );

    expect(proxyUri.path, '/novel-api/video-source');
    expect(proxyUri.queryParameters['path'], '/album/demo-1-2.html');
  });

  test('routes all current numbered CDN families through the backend', () {
    for (final sourceUrl in [
      'https://v.lzcdn31.com/path/index.m3u8',
      'https://v.cdnlz22.com/path/index.m3u8',
      'https://vip1.lz-cdn1.com/path/index.m3u8',
      'https://v.lfthirtytwo.com/path/index.m3u8',
    ]) {
      final proxyUri = Uri.parse(WuhandkyService.playbackProxyUrl(sourceUrl));
      expect(proxyUri.path, '/novel-api/video-playback');
      expect(proxyUri.queryParameters['url'], sourceUrl);
    }
  });

  test('leaves unrelated playback hosts unchanged', () {
    const sourceUrl = 'https://media.example/video.m3u8';

    expect(WuhandkyService.playbackProxyUrl(sourceUrl), sourceUrl);
  });

  test('upgrades a known CDN http URL before proxying it', () {
    const sourceUrl = 'http://v9.adfg8.vip/wjv9/demo/video/index.m3u8';

    final proxyUri = Uri.parse(WuhandkyService.playbackProxyUrl(sourceUrl));

    expect(
      proxyUri.queryParameters['url'],
      'https://v9.adfg8.vip/wjv9/demo/video/index.m3u8',
    );
  });
}
