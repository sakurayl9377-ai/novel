import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/content_progress.dart';
import 'interaction_auth_service.dart';
import 'progress_database.dart';

class ProgressSyncPage {
  const ProgressSyncPage({
    required this.cursor,
    required this.items,
    required this.hasMore,
  });

  final String cursor;
  final List<ContentProgressRecord> items;
  final bool hasMore;
}

abstract class ProgressSyncApi {
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  });

  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  });
}

class HttpProgressSyncApi implements ProgressSyncApi {
  HttpProgressSyncApi({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  }) async {
    final response = await _client
        .post(
          Uri.parse('${InteractionAuthService.baseUrl}/users/me/progress/sync'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'deviceId': deviceId,
            'cursor': cursor,
            'items': items.map((item) => item.toSyncJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _parseResponse(response);
  }

  @override
  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  }) async {
    final uri = Uri.parse(
      '${InteractionAuthService.baseUrl}/users/me/progress',
    ).replace(queryParameters: {'cursor': cursor, 'limit': '$limit'});
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    return _parseResponse(response);
  }

  ProgressSyncPage _parseResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProgressSyncException(
        'Progress sync failed',
        statusCode: response.statusCode,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const ProgressSyncException('Invalid progress sync response');
    }
    if (decoded is! Map) {
      throw const ProgressSyncException('Invalid progress sync response');
    }
    final map = decoded.cast<String, dynamic>();
    final items = <ContentProgressRecord>[];
    final rawItems = map['items'];
    if (rawItems is List) {
      for (final raw in rawItems.whereType<Map>()) {
        try {
          items.add(
            ContentProgressRecord.fromSyncJson(raw.cast<String, dynamic>()),
          );
        } catch (_) {
          // One malformed server item must not discard the rest of the page.
        }
      }
    }
    return ProgressSyncPage(
      cursor: map['cursor']?.toString() ?? '',
      items: items,
      hasMore: map['hasMore'] == true,
    );
  }
}

class ProgressSyncException implements Exception {
  const ProgressSyncException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ProgressSyncService {
  ProgressSyncService({
    ProgressDatabase? database,
    ProgressSyncApi? api,
    Uuid? uuid,
  }) : _database = database ?? ProgressDatabase(),
       _api = api ?? HttpProgressSyncApi(),
       _uuid = uuid ?? const Uuid();

  static final ProgressSyncService instance = ProgressSyncService(
    database: appProgressDatabase,
  );

  static const Duration _foregroundThrottle = Duration(minutes: 2);
  static const String _deviceIdStateKey = 'progress_device_id';

  final ProgressDatabase _database;
  final ProgressSyncApi _api;
  final Uuid _uuid;
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  String _activeToken = '';
  String _activeUserId = '';
  int _sessionGeneration = 0;
  DateTime? _lastAttemptAt;
  Future<void> _syncChain = Future<void>.value();
  Timer? _localMutationTimer;

  String? get activeUserId => _activeUserId.isEmpty ? null : _activeUserId;
  String get activeOwnerUserId =>
      _activeUserId.isEmpty ? ProgressOwner.guest : _activeUserId;

  void bindSession({required String token, required String userId}) {
    final ownerChanged = _activeUserId != userId;
    _sessionGeneration += 1;
    final generation = _sessionGeneration;
    _activeToken = token;
    _activeUserId = userId;
    if (ownerChanged) revision.value += 1;
    unawaited(
      _adoptGuestAndSync(token: token, userId: userId, generation: generation),
    );
  }

  void clearSession() {
    _sessionGeneration += 1;
    _activeToken = '';
    _activeUserId = '';
    _localMutationTimer?.cancel();
    revision.value += 1;
  }

  void notifyLocalMutation() {
    if (_activeToken.isEmpty || _activeUserId.isEmpty) return;
    _localMutationTimer?.cancel();
    _localMutationTimer = Timer(const Duration(seconds: 15), () {
      unawaited(syncInBackground(force: true));
    });
  }

  Future<void> _adoptGuestAndSync({
    required String token,
    required String userId,
    required int generation,
  }) async {
    bool isSessionActive() =>
        generation == _sessionGeneration &&
        _activeToken == token &&
        _activeUserId == userId;

    final adopted = await _database.adoptGuestProgress(
      userId,
      isSessionActive: isSessionActive,
    );
    if (!isSessionActive()) return;
    if (adopted) revision.value += 1;
    await syncInBackground(force: true);
  }

  void handleLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(syncInBackground());
  }

