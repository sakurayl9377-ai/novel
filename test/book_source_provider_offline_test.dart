import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/book_source.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/providers/book_source_provider.dart';
import 'package:novel_app/services/book_source_service.dart';
import 'package:novel_app/services/progress_sync_service.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'chapter loading falls back to the persistent offline catalog',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'book-source-offline-catalog-',
      );
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => call.method == 'getApplicationDocumentsDirectory'
                ? root.path
                : null,
          );
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        await appProgressDatabase.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final novel = Novel(
        id: 'offline-book',
        title: 'Offline book',
        sourceId: 'offline-source',
        chapterUrl: 'https://offline.example/book/1',
      );
      final chapters = List<Chapter>.generate(
        3,
        (index) => Chapter(
          id: 'offline-$index',
          novelId: novel.id,
          title: 'Chapter $index',
          index: index,
          url: 'https://offline.example/book/1/${index + 1}',
        ),
      );
      final storage = StorageService();
      await storage.init();
      await storage.savePersistentNovelChapterList(novel, chapters);
      final provider = BookSourceProvider.forTesting(
        sources: [_OfflineBookSourceService.source],
        selectedSourceId: _OfflineBookSourceService.source.id,
        sourceService: _OfflineBookSourceService(),
      );
      addTearDown(provider.dispose);

      final restored = await provider.getChapterList(novel);

      expect(
        restored.map((chapter) => chapter.id),
        chapters.map((item) => item.id),
      );
      expect(restored.map((chapter) => chapter.index), <int>[0, 1, 2]);
    },
  );

  test(
    'network catalog refresh keeps uniquely matched downloaded content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'book-source-refresh-catalog-',
      );
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => call.method == 'getApplicationDocumentsDirectory'
                ? root.path
                : null,
          );
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        await appProgressDatabase.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final novel = Novel(
        id: 'refresh-book',
        title: 'Refresh book',
        sourceId: _RefreshingBookSourceService.source.id,
        chapterUrl: 'https://refresh.example/book/1',
      );
      final original = <Chapter>[
        Chapter(
          id: '${novel.id}_ch0',
          novelId: novel.id,
          title: 'Alpha',
          index: 0,
          url: 'https://refresh.example/book/1/1.html',
        ),
      ];
      final refreshed = <Chapter>[
        Chapter(
          id: '${novel.id}_ch0',
          novelId: novel.id,
          title: 'Inserted',
          index: 0,
          url: 'https://mirror.example/book/1/1.html',
        ),
        Chapter(
          id: '${novel.id}_ch1',
          novelId: novel.id,
          title: 'Alpha',
          index: 1,
          url: 'https://mirror.example/book/1/2.html',
        ),
      ];
      final storage = StorageService();
      await storage.init();
      await storage.savePersistentNovelChapterList(novel, original);
      await storage.saveDownloadedNovelChapter(
        novel,
        original.single,
        'alpha body',
      );
      final sourceService = _RefreshingBookSourceService(refreshed);
      final provider = BookSourceProvider.forTesting(
        sources: [_RefreshingBookSourceService.source],
        selectedSourceId: _RefreshingBookSourceService.source.id,
        sourceService: sourceService,
        storage: storage,
      );
      addTearDown(provider.dispose);

      final loaded = await provider.getChapterList(novel);
      final content = await provider.getChapterContent(novel, loaded[1]);

      expect(loaded.map((chapter) => chapter.title), <String>[
        'Inserted',
        'Alpha',
      ]);
      expect(content, 'alpha body');
      expect(sourceService.contentLoadCount, 0);
      expect(
        (await storage.getPersistentNovelChapterList(
          novel,
        )).map((chapter) => chapter.url),
        refreshed.map((chapter) => chapter.url),
      );
    },
  );
}

class _OfflineBookSourceService extends BookSourceService {
  static final BookSource source = BookSource(
    id: 'offline-source',
    name: 'Offline source',
    baseUrl: 'https://offline.example',
  );

  @override
  Future<List<Chapter>> getChapterList(
    Novel novel, {
    bool forceRefresh = false,
  }) async {
    throw const SocketException('offline');
  }
}

class _RefreshingBookSourceService extends BookSourceService {
  _RefreshingBookSourceService(this.chapters);

  static final BookSource source = BookSource(
    id: 'refresh-source',
    name: 'Refresh source',
    baseUrl: 'https://refresh.example',
  );

  final List<Chapter> chapters;
  int contentLoadCount = 0;

  @override
  Future<List<Chapter>> getChapterList(
    Novel novel, {
    bool forceRefresh = false,
  }) async => chapters;

  @override
  Future<String> getChapterContent(Chapter chapter, BookSource source) async {
    contentLoadCount += 1;
    throw const SocketException('offline');
  }
}
