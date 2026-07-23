import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'interaction_auth_service.dart';
import 'modao_parallel_downloader.dart';

class ModaoGameException implements Exception {
  const ModaoGameException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ModaoGameManifest {
  const ModaoGameManifest({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.sizeBytes,
    required this.sha256,
    required this.signingCertificateSha256,
    required this.notes,
    required this.parts,
  });

  static const String expectedPackageName = 'com.you91.fish.lucky';
  static const String expectedSigningCertificateSha256 =
      'c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c';

  final String packageName;
  final String versionName;
  final int versionCode;
  final Uri apkUrl;
  final int sizeBytes;
  final String sha256;
  final String signingCertificateSha256;
  final List<String> notes;
  final List<ModaoGameDownloadPart> parts;

  String get downloadFileName =>
      'modao-$versionCode-${sha256.substring(0, 12)}.apk';

  String get artifactKey {
    final fingerprintInput = StringBuffer();
    for (final part in parts) {
      fingerprintInput
        ..writeln(part.index)
        ..writeln(part.url)
        ..writeln(part.fileName)
        ..writeln(part.sizeBytes)
        ..writeln(part.sha256);
    }
    final fingerprint = crypto.sha256
        .convert(utf8.encode(fingerprintInput.toString()))
        .toString();
    return '$downloadFileName:$sha256:$fingerprint';
  }

  factory ModaoGameManifest.fromJson(Map<String, dynamic> json) {
    final apkUrl = Uri.tryParse(
      (json['apkUrl'] ?? json['downloadUrl'] ?? json['url'])
              ?.toString()
              .trim() ??
          '',
    );
    final versionCode =
        json['versionCode'] ?? json['buildNumber'] ?? json['version_code'];
    final sizeBytes = json['sizeBytes'] ?? json['fileSize'] ?? json['size'];
    final rawCertificate =
        json['signingCertificateSha256'] ??
        json['signingCertificateSha256s'] ??
        json['certificateSha256'] ??
        json['signatureSha256'];
    final certificate = rawCertificate is List && rawCertificate.isNotEmpty
        ? rawCertificate.first
        : rawCertificate;
    return ModaoGameManifest(
      packageName: json['packageName']?.toString().trim() ?? '',
      versionName: (json['versionName'] ?? json['version'] ?? '')
          .toString()
          .trim(),
      versionCode: int.tryParse(versionCode?.toString() ?? '') ?? 0,
      apkUrl: apkUrl ?? Uri(),
      sizeBytes: int.tryParse(sizeBytes?.toString() ?? '') ?? 0,
      sha256: _normalizeFingerprint(json['sha256']),
      signingCertificateSha256: _normalizeFingerprint(certificate),
      notes: switch (json['notes']) {
        final List<dynamic> values =>
          values
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .take(8)
              .toList(growable: false),
        _ => const <String>[],
      },
      parts: switch (json['parts']) {
        final List<dynamic> values =>
          values
              .map((value) {
                if (value is! Map) {
                  return ModaoGameDownloadPart(
                    index: -1,
                    url: Uri(),
                    sizeBytes: 0,
                    sha256: '',
                  );
                }
                return ModaoGameDownloadPart.fromJson(
                  value.cast<String, dynamic>(),
                );
              })
              .toList(growable: false),
        _ => const <ModaoGameDownloadPart>[],
      },
    );
  }
}

class ModaoGameDownloadPart {
  const ModaoGameDownloadPart({
    required this.index,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  final int index;
  final Uri url;
  final int sizeBytes;
  final String sha256;

  String get fileName => url.pathSegments.isEmpty ? '' : url.pathSegments.last;

  Map<String, Object> toPlatformMap() => {
    'index': index,
    'url': url.toString(),
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };

  factory ModaoGameDownloadPart.fromJson(Map<String, dynamic> json) {
    return ModaoGameDownloadPart(
      index: int.tryParse(json['index']?.toString() ?? '') ?? -1,
      url: Uri.tryParse(json['url']?.toString().trim() ?? '') ?? Uri(),
      sizeBytes:
          int.tryParse((json['sizeBytes'] ?? json['size'])?.toString() ?? '') ??
          0,
      sha256: _normalizeFingerprint(json['sha256']),
    );
  }
}

class ModaoInstalledGame {
  const ModaoInstalledGame({
    required this.installed,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.signingCertificateSha256s,
  });

  const ModaoInstalledGame.notInstalled()
    : installed = false,
      packageName = '',
      versionName = '',
      versionCode = 0,
      signingCertificateSha256s = const <String>[];

  final bool installed;
  final String packageName;
  final String versionName;
  final int versionCode;
  final List<String> signingCertificateSha256s;

  bool isTrustedFor(ModaoGameManifest manifest) =>
      installed &&
      packageName == manifest.packageName &&
      signingCertificateSha256s.contains(manifest.signingCertificateSha256);

  bool isCurrentFor(ModaoGameManifest manifest) =>
      isTrustedFor(manifest) && versionCode >= manifest.versionCode;

  factory ModaoInstalledGame.fromPlatform(Map<Object?, Object?> value) {
    final signatures = value['signingCertificateSha256s'];
    return ModaoInstalledGame(
      installed: value['installed'] == true,
      packageName: value['packageName']?.toString() ?? '',
      versionName: value['versionName']?.toString() ?? '',
      versionCode: int.tryParse(value['versionCode']?.toString() ?? '') ?? 0,
      signingCertificateSha256s: signatures is List
          ? signatures
                .map(_normalizeFingerprint)
                .where(_isSha256)
                .toList(growable: false)
          : const <String>[],
    );
  }
}

enum ModaoDownloadStatus {
  none,
  queued,
  downloading,
  merging,
  paused,
  completed,
  failed;

  static ModaoDownloadStatus parse(Object? value) {
    return ModaoDownloadStatus.values.firstWhere(
      (item) => item.name == value?.toString(),
      orElse: () => ModaoDownloadStatus.none,
    );
  }
}

class ModaoDownloadState {
  const ModaoDownloadState({
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.localPath,
    required this.reason,
    this.segmented = false,
    this.partCount = 0,
    this.retainedBytes = 0,
    this.transport = '',
    this.artifactKey = '',
    this.releaseKey = '',
  });

  const ModaoDownloadState.none()
    : status = ModaoDownloadStatus.none,
      downloadedBytes = 0,
      totalBytes = 0,
      localPath = '',
      reason = '',
      segmented = false,
      partCount = 0,
      retainedBytes = 0,
      transport = '',
      artifactKey = '',
      releaseKey = '';

  final ModaoDownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final String localPath;
  final String reason;
  final bool segmented;
  final int partCount;
  final int retainedBytes;
  final String transport;
  final String artifactKey;
  final String releaseKey;

  bool get isActive =>
      status == ModaoDownloadStatus.queued ||
      status == ModaoDownloadStatus.downloading ||
      status == ModaoDownloadStatus.merging ||
      status == ModaoDownloadStatus.paused;

  factory ModaoDownloadState.fromPlatform(Map<Object?, Object?> value) {
    return ModaoDownloadState(
      status: ModaoDownloadStatus.parse(value['status']),
      downloadedBytes:
          int.tryParse(value['downloadedBytes']?.toString() ?? '') ?? 0,
      totalBytes: int.tryParse(value['totalBytes']?.toString() ?? '') ?? 0,
      localPath: value['localPath']?.toString() ?? '',
      reason: value['reason']?.toString() ?? '',
      segmented: value['segmented'] == true,
      partCount: int.tryParse(value['partCount']?.toString() ?? '') ?? 0,
      retainedBytes:
          int.tryParse(value['retainedBytes']?.toString() ?? '') ?? 0,
      transport: value['transport']?.toString() ?? '',
      artifactKey: value['artifactKey']?.toString() ?? '',
      releaseKey: value['releaseKey']?.toString() ?? '',
    );
  }
}

class ModaoDeviceEnvironment {
  const ModaoDeviceEnvironment({
    required this.freeBytes,
    required this.networkType,
    required this.connected,
    required this.validated,
    required this.metered,
  });

  final int freeBytes;
  final String networkType;
  final bool connected;
  final bool validated;
  final bool metered;

  factory ModaoDeviceEnvironment.fromPlatform(Map<Object?, Object?> value) {
    return ModaoDeviceEnvironment(
      freeBytes: int.tryParse(value['freeBytes']?.toString() ?? '') ?? 0,
      networkType: value['networkType']?.toString() ?? 'unknown',
      connected: value['connected'] == true,
      validated: value['validated'] == true,
      metered: value['metered'] == true,
    );
  }
}

class ModaoSsoTicket {
  const ModaoSsoTicket({required this.ticket, required this.exchangeUrl});

  final String ticket;
  final Uri exchangeUrl;
}

class ModaoPaymentRequest {
  const ModaoPaymentRequest({
    required this.gameOrderId,
    required this.productId,
  });

  final String gameOrderId;
  final String productId;

  factory ModaoPaymentRequest.fromPlatform(Map<Object?, Object?> value) {
    final gameOrderId = value['gameOrderId']?.toString().trim() ?? '';
    final productId = value['productId']?.toString().trim() ?? '';
    if (!_isPaymentIdentifier(gameOrderId) ||
        !_isPaymentIdentifier(productId)) {
      throw const ModaoGameException('游戏支付请求无效');
    }
    return ModaoPaymentRequest(gameOrderId: gameOrderId, productId: productId);
  }
}

class ModaoPayment {
  const ModaoPayment({
    required this.gameOrderId,
    required this.productId,
    required this.productName,
    required this.moneyCents,
    required this.coinCost,
    required this.balance,
    required this.status,
    required this.lastError,
    required this.canRetry,
  });

  final String gameOrderId;
  final String productId;
  final String productName;
  final int moneyCents;
  final int coinCost;
  final int balance;
  final String status;
  final String lastError;
  final bool canRetry;

  int get sakuraCoinAmount => coinCost;

  bool get delivered =>
      status == 'delivered' || status == 'fulfilled' || status == 'success';
  bool get deliveryFailed => status == 'delivery_failed' || status == 'failed';
  bool get refunded => status == 'refunded';
  bool get awaitingDelivery =>
      status == 'paid' ||
      status == 'fulfilling' ||
      status == 'pending' ||
      status == 'processing';

  factory ModaoPayment.fromJson(Map<String, dynamic> json) {
    int number(String key) => int.tryParse(json[key]?.toString() ?? '') ?? 0;
    final coinCost = number('coinCost') > 0
        ? number('coinCost')
        : number('sakuraCoinAmount');
    final status = json['status']?.toString().trim().toLowerCase() ?? '';
    return ModaoPayment(
      gameOrderId: json['gameOrderId']?.toString().trim() ?? '',
      productId: json['productId']?.toString().trim() ?? '',
      productName: json['productName']?.toString().trim() ?? '',
      moneyCents: number('moneyCents'),
      coinCost: coinCost,
      balance: number('balance'),
      status: status,
      lastError: json['lastError']?.toString().trim() ?? '',
      canRetry:
          json['canRetry'] == true ||
          status == 'delivery_failed' ||
          status == 'failed',
    );
  }
}

class ModaoPaymentBridge {
  ModaoPaymentBridge({MethodChannel? platformChannel})
    : _platformChannel =
          platformChannel ??
          const MethodChannel('com.novel.novel_app/modao_game');

  final MethodChannel _platformChannel;

  void start(void Function() onPaymentRequestAvailable) {
    _platformChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPaymentRequestAvailable') {
        onPaymentRequestAvailable();
      }
    });
  }

