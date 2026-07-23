import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/screens/modao_game_screen.dart';
import 'package:novel_app/services/modao_game_service.dart';

class _FakeModaoGameService extends ModaoGameService {
  int stateCalls = 0;

  @override
  Future<ModaoGameManifest> fetchManifest() async {
    return ModaoGameManifest.fromJson({
      'packageName': ModaoGameManifest.expectedPackageName,
      'versionName': '10.0.0.0',
      'versionCode': 2023981000,
      'apkUrl':
          'https://novel.kxhub.xyz/games/modao/modao-2023981000-aaaaaaaaaaaa.apk',
      'sizeBytes': 200 * 1024 * 1024,
      'sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'signingCertificateSha256':
          ModaoGameManifest.expectedSigningCertificateSha256,
      'notes': const <String>[],
    });
  }

  @override
  Future<ModaoInstalledGame> getInstalledGame() async {
    return const ModaoInstalledGame.notInstalled();
  }

  @override
  Future<ModaoDownloadState> getDownloadState() async {
    stateCalls++;
    return ModaoDownloadState(
      status: ModaoDownloadStatus.downloading,
      downloadedBytes: stateCalls == 1 ? 100 * 1024 * 1024 : 110 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
    );
  }
}

class _LegacyDownloadMigrationService extends _FakeModaoGameService {
  int clearCalls = 0;

  @override
  Future<ModaoGameManifest> fetchManifest() async {
    return ModaoGameManifest.fromJson({
      'packageName': ModaoGameManifest.expectedPackageName,
      'versionName': '10.0.0.0',
      'versionCode': 2023981000,
      'apkUrl':
          'https://novel.kxhub.xyz/games/modao/modao-2023981000-aaaaaaaaaaaa.apk',
      'sizeBytes': 200 * 1024 * 1024,
      'sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'signingCertificateSha256':
          ModaoGameManifest.expectedSigningCertificateSha256,
      'parts': List.generate(5, (index) {
        final label = index.toString().padLeft(3, '0');
        return {
          'index': index,
          'url':
              'https://novel.kxhub.xyz/games/modao/modao-2023981000-aaaaaaaaaaaa.part-$label.apk',
          'sizeBytes': 40 * 1024 * 1024,
          'sha256': '${index + 1}' * 64,
        };
      }),
      'notes': const <String>[],
    });
  }

  @override
  Future<ModaoDownloadState> getDownloadState() async {
    return const ModaoDownloadState(
      status: ModaoDownloadStatus.downloading,
      downloadedBytes: 3 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
      segmented: false,
      partCount: 0,
    );
  }

  @override
  Future<void> clearDownload() async {
    clearCalls++;
  }
}

class _CompletedLegacyDownloadService extends _LegacyDownloadMigrationService {
  int verifyCalls = 0;

  @override
  Future<ModaoDownloadState> getDownloadState() async {
    return const ModaoDownloadState(
      status: ModaoDownloadStatus.completed,
      downloadedBytes: 200 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
      segmented: false,
      partCount: 0,
    );
  }

  @override
  Future<void> verifyDownloadedApk(
    ModaoGameManifest manifest,
    String localPath,
  ) async {
    verifyCalls++;
  }
}

class _DownloadManagerMigrationService extends _LegacyDownloadMigrationService {
  _DownloadManagerMigrationService({this.metered = false});

  final bool metered;
  int startCalls = 0;

  @override
  Future<ModaoDownloadState> getDownloadState() async {
    final manifest = await fetchManifest();
    return ModaoDownloadState(
      status: ModaoDownloadStatus.downloading,
      downloadedBytes: 3 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
      segmented: true,
      partCount: 5,
      transport: 'download_manager',
      artifactKey: manifest.artifactKey,
      releaseKey: 'legacy-release',
    );
  }

  @override
  Future<ModaoDeviceEnvironment> getDeviceEnvironment() async {
    return ModaoDeviceEnvironment(
      freeBytes: 10 * 1024 * 1024 * 1024,
      networkType: metered ? 'cellular' : 'wifi',
      connected: true,
      validated: true,
      metered: metered,
    );
  }

  @override
  Future<ModaoDownloadState> startDownload(
    ModaoGameManifest manifest, {
    required bool allowMetered,
  }) async {
    startCalls++;
    expect(allowMetered, metered);
    return ModaoDownloadState(
      status: ModaoDownloadStatus.downloading,
      downloadedBytes: 3 * 1024 * 1024,
      totalBytes: manifest.sizeBytes,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
      segmented: true,
      partCount: manifest.parts.length,
      transport: 'app_http',
      artifactKey: manifest.artifactKey,
      releaseKey: 'app-http-release',
    );
  }
}

class _AppHttpRecoveryService extends _LegacyDownloadMigrationService {
  int startCalls = 0;