  Future<void> syncInBackground({bool force = false}) async {
    final token = _activeToken;
    final userId = _activeUserId;
    if (token.isEmpty || userId.isEmpty) return;
    final lastAttemptAt = _lastAttemptAt;
    if (!force &&
        lastAttemptAt != null &&
        DateTime.now().difference(lastAttemptAt) < _foregroundThrottle) {
      return;
    }
    _lastAttemptAt = DateTime.now();
    final next = _syncChain.then((_) async {
      try {
        await syncNow(token: token, userId: userId);
      } catch (_) {
        // Reading and playback are fully offline-first. Dirty rows stay queued.
      }
    });
    _syncChain = next.then<void>((_) {}, onError: (_, _) {});
    await next;
  }

  Future<void> syncNow({required String token, required String userId}) async {
    await _database.init();
    final deviceId = await getDeviceId();
    var cursor = await _database.getState(_cursorKey(userId)) ?? '';
    var changed = false;
    var pushedAny = false;

    for (var batchIndex = 0; batchIndex < 20; batchIndex++) {
      final dirty = await _database.claimDirty(userId);
      if (dirty.isEmpty) break;
      pushedAny = true;
      final page = await _api.push(
        token: token,
        deviceId: deviceId,
        cursor: cursor,
        items: dirty,
      );
      await _database.markClean(userId, dirty);
      changed = await _applyPage(page, userId: userId) || changed;
      cursor = page.cursor.isEmpty ? cursor : page.cursor;
      await _database.setState(_cursorKey(userId), cursor);
      if (page.hasMore) {
        final result = await _pullRemaining(
          token: token,
          userId: userId,
          cursor: cursor,
        );
        cursor = result.cursor;
        changed = result.changed || changed;
      }
    }
    if (!pushedAny) {
      final result = await _pullRemaining(
        token: token,
        userId: userId,
        cursor: cursor,
      );
      cursor = result.cursor;
      changed = result.changed;
    }

    await _database.setState(_cursorKey(userId), cursor);
    if (changed) revision.value += 1;
  }

  Future<({String cursor, bool changed})> _pullRemaining({
    required String token,
    required String userId,
    required String cursor,
  }) async {
    var nextCursor = cursor;
    var changed = false;
    for (var pageIndex = 0; pageIndex < 20; pageIndex++) {
      final page = await _api.pull(
        token: token,
        cursor: nextCursor,
        limit: 100,
      );
      changed = await _applyPage(page, userId: userId) || changed;
      if (page.cursor.isNotEmpty) nextCursor = page.cursor;
      await _database.setState(_cursorKey(userId), nextCursor);
      if (!page.hasMore) break;
    }
    return (cursor: nextCursor, changed: changed);
  }

  Future<bool> _applyPage(
    ProgressSyncPage page, {
    required String userId,
  }) async {
    var changed = false;
    for (final item in page.items) {
      changed = await _database.applyRemote(item, userId: userId) || changed;
    }
    return changed;
  }

  Future<String> getDeviceId() async {
    final existing = await _database.getState(_deviceIdStateKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = _uuid.v4();
    await _database.setState(_deviceIdStateKey, generated);
    return generated;
  }

  static String _cursorKey(String userId) => 'progress_cursor_user_$userId';
}

final ProgressDatabase appProgressDatabase = ProgressDatabase();