  void stop() => _platformChannel.setMethodCallHandler(null);

  Future<ModaoPaymentRequest?> takePendingRequest() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'takePendingPaymentRequest',
    );
    return value == null ? null : ModaoPaymentRequest.fromPlatform(value);
  }

  Future<bool> returnToGame({
    required String gameOrderId,
    required String status,
    required int balance,
  }) async {
    if (!_isPaymentIdentifier(gameOrderId)) {
      throw const ModaoGameException('游戏订单号无效');
    }
    return await _platformChannel.invokeMethod<bool>('returnPaymentToGame', {
          'gameOrderId': gameOrderId,
          'status': status,
          'balance': balance,
        }) ??
        false;
  }
}

class ModaoGameService {
  ModaoGameService({
    this.httpClient,
    MethodChannel? platformChannel,
    Uuid? uuid,
    ModaoParallelDownloader? parallelDownloader,
    this.networkPolicyPollInterval = const Duration(seconds: 1),
  }) : _platformChannel = platformChannel ?? _defaultPlatformChannel,
       _uuid = uuid ?? const Uuid(),
       _parallelDownloader =
           parallelDownloader ??
           ModaoParallelDownloader(httpClient: httpClient),
       assert(networkPolicyPollInterval > Duration.zero);

  static const String manifestUrl =
      'https://novel.kxhub.xyz/games/modao/manifest.json';
  static const String modaoSsoHost = String.fromEnvironment(
    'MODAO_SSO_HOST',
    defaultValue: '49.232.137.85',
  );
  static const int maximumApkBytes = 4 * 1024 * 1024 * 1024;
  static const int _maximumManifestBytes = 64 * 1024;
  static const MethodChannel _defaultPlatformChannel = MethodChannel(
    'com.novel.novel_app/modao_game',
  );
  static final Map<String, Future<ModaoDownloadState>> _activeDownloadStarts =
      {};