  @override
  Future<ModaoDownloadState> getDownloadState() async {
    final manifest = await fetchManifest();
    return ModaoDownloadState(
      status: ModaoDownloadStatus.failed,
      downloadedBytes: 3 * 1024 * 1024,
      totalBytes: manifest.sizeBytes,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '游戏下载已中断',
      segmented: true,
      partCount: manifest.parts.length,
      retainedBytes: 3 * 1024 * 1024,
      transport: 'app_http',
      artifactKey: manifest.artifactKey,
      releaseKey: 'interrupted-release',
    );
  }

  @override
  Future<ModaoDeviceEnvironment> getDeviceEnvironment() async {
    return const ModaoDeviceEnvironment(
      freeBytes: 10 * 1024 * 1024 * 1024,
      networkType: 'wifi',
      connected: true,
      validated: true,
      metered: false,
    );
  }

  @override
  Future<ModaoDownloadState> startDownload(
    ModaoGameManifest manifest, {
    required bool allowMetered,
  }) async {
    startCalls++;
    expect(allowMetered, isFalse);
    return ModaoDownloadState(
      status: ModaoDownloadStatus.downloading,
      downloadedBytes: 3 * 1024 * 1024,
      totalBytes: manifest.sizeBytes,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '',
      segmented: true,
      partCount: manifest.parts.length,
      retainedBytes: 3 * 1024 * 1024,
      transport: 'app_http',
      artifactKey: manifest.artifactKey,
      releaseKey: 'resumed-release',
    );
  }
}

class _MergingGameService extends _FakeModaoGameService {
  @override
  Future<ModaoDownloadState> getDownloadState() async {
    return const ModaoDownloadState(
      status: ModaoDownloadStatus.merging,
      downloadedBytes: 200 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024,
      localPath: r'C:\games\modao-2023981000-aaaaaaaaaaaa.apk',
      reason: '正在合并安装包',
      segmented: true,
      partCount: 5,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formats a bounded human-readable download ETA', () {
    expect(formatModaoDownloadEta(9.1), '10秒');
    expect(formatModaoDownloadEta(61), '2分钟');
    expect(formatModaoDownloadEta(3660), '1小时1分钟');
    expect(formatModaoDownloadEta(double.infinity), isEmpty);
  });

  test('reserves enough space for a segmented APK merge', () {
    const mib = 1024 * 1024;
    const gib = 1024 * mib;

    expect(
      calculateModaoRequiredFreeBytes(apkSizeBytes: 2 * gib),
      (2 * gib) + (512 * mib),
    );
    expect(
      calculateModaoRequiredFreeBytes(
        apkSizeBytes: 2 * gib,
        partSizeBytes: const [400 * mib, 700 * mib, 300 * mib],
        retainedBytes: 1 * gib,
      ),
      (1 * gib) + (700 * mib),
    );
    expect(
      calculateModaoRequiredFreeBytes(apkSizeBytes: 8 * gib),
      (8 * gib) + ((8 * gib) ~/ 10 + 1),
    );
  });

  test('space budget saturates at the Android Long limit', () {
    const maxLong = 0x7FFFFFFFFFFFFFFF;

    expect(
      calculateModaoRequiredFreeBytes(
        apkSizeBytes: maxLong - 100,
        partSizeBytes: const [512 * 1024 * 1024],
      ),
      maxLong,
    );
  });

  testWidgets('shows aggregate speed and estimated remaining time', (
    tester,
  ) async {
    final service = _FakeModaoGameService();

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(find.textContaining('下载中 · 正在估算剩余时间'), findsWidgets);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('/s'), findsWidgets);
    expect(find.textContaining('预计剩余'), findsWidgets);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });

  testWidgets('automatically clears a legacy single-connection task', (
    tester,
  ) async {
    final service = _LegacyDownloadMigrationService();

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(service.clearCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('modao-download-button')),
      findsOneWidget,
    );
    expect(find.textContaining('下载中'), findsNothing);
  });

  testWidgets('migrates a matching DownloadManager task without clearing it', (
    tester,
  ) async {
    final service = _DownloadManagerMigrationService();

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(service.startCalls, 1);
    expect(service.clearCalls, 0);
  });

  testWidgets('keeps the old task when metered migration is declined', (
    tester,
  ) async {
    final service = _DownloadManagerMigrationService(metered: true);

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('使用移动网络继续下载？'), findsOneWidget);

    await tester.tap(find.text('暂不迁移'));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(service.startCalls, 0);
    expect(service.clearCalls, 0);
  });

  testWidgets('cold start resumes matching app HTTP partials on Wi-Fi', (
    tester,
  ) async {
    final service = _AppHttpRecoveryService();

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(service.startCalls, 1);
    expect(service.clearCalls, 0);
    expect(find.textContaining('下载中'), findsWidgets);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });

  testWidgets('keeps and verifies a completed legacy APK', (tester) async {
    final service = _CompletedLegacyDownloadService();

    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(service.clearCalls, 0);
    expect(service.verifyCalls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });

  testWidgets('keeps the merge phase active with a clear status label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ModaoGameScreen(token: 'token', service: _MergingGameService()),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(find.text('正在合并安装包'), findsWidgets);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });
}
