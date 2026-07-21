import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/reading_settings.dart';
import 'package:novel_app/providers/reading_provider.dart';

void main() {
  test('preview debounce persists only the latest settings snapshot', () async {
    final writes = <double>[];
    final provider = ReadingProvider(
      settingsSaveDebounce: const Duration(milliseconds: 20),
      ownerUserIdProvider: () => 'user-a',
      syncRevision: _RevisionSignal(),
      settingsLoader: (_) async => null,
      settingsSaver: (settings, _) async {
        writes.add((settings['fontSize'] as num).toDouble());
      },
    );
    addTearDown(provider.dispose);

    provider.previewSettings(provider.settings.copyWith(fontSize: 24));
    provider.previewSettings(provider.settings.copyWith(fontSize: 26));
    provider.previewSettings(provider.settings.copyWith(fontSize: 29));

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(writes, [29]);
  });

  test('a rebuilt provider restores every reader setting', () async {
    Map<String, dynamic>? persisted;
    final revision = _RevisionSignal();
    final first = ReadingProvider(
      settingsSaveDebounce: const Duration(hours: 1),
      ownerUserIdProvider: () => 'user-a',
      syncRevision: revision,
      settingsLoader: (_) async => persisted,
      settingsSaver: (settings, _) async {
        persisted = Map<String, dynamic>.from(settings);
      },
    );
    final expected = first.settings.copyWith(
      fontSize: 30,
      fontFamily: ReadingSettings.notoSerifFont,
      backgroundColor: '#C7EDCC',
      brightness: 0.45,
      useSystemBrightness: false,
      pageMode: NovelPageMode.cover,
      showLineHeight: true,
      nightMode: false,
      lineHeight: 1.6,
      paragraphSpacing: 1.2,
      horizontalPadding: 34,
      singleHandMode: true,
      volumeKeyTurnPage: true,
      keepScreenOn: true,
      autoReadSpeed: 2.5,
    );

    first.previewSettings(expected);
    await first.flushPendingSettings();
    first.dispose();

    final rebuilt = ReadingProvider(
      ownerUserIdProvider: () => 'user-a',
      syncRevision: revision,
      settingsLoader: (_) async => persisted,
      settingsSaver: (_, _) async {},
    );
    addTearDown(rebuilt.dispose);
    await rebuilt.loadSettings();

    expect(rebuilt.settings.toJson(), expected.toJson());
  });

  test(
    'an immediate flush persists a font preview before provider rebuild',
    () async {
      final persistedByOwner = <String, Map<String, dynamic>>{};
      final revision = _RevisionSignal();
      const owner = 'user-a';
      final first = ReadingProvider(
        settingsSaveDebounce: const Duration(hours: 1),
        ownerUserIdProvider: () => owner,
        syncRevision: revision,
        settingsLoader: (savedOwner) async => persistedByOwner[savedOwner],
        settingsSaver: (settings, savedOwner) async {
          persistedByOwner[savedOwner] = Map<String, dynamic>.from(settings);
        },
      );

      first.previewSettings(first.settings.copyWith(fontSize: 31));
      await first.flushPendingSettings();
      first.dispose();

      final rebuilt = ReadingProvider(
        ownerUserIdProvider: () => owner,
        syncRevision: revision,
        settingsLoader: (savedOwner) async => persistedByOwner[savedOwner],
        settingsSaver: (_, _) async {},
      );
      addTearDown(rebuilt.dispose);
      await rebuilt.loadSettings();

      expect(rebuilt.settings.fontSize, 31);
    },
  );

  test(
    'partial settings data does not trigger a layout migration write',
    () async {
      final writes = <Map<String, dynamic>>[];
      final provider = ReadingProvider(
        ownerUserIdProvider: () => 'user-a',
        syncRevision: _RevisionSignal(),
        settingsLoader: (_) async => <String, dynamic>{
          'brightness': 0.4,
          'useSystemBrightness': false,
        },
        settingsSaver: (settings, _) async {
          writes.add(Map<String, dynamic>.from(settings));
        },
      );
      addTearDown(provider.dispose);
      await provider.loadSettings();

      expect(writes, isEmpty);
      expect(provider.settings.fontSize, ReadingSettings.defaultFontSize);
      expect(provider.settings.brightness, 0.4);
      expect(provider.settings.useSystemBrightness, isFalse);
    },
  );

  test(
    'settings writes are serialized and finish with the latest value',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final started = <double>[];
      final completed = <double>[];
      var activeWrites = 0;
      var maxActiveWrites = 0;
      final provider = ReadingProvider(
        settingsSaveDebounce: const Duration(hours: 1),
        ownerUserIdProvider: () => 'user-a',
        syncRevision: _RevisionSignal(),
        settingsLoader: (_) async => null,
        settingsSaver: (settings, _) async {
          final fontSize = (settings['fontSize'] as num).toDouble();
          started.add(fontSize);
          activeWrites += 1;
          maxActiveWrites = maxActiveWrites < activeWrites
              ? activeWrites
              : maxActiveWrites;
          if (fontSize == 24) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          completed.add(fontSize);
          activeWrites -= 1;
        },
      );
      addTearDown(provider.dispose);

      provider.previewSettings(provider.settings.copyWith(fontSize: 24));
      final firstFlush = provider.flushPendingSettings();
      await firstStarted.future;

      provider.previewSettings(provider.settings.copyWith(fontSize: 31));
      final secondFlush = provider.flushPendingSettings();
      await Future<void>.delayed(Duration.zero);

      expect(started, [24]);
      releaseFirst.complete();
      await Future.wait([firstFlush, secondFlush]);

      expect(maxActiveWrites, 1);
      expect(completed, [24, 31]);
      expect(completed.last, 31);
    },
  );

  test('a failed settings flush keeps the latest snapshot for retry', () async {
    var attempts = 0;
    final completed = <double>[];
    final provider = ReadingProvider(
      settingsSaveDebounce: const Duration(hours: 1),
      ownerUserIdProvider: () => 'user-a',
      syncRevision: _RevisionSignal(),
      settingsLoader: (_) async => null,
      settingsSaver: (settings, _) async {
        attempts += 1;
        if (attempts == 1) throw StateError('storage unavailable');
        completed.add((settings['fontSize'] as num).toDouble());
      },
    );
    addTearDown(provider.dispose);

    provider.previewSettings(provider.settings.copyWith(fontSize: 30));
    await expectLater(provider.flushPendingSettings(), throwsStateError);

    await provider.flushPendingSettings();

    expect(attempts, 2);
    expect(completed, [30]);
  });

  test('preview captures the owner before a later account switch', () async {
    var owner = 'user-a';
    final writes = <({String owner, double fontSize})>[];
    final provider = ReadingProvider(
      settingsSaveDebounce: const Duration(hours: 1),
      ownerUserIdProvider: () => owner,
      syncRevision: _RevisionSignal(),
      settingsLoader: (_) async => null,
      settingsSaver: (settings, savedOwner) async {
        writes.add((
          owner: savedOwner,
          fontSize: (settings['fontSize'] as num).toDouble(),
        ));
      },
    );
    addTearDown(provider.dispose);

    provider.previewSettings(provider.settings.copyWith(fontSize: 28));
    owner = 'user-b';
    await provider.flushPendingSettings();

    expect(writes.single.owner, 'user-a');
    expect(writes.single.fontSize, 28);
  });

  test('load ignores a stale owner result', () async {
    var owner = 'user-a';
    final revision = _RevisionSignal();
    final firstLoad = Completer<Map<String, dynamic>?>();
    final provider = ReadingProvider(
      ownerUserIdProvider: () => owner,
      syncRevision: revision,
      settingsLoader: (_) => firstLoad.future,
      settingsSaver: (_, _) async {},
    );
    addTearDown(provider.dispose);

    final load = provider.loadSettings();
    owner = 'user-b';
    firstLoad.complete(ReadingSettings(fontSize: 32).toJson());
    await load;

    expect(provider.settings.fontSize, ReadingSettings.defaultFontSize);
  });

  test('load ignores a stale sync revision result', () async {
    final revision = _RevisionSignal();
    final firstLoad = Completer<Map<String, dynamic>?>();
    final provider = ReadingProvider(
      ownerUserIdProvider: () => 'user-a',
      syncRevision: revision,
      settingsLoader: (_) => firstLoad.future,
      settingsSaver: (_, _) async {},
    );
    addTearDown(provider.dispose);

    final load = provider.loadSettings();
    revision.incrementSilently();
    firstLoad.complete(ReadingSettings(fontSize: 32).toJson());
    await load;

    expect(provider.settings.fontSize, ReadingSettings.defaultFontSize);
  });

  test('remote revision cannot overwrite a pending local preview', () async {
    var persisted = ReadingSettings(fontSize: 18).toJson();
    final revision = _RevisionSignal();
    final provider = ReadingProvider(
      settingsSaveDebounce: const Duration(hours: 1),
      ownerUserIdProvider: () => 'user-a',
      syncRevision: revision,
      settingsLoader: (_) {
        final snapshot = Map<String, dynamic>.from(persisted);
        return Future<Map<String, dynamic>?>.delayed(
          Duration.zero,
          () => snapshot,
        );
      },
      settingsSaver: (settings, _) async {
        persisted = Map<String, dynamic>.from(settings);
      },
    );
    addTearDown(provider.dispose);

    provider.previewSettings(provider.settings.copyWith(fontSize: 29));
    revision.increment();
    await provider.flushPendingSettings();
    await Future<void>.delayed(Duration.zero);

    expect(provider.settings.fontSize, 29);
    expect((persisted['fontSize'] as num).toDouble(), 29);
  });

  test(
    'dispose schedules the captured pending snapshot for persistence',
    () async {
      final persisted = Completer<double>();
      final provider = ReadingProvider(
        settingsSaveDebounce: const Duration(hours: 1),
        ownerUserIdProvider: () => 'user-a',
        syncRevision: _RevisionSignal(),
        settingsLoader: (_) async => null,
        settingsSaver: (settings, _) async {
          persisted.complete((settings['fontSize'] as num).toDouble());
        },
      );

      provider.previewSettings(provider.settings.copyWith(fontSize: 27));
      provider.dispose();

      expect(await persisted.future, 27);
    },
  );
}

class _RevisionSignal extends ChangeNotifier implements ValueListenable<int> {
  @override
  int value = 0;

  void incrementSilently() {
    value += 1;
  }

  void increment() {
    value += 1;
    notifyListeners();
  }
}
