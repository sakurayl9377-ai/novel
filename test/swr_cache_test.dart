import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/swr_cache.dart';

void main() {
  group('SwrCache', () {
    late DateTime now;
    late SwrCache<String, int> cache;

    setUp(() {
      now = DateTime(2026, 7, 10, 12);
      cache = SwrCache<String, int>(
        freshTtl: const Duration(minutes: 1),
        staleTtl: const Duration(minutes: 4),
        maxEntries: 2,
        now: () => now,
      );
    });

    test('joins concurrent misses with one loader', () async {
      final completer = Completer<int>();
      var loads = 0;

      Future<int> load() {
        loads += 1;
        return completer.future;
      }

      final first = cache.get('book', loader: load);
      final second = cache.get('book', loader: load);
      expect(loads, 1);

      completer.complete(7);
      expect(await Future.wait([first, second]), [7, 7]);
      expect(cache.stats.singleflightJoins, 1);
    });

    test('returns fresh value without loading', () async {
      cache.put('book', 1);
      var loads = 0;

      final value = await cache.get('book', loader: () async => ++loads);

      expect(value, 1);
      expect(loads, 0);
      expect(cache.stats.freshHits, 1);
    });

    test('returns stale immediately and refreshes in background', () async {
      cache.put('book', 1);
      now = now.add(const Duration(minutes: 2));
      final completer = Completer<int>();
      var loads = 0;

      final value = await cache.get(
        'book',
        loader: () {
          loads += 1;
          return completer.future;
        },
      );

      expect(value, 1);
      expect(loads, 1);
      expect(cache.inflightCount, 1);
      completer.complete(2);
      await Future<void>.delayed(Duration.zero);
      expect(cache.peek('book'), 2);
      expect(cache.stats.staleHits, 1);
    });

    test(
      'stale callers do not wait for an existing background refresh',
      () async {
        cache.put('book', 4);
        now = now.add(const Duration(minutes: 2));
        final completer = Completer<int>();
        var loads = 0;

        Future<int> load() {
          loads += 1;
          return completer.future;
        }

        final first = await cache.get('book', loader: load);
        final second = await cache.get('book', loader: load);

        expect([first, second], [4, 4]);
        expect(loads, 1);
        expect(cache.inflightCount, 1);
        completer.complete(5);
        await Future<void>.delayed(Duration.zero);
        expect(cache.peek('book'), 5);
      },
    );

    test('falls back to stale value when refresh fails', () async {
      cache.put('book', 3);
      now = now.add(const Duration(minutes: 2));

      final value = await cache.refresh(
        'book',
        loader: () async => throw StateError('offline'),
      );

      expect(value, 3);
      expect(cache.stats.refreshFailures, 1);
      expect(cache.stats.staleFallbacks, 1);
    });

    test('evicts the least recently used entry', () {
      cache.put('a', 1);
      cache.put('b', 2);
      expect(cache.peek('a'), 1);
      cache.put('c', 3);

      expect(cache.stateOf('a'), SwrValueState.fresh);
      expect(cache.stateOf('b'), SwrValueState.missing);
      expect(cache.stateOf('c'), SwrValueState.fresh);
      expect(cache.stats.evictions, 1);
    });

    test('expires values after fresh and stale windows', () async {
      cache.put('book', 1);
      now = now.add(const Duration(minutes: 6));

      final value = await cache.get('book', loader: () async => 2);

      expect(value, 2);
      expect(cache.stats.misses, 1);
    });

    test('invalidates by key and prefix', () {
      cache.put('novel:1', 1);
      cache.put('novel:2', 2);
      expect(cache.invalidatePrefix('novel:'), 2);
      expect(cache.stateOf('novel:1'), SwrValueState.missing);
      expect(cache.stateOf('novel:2'), SwrValueState.missing);

      cache.put('manga:1', 3);
      cache.invalidate('manga:1');
      expect(cache.stateOf('manga:1'), SwrValueState.missing);
    });

    test(
      'invalidation prevents an older inflight value repopulating cache',
      () async {
        final oldCompleter = Completer<int>();
        final loading = cache.get('book', loader: () => oldCompleter.future);
        cache.invalidate('book');
        final replacement = cache.get('book', loader: () async => 10);
        oldCompleter.complete(9);

        expect(await loading, 9);
        expect(await replacement, 10);
        expect(cache.peek('book'), 10);
      },
    );
  });
}