  final http.Client? httpClient;
  final MethodChannel _platformChannel;
  final Uuid _uuid;
  final ModaoParallelDownloader _parallelDownloader;
  final Duration networkPolicyPollInterval;
  String _lastArtifactKey = '';
  String _lastReleaseKey = '';
  Timer? _networkPolicyTimer;
  bool _networkPolicyChecking = false;
  _ManagedModaoDownload? _managedDownload;

  Future<ModaoGameManifest> fetchManifest() async {
    final uri = Uri.parse(manifestUrl).replace(
      queryParameters: {
        'cacheBust': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Accept': 'application/json',
          'Cache-Control': 'no-cache, no-store',
          'Pragma': 'no-cache',
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw const ModaoGameException('游戏版本信息暂时不可用');
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > _maximumManifestBytes) {
        throw const ModaoGameException('游戏版本信息无效');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (bytes.length + chunk.length > _maximumManifestBytes) {
          throw const ModaoGameException('游戏版本信息无效');
        }
        bytes.add(chunk);
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(
          utf8.decode(bytes.takeBytes(), allowMalformed: false),
        );
      } on FormatException {
        throw const ModaoGameException('游戏版本信息无效');
      }
      if (decoded is! Map) {
        throw const ModaoGameException('游戏版本信息无效');
      }
      final decodedMap = decoded.cast<String, dynamic>();
      final rawManifest = decodedMap['item'] is Map
          ? (decodedMap['item'] as Map).cast<String, dynamic>()
          : decodedMap['manifest'] is Map
          ? (decodedMap['manifest'] as Map).cast<String, dynamic>()
          : decodedMap;
      final manifest = ModaoGameManifest.fromJson(rawManifest);
      _validateManifest(manifest);
      return manifest;
    } on ModaoGameException {
      rethrow;
    } catch (_) {
      throw const ModaoGameException('无法连接游戏下载服务器');
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<ModaoInstalledGame> getInstalledGame() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getInstalledGame',
      {'packageName': ModaoGameManifest.expectedPackageName},
    );
    return value == null
        ? const ModaoInstalledGame.notInstalled()
        : ModaoInstalledGame.fromPlatform(value);
  }

