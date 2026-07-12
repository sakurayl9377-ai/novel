import 'dart:async';
import 'dart:collection';

/// A bounded in-memory stale-while-revalidate cache.
///
/// Values younger than [freshTtl] are returned directly. Values inside the
/// following [staleTtl] window are returned immediately while one shared
/// background refresh runs. A failed refresh falls back to the stale value.
class SwrCache<K, V> {
  SwrCache({
    required this.freshTtl,
    required this.staleTtl,
    required this.maxEntries,
    DateTime Function()? now,
  }) : assert(!freshTtl.isNegative),
       assert(!staleTtl.isNegative),
       assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  final Duration freshTtl;
  final Duration staleTtl;
  final int maxEntries;
  final DateTime Function() _now;

  final LinkedHashMap<K, _SwrEntry<V>> _entries =
      LinkedHashMap<K, _SwrEntry<V>>();
  final Map<K, Future<V>> _inflight = <K, Future<V>>{};
  final Map<K, int> _versions = <K, int>{};
  final SwrCacheStats stats = SwrCacheStats();

  int get length => _entries.length;
  int get inflightCount => _inflight.length;

  /// Returns true when [key] has a fresh or stale (but not expired) value.
  bool containsUsable(K key) {
    final entry = _entries[key];
    if (entry == null) return false;
    if (_stateOf(entry) == SwrValueState.expired) {
      _entries.remove(key);
      return false;
    }
    return true;
  }

  /// Reads a cached value without triggering a refresh or changing statistics.
  V? peek(K key, {bool allowExpired = false}) {
    final entry = _entries[key];
    if (entry == null) return null;
    final state = _stateOf(entry);
    if (!allowExpired && state == SwrValueState.expired) {
      _entries.remove(key);
      return null;
    }
    _touch(key, entry);
    return entry.value;
  }

  SwrValueState stateOf(K key) {
    final entry = _entries[key];
    return entry == null ? SwrValueState.missing : _stateOf(entry);
  }

  /// Inserts a value and makes it the most recently used entry.
  void put(K key, V value, {DateTime? writtenAt}) {
    _putEntry(key, _SwrEntry<V>(value, writtenAt ?? _now()));
  }

  /// Gets a value using stale-while-revalidate semantics.
  Future<V> get(
    K key, {
    required Future<V> Function() loader,
    bool forceRefresh = false,
    bool revalidateStale = true,
  }) {
    final entry = _entries[key];
    final state = entry == null ? SwrValueState.missing : _stateOf(entry);

    if (!forceRefresh && entry != null && state == SwrValueState.fresh) {
      stats.freshHits += 1;
      _touch(key, entry);
      return Future<V>.value(entry.value);
    }

    if (!forceRefresh && entry != null && state == SwrValueState.stale) {
      stats.staleHits += 1;
      _touch(key, entry);
      if (revalidateStale) {
        unawaited(_refreshInBackground(key, loader));
      }
      return Future<V>.value(entry.value);
    }

    if (state == SwrValueState.expired) {
      _entries.remove(key);
    }

    if (!forceRefresh) stats.misses += 1;
    return refresh(key, loader: loader);
  }

  /// Forces a shared refresh. Concurrent refreshes for the same key join the
  /// same future. A usable stale value is returned if the loader fails.
  Future<V> refresh(K key, {required Future<V> Function() loader}) {
    final running = _inflight[key];
    if (running != null) {
      stats.singleflightJoins += 1;
      return running;
    }

    final fallback = _entries[key];
    final fallbackUsable =
        fallback != null && _stateOf(fallback) != SwrValueState.expired;
    final version = _versions[key] ?? 0;
    late final Future<V> task;
    task = Future<V>.sync(loader)
        .then(
          (value) {
            stats.refreshSuccesses += 1;
            if ((_versions[key] ?? 0) == version) put(key, value);
            return value;
          },
          onError: (Object error, StackTrace stackTrace) {
            stats.refreshFailures += 1;
            if (fallbackUsable) {
              stats.staleFallbacks += 1;
              return fallback.value;
            }
            Error.throwWithStackTrace(error, stackTrace);
          },
        )
        .whenComplete(() {
          if (identical(_inflight[key], task)) _inflight.remove(key);
        });
    _inflight[key] = task;
    return task;
  }

  void invalidate(K key) {
    _entries.remove(key);
    _inflight.remove(key);
    _versions[key] = (_versions[key] ?? 0) + 1;
    stats.invalidations += 1;
  }

  int invalidateWhere(bool Function(K key) predicate) {
    final keys = <K>{
      ..._entries.keys.where(predicate),
      ..._inflight.keys.where(predicate),
    };
    for (final key in keys) {
      invalidate(key);
    }
    return keys.length;
  }

  int invalidatePrefix(String prefix, {String Function(K key)? stringifyKey}) {
    return invalidateWhere(
      (key) => (stringifyKey?.call(key) ?? key.toString()).startsWith(prefix),
    );
  }

  void clear() {
    final keys = <K>{..._entries.keys, ..._inflight.keys};
    _entries.clear();
    _inflight.clear();
    for (final key in keys) {
      _versions[key] = (_versions[key] ?? 0) + 1;
    }
    stats.invalidations += keys.length;
  }

  Future<void> _refreshInBackground(K key, Future<V> Function() loader) async {
    try {
      await refresh(key, loader: loader);
    } catch (_) {
      // Background revalidation is best-effort. The stale value has already
      // been returned, and failures remain visible through [stats].
    }
  }

  SwrValueState _stateOf(_SwrEntry<V> entry) {
    final age = _now().difference(entry.writtenAt);
    if (age <= freshTtl) return SwrValueState.fresh;
    if (age <= freshTtl + staleTtl) return SwrValueState.stale;
    return SwrValueState.expired;
  }

  void _touch(K key, _SwrEntry<V> entry) {
    _entries.remove(key);
    _entries[key] = entry;
  }

  void _putEntry(K key, _SwrEntry<V> entry) {
    _entries.remove(key);
    _entries[key] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
      stats.evictions += 1;
    }
  }
}

enum SwrValueState { missing, fresh, stale, expired }

class SwrCacheStats {
  int freshHits = 0;
  int staleHits = 0;
  int misses = 0;
  int singleflightJoins = 0;
  int refreshSuccesses = 0;
  int refreshFailures = 0;
  int staleFallbacks = 0;
  int evictions = 0;
  int invalidations = 0;

  Map<String, int> toTelemetryMetadata({String prefix = 'cache'}) => {
    '${prefix}FreshHits': freshHits,
    '${prefix}StaleHits': staleHits,
    '${prefix}Misses': misses,
    '${prefix}SingleflightJoins': singleflightJoins,
    '${prefix}RefreshSuccesses': refreshSuccesses,
    '${prefix}RefreshFailures': refreshFailures,
    '${prefix}StaleFallbacks': staleFallbacks,
    '${prefix}Evictions': evictions,
    '${prefix}Invalidations': invalidations,
  };
}

class _SwrEntry<V> {
  const _SwrEntry(this.value, this.writtenAt);

  final V value;
  final DateTime writtenAt;
}
