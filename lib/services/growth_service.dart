import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/growth_models.dart';
import 'interaction_auth_service.dart';
import 'storage_service.dart';
import 'swr_cache.dart';

class GrowthServiceException implements Exception {
  const GrowthServiceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class GrowthService {
  GrowthService({
    http.Client? httpClient,
    String? baseUrl,
    this.clientContextLoader,
    String Function()? idFactory,
    DateTime Function()? now,
  }) : _httpClient = httpClient ?? _sharedClient,
       _baseUrl = _normalizeBaseUrl(baseUrl ?? InteractionAuthService.baseUrl),
       _idFactory = idFactory ?? _uuid.v4,
       _now = now ?? DateTime.now;

  static final GrowthService instance = GrowthService();
  static final http.Client _sharedClient = http.Client();
  static const String _installIdKey = 'app_install_instance_id_v1';
  static const Uuid _uuid = Uuid();

  final http.Client _httpClient;
  final String _baseUrl;
  final Future<GrowthClientContext> Function()? clientContextLoader;
  final String Function() _idFactory;
  final DateTime Function() _now;
  final StorageService _storage = StorageService();
  final SwrCache<String, Object> _cache = SwrCache<String, Object>(
    freshTtl: const Duration(seconds: 45),
    staleTtl: const Duration(minutes: 8),
    maxEntries: 24,
  );

  AppBootstrapPayload _bootstrap = const AppBootstrapPayload();
  Future<GrowthClientContext>? _clientContextFuture;

  AppBootstrapPayload get bootstrap => _bootstrap;

  bool featureEnabled(String key, {bool fallback = false}) {
    final value = _bootstrap.features[key];
    if (value is bool) return value;
    if (value is Map) {
      final enabled = value['enabled'];
      if (enabled is bool) return enabled;
    }
    return fallback;
  }

  Future<AppBootstrapPayload> fetchBootstrap({
    String token = '',
    bool forceRefresh = false,
  }) async {
    final context = await _clientContext();
    final key = 'bootstrap:${_actorKey(token)}';
    final result = await _cache.get(
      key,
      forceRefresh: forceRefresh,
      loader: () async {
        final json = await _request(
          'GET',
          Uri.parse('$_baseUrl/app/bootstrap').replace(
            queryParameters: {
              'versionCode': '${context.versionCode}',
              'installId': context.installId,
              'platform': context.platform,
            },
          ),
          token: token,
        );
        return AppBootstrapPayload.fromJson(json);
      },
    );
    _bootstrap = result as AppBootstrapPayload;
    return _bootstrap;
  }

  Future<List<GrowthRecommendation>> fetchRecommendations({
    String token = '',
    String contentType = '',
    int limit = 20,
    bool forceRefresh = false,
  }) async {
    final context = await _clientContext();
    final type = _contentType(contentType);
    final safeLimit = limit.clamp(1, 50);
    final key = 'recommendations:${_actorKey(token)}:$type:$safeLimit';
    final result = await _cache.get(
      key,
      forceRefresh: forceRefresh,
      loader: () async {
        final json = await _request(
          'GET',
          Uri.parse('$_baseUrl/app/recommendations').replace(
            queryParameters: {
              if (type.isNotEmpty) 'contentType': type,
              'limit': '$safeLimit',
              'versionCode': '${context.versionCode}',
              'installId': context.installId,
              'platform': context.platform,
            },
          ),
          token: token,
        );
        return _items(
          json,
        ).map(GrowthRecommendation.fromJson).toList(growable: false);
      },
    );
    return (result as List).cast<GrowthRecommendation>();
  }

  Future<List<GrowthRankingItem>> fetchRankings({
    String token = '',
    String period = 'weekly',
    String metric = 'hot',
    String contentType = '',
    int limit = 30,
    bool forceRefresh = false,
  }) async {
    final type = _contentType(contentType);
    final safePeriod = period == 'daily' ? 'daily' : 'weekly';
    const metrics = {'hot', 'new', 'following', 'completion'};
    final safeMetric = metrics.contains(metric) ? metric : 'hot';
    final safeLimit = limit.clamp(1, 100);
    final key =
        'rankings:${_actorKey(token)}:$safePeriod:$safeMetric:$type:$safeLimit';
    final result = await _cache.get(
      key,
      forceRefresh: forceRefresh,
      loader: () async {
        final json = await _request(
          'GET',
          Uri.parse('$_baseUrl/app/rankings').replace(
            queryParameters: {
              'period': safePeriod,
              'metric': safeMetric,
              if (type.isNotEmpty) 'contentType': type,
              'limit': '$safeLimit',
            },
          ),
          token: token,
        );
        return _items(
          json,
        ).map(GrowthRankingItem.fromJson).toList(growable: false);
      },
    );
    return (result as List).cast<GrowthRankingItem>();
  }

  Future<List<ActivityCampaign>> fetchActivities({
    String token = '',
    bool forceRefresh = false,
  }) async {
    final context = await _clientContext();
    final key = 'activities:${_actorKey(token)}:${context.versionCode}';
    final result = await _cache.get(
      key,
      forceRefresh: forceRefresh,
      loader: () async {
        final json = await _request(
          'GET',
          Uri.parse(
            '$_baseUrl/app/activities',
          ).replace(queryParameters: {'versionCode': '${context.versionCode}'}),
          token: token,
        );
        return _items(
          json,
        ).map(ActivityCampaign.fromJson).toList(growable: false);
      },
    );
    return (result as List).cast<ActivityCampaign>();
  }

  Future<void> claimActivityTask({
    required String token,
    required int campaignId,
    required int taskId,
  }) async {
    await _request(
      'POST',
      Uri.parse('$_baseUrl/app/activities/$campaignId/tasks/$taskId/claim'),
      token: token,
      body: {'idempotencyKey': _idFactory()},
    );
    _cache.invalidatePrefix('activities:${_actorKey(token)}:');
  }

  Future<HorseRaceSeasonPayload> fetchHorseRaceSeason({
    String token = '',
    bool forceRefresh = false,
  }) async {
    final key = 'horse-season:${_actorKey(token)}';
    final result = await _cache.get(
      key,
      forceRefresh: forceRefresh,
      loader: () async {
        final json = await _request(
          'GET',
          Uri.parse('$_baseUrl/games/horse-race/season'),
          token: token,
        );
        return HorseRaceSeasonPayload.fromJson(_map(json['item']));
      },
    );
    return result as HorseRaceSeasonPayload;
  }

  Future<void> claimHorseRaceSeasonTask({
    required String token,
    required int taskId,
  }) async {
    await _request(
      'POST',
      Uri.parse('$_baseUrl/games/horse-race/season/tasks/$taskId/claim'),
      token: token,
      body: const {},
    );
    _cache.invalidate('horse-season:${_actorKey(token)}');
  }

  Future<ResponsibleGamingSettings> fetchResponsibleGaming({
    required String token,
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$_baseUrl/games/horse-race/responsible-gaming'),
      token: token,
    );
    return ResponsibleGamingSettings.fromJson(_map(json['item']));
  }

  Future<ResponsibleGamingSettings> updateResponsibleGaming({
    required String token,
    required int dailyBetLimit,
    required int dailyLossLimit,
    required int reminderLossThreshold,
  }) async {
    final json = await _request(
      'PATCH',
      Uri.parse('$_baseUrl/games/horse-race/responsible-gaming'),
      token: token,
      body: {
        'dailyBetLimit': dailyBetLimit,
        'dailyLossLimit': dailyLossLimit,
        'reminderLossThreshold': reminderLossThreshold,
      },
    );
    return ResponsibleGamingSettings.fromJson(_map(json['item']));
  }

  Future<ResponsibleGamingSettings> startCooldown({
    required String token,
    int hours = 24,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$_baseUrl/games/horse-race/responsible-gaming/cooldown'),
      token: token,
      body: {'hours': hours},
    );
    return ResponsibleGamingSettings.fromJson(_map(json['item']));
  }

  Future<ResponsibleGamingSettings> startSelfExclusion({
    required String token,
    int days = 7,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$_baseUrl/games/horse-race/responsible-gaming/self-exclusion'),
      token: token,
      body: {'days': days},
    );
    return ResponsibleGamingSettings.fromJson(_map(json['item']));
  }

  Future<void> recordBehavior({
    required GrowthContent content,
    required String event,
    required String source,
    String token = '',
  }) async {
    final context = await _clientContext();
    await _request(
      'POST',
      Uri.parse('$_baseUrl/app/behavior-events'),
      token: token,
      body: {
        'eventId': _idFactory(),
        'event': event,
        'source': source,
        'contentKey': content.stableKey,
        'installId': context.installId,
        'occurredAt': _now().toUtc().toIso8601String(),
        'versionCode': context.versionCode,
      },
    );
  }

  Future<GrowthClientContext> _clientContext() {
    return _clientContextFuture ??=
        (clientContextLoader?.call() ?? _loadClientContext());
  }

  Future<GrowthClientContext> _loadClientContext() async {
    final package = await PackageInfo.fromPlatform();
    await _storage.init();
    var installId = _storage.getString(_installIdKey)?.trim() ?? '';
    if (installId.isEmpty) {
      installId = _uuid.v4();
      await _storage.setString(_installIdKey, installId);
    }
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
    return GrowthClientContext(
      installId: installId,
      versionCode: int.tryParse(package.buildNumber) ?? 0,
      platform: platform,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    String token = '',
    Map<String, dynamic>? body,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };
    final response = switch (method) {
      'GET' =>
        await _httpClient
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15)),
      'POST' =>
        await _httpClient
            .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
            .timeout(const Duration(seconds: 15)),
      'PATCH' =>
        await _httpClient
            .patch(uri, headers: headers, body: jsonEncode(body ?? const {}))
            .timeout(const Duration(seconds: 15)),
      _ => throw ArgumentError.value(method, 'method'),
    };
    Map<String, dynamic> json = const {};
    if (response.bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) json = decoded.cast<String, dynamic>();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = (json['message'] ?? json['error'] ?? '请求失败').toString();
      throw GrowthServiceException(message, statusCode: response.statusCode);
    }
    return json;
  }

  String _actorKey(String token) => token.trim().isEmpty
      ? 'guest'
      : 'user:${token.trim().hashCode.toUnsigned(32)}';

  String _contentType(String value) {
    final type = value.trim().toLowerCase();
    return const {'novel', 'manga', 'anime'}.contains(type) ? type : '';
  }
}

class GrowthClientContext {
  const GrowthClientContext({
    required this.installId,
    required this.versionCode,
    required this.platform,
  });

  final String installId;
  final int versionCode;
  final String platform;
}

String _normalizeBaseUrl(String value) =>
    value.trim().replaceFirst(RegExp(r'/+$'), '');

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : const {};

List<Map<String, dynamic>> _items(Map<String, dynamic> json) {
  final value = json['items'];
  return value is List
      ? value.whereType<Map>().map((item) => _map(item)).toList()
      : const [];
}