  Future<ModaoDeviceEnvironment> getDeviceEnvironment() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getDeviceEnvironment',
    );
    if (value == null) {
      throw const ModaoGameException('无法检查设备存储和网络状态');
    }
    return ModaoDeviceEnvironment.fromPlatform(value);
  }

  Future<ModaoDownloadState> getDownloadState() async {
    final native = await _nativeDownloadState();
    final artifactKey = native.artifactKey.isNotEmpty
        ? native.artifactKey
        : _lastArtifactKey;
    final releaseKey = native.releaseKey.isNotEmpty
        ? native.releaseKey
        : _lastReleaseKey;
    final snapshot = artifactKey.isEmpty || releaseKey.isEmpty
        ? null
        : _parallelDownloader.snapshot(artifactKey, releaseKey: releaseKey);
    if (snapshot != null &&
        snapshot.releaseKey == native.releaseKey &&
        (snapshot.status == ModaoParallelDownloadStatus.downloading ||
            snapshot.status == ModaoParallelDownloadStatus.paused ||
            snapshot.status == ModaoParallelDownloadStatus.failed)) {
      return _downloadStateFromSnapshot(snapshot, native);
    }
    return native;
  }

  Future<ModaoDownloadState> startDownload(
    ModaoGameManifest manifest, {
    required bool allowMetered,
  }) async {
    _validateManifest(manifest);
    final key = manifest.artifactKey;
    final existing = _activeDownloadStarts[key];
    if (existing != null) return existing;
    final future = _startDownloadInternal(manifest, allowMetered: allowMetered);
    _activeDownloadStarts[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_activeDownloadStarts[key], future)) {
        _activeDownloadStarts.remove(key);
      }
    }
  }

  Future<ModaoDownloadState> _startDownloadInternal(
    ModaoGameManifest manifest, {
    required bool allowMetered,
  }) async {
    if (manifest.parts.isEmpty) {
      throw const ModaoGameException('游戏分包信息无效，请刷新后重试');
    }
    final expectedArtifactKey = manifest.artifactKey;
    final nativeBeforePrepare = await _nativeDownloadState();
    final currentSnapshot =
        nativeBeforePrepare.artifactKey.isEmpty ||
            nativeBeforePrepare.releaseKey.isEmpty
        ? null
        : _parallelDownloader.snapshot(
            nativeBeforePrepare.artifactKey,
            releaseKey: nativeBeforePrepare.releaseKey,
          );
    if (nativeBeforePrepare.artifactKey == expectedArtifactKey &&
        currentSnapshot?.status == ModaoParallelDownloadStatus.downloading) {
      _lastArtifactKey = nativeBeforePrepare.artifactKey;
      _lastReleaseKey = nativeBeforePrepare.releaseKey;
      return _downloadStateFromSnapshot(currentSnapshot!, nativeBeforePrepare);
    }
    final managedBeforePrepare = _managedDownload;
    if (nativeBeforePrepare.artifactKey == expectedArtifactKey &&
        currentSnapshot?.status == ModaoParallelDownloadStatus.paused &&
        managedBeforePrepare != null &&
        managedBeforePrepare.plan.releaseKey ==
            nativeBeforePrepare.releaseKey) {
      final managed = allowMetered && !managedBeforePrepare.allowMetered
          ? managedBeforePrepare.copyWith(allowMetered: true)
          : managedBeforePrepare;
      _managedDownload = managed;
      final resumed = await _startManagedDownload(managed);
      _startNetworkPolicyMonitor(managed);
      return _downloadStateFromSnapshot(resumed, nativeBeforePrepare);
    }
    if (currentSnapshot?.isActive == true) {
      await _parallelDownloader.cancel(
        nativeBeforePrepare.artifactKey,
        releaseKey: nativeBeforePrepare.releaseKey,
      );
    }
    final value = await _platformChannel
        .invokeMapMethod<Object?, Object?>('prepareAppDownload', {
          'url': manifest.apkUrl.toString(),
          'fileName': manifest.downloadFileName,
          'sizeBytes': manifest.sizeBytes,
          'sha256': manifest.sha256,
          'parts': manifest.parts
              .map((part) => part.toPlatformMap())
              .toList(growable: false),
          'allowMetered': allowMetered,
        });
    if (value == null) {
      throw const ModaoGameException('游戏下载启动失败');
    }
    final nativePlan = _NativeModaoDownloadPlan.fromPlatform(value, manifest);
    await _parallelDownloader.cancelAllExcept(
      artifactKey: nativePlan.artifactKey,
      releaseKey: nativePlan.releaseKey,
    );
    _lastArtifactKey = nativePlan.artifactKey;
    _lastReleaseKey = nativePlan.releaseKey;
    final plan = ModaoParallelDownloadPlan(
      artifactKey: nativePlan.artifactKey,
      releaseKey: nativePlan.releaseKey,
      totalBytes: manifest.sizeBytes,
      parts: [
        for (var index = 0; index < manifest.parts.length; index++)
          ModaoPartDownloadTarget(
            index: index,
            url: manifest.parts[index].url,
            path: nativePlan.partPaths[index],
            sizeBytes: manifest.parts[index].sizeBytes,
            sha256: manifest.parts[index].sha256,
          ),
      ],
    );
    final managed = _ManagedModaoDownload(
      nativePlan: nativePlan,
      plan: plan,
      allowMetered: allowMetered,
    );
    _managedDownload = managed;
    final snapshot = await _startManagedDownload(managed);
    _startNetworkPolicyMonitor(managed);
    return _downloadStateFromSnapshot(
      snapshot,
      ModaoDownloadState(
        status: ModaoDownloadStatus.downloading,
        downloadedBytes: 0,
        totalBytes: manifest.sizeBytes,
        localPath: nativePlan.finalPath,
        reason: '',
        segmented: true,
        partCount: manifest.parts.length,
        transport: 'app_http',
        artifactKey: nativePlan.artifactKey,
        releaseKey: nativePlan.releaseKey,
      ),
    );
  }

  Future<void> clearDownload() async {
    final starts = _activeDownloadStarts.values.toList(growable: false);
    for (final start in starts) {
      try {
        await start;
      } catch (_) {
        // A failed prepare has no active writer to settle.
      }
    }
    final native = await _nativeDownloadState();
    final artifactKey = native.artifactKey.isNotEmpty
        ? native.artifactKey
        : _lastArtifactKey;
    final releaseKey = native.releaseKey.isNotEmpty
        ? native.releaseKey
        : _lastReleaseKey;
    _stopNetworkPolicyMonitor();
    _managedDownload = null;
    if (artifactKey.isNotEmpty && releaseKey.isNotEmpty) {
      await _parallelDownloader.cancel(artifactKey, releaseKey: releaseKey);
    }
    final cleared = await _platformChannel.invokeMethod<bool>(
      'clearDownload',
      releaseKey.isEmpty ? null : {'releaseKey': releaseKey},
    );
    if (cleared == false) return;
    if (artifactKey.isNotEmpty && releaseKey.isNotEmpty) {
      _parallelDownloader.forget(artifactKey, releaseKey: releaseKey);
    }
    if (_lastArtifactKey == artifactKey && _lastReleaseKey == releaseKey) {
      _lastArtifactKey = '';
      _lastReleaseKey = '';
    }
  }

  Future<ModaoDownloadState> _nativeDownloadState() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getDownloadState',
    );
    return value == null
        ? const ModaoDownloadState.none()
        : ModaoDownloadState.fromPlatform(value);
  }

  ModaoDownloadState _downloadStateFromSnapshot(
    ModaoParallelDownloadSnapshot snapshot,
    ModaoDownloadState native,
  ) {
    return ModaoDownloadState(
      status: switch (snapshot.status) {
        ModaoParallelDownloadStatus.paused => ModaoDownloadStatus.paused,
        ModaoParallelDownloadStatus.failed => ModaoDownloadStatus.failed,
        _ => ModaoDownloadStatus.downloading,
      },
      downloadedBytes: snapshot.downloadedBytes,
      totalBytes: snapshot.totalBytes,
      localPath: native.localPath,
      reason: snapshot.reason,
      segmented: true,
      partCount: snapshot.partCount,
      retainedBytes: snapshot.downloadedBytes,
      transport: 'app_http',
      artifactKey: snapshot.artifactKey,
      releaseKey: snapshot.releaseKey,
    );
  }

  Future<ModaoParallelDownloadSnapshot> _startManagedDownload(
    _ManagedModaoDownload managed,
  ) {
    return _parallelDownloader.start(
      managed.plan,
      onPartsReady: () => _finalizeManagedDownload(managed),
    );
  }

  Future<void> _finalizeManagedDownload(_ManagedModaoDownload managed) async {
    final nativePlan = managed.nativePlan;
    final finalized = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'finalizeAppDownload',
      {
        'releaseKey': nativePlan.releaseKey,
        'artifactKey': nativePlan.artifactKey,
      },
    );
    if (finalized == null) {
      throw const ModaoGameException('游戏安装包合并启动失败');
    }
    final state = ModaoDownloadState.fromPlatform(finalized);
    if (state.releaseKey != nativePlan.releaseKey ||
        state.artifactKey != nativePlan.artifactKey ||
        state.transport != 'app_http' ||
        (state.status != ModaoDownloadStatus.merging &&
            state.status != ModaoDownloadStatus.completed)) {
      throw const ModaoGameException('游戏安装包合并状态无效');
    }
  }

  void _startNetworkPolicyMonitor(_ManagedModaoDownload managed) {
    _stopNetworkPolicyMonitor();
    if (managed.allowMetered) return;
    _networkPolicyTimer = Timer.periodic(
      networkPolicyPollInterval,
      (_) => unawaited(_enforceNetworkPolicy(managed)),
    );
  }

  void _stopNetworkPolicyMonitor() {
    _networkPolicyTimer?.cancel();
    _networkPolicyTimer = null;
  }

  Future<void> _enforceNetworkPolicy(_ManagedModaoDownload managed) async {
    if (_networkPolicyChecking || !identical(_managedDownload, managed)) {
      return;
    }
    final before = _parallelDownloader.snapshot(
      managed.plan.artifactKey,
      releaseKey: managed.plan.releaseKey,
    );
    if (before == null ||
        before.status == ModaoParallelDownloadStatus.completed ||
        before.status == ModaoParallelDownloadStatus.failed ||
        before.status == ModaoParallelDownloadStatus.cancelled) {
      if (identical(_managedDownload, managed)) {
        _stopNetworkPolicyMonitor();
      }
      return;
    }

    _networkPolicyChecking = true;
    try {
      final environment = await getDeviceEnvironment();
      if (!identical(_managedDownload, managed)) return;
      final current = _parallelDownloader.snapshot(
        managed.plan.artifactKey,
        releaseKey: managed.plan.releaseKey,
      );
      if (current == null) return;
      final networkAllowed =
          environment.connected &&
          environment.validated &&
          (!environment.metered || managed.allowMetered);
      if (current.status == ModaoParallelDownloadStatus.downloading &&
          !networkAllowed) {
        await _parallelDownloader.pause(
          managed.plan.artifactKey,
          releaseKey: managed.plan.releaseKey,
          reason: environment.metered ? '已暂停，等待 Wi-Fi 网络' : '已暂停，等待网络恢复',
        );
      } else if (current.status == ModaoParallelDownloadStatus.paused &&
          networkAllowed) {
        await _startManagedDownload(managed);
      }
    } catch (_) {
      // A transient platform query failure must not destroy resumable parts.
    } finally {
      _networkPolicyChecking = false;
    }
  }

  Future<void> verifyDownloadedApk(
    ModaoGameManifest manifest,
    String localPath,
  ) async {
    _validateManifest(manifest);
    if (localPath.trim().isEmpty) {
      throw const ModaoGameException('未找到已下载的游戏安装包');
    }
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'inspectApk',
      {'path': localPath},
    );
    if (value == null || value['exists'] != true) {
      throw const ModaoGameException('未找到已下载的游戏安装包');
    }
    final actualSize = int.tryParse(value['sizeBytes']?.toString() ?? '') ?? 0;
    final actualSha256 = _normalizeFingerprint(value['sha256']);
    final packageName = value['packageName']?.toString() ?? '';
    final versionCode =
        int.tryParse(value['versionCode']?.toString() ?? '') ?? 0;
    final rawSignatures =
        value['signingCertificateSha256s'] ??
        value['signingCertificateSha256'] ??
        value['signatureSha256'];
    final signatures = rawSignatures is List
        ? rawSignatures.map(_normalizeFingerprint).toSet()
        : rawSignatures == null
        ? const <String>{}
        : <String>{_normalizeFingerprint(rawSignatures)};
    if (actualSize != manifest.sizeBytes || actualSha256 != manifest.sha256) {
      throw const ModaoGameException('安装包校验失败，请重新下载');
    }
    if (packageName != manifest.packageName ||
        versionCode != manifest.versionCode) {
      throw const ModaoGameException('安装包版本与发布信息不一致');
    }
    if (!signatures.contains(manifest.signingCertificateSha256)) {
      throw const ModaoGameException('安装包签名校验失败，已阻止安装');
    }
  }

  Future<bool> canInstallPackages() async =>
      await _platformChannel.invokeMethod<bool>('canInstallPackages') ?? false;

  Future<bool> openInstallPermissionSettings() async =>
      await _platformChannel.invokeMethod<bool>(
        'openInstallPermissionSettings',
      ) ??
      false;

  Future<void> installApk(String localPath) => _platformChannel
      .invokeMethod<void>('installGameApk', {'path': localPath});

  Future<ModaoSsoTicket> createSsoTicket(String token) async {
    if (token.trim().isEmpty) {
      throw const ModaoGameException('请先登录后再进入游戏');
    }
    final uri = Uri.parse(
      '${InteractionAuthService.baseUrl}/games/modao/sso-ticket',
    );
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final response = await client
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${token.trim()}',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 15));
      final dynamic decoded;
      try {
        decoded = jsonDecode(
          utf8.decode(response.bodyBytes, allowMalformed: true),
        );
      } on FormatException {
        throw const ModaoGameException('游戏登录服务返回异常');
      }
      final body = decoded is Map
          ? decoded.cast<String, dynamic>()
          : const <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = body['error']?.toString().trim() ?? '';
        throw ModaoGameException(message.isEmpty ? '游戏登录失败，请稍后重试' : message);
      }
      final item = body['item'] is Map
          ? (body['item'] as Map).cast<String, dynamic>()
          : body['data'] is Map
          ? (body['data'] as Map).cast<String, dynamic>()
          : body;
      final ticket =
          (item['ticket'] ?? item['ssoTicket'])?.toString().trim() ?? '';
      if (ticket.isEmpty || ticket.length > 2048) {
        throw const ModaoGameException('游戏登录凭证无效');
      }
      final exchangeUrl = Uri.tryParse(
        (item['launchUrl'] ?? body['launchUrl'])?.toString().trim() ?? '',
      );
      if (exchangeUrl == null ||
          exchangeUrl.scheme != 'https' ||
          exchangeUrl.host.isEmpty ||
          (exchangeUrl.hasPort && exchangeUrl.port != 443) ||
          modaoSsoHost.isEmpty ||
          exchangeUrl.host != modaoSsoHost ||
          exchangeUrl.userInfo.isNotEmpty ||
          exchangeUrl.fragment.isNotEmpty ||
          exchangeUrl.path != '/sakura/sso/exchange') {
        throw const ModaoGameException('游戏登录地址无效');
      }
      return ModaoSsoTicket(ticket: ticket, exchangeUrl: exchangeUrl);
    } on ModaoGameException {
      rethrow;
    } catch (_) {
      throw const ModaoGameException('无法连接游戏登录服务');
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<void> launchGame(ModaoSsoTicket ticket) async {
    final launched = await _platformChannel.invokeMethod<bool>('launchGame', {
      'packageName': ModaoGameManifest.expectedPackageName,
      'ticket': ticket.ticket,
      'exchangeUrl': ticket.exchangeUrl.toString(),
      'allowedSsoHost': modaoSsoHost,
    });
    if (launched != true) {
      throw const ModaoGameException('游戏启动失败，请确认已完成安装');
    }
  }

  String createPaymentIdempotencyKey() => _uuid.v4();

  Future<ModaoPayment> previewPayment(
    String token,
    ModaoPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path: '/games/modao/payments/preview',
        body: {
          'gameOrderId': request.gameOrderId,
          'productId': request.productId,
        },
      ),
      request,
    );
  }

  Future<ModaoPayment> pay(
    String token,
    ModaoPaymentRequest request, {
    required String idempotencyKey,
  }) async {
    if (!_isIdempotencyKey(idempotencyKey)) {
      throw const ModaoGameException('支付请求标识无效');
    }
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path: '/games/modao/payments',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {
          'gameOrderId': request.gameOrderId,
          'productId': request.productId,
          'idempotencyKey': idempotencyKey,
        },
      ),
      request,
    );
  }

  Future<ModaoPayment> paymentStatus(
    String token,
    ModaoPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'GET',
        path:
            '/games/modao/payments/${Uri.encodeComponent(request.gameOrderId)}',
      ),
      request,
    );
  }

  Future<ModaoPayment> retryDelivery(
    String token,
    ModaoPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path:
            '/games/modao/payments/${Uri.encodeComponent(request.gameOrderId)}/retry',
        body: const <String, dynamic>{},
      ),
      request,
    );
  }

  Future<Map<String, dynamic>> _authorizedJsonRequest({
    required String token,
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (token.trim().isEmpty) {
      throw const ModaoGameException('请先登录后再进行支付');
    }
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final request =
          http.Request(
              method,
              Uri.parse('${InteractionAuthService.baseUrl}$path'),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${token.trim()}',
              ...headers,
            });
      if (body != null) request.body = jsonEncode(body);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final decoded = await _decodeLimitedJsonResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded['error']?.toString().trim() ?? '';
        throw ModaoGameException(_paymentErrorMessage(code));
      }
      return decoded;
    } on ModaoGameException {
      rethrow;
    } catch (_) {
      throw const ModaoGameException('无法连接支付服务，请稍后重试');
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeLimitedJsonResponse(
    http.StreamedResponse response,
  ) async {
    const limit = 128 * 1024;
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > limit) {
      throw const ModaoGameException('支付服务返回异常');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw const ModaoGameException('支付服务返回异常');
      }
      bytes.add(chunk);
    }
    try {
      final decoded = jsonDecode(
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
      );
      return decoded is Map<String, dynamic>
          ? decoded
          : decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{};
    } on FormatException {
      throw const ModaoGameException('支付服务返回异常');
    }
  }

  ModaoPayment _paymentFromResponse(
    Map<String, dynamic> response,
    ModaoPaymentRequest request,
  ) {
    final rawItem = response['item'] ?? response['data'];
    final item = rawItem is Map ? rawItem.cast<String, dynamic>() : response;
    final payment = ModaoPayment.fromJson(item);
    if (payment.gameOrderId != request.gameOrderId ||
        payment.productId != request.productId ||
        payment.productName.isEmpty ||
        payment.moneyCents <= 0 ||
        payment.coinCost <= 0 ||
        payment.moneyCents != payment.coinCost * 10 ||
        payment.balance < 0) {
      throw const ModaoGameException('支付价格校验失败，已停止支付');
    }
    return payment;
  }

  String _paymentErrorMessage(String code) {
    return switch (code) {
      'insufficient_balance' || 'coins_not_enough' => '樱花币余额不足',
      'product_not_found' || 'invalid_product' => '游戏商品不存在',
      'order_conflict' => '游戏订单信息冲突',
      'unauthorized' => '登录状态已失效，请重新登录',
      'delivery_unavailable' => '游戏发货服务暂时不可用',
      _ => code.isEmpty ? '支付请求失败，请稍后重试' : '支付请求失败：$code',
    };
  }

  static void _validateManifest(ModaoGameManifest manifest) {
    if (manifest.packageName != ModaoGameManifest.expectedPackageName ||
        manifest.versionName.isEmpty ||
        manifest.versionCode <= 0 ||
        manifest.sizeBytes <= 0 ||
        manifest.sizeBytes > maximumApkBytes ||
        !_isTrustedApkUri(manifest.apkUrl) ||
        !_isSha256(manifest.sha256) ||
        manifest.signingCertificateSha256 !=
            ModaoGameManifest.expectedSigningCertificateSha256) {
      throw const ModaoGameException('游戏版本信息无效');
    }
    if (manifest.parts.isNotEmpty) {
      if (manifest.parts.length < 2 || manifest.parts.length > 16) {
        throw const ModaoGameException('游戏分片信息无效');
      }
      var partBytes = 0;
      for (var index = 0; index < manifest.parts.length; index++) {
        final part = manifest.parts[index];
        final paddedIndex = index.toString().padLeft(3, '0');
        final apkStem = manifest.downloadFileName.substring(
          0,
          manifest.downloadFileName.length - 4,
        );
        final expectedName = '$apkStem.part-$paddedIndex.apk';
        if (part.index != index ||
            part.sizeBytes <= 0 ||
            !_isSha256(part.sha256) ||
            !_isTrustedPartUri(part.url) ||
            part.fileName != expectedName) {
          throw const ModaoGameException('游戏分片信息无效');
        }
        partBytes += part.sizeBytes;
      }
      if (partBytes != manifest.sizeBytes) {
        throw const ModaoGameException('游戏分片大小与安装包不一致');
      }
    }
  }

  static bool _isTrustedApkUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'novel.kxhub.xyz' &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      uri.fragment.isEmpty &&
      uri.path.startsWith('/games/modao/') &&
      uri.path.toLowerCase().endsWith('.apk');

  static bool _isTrustedPartUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'novel.kxhub.xyz' &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      uri.fragment.isEmpty &&
      uri.path.startsWith('/games/modao/') &&
      RegExp(r'\.part-[0-9]{3}\.apk$').hasMatch(uri.path.toLowerCase());
}

