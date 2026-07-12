import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/novel.dart';

typedef TtsMediaAction = Future<void> Function();

enum TtsNotificationIssue {
  none,
  runtimePermissionDenied,
  appNotificationsDisabled,
  notificationsPaused,
  channelMissing,
  channelDisabled,
  channelImportanceTooLow,
  channelNotPublic,
  lockScreenNotificationsDisabled,
}

enum TtsNotificationSettingsTarget { app, channel, lockScreen }

class TtsNotificationStatus {
  const TtsNotificationStatus({
    required this.available,
    required this.sdkInt,
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.isVivoOriginOs,
    required this.runtimePermissionRequired,
    required this.runtimePermissionGranted,
    required this.permissionPermanentlyDenied,
    required this.mediaNotificationPermissionExempt,
    required this.appNotificationsEnabled,
    required this.notificationsPaused,
    required this.channelSupported,
    required this.channelExists,
    required this.channelImportance,
    required this.channelEnabled,
    required this.channelImportanceSufficient,
    required this.channelLockscreenVisibility,
    required this.channelPublic,
    required this.lockScreenSettingKnown,
    required this.lockScreenNotificationsEnabled,
    required this.lockScreenPrivateContentAllowed,
    required this.deviceSecure,
    required this.canShowNotification,
    required this.canShowLockScreenCard,
  });

  const TtsNotificationStatus.notApplicable()
    : available = false,
      sdkInt = 0,
      manufacturer = '',
      brand = '',
      model = '',
      isVivoOriginOs = false,
      runtimePermissionRequired = false,
      runtimePermissionGranted = true,
      permissionPermanentlyDenied = false,
      mediaNotificationPermissionExempt = false,
      appNotificationsEnabled = true,
      notificationsPaused = false,
      channelSupported = false,
      channelExists = true,
      channelImportance = 3,
      channelEnabled = true,
      channelImportanceSufficient = true,
      channelLockscreenVisibility = 1,
      channelPublic = true,
      lockScreenSettingKnown = false,
      lockScreenNotificationsEnabled = null,
      lockScreenPrivateContentAllowed = null,
      deviceSecure = false,
      canShowNotification = true,
      canShowLockScreenCard = true;

  final bool available;
  final int sdkInt;
  final String manufacturer;
  final String brand;
  final String model;
  final bool isVivoOriginOs;
  final bool runtimePermissionRequired;
  final bool runtimePermissionGranted;
  final bool permissionPermanentlyDenied;
  final bool mediaNotificationPermissionExempt;
  final bool appNotificationsEnabled;
  final bool notificationsPaused;
  final bool channelSupported;
  final bool channelExists;
  final int channelImportance;
  final bool channelEnabled;
  final bool channelImportanceSufficient;
  final int channelLockscreenVisibility;
  final bool channelPublic;
  final bool lockScreenSettingKnown;
  final bool? lockScreenNotificationsEnabled;
  final bool? lockScreenPrivateContentAllowed;
  final bool deviceSecure;
  final bool canShowNotification;
  final bool canShowLockScreenCard;

