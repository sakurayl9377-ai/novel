import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'player_platform_service.dart';

enum ReaderPageCommand { previousPage, nextPage }

/// Owns Android-only controls that must never outlive a reader route.
///
/// A reader screen configures the shared instance when it becomes active,
/// listens to [pageCommands], and calls [releaseReaderSession] from dispose.
/// Configuration is idempotent, so settings changes can be applied without
/// recreating the route.
class ReaderPlatformService {
  ReaderPlatformService._(this._channel, this._supportedOverride) {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  static const String channelName = 'com.novel.novel_app/reader';

  static final ReaderPlatformService instance = ReaderPlatformService._(
    const MethodChannel(channelName),
    null,
  );

  @visibleForTesting
  factory ReaderPlatformService.forTesting(MethodChannel channel) {
    return ReaderPlatformService._(channel, true);
  }

  final MethodChannel _channel;
  final bool? _supportedOverride;
  final StreamController<ReaderPageCommand> _pageCommands =
      StreamController<ReaderPageCommand>.broadcast(sync: true);

  int _sessionGeneration = 0;
  bool _sessionActive = false;
  bool _volumeKeyTurnPage = false;
  bool _brightnessOverridden = false;
  bool _disposed = false;

  bool get isSessionActive => _sessionActive;

  Stream<ReaderPageCommand> get pageCommands => _pageCommands.stream;

  bool get _supportsNativeReaderActions =>
      _supportedOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<bool> configureReaderSession({
    required bool volumeKeyTurnPage,
    required bool keepScreenOn,
  }) async {
    if (_disposed || !_supportsNativeReaderActions) return false;

    final generation = ++_sessionGeneration;
    final previousActive = _sessionActive;
    final previousVolumeKeyTurnPage = _volumeKeyTurnPage;
    _sessionActive = true;
    _volumeKeyTurnPage = volumeKeyTurnPage;
    try {
      final configured =
          await _channel.invokeMethod<bool>('configureReaderSession', {
            'volumeKeyTurnPage': volumeKeyTurnPage,
            'keepScreenOn': keepScreenOn,
          }) ??
          true;
      if (generation != _sessionGeneration || _disposed) return false;
      if (!configured) {
        _sessionActive = previousActive;
        _volumeKeyTurnPage = previousVolumeKeyTurnPage;
      }
      return configured;
    } on MissingPluginException {
      if (generation == _sessionGeneration) {
        _sessionActive = previousActive;
        _volumeKeyTurnPage = previousVolumeKeyTurnPage;
      }
      return false;
    } on PlatformException {
      if (generation == _sessionGeneration) {
        _sessionActive = previousActive;
        _volumeKeyTurnPage = previousVolumeKeyTurnPage;
      }
      return false;
    }
  }

  /// Releases volume-key ownership, the reader wakelock, and any brightness
  /// override applied through this service. It is safe to call more than once.
  Future<void> releaseReaderSession() async {
    if (_disposed) return;
    ++_sessionGeneration;
    _sessionActive = false;
    _volumeKeyTurnPage = false;

    if (_brightnessOverridden) {
      _brightnessOverridden = false;
      await PlayerPlatformService.resetScreenBrightness();
    }
    if (!_supportsNativeReaderActions) return;
    try {
      await _channel.invokeMethod<bool>('releaseReaderSession');
    } on MissingPluginException {
      // Older builds do not expose reader-only platform controls.
    } on PlatformException {
      // The Flutter engine may already be detaching while a route disposes.
    }
  }

  Future<double> getScreenBrightness() {
    return PlayerPlatformService.getScreenBrightness();
  }

  Future<void> setScreenBrightness(double value) async {
    if (!_sessionActive || _disposed) return;
    _brightnessOverridden = true;
    await PlayerPlatformService.setScreenBrightness(value);
  }

  Future<void> resetScreenBrightness() async {
    if (!_brightnessOverridden || _disposed) return;
    _brightnessOverridden = false;
    await PlayerPlatformService.resetScreenBrightness();
  }

  @visibleForTesting
  Future<void> dispose() async {
    if (_disposed) return;
    await releaseReaderSession();
    _disposed = true;
    ++_sessionGeneration;
    _channel.setMethodCallHandler(null);
    await _pageCommands.close();
  }

  Future<void> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'onVolumeKey' ||
        !_sessionActive ||
        !_volumeKeyTurnPage ||
        _disposed) {
      return;
    }
    final arguments = call.arguments;
    final action = arguments is Map ? arguments['action'] as String? : null;
    final command = switch (action) {
      'previous' => ReaderPageCommand.previousPage,
      'next' => ReaderPageCommand.nextPage,
      _ => null,
    };
    if (command != null && !_pageCommands.isClosed) {
      _pageCommands.add(command);
    }
  }
}
