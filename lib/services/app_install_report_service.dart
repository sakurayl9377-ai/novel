import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import 'interaction_auth_service.dart';
import 'storage_service.dart';

class AppInstallReportService {
  AppInstallReportService({
    InteractionAuthService? authService,
    StorageService? storageService,
  }) : _authService = authService ?? InteractionAuthService(),
       _storage = storageService ?? StorageService();

  static const String _installIdKey = 'app_install_instance_id_v1';
  static const MethodChannel _channel = MethodChannel(
    'com.novel.novel_app/app_info',
  );

  final InteractionAuthService _authService;
  final StorageService _storage;
  final Map<String, Future<void>> _inFlight = {};

  Future<void> report(String token) {
    if (token.isEmpty) return Future<void>.value();
    final running = _inFlight[token];
    if (running != null) return running;
    late final Future<void> task;
    task = _report(token).whenComplete(() {
      if (identical(_inFlight[token], task)) _inFlight.remove(token);
    });
    _inFlight[token] = task;
    return task;
  }

  Future<void> _report(String token) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final versionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    if (packageInfo.version.trim().isEmpty || versionCode <= 0) return;

    var installId = _storage.getString(_installIdKey)?.trim() ?? '';
    if (installId.isEmpty) {
      installId = const Uuid().v4();
      await _storage.setString(_installIdKey, installId);
    }

    final device = await _loadDeviceInfo();
    await _authService.reportAppInstall(
      token: token,
      installId: installId,
      versionName: packageInfo.version,
      versionCode: versionCode,
      platform: device.platform,
      osVersion: device.osVersion,
      deviceModel: device.deviceModel,
    );
  }

  Future<_AppDeviceInfo> _loadDeviceInfo() async {
    final fallbackPlatform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getDeviceInfo',
      );
      return _AppDeviceInfo(
        platform: _text(raw?['platform'], fallbackPlatform),
        osVersion: _text(raw?['osVersion']),
        deviceModel: _text(raw?['deviceModel']),
      );
    } on MissingPluginException {
      return _AppDeviceInfo(platform: fallbackPlatform);
    } on PlatformException {
      return _AppDeviceInfo(platform: fallbackPlatform);
    }
  }

  String _text(Object? value, [String fallback = '']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }
}

class _AppDeviceInfo {
  const _AppDeviceInfo({
    required this.platform,
    this.osVersion = '',
    this.deviceModel = '',
  });

  final String platform;
  final String osVersion;
  final String deviceModel;
}