  factory TtsNotificationStatus.fromMap(
    Map<Object?, Object?> map, {
    bool permissionPermanentlyDenied = false,
  }) {
    return TtsNotificationStatus(
      available: map.isNotEmpty,
      sdkInt: _statusInt(map['sdkInt']),
      manufacturer: map['manufacturer']?.toString() ?? '',
      brand: map['brand']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      isVivoOriginOs: _statusBool(map['isVivoOriginOs']),
      runtimePermissionRequired: _statusBool(map['runtimePermissionRequired']),
      runtimePermissionGranted: _statusBool(
        map['runtimePermissionGranted'],
        fallback: true,
      ),
      permissionPermanentlyDenied: permissionPermanentlyDenied,
      mediaNotificationPermissionExempt: _statusBool(
        map['mediaNotificationPermissionExempt'],
      ),
      appNotificationsEnabled: _statusBool(
        map['appNotificationsEnabled'],
        fallback: true,
      ),
      notificationsPaused: _statusBool(map['notificationsPaused']),
      channelSupported: _statusBool(map['channelSupported']),
      channelExists: _statusBool(map['channelExists'], fallback: true),
      channelImportance: _statusInt(map['channelImportance']),
      channelEnabled: _statusBool(map['channelEnabled'], fallback: true),
      channelImportanceSufficient: _statusBool(
        map['channelImportanceSufficient'],
        fallback: true,
      ),
      channelLockscreenVisibility: _statusInt(
        map['channelLockscreenVisibility'],
      ),
      channelPublic: _statusBool(map['channelPublic'], fallback: true),
      lockScreenSettingKnown: _statusBool(map['lockScreenSettingKnown']),
      lockScreenNotificationsEnabled: _statusNullableBool(
        map['lockScreenNotificationsEnabled'],
      ),
      lockScreenPrivateContentAllowed: _statusNullableBool(
        map['lockScreenPrivateContentAllowed'],
      ),
      deviceSecure: _statusBool(map['deviceSecure']),
      canShowNotification: _statusBool(
        map['canShowNotification'],
        fallback: true,
      ),
      canShowLockScreenCard: _statusBool(
        map['canShowLockScreenCard'],
        fallback: true,
      ),
    );
  }

  TtsNotificationIssue get issue {
    if (!available) return TtsNotificationIssue.none;
    if (runtimePermissionRequired && !runtimePermissionGranted) {
      return TtsNotificationIssue.runtimePermissionDenied;
    }
    if (!appNotificationsEnabled) {
      return TtsNotificationIssue.appNotificationsDisabled;
    }
    if (notificationsPaused) return TtsNotificationIssue.notificationsPaused;
    if (channelSupported && !channelExists) {
      return TtsNotificationIssue.channelMissing;
    }
    if (!channelEnabled) return TtsNotificationIssue.channelDisabled;
    if (!channelImportanceSufficient) {
      return TtsNotificationIssue.channelImportanceTooLow;
    }
    if (!channelPublic) return TtsNotificationIssue.channelNotPublic;
    if (lockScreenSettingKnown && lockScreenNotificationsEnabled == false) {
      return TtsNotificationIssue.lockScreenNotificationsDisabled;
    }
    return TtsNotificationIssue.none;
  }

  TtsNotificationSettingsTarget get settingsTarget {
    return switch (issue) {
      TtsNotificationIssue.channelMissing ||
      TtsNotificationIssue.channelDisabled ||
      TtsNotificationIssue.channelImportanceTooLow ||
      TtsNotificationIssue.channelNotPublic =>
        TtsNotificationSettingsTarget.channel,
      TtsNotificationIssue.lockScreenNotificationsDisabled =>
        TtsNotificationSettingsTarget.lockScreen,
      _ => TtsNotificationSettingsTarget.app,
    };
  }

  String get guidanceTitle {
    return switch (issue) {
      TtsNotificationIssue.runtimePermissionDenied => '通知权限未开启',
      TtsNotificationIssue.appNotificationsDisabled => 'Sakura 通知已关闭',
      TtsNotificationIssue.notificationsPaused => 'Sakura 通知已被系统暂停',
      TtsNotificationIssue.channelMissing => '听书通知频道不可用',
      TtsNotificationIssue.channelDisabled => '“听书播放”频道已关闭',
      TtsNotificationIssue.channelImportanceTooLow => '听书通知被设为最低级别',
      TtsNotificationIssue.channelNotPublic => '锁屏内容被限制',
      TtsNotificationIssue.lockScreenNotificationsDisabled => '锁屏通知已关闭',
      TtsNotificationIssue.none => '听书锁屏卡片已就绪',
    };
  }