class _NativeModaoDownloadPlan {
  const _NativeModaoDownloadPlan({
    required this.artifactKey,
    required this.releaseKey,
    required this.finalPath,
    required this.partPaths,
  });

  final String artifactKey;
  final String releaseKey;
  final String finalPath;
  final List<String> partPaths;

  factory _NativeModaoDownloadPlan.fromPlatform(
    Map<Object?, Object?> value,
    ModaoGameManifest manifest,
  ) {
    final artifactKey = value['artifactKey']?.toString() ?? '';
    final releaseKey = value['releaseKey']?.toString() ?? '';
    final finalPath = value['finalPath']?.toString() ?? '';
    final totalBytes = int.tryParse(value['totalBytes']?.toString() ?? '') ?? 0;
    final rawParts = value['parts'];
    if (artifactKey != manifest.artifactKey ||
        releaseKey.isEmpty ||
        releaseKey.length > 512 ||
        value['transport']?.toString() != 'app_http' ||
        totalBytes != manifest.sizeBytes ||
        finalPath.isEmpty ||
        _fileName(finalPath) != manifest.downloadFileName ||
        rawParts is! List ||
        rawParts.length != manifest.parts.length) {
      throw const ModaoGameException('游戏本地下载计划无效');
    }

    final paths = <String>[];
    final seen = <String>{};
    for (var index = 0; index < rawParts.length; index++) {
      final raw = rawParts[index];
      if (raw is! Map) {
        throw const ModaoGameException('游戏本地下载计划无效');
      }
      final item = raw.cast<Object?, Object?>();
      final path = item['path']?.toString() ?? '';
      final part = manifest.parts[index];
      if (int.tryParse(item['index']?.toString() ?? '') != index ||
          int.tryParse(item['sizeBytes']?.toString() ?? '') != part.sizeBytes ||
          _normalizeFingerprint(item['sha256']) != part.sha256 ||
          path.isEmpty ||
          _fileName(path) != part.fileName ||
          !seen.add(path)) {
        throw const ModaoGameException('游戏本地下载计划无效');
      }
      paths.add(path);
    }
    return _NativeModaoDownloadPlan(
      artifactKey: artifactKey,
      releaseKey: releaseKey,
      finalPath: finalPath,
      partPaths: paths,
    );
  }

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    return separator < 0 ? normalized : normalized.substring(separator + 1);
  }
}

class _ManagedModaoDownload {
  const _ManagedModaoDownload({
    required this.nativePlan,
    required this.plan,
    required this.allowMetered,
  });

  final _NativeModaoDownloadPlan nativePlan;
  final ModaoParallelDownloadPlan plan;
  final bool allowMetered;

  _ManagedModaoDownload copyWith({required bool allowMetered}) {
    return _ManagedModaoDownload(
      nativePlan: nativePlan,
      plan: plan,
      allowMetered: allowMetered,
    );
  }
}

String _normalizeFingerprint(Object? value) =>
    value
        ?.toString()
        .replaceAll(':', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase() ??
    '';

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _isPaymentIdentifier(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

bool _isIdempotencyKey(String value) =>
    value.length >= 16 &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
