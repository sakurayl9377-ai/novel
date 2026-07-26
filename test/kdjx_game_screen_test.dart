import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/screens/kdjx_game_screen.dart';
import 'package:novel_app/services/kdjx_game_service.dart';

class _FakeKdjxGameService extends KdjxGameService {
  int stateCalls = 0;

  @override
  Future<KdjxGameManifest> fetchManifest() async {
    return const KdjxGameManifest(
      packageName: KdjxGameManifest.expectedPackageName,
      versionName: '2.1.0.0',
      versionCode: 4,
      apkUrls: [],
      parts: [],
      sizeBytes: 200 * 1024 * 1024,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      signingCertificateSha256:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      notes: [],
    );
  }

  @override
  Future<KdjxInstalledGame> getInstalledGame() async {
    return const KdjxInstalledGame.notInstalled();
  }

  @override
  Future<KdjxDownloadState> getDownloadState() async {
    stateCalls++;
    return KdjxDownloadState(
      status: KdjxDownloadStatus.downloading,
      downloadedBytes: stateCalls == 1 ? 100 * 1024 * 1024 : 110 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: '/games/kdjx-4-aaaaaaaaaaaa.apk',
      reason: '',
      sourceUrl:
          'https://novel.kxhub.xyz/games/kdjx/'
          'kdjx-4-aaaaaaaaaaaa.part-000.apk',
      sourceIndex: 0,
      segmented: true,
      partCount: 5,
      transport: 'app_http',
      artifactKey:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      releaseKey:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    );
  }
}

void main() {
  test('formats KDJX download remaining time for the progress UI', () {
    expect(formatKdjxDownloadEta(9.1), '10秒');
    expect(formatKdjxDownloadEta(61), '2分钟');
    expect(formatKdjxDownloadEta(3660), '1小时1分钟');
    expect(formatKdjxDownloadEta(double.infinity), isEmpty);
  });

  testWidgets('shows aggregate speed and estimated remaining time', (
    tester,
  ) async {
    final service = _FakeKdjxGameService();

    await tester.pumpWidget(
      MaterialApp(
        home: KdjxGameScreen(expectedUserId: '42', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(find.textContaining('正在估算速度和剩余时间'), findsWidgets);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('/s'), findsWidgets);
    expect(find.textContaining('预计剩余'), findsWidgets);
    expect(find.textContaining('110 MB / 200 MB'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });
}
