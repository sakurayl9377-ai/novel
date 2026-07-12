import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import 'interaction_auth_service.dart';
import 'storage_service.dart';

class AppTelemetryService {
  AppTelemetryService._();

  static final AppTelemetryService instance = AppTelemetryService._();

  static const String _installIdKey = 'app_install_instance_id_v1';
  static const String _eventQueueKey = 'app_telemetry_event_queue_v1';
  static const String _errorQueueKey = 'app_telemetry_error_queue_v1';
  static const MethodChannel _deviceChannel = MethodChannel(
    'com.novel.novel_app/app_info',
  );
  static const Uuid _uuid = Uuid();
  static final http.Client _httpClient = http.Client();

  final StorageService _storage = StorageService();
  final List<Map<String, dynamic>> _events = [];
  final List<Map<String, dynamic>> _errors = [];
  final List<_ActiveScreen> _activeScreens = [];

  bool _initialized = false;
  String _installId = '';
  String _sessionId = '';
  String _versionName = '';
  int _versionCode = 0;
  String _platform = '';
  String _osVersion = '';
  String _deviceModel = '';
  String _authToken = '';
  Future<void>? _flushInFlight;
  Timer? _flushTimer;
  DateTime? _backgroundStartedAt;

  int _frameCount = 0;
  int _slow16 = 0;
  int _slow32 = 0;
  int _frozen700 = 0;
  double _maxBuildMs = 0;
  double _maxRasterMs = 0;
  DateTime _lastFrameReportAt = DateTime.now();

  String get currentScreen =>
      _activeScreens.isEmpty ? '' : _activeScreens.last.name;