  String get guidanceMessage {
    return switch (issue) {
      TtsNotificationIssue.runtimePermissionDenied =>
        mediaNotificationPermissionExempt
            ? 'Android 13 及以上的标准媒体通知可获得系统豁免，但部分品牌仍会在通知权限关闭时隐藏锁屏卡片。听书可以继续播放，建议开启 Sakura 通知以稳定显示控制卡片。'
            : '系统尚未授予通知权限。听书可以继续播放，但通知栏和锁屏控制卡片可能不会显示。',
      TtsNotificationIssue.appNotificationsDisabled =>
        '系统关闭了 Sakura 的通知总开关。听书可以继续播放，但通知栏和多数设备的锁屏不会显示播放控制。',
      TtsNotificationIssue.notificationsPaused =>
        '系统正在暂停 Sakura 的通知，常见原因是应用暂停、专注模式、数字健康或工作资料限制。恢复通知后才能稳定显示锁屏控制。',
      TtsNotificationIssue.channelMissing =>
        '系统没有正确创建“听书播放”频道。可以进入通知设置检查；应用下次启动也会再次修复该频道。',
      TtsNotificationIssue.channelDisabled =>
        '“听书播放”通知频道被单独关闭。其他通知即使正常，听书卡片仍不会出现。请在频道设置中开启。',
      TtsNotificationIssue.channelImportanceTooLow =>
        '“听书播放”频道被设为最低级别，部分 Android 和定制系统不会把它显示在锁屏。请将该频道调整为允许通知。',
      TtsNotificationIssue.channelNotPublic =>
        '“听书播放”频道当前限制锁屏可见内容，卡片可能只显示图标或被隐藏。请在频道设置中允许锁屏显示。',
      TtsNotificationIssue.lockScreenNotificationsDisabled =>
        '系统的锁屏通知总开关已关闭。通知栏仍可能显示听书控制，但锁屏不会显示；请在系统通知设置中开启锁屏通知。',
      TtsNotificationIssue.none => '',
    };
  }

  String get oemGuidance {
    if (!isVivoOriginOs) return '';
    return 'OriginOS 请依次确认 Sakura 通知总开关、“听书播放”频道、锁屏通知和“显示详情”。'
        '只有在息屏后朗读本身也会停止时，才需要继续检查后台高耗电与自启动；单纯卡片不显示无需开启这些后台权限。';
  }
}

class TtsMediaControlService {
  TtsMediaControlService._(this._handler);

  TtsMediaControlService.disabled() : _handler = null;

  final _TtsMediaHandler? _handler;
  Object? _owner;
  static const MethodChannel _appInfoChannel = MethodChannel(
    'com.novel.novel_app/app_info',
  );

