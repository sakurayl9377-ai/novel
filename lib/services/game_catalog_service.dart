import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'interaction_auth_service.dart';

enum GameCatalogSource { network, cache, fallback }

class GameCatalogSnapshot {
  GameCatalogSnapshot({required Iterable<String> gameIds, required this.source})
    : gameIds = List<String>.unmodifiable(gameIds);

  final List<String> gameIds;
  final GameCatalogSource source;

  bool get isStale => source != GameCatalogSource.network;
}

class GameCatalogService {
  GameCatalogService({
    this.httpClient,
    this.preferences,
    this.timeout = const Duration(seconds: 8),
  });

  static const String cacheKey = 'game_catalog_enabled_ids_v1';
  static const int maxResponseBytes = 64 * 1024;
  static const List<String> safeFallbackGameIds = <String>['horse-race'];

  static const Map<String, _KnownGame> _knownGames = <String, _KnownGame>{
    'horse-race': _KnownGame(route: 'horse-race', entryType: 'native'),
    'bailian': _KnownGame(route: 'bailian', entryType: 'web'),
    'modao': _KnownGame(route: 'modao', entryType: 'apk'),
  };

  static final http.Client _sharedHttpClient = http.Client();

  final http.Client? httpClient;
  final SharedPreferences? preferences;
  final Duration timeout;

  Future<GameCatalogSnapshot> load() async {
    try {
      final request =
          http.Request(
              'GET',
              Uri.parse('${InteractionAuthService.baseUrl}/games/catalog'),
            )
            ..followRedirects = false
            ..headers.addAll(const <String, String>{
              'Accept': 'application/json',
              'Accept-Encoding': 'identity',
            });
      final response = await (httpClient ?? _sharedHttpClient)
          .send(request)
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw const FormatException('Game catalog request failed');
      }
      final contentEncoding = response.headers['content-encoding']
          ?.trim()
          .toLowerCase();
      if (contentEncoding != null &&
          contentEncoding.isNotEmpty &&
          contentEncoding != 'identity') {
        throw const FormatException('Compressed game catalog rejected');
      }
      if ((response.contentLength ?? 0) > maxResponseBytes) {
        throw const FormatException('Game catalog response too large');
      }

      final bodyBytes = await _readBounded(response.stream).timeout(timeout);
      final gameIds = _parseEnabledGameIds(bodyBytes);
      await _cache(gameIds);
      return GameCatalogSnapshot(
        gameIds: gameIds,
        source: GameCatalogSource.network,
      );
    } catch (_) {
      final cached = await _readCache();
      if (cached != null) {
        return GameCatalogSnapshot(
          gameIds: _failClosedGames(cached),
          source: GameCatalogSource.cache,
        );
      }
      return GameCatalogSnapshot(
        gameIds: safeFallbackGameIds,
        source: GameCatalogSource.fallback,
      );
    }
  }

  List<String> _failClosedGames(Iterable<String> gameIds) {
    return gameIds
        .where((id) => _knownGames[id]?.entryType == 'native')
        .toList(growable: false);
  }

  Future<List<int>> _readBounded(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const FormatException('Game catalog response too large');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  List<String> _parseEnabledGameIds(List<int> bodyBytes) {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map || decoded['games'] is! List) {
      throw const FormatException('Invalid game catalog');
    }

    final candidates = <_CatalogCandidate>[];
    final games = decoded['games'] as List<dynamic>;
    for (var index = 0; index < games.length; index += 1) {
      final raw = games[index];
      if (raw is! Map) continue;

      final id = raw['id']?.toString().trim() ?? '';
      final known = _knownGames[id];
      if (known == null || raw['route'] != known.route) continue;
      if (raw['entryType'] != known.entryType) continue;
      if (raw['visible'] != true || raw['enabled'] != true) continue;

      final sortOrder = switch (raw['sortOrder']) {
        int value => value,
        num value => value.toInt(),
        _ => index,
      };
      candidates.add(
        _CatalogCandidate(id: id, sortOrder: sortOrder, responseIndex: index),
      );
    }

    candidates.sort((left, right) {
      final byOrder = left.sortOrder.compareTo(right.sortOrder);
      return byOrder != 0
          ? byOrder
          : left.responseIndex.compareTo(right.responseIndex);
    });

    final ids = <String>[];
    for (final candidate in candidates) {
      if (!ids.contains(candidate.id)) ids.add(candidate.id);
    }
    return ids;
  }

  Future<void> _cache(List<String> gameIds) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.setStringList(cacheKey, gameIds);
    } catch (_) {
      // A successful network response remains usable even if local storage fails.
    }
  }

  Future<List<String>?> _readCache() async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      if (!prefs.containsKey(cacheKey)) return null;
      final cached = prefs.getStringList(cacheKey) ?? const <String>[];
      final sanitized = <String>[];
      for (final id in cached) {
        if (_knownGames.containsKey(id) && !sanitized.contains(id)) {
          sanitized.add(id);
        }
      }
      return sanitized;
    } catch (_) {
      return null;
    }
  }
}

class _KnownGame {
  const _KnownGame({required this.route, required this.entryType});

  final String route;
  final String entryType;
}

class _CatalogCandidate {
  const _CatalogCandidate({
    required this.id,
    required this.sortOrder,
    required this.responseIndex,
  });

  final String id;
  final int sortOrder;
  final int responseIndex;
}