  Future<void> init() async {
    if (_initialized) return;
    final packageInfo = await PackageInfo.fromPlatform();
    _versionName = packageInfo.version.trim();
    _versionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    _sessionId = _uuid.v4();
    _installId = _storage.getString(_installIdKey)?.trim() ?? '';
    if (_installId.isEmpty) {
      _installId = _uuid.v4();
      await _storage.setString(_installIdKey, _installId);
    }
    final device = await _loadDeviceInfo();
    _platform = device.platform;
    _osVersion = device.osVersion;
    _deviceModel = device.deviceModel;
    _events.addAll(_readQueue(_eventQueueKey, maximum: 200));
    _errors.addAll(_readQueue(_errorQueueKey, maximum: 50));
    _initialized = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _flushTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(flush()),
    );
    trackEvent(
      'app_start',
      metadata: {
        'previousPendingEvents': _events.length,
        'previousPendingErrors': _errors.length,
      },
    );
    unawaited(flush());
  }

  void setAuthToken(String token) {
    _authToken = token.trim();
    if (_authToken.isNotEmpty) unawaited(flush());
  }

  void trackEvent(
    String name, {
    String screen = '',
    int durationMs = 0,
    bool? success,
    Map<String, Object?> metadata = const {},
    bool flushImmediately = false,
  }) {
    if (!_initialized) return;
    final eventName = _normalizeEventName(name);
    if (eventName.isEmpty) return;
    final event = <String, dynamic>{
      'name': eventName,
      if (screen.trim().isNotEmpty) 'screen': _limit(screen, 120),
      if (durationMs > 0) 'durationMs': durationMs.clamp(0, 3600000),
      if (metadata.isNotEmpty) 'metadata': _safeMetadata(metadata),
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (success != null) event['success'] = success;
    _events.add(event);
    if (_events.length > 200) {
      _events.removeRange(0, _events.length - 200);
    }
    unawaited(_persistQueues());
    if (flushImmediately || _events.length >= 12) unawaited(flush());
  }

  AppTelemetryScreenTrace openScreen(
    String name, {
    Map<String, Object?> metadata = const {},
  }) {
    final active = _ActiveScreen(_uuid.v4(), _limit(name, 120), DateTime.now());
    _activeScreens.add(active);
    trackEvent('screen_open', screen: active.name, metadata: metadata);
    return AppTelemetryScreenTrace._(this, active, metadata);
  }

  void captureFlutterError(FlutterErrorDetails details) {
    captureError(
      details.exception,
      details.stack ?? StackTrace.current,
      type: details.exception.runtimeType.toString(),
      fatal: false,
      metadata: {
        if (details.library?.isNotEmpty == true) 'library': details.library,
        if (details.context != null) 'context': details.context.toString(),
      },
    );
  }

  void captureError(
    Object error,
    StackTrace stack, {
    String type = '',
    bool fatal = false,
    String screen = '',
    Map<String, Object?> metadata = const {},
  }) {
    if (!_initialized) return;
    _errors.add({
      'type': _limit(type.isEmpty ? error.runtimeType.toString() : type, 120),
      'message': _limit(error.toString(), 2000),
      'stack': _limit(stack.toString(), 12000),
      if ((screen.isEmpty ? currentScreen : screen).isNotEmpty)
        'screen': _limit(screen.isEmpty ? currentScreen : screen, 120),
      'fatal': fatal,
      if (metadata.isNotEmpty) 'metadata': _safeMetadata(metadata),
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (_errors.length > 50) {
      _errors.removeRange(0, _errors.length - 50);
    }
    unawaited(_persistQueues());
    unawaited(flush());
  }

  void handleLifecycle(AppLifecycleState state) {
    if (!_initialized) return;
    if (state == AppLifecycleState.resumed) {
      final backgroundStartedAt = _backgroundStartedAt;
      _backgroundStartedAt = null;
      trackEvent(
        'app_foreground',
        durationMs: backgroundStartedAt == null
            ? 0
            : DateTime.now().difference(backgroundStartedAt).inMilliseconds,
      );
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _backgroundStartedAt ??= DateTime.now();
      _emitFrameMetrics();
      trackEvent('app_background', flushImmediately: true);
      if (state == AppLifecycleState.detached) {
        _flushTimer?.cancel();
        _flushTimer = null;
      }
    }
  }

  Future<void> flush() {
    final running = _flushInFlight;
    if (running != null) return running;
    late final Future<void> task;
    task = _flushOnce().whenComplete(() {
      if (identical(_flushInFlight, task)) _flushInFlight = null;
    });
    _flushInFlight = task;
    return task;
  }

  Future<void> _flushOnce() async {
    if (!_initialized || (_events.isEmpty && _errors.isEmpty)) return;
    final eventCount = _events.length.clamp(0, 50).toInt();
    final errorCount = _errors.length.clamp(0, 20).toInt();
    final eventBatch = _events.take(eventCount).toList(growable: false);
    final errorBatch = _errors.take(errorCount).toList(growable: false);
    try {
      final response = await _httpClient
          .post(
            Uri.parse('${InteractionAuthService.baseUrl}/app/telemetry/batch'),
            headers: {
              'content-type': 'application/json',
              if (_authToken.isNotEmpty) 'authorization': 'Bearer $_authToken',
            },
            body: jsonEncode({
              'installId': _installId,
              'sessionId': _sessionId,
              'versionName': _versionName,
              'versionCode': _versionCode,
              'platform': _platform,
              'osVersion': _osVersion,
              'deviceModel': _deviceModel,
              'events': eventBatch,
              'errors': errorBatch,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (eventCount > 0) _events.removeRange(0, eventCount);
        if (errorCount > 0) _errors.removeRange(0, errorCount);
        await _persistQueues();
      } else if (response.statusCode >= 400 &&
          response.statusCode < 500 &&
          response.statusCode != 429) {
        // A malformed queued item must not block all newer diagnostics.
        if (eventCount > 0) _events.removeRange(0, eventCount);
        if (errorCount > 0) _errors.removeRange(0, errorCount);
        await _persistQueues();
      }
    } catch (_) {
      // Diagnostics are best-effort and stay queued for the next foreground.
    }
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!_initialized) return;
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      final worstMs = buildMs > rasterMs ? buildMs : rasterMs;
      _frameCount += 1;
      if (worstMs > 16.7) _slow16 += 1;
      if (worstMs > 32) _slow32 += 1;
      if (worstMs > 700) _frozen700 += 1;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;
    }
    if (_frameCount >= 180 ||
        DateTime.now().difference(_lastFrameReportAt) >=
            const Duration(minutes: 1)) {
      _emitFrameMetrics();
    }
  }

  void _emitFrameMetrics() {
    if (_frameCount == 0) return;
    trackEvent(
      'frame_metrics',
      screen: currentScreen,
      metadata: {
        'frames': _frameCount,
        'slow16': _slow16,
        'slow32': _slow32,
        'frozen700': _frozen700,
        'maxBuildMs': double.parse(_maxBuildMs.toStringAsFixed(2)),
        'maxRasterMs': double.parse(_maxRasterMs.toStringAsFixed(2)),
      },
    );
    _frameCount = 0;
    _slow16 = 0;
    _slow32 = 0;
    _frozen700 = 0;
    _maxBuildMs = 0;
    _maxRasterMs = 0;
    _lastFrameReportAt = DateTime.now();
  }

  void _closeScreen(
    _ActiveScreen active, {
    required Map<String, Object?> initialMetadata,
    Map<String, Object?> metadata = const {},
    bool? success,
  }) {
    final index = _activeScreens.indexWhere((item) => item.id == active.id);
    if (index < 0) return;
    _activeScreens.removeAt(index);
    trackEvent(
      'screen_view',
      screen: active.name,
      durationMs: DateTime.now().difference(active.startedAt).inMilliseconds,
      success: success,
      metadata: {...initialMetadata, ...metadata},
    );
  }

  Future<void> _persistQueues() async {
    await Future.wait([
      _storage.setString(_eventQueueKey, jsonEncode(_events)),
      _storage.setString(_errorQueueKey, jsonEncode(_errors)),
    ]);
  }

  List<Map<String, dynamic>> _readQueue(String key, {required int maximum}) {
    final raw = _storage.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = decoded
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      return items.length <= maximum
          ? items
          : items.sublist(items.length - maximum);
    } catch (_) {
      return const [];
    }
  }

  Future<_RuntimeDeviceInfo> _loadDeviceInfo() async {
    final fallbackPlatform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
    try {
      final raw = await _deviceChannel.invokeMapMethod<String, dynamic>(
        'getDeviceInfo',
      );
      return _RuntimeDeviceInfo(
        platform: _text(raw?['platform'], fallbackPlatform),
        osVersion: _text(raw?['osVersion']),
        deviceModel: _text(raw?['deviceModel']),
      );
    } on MissingPluginException {
      return _RuntimeDeviceInfo(platform: fallbackPlatform);
    } on PlatformException {
      return _RuntimeDeviceInfo(platform: fallbackPlatform);
    }
  }

  Map<String, Object?> _safeMetadata(Map<String, Object?> value) {
    final result = <String, Object?>{};
    for (final entry in value.entries.take(30)) {
      final key = _limit(entry.key, 80);
      final item = entry.value;
      if (item == null || item is num || item is bool) {
        result[key] = item;
      } else {
        result[key] = _limit(item.toString(), 400);
      }
    }
    return result;
  }

  String _normalizeEventName(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  String _limit(Object? value, int maximum) {
    final text = value?.toString().trim() ?? '';
    return text.length <= maximum ? text : text.substring(0, maximum);
  }

  String _text(Object? value, [String fallback = '']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }
}

class AppTelemetryScreenTrace {
  AppTelemetryScreenTrace._(this._service, this._active, this._initialMetadata);

  final AppTelemetryService _service;
  final _ActiveScreen _active;
  final Map<String, Object?> _initialMetadata;
  bool _closed = false;

  void close({Map<String, Object?> metadata = const {}, bool? success}) {
    if (_closed) return;
    _closed = true;
    _service._closeScreen(
      _active,
      initialMetadata: _initialMetadata,
      metadata: metadata,
      success: success,
    );
  }
}

class _ActiveScreen {
  const _ActiveScreen(this.id, this.name, this.startedAt);

  final String id;
  final String name;
  final DateTime startedAt;
}

class _RuntimeDeviceInfo {
  const _RuntimeDeviceInfo({
    required this.platform,
    this.osVersion = '',
    this.deviceModel = '',
  });

  final String platform;
  final String osVersion;
  final String deviceModel;
}