  static Future<TtsMediaControlService> init() async {
    await _ensureNativeNotificationChannel();
    final handler = await AudioService.init<_TtsMediaHandler>(
      builder: _TtsMediaHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.novel.novel_app.channel.tts',
        androidNotificationChannelName: '听书播放',
        androidNotificationChannelDescription: '小说听书锁屏控制',
        androidNotificationClickStartsActivity: true,
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
    return TtsMediaControlService._(handler);
  }

  void bindControls({
    required Object owner,
    required TtsMediaAction onPrevious,
    required TtsMediaAction onPlay,
    required TtsMediaAction onPause,
    required TtsMediaAction onNext,
    required TtsMediaAction onStop,
  }) {
    _owner = owner;
    _handler?.bindControls(
      onPrevious: onPrevious,
      onPlay: onPlay,
      onPause: onPause,
      onNext: onNext,
      onStop: onStop,
    );
  }

  void unbindControls(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _handler?.clearControls();
  }

  Future<TtsNotificationStatus> prepareNotificationAccess() async {
    if (!Platform.isAndroid) {
      return const TtsNotificationStatus.notApplicable();
    }

    await _ensureNativeNotificationChannel();
    var nativeStatusMap = await _notificationStatus();
    var nativeStatus = TtsNotificationStatus.fromMap(nativeStatusMap);
    var permissionStatus = await Permission.notification.status;
    if (nativeStatus.runtimePermissionRequired &&
        !nativeStatus.runtimePermissionGranted &&
        !permissionStatus.isPermanentlyDenied) {
      permissionStatus = await Permission.notification.request();
      nativeStatusMap = await _notificationStatus();
      nativeStatus = TtsNotificationStatus.fromMap(nativeStatusMap);
    }
    return TtsNotificationStatus.fromMap(
      nativeStatusMap,
      permissionPermanentlyDenied: permissionStatus.isPermanentlyDenied,
    );
  }

  Future<bool> ensureNotificationPermission() async {
    return (await prepareNotificationAccess()).canShowLockScreenCard;
  }

  static Future<void> _ensureNativeNotificationChannel() async {
    if (!Platform.isAndroid) return;
    try {
      await _appInfoChannel.invokeMethod<Object?>(
        'ensureTtsNotificationChannel',
      );
    } on MissingPluginException {
      // Unit tests and non-standard embedders may not install the Android side.
    } on PlatformException {
      // audio_service can still create its own channel as a fallback.
    }
  }

  Future<Map<Object?, Object?>> _notificationStatus() async {
    try {
      final status = await _appInfoChannel.invokeMethod<Map<Object?, Object?>>(
        'getTtsNotificationStatus',
      );
      return status ?? const <Object?, Object?>{};
    } on MissingPluginException {
      return const <Object?, Object?>{};
    } on PlatformException {
      return const <Object?, Object?>{};
    }
  }

  Future<bool> openNotificationSettings(
    TtsNotificationSettingsTarget target,
  ) async {
    if (!Platform.isAndroid) return false;
    try {
      final opened = await _appInfoChannel.invokeMethod<bool>(
        'openTtsNotificationSettings',
        {'target': target.name},
      );
      if (opened == true) return true;
    } on MissingPluginException {
      // Fall through to the plugin's application-details settings page.
    } on PlatformException {
      // Fall through to the plugin's application-details settings page.
    }
    return openAppSettings();
  }

  Future<void> show({
    required Novel novel,
    required String chapterTitle,
    required bool playing,
  }) async {
    final novelTitle = novel.title.trim().isEmpty ? '语音朗读' : novel.title.trim();
    final title = chapterTitle.trim().isEmpty ? '语音朗读' : chapterTitle.trim();
    final author = novel.author.trim().isEmpty ? 'Sakura' : novel.author.trim();
    final artworkUri = _networkArtworkUri(novel.coverUrl);

    _handler?.setMediaItem(
      MediaItem(
        id: 'novel:${novel.id}:chapter:${Uri.encodeComponent(title)}',
        title: title,
        artist: '$novelTitle · $author',
        album: novelTitle,
        artUri: artworkUri,
        extras: {'novelId': novel.id, 'chapterTitle': title},
      ),
    );
    await setPlaying(playing);
  }

  Future<void> setPlaying(bool playing) async {
    _handler?.emitPlaybackState(
      playing: playing,
      processingState: AudioProcessingState.ready,
    );
  }

  Future<void> stop() async {
    _handler?.clearMediaSession();
  }
}

class _TtsMediaHandler extends BaseAudioHandler {
  TtsMediaAction? _onPrevious;
  TtsMediaAction? _onPlay;
  TtsMediaAction? _onPause;
  TtsMediaAction? _onNext;
  TtsMediaAction? _onStop;

  void bindControls({
    required TtsMediaAction onPrevious,
    required TtsMediaAction onPlay,
    required TtsMediaAction onPause,
    required TtsMediaAction onNext,
    required TtsMediaAction onStop,
  }) {
    _onPrevious = onPrevious;
    _onPlay = onPlay;
    _onPause = onPause;
    _onNext = onNext;
    _onStop = onStop;
  }

  void clearControls() {
    _onPrevious = null;
    _onPlay = null;
    _onPause = null;
    _onNext = null;
    _onStop = null;
  }

  void setMediaItem(MediaItem item) {
    mediaItem.add(item);
  }

  void emitPlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    final controls = [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];

    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processingState,
        playing: playing,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      ),
    );
  }

  void clearMediaSession() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        androidCompactActionIndices: const [],
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );
    mediaItem.add(null);
  }

  @override
  Future<void> play() async {
    await _onPlay?.call();
  }

  @override
  Future<void> pause() async {
    await _onPause?.call();
  }

  @override
  Future<void> stop() async {
    await _onStop?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }
}

bool _statusBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return fallback;
}

bool? _statusNullableBool(Object? value) {
  if (value == null) return null;
  return _statusBool(value);
}

int _statusInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Uri? _networkArtworkUri(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri;
}
