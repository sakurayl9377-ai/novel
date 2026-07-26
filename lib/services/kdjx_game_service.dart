import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'interaction_auth_service.dart';

class KdjxGameException implements Exception {
  const KdjxGameException(this.message);

  final String message;

  @override
  String toString() => message;
}

class KdjxGameManifest {
  const KdjxGameManifest({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.apkUrls,
    required this.parts,
    required this.sizeBytes,
    required this.sha256,
    required this.signingCertificateSha256,
    required this.notes,
  });

  static const String expectedPackageName = 'com.kd.kdjxcs';

  final String packageName;
  final String versionName;
  final int versionCode;
  final List<Uri> apkUrls;
  final List<KdjxApkPart> parts;
  final int sizeBytes;
  final String sha256;
  final String signingCertificateSha256;
  final List<String> notes;

  Uri? get fallbackApkUrl => apkUrls.isEmpty ? null : apkUrls.first;

  String get downloadFileName =>
      'kdjx-$versionCode-${sha256.substring(0, 12)}.apk';

  factory KdjxGameManifest.fromJson(Map<String, dynamic> json) {
    final urls = <Uri>[];
    final seen = <String>{};

    void addUrl(Object? raw) {
      final value = switch (raw) {
        final String value => value.trim(),
        final Map value =>
          (value['url'] ?? value['apkUrl'] ?? value['downloadUrl'])
                  ?.toString()
                  .trim() ??
              '',
        _ => '',
      };
      final uri = Uri.tryParse(value);
      if (uri != null && value.isNotEmpty && seen.add(uri.toString())) {
        urls.add(uri);
      }
    }

    void addUrls(Object? raw) {
      if (raw is List) {
        for (final value in raw) {
          addUrl(value);
        }
      } else {
        addUrl(raw);
      }
    }

    addUrl(json['apkUrl'] ?? json['downloadUrl'] ?? json['url']);
    addUrls(json['apkUrls']);
    addUrls(json['downloadUrls']);
    addUrls(json['mirrors']);

    final parts = switch (json['parts']) {
      final List values =>
        values
            .whereType<Map>()
            .map((value) => KdjxApkPart.fromJson(value.cast<String, dynamic>()))
            .toList(growable: false),
      _ => const <KdjxApkPart>[],
    };

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

    return KdjxGameManifest(
      packageName: json['packageName']?.toString().trim() ?? '',
      versionName: (json['versionName'] ?? json['version'] ?? '')
          .toString()
          .trim(),
      versionCode: int.tryParse(versionCode?.toString() ?? '') ?? 0,
      apkUrls: List<Uri>.unmodifiable(urls),
      parts: List<KdjxApkPart>.unmodifiable(parts),
      sizeBytes: int.tryParse(sizeBytes?.toString() ?? '') ?? 0,
      sha256: _normalizeFingerprint(json['sha256']),
      signingCertificateSha256: _normalizeFingerprint(certificate),
      notes: switch (json['notes']) {
        final List values =>
          values
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .take(8)
              .toList(growable: false),
        _ => const <String>[],
      },
    );
  }
}

class KdjxApkPart {
  const KdjxApkPart({
    required this.index,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  final int index;
  final Uri url;
  final int sizeBytes;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'index': index,
    'url': url.toString(),
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };

  factory KdjxApkPart.fromJson(Map<String, dynamic> json) {
    return KdjxApkPart(
      index: int.tryParse(json['index']?.toString() ?? '') ?? -1,
      url: Uri.tryParse(json['url']?.toString().trim() ?? '') ?? Uri(),
      sizeBytes: int.tryParse(json['sizeBytes']?.toString() ?? '') ?? 0,
      sha256: _normalizeFingerprint(json['sha256']),
    );
  }
}

class KdjxInstalledGame {
  const KdjxInstalledGame({
    required this.installed,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.signingCertificateSha256s,
  });

  const KdjxInstalledGame.notInstalled()
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

  bool isTrustedFor(KdjxGameManifest manifest) =>
      installed &&
      packageName == manifest.packageName &&
      signingCertificateSha256s.contains(manifest.signingCertificateSha256);

  bool isCurrentFor(KdjxGameManifest manifest) =>
      isTrustedFor(manifest) && versionCode >= manifest.versionCode;

  factory KdjxInstalledGame.fromPlatform(Map<Object?, Object?> value) {
    final signatures = value['signingCertificateSha256s'];
    return KdjxInstalledGame(
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

enum KdjxDownloadStatus {
  none,
  queued,
  downloading,
  paused,
  completed,
  failed;

  static KdjxDownloadStatus parse(Object? value) {
    return KdjxDownloadStatus.values.firstWhere(
      (item) => item.name == value?.toString(),
      orElse: () => KdjxDownloadStatus.none,
    );
  }
}

class KdjxDownloadState {
  const KdjxDownloadState({
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.localPath,
    required this.reason,
    required this.sourceUrl,
    required this.sourceIndex,
  });

  const KdjxDownloadState.none()
    : status = KdjxDownloadStatus.none,
      downloadedBytes = 0,
      totalBytes = 0,
      localPath = '',
      reason = '',
      sourceUrl = '',
      sourceIndex = 0;

  final KdjxDownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final String localPath;
  final String reason;
  final String sourceUrl;
  final int sourceIndex;

  bool get isActive =>
      status == KdjxDownloadStatus.queued ||
      status == KdjxDownloadStatus.downloading ||
      status == KdjxDownloadStatus.paused;

  factory KdjxDownloadState.fromPlatform(Map<Object?, Object?> value) {
    return KdjxDownloadState(
      status: KdjxDownloadStatus.parse(value['status']),
      downloadedBytes:
          int.tryParse(value['downloadedBytes']?.toString() ?? '') ?? 0,
      totalBytes: int.tryParse(value['totalBytes']?.toString() ?? '') ?? 0,
      localPath: value['localPath']?.toString() ?? '',
      reason: value['reason']?.toString() ?? '',
      sourceUrl: value['sourceUrl']?.toString() ?? '',
      sourceIndex: int.tryParse(value['sourceIndex']?.toString() ?? '') ?? 0,
    );
  }
}

class KdjxDeviceEnvironment {
  const KdjxDeviceEnvironment({
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

  factory KdjxDeviceEnvironment.fromPlatform(Map<Object?, Object?> value) {
    return KdjxDeviceEnvironment(
      freeBytes: int.tryParse(value['freeBytes']?.toString() ?? '') ?? 0,
      networkType: value['networkType']?.toString() ?? 'unknown',
      connected: value['connected'] == true,
      validated: value['validated'] == true,
      metered: value['metered'] == true,
    );
  }
}

class KdjxPaymentRequest {
  const KdjxPaymentRequest({
    required this.gameOrderId,
    required this.accountId,
    required this.productId,
    required this.roleId,
    required this.serverKey,
    required this.yyId,
    required this.csvId,
    required this.returnNonce,
  });

  final String gameOrderId;
  final String accountId;
  final String productId;
  final String roleId;
  final String serverKey;
  final String yyId;
  final String csvId;
  final String returnNonce;

  Map<String, String> toJson() => {
    'gameOrderId': gameOrderId,
    'accountId': accountId,
    'productId': productId,
    'roleId': roleId,
    'serverKey': serverKey,
    'yyId': yyId,
    'csvId': csvId,
  };

  factory KdjxPaymentRequest.fromPlatform(Map<Object?, Object?> value) {
    String field(String key) => value[key]?.toString().trim() ?? '';

    final request = KdjxPaymentRequest(
      gameOrderId: field('gameOrderId'),
      accountId: field('accountId'),
      productId: field('productId').isNotEmpty
          ? field('productId')
          : field('rechargeId'),
      roleId: field('roleId'),
      serverKey: field('serverKey'),
      yyId: field('yyId'),
      csvId: field('csvId'),
      returnNonce: field('returnNonce'),
    );
    if (request.toJson().values.any((value) => !_isIdentifier(value)) ||
        !_isPaymentReturnNonce(request.returnNonce)) {
      throw const KdjxGameException('游戏支付请求无效');
    }
    return request;
  }
}

class KdjxAuthorizationRequest {
  const KdjxAuthorizationRequest({
    required this.deviceCode,
    required this.userCode,
  });

  final String deviceCode;
  final String userCode;

  factory KdjxAuthorizationRequest.fromPlatform(Map<Object?, Object?> value) {
    final deviceCode =
        (value['deviceCode'] ?? value['device_code'])?.toString().trim() ?? '';
    final userCode = _normalizeUserCode(
      (value['userCode'] ?? value['user_code'])?.toString() ?? '',
    );
    if (!_isDeviceCode(deviceCode) || userCode == null) {
      throw const KdjxGameException('游戏授权请求无效');
    }
    return KdjxAuthorizationRequest(deviceCode: deviceCode, userCode: userCode);
  }
}

class KdjxPayment {
  const KdjxPayment({
    required this.gameOrderId,
    required this.sakuraOrderId,
    required this.productId,
    required this.productName,
    required this.displayPrice,
    required this.moneyCents,
    required this.coinCost,
    required this.balance,
    required this.status,
    required this.lastError,
    required this.canRetry,
  });

  final String gameOrderId;
  final String sakuraOrderId;
  final String productId;
  final String productName;
  final String displayPrice;
  final int moneyCents;
  final int coinCost;
  final int balance;
  final String status;
  final String lastError;
  final bool canRetry;

  bool get delivered =>
      status == 'delivered' || status == 'fulfilled' || status == 'success';
  bool get deliveryFailed => status == 'delivery_failed' || status == 'failed';
  bool get refunded => status == 'refunded';
  bool get awaitingDelivery =>
      status == 'paid' ||
      status == 'fulfilling' ||
      status == 'pending' ||
      status == 'processing';

  factory KdjxPayment.fromJson(Map<String, dynamic> json) {
    int number(String key) => int.tryParse(json[key]?.toString() ?? '') ?? 0;
    final moneyCents = number('moneyCents') > 0
        ? number('moneyCents')
        : number('displayMoneyCents');
    final coinCost = number('coinCost') > 0
        ? number('coinCost')
        : number('sakuraCoinAmount');
    final displayPrice = json['displayPrice']?.toString().trim() ?? '';
    return KdjxPayment(
      gameOrderId: json['gameOrderId']?.toString().trim() ?? '',
      sakuraOrderId: json['sakuraOrderId']?.toString().trim() ?? '',
      productId: json['productId']?.toString().trim() ?? '',
      productName: json['productName']?.toString().trim() ?? '',
      displayPrice: _isYuanPrice(displayPrice)
          ? displayPrice
          : _formatYuanPrice(moneyCents),
      moneyCents: moneyCents,
      coinCost: coinCost,
      balance: number('balance'),
      status: json['status']?.toString().trim().toLowerCase() ?? '',
      lastError: json['lastError']?.toString().trim() ?? '',
      canRetry:
          json['canRetry'] == true ||
          json['status'] == 'delivery_failed' ||
          json['status'] == 'failed',
    );
  }
}

class KdjxPaymentBridge {
  KdjxPaymentBridge({MethodChannel? platformChannel})
    : _platformChannel =
          platformChannel ??
          const MethodChannel('com.novel.novel_app/kdjx_game');

  final MethodChannel _platformChannel;

  void start(
    void Function() onPaymentRequestAvailable, {
    void Function()? onAuthorizationRequestAvailable,
  }) {
    _platformChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPaymentRequestAvailable') {
        onPaymentRequestAvailable();
      } else if (call.method == 'onAuthorizationRequestAvailable') {
        onAuthorizationRequestAvailable?.call();
      }
    });
  }

  void stop() => _platformChannel.setMethodCallHandler(null);

  Future<KdjxPaymentRequest?> takePendingRequest() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'takePendingPaymentRequest',
    );
    return value == null ? null : KdjxPaymentRequest.fromPlatform(value);
  }

  Future<bool> acknowledgePaymentRequest(KdjxPaymentRequest request) async {
    return await _platformChannel.invokeMethod<bool>(
          'ackPendingPaymentRequest',
          {
            'gameOrderId': request.gameOrderId,
            'returnNonce': request.returnNonce,
          },
        ) ??
        false;
  }

  Future<KdjxAuthorizationRequest?> takePendingAuthorizationRequest() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'takePendingAuthorizationRequest',
    );
    return value == null ? null : KdjxAuthorizationRequest.fromPlatform(value);
  }

  Future<bool> acknowledgeAuthorizationRequest(
    KdjxAuthorizationRequest request,
  ) async {
    return await _platformChannel.invokeMethod<bool>(
          'ackPendingAuthorizationRequest',
          {'deviceCode': request.deviceCode, 'userCode': request.userCode},
        ) ??
        false;
  }

  Future<bool> returnAuthorizationToGame({
    required String deviceCode,
    required String status,
  }) async {
    if (!_isDeviceCode(deviceCode) || !_isAuthorizationStatus(status)) {
      throw const KdjxGameException('游戏授权回调无效');
    }
    return await _platformChannel.invokeMethod<bool>(
          'returnAuthorizationToGame',
          {'deviceCode': deviceCode, 'status': status},
        ) ??
        false;
  }

  Future<bool> returnToGame({
    required String gameOrderId,
    required String status,
    required int balance,
    required String returnNonce,
  }) async {
    if (!_isIdentifier(gameOrderId) ||
        !_isPaymentStatus(status) ||
        !_isPaymentReturnNonce(returnNonce)) {
      throw const KdjxGameException('游戏支付回调无效');
    }
    return await _platformChannel.invokeMethod<bool>('returnPaymentToGame', {
          'gameOrderId': gameOrderId,
          'status': status,
          'balance': balance,
          'returnNonce': returnNonce,
        }) ??
        false;
  }
}

class KdjxGameService {
  KdjxGameService({
    this.httpClient,
    MethodChannel? platformChannel,
    String? expectedSigningCertificateSha256,
    Set<String>? trustedDownloadHosts,
    String? apiBaseUrl,
  }) : _platformChannel = platformChannel ?? _defaultPlatformChannel,
       _expectedSigningCertificateSha256 = _normalizeFingerprint(
         expectedSigningCertificateSha256 ?? _buildSigningCertificateSha256,
       ),
       _trustedDownloadHosts = _validatedDownloadHosts(
         trustedDownloadHosts ?? _buildDownloadHosts(),
       ),
       _apiBaseUri = _validatedApiBaseUri(
         apiBaseUrl ?? InteractionAuthService.baseUrl,
       );

  static const String manifestUrl =
      'https://novel.kxhub.xyz/games/kdjx/manifest.json';
  static const String _primaryDownloadHost = 'novel.kxhub.xyz';
  static const Set<String> _trustedApiHosts = {
    'novel.kxhub.xyz',
    '49.232.137.85',
  };
  static const String _buildSigningCertificateSha256 = String.fromEnvironment(
    'KDJX_SIGNING_CERT_SHA256',
  );
  static const int maximumApkBytes = 4 * 1024 * 1024 * 1024;
  static const int _maximumManifestBytes = 64 * 1024;
  static const int _maximumJsonBytes = 128 * 1024;
  static const MethodChannel _defaultPlatformChannel = MethodChannel(
    'com.novel.novel_app/kdjx_game',
  );

  final http.Client? httpClient;
  final MethodChannel _platformChannel;
  final String _expectedSigningCertificateSha256;
  final Set<String> _trustedDownloadHosts;
  final Uri _apiBaseUri;

  Future<KdjxGameManifest> fetchManifest() async {
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
        throw const KdjxGameException('游戏版本信息暂时不可用');
      }
      final body = await _readLimitedBytes(
        response,
        limit: _maximumManifestBytes,
        errorMessage: '游戏版本信息无效',
      );
      final dynamic decoded;
      try {
        decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
      } on FormatException {
        throw const KdjxGameException('游戏版本信息无效');
      }
      if (decoded is! Map) {
        throw const KdjxGameException('游戏版本信息无效');
      }
      final decodedMap = decoded.cast<String, dynamic>();
      final rawManifest = decodedMap['item'] is Map
          ? (decodedMap['item'] as Map).cast<String, dynamic>()
          : decodedMap['manifest'] is Map
          ? (decodedMap['manifest'] as Map).cast<String, dynamic>()
          : decodedMap;
      final manifest = KdjxGameManifest.fromJson(rawManifest);
      _validateManifest(manifest);
      return manifest;
    } on KdjxGameException {
      rethrow;
    } catch (_) {
      throw const KdjxGameException('无法连接游戏下载服务器');
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<KdjxInstalledGame> getInstalledGame() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getInstalledGame',
      {'packageName': KdjxGameManifest.expectedPackageName},
    );
    return value == null
        ? const KdjxInstalledGame.notInstalled()
        : KdjxInstalledGame.fromPlatform(value);
  }

  Future<KdjxDeviceEnvironment> getDeviceEnvironment() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getDeviceEnvironment',
    );
    if (value == null) {
      throw const KdjxGameException('无法检查设备存储和网络状态');
    }
    return KdjxDeviceEnvironment.fromPlatform(value);
  }

  Future<KdjxDownloadState> getDownloadState() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getDownloadState',
    );
    return value == null
        ? const KdjxDownloadState.none()
        : KdjxDownloadState.fromPlatform(value);
  }

  Future<KdjxDownloadState> startDownload(
    KdjxGameManifest manifest, {
    required bool allowMetered,
    int preferredSourceIndex = 0,
  }) async {
    _validateManifest(manifest);
    if (preferredSourceIndex < 0 ||
        (manifest.apkUrls.isNotEmpty &&
            preferredSourceIndex >= manifest.apkUrls.length)) {
      throw const KdjxGameException('下载线路无效');
    }
    final fallbackUrl = manifest.apkUrls.isEmpty
        ? ''
        : manifest.apkUrls[preferredSourceIndex].toString();
    final value = await _platformChannel
        .invokeMapMethod<Object?, Object?>('startDownload', {
          'url': fallbackUrl,
          'urls': manifest.apkUrls.map((url) => url.toString()).toList(),
          'parts': manifest.parts.map((part) => part.toJson()).toList(),
          'trustedDownloadHosts': _trustedDownloadHosts.toList()..sort(),
          'signingCertificateSha256': manifest.signingCertificateSha256,
          'sourceIndex': preferredSourceIndex,
          'fileName': manifest.downloadFileName,
          'allowMetered': allowMetered,
        });
    if (value == null) {
      throw const KdjxGameException('游戏下载启动失败');
    }
    return KdjxDownloadState.fromPlatform(value);
  }

  int nextDownloadSourceIndex(
    KdjxGameManifest manifest,
    KdjxDownloadState state,
  ) {
    if (manifest.apkUrls.length <= 1) return 0;
    return (state.sourceIndex + 1) % manifest.apkUrls.length;
  }

  Future<void> clearDownload() =>
      _platformChannel.invokeMethod<void>('clearDownload');

  Future<void> verifyDownloadedApk(
    KdjxGameManifest manifest,
    String localPath,
  ) async {
    _validateManifest(manifest);
    if (localPath.trim().isEmpty) {
      throw const KdjxGameException('未找到已下载的游戏安装包');
    }
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'inspectApk',
      {'path': localPath},
    );
    if (value == null || value['exists'] != true) {
      throw const KdjxGameException('未找到已下载的游戏安装包');
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
      throw const KdjxGameException('安装包校验失败，请重新下载');
    }
    if (packageName != manifest.packageName ||
        versionCode != manifest.versionCode) {
      throw const KdjxGameException('安装包版本与发布信息不一致');
    }
    if (!signatures.contains(manifest.signingCertificateSha256)) {
      throw const KdjxGameException('安装包签名校验失败，已阻止安装');
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

  Future<void> launchGame(String expectedUserId) async {
    if (!_isCanonicalUserId(expectedUserId)) {
      throw const KdjxGameException('Sakura 账号标识无效');
    }
    final launched = await _platformChannel.invokeMethod<bool>('launchGame', {
      'packageName': KdjxGameManifest.expectedPackageName,
      'expectedUserId': expectedUserId,
    });
    if (launched != true) {
      throw const KdjxGameException('Unable to launch KDJX.');
    }
  }

  String createPaymentIdempotencyKey(KdjxPaymentRequest request) {
    if (!_isPaymentReturnNonce(request.returnNonce)) {
      throw const KdjxGameException('支付请求标识无效');
    }
    return 'kdjx-pay-${request.returnNonce}';
  }

  Future<void> decideDeviceAuthorization(
    String token,
    KdjxAuthorizationRequest request, {
    required bool approve,
  }) async {
    if (!_isDeviceCode(request.deviceCode) ||
        _normalizeUserCode(request.userCode) != request.userCode) {
      throw const KdjxGameException('游戏授权请求无效');
    }
    await _authorizedJsonRequest(
      token: token,
      method: 'POST',
      path: '/games/kdjx/device-authorizations/${approve ? 'approve' : 'deny'}',
      body: {'deviceCode': request.deviceCode, 'userCode': request.userCode},
      operation: '授权',
    );
  }

  Future<KdjxPayment> previewPayment(
    String token,
    KdjxPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path: '/games/kdjx/payments/preview',
        body: request.toJson(),
        operation: '支付',
      ),
      request,
    );
  }

  Future<KdjxPayment> pay(
    String token,
    KdjxPaymentRequest request, {
    required String idempotencyKey,
    required KdjxPayment expectedPreview,
  }) async {
    if (!_isIdempotencyKey(idempotencyKey)) {
      throw const KdjxGameException('支付请求标识无效');
    }
    if (!_isExpectedPaymentPreview(expectedPreview, request)) {
      throw const KdjxGameException('支付报价无效，请重新确认');
    }
    final payment = _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path: '/games/kdjx/payments',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {
          ...request.toJson(),
          'idempotencyKey': idempotencyKey,
          'expectedMoneyCents': expectedPreview.moneyCents,
          'expectedCoinCost': expectedPreview.coinCost,
          'expectedDisplayPrice': expectedPreview.displayPrice,
        },
        operation: '支付',
      ),
      request,
    );
    if (payment.moneyCents != expectedPreview.moneyCents ||
        payment.coinCost != expectedPreview.coinCost ||
        payment.displayPrice != expectedPreview.displayPrice) {
      throw const KdjxGameException('支付报价已变化，请重新确认');
    }
    return payment;
  }

  Future<KdjxPayment> paymentStatus(
    String token,
    KdjxPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'GET',
        path:
            '/games/kdjx/payments/${Uri.encodeComponent(request.gameOrderId)}',
        operation: '支付',
      ),
      request,
    );
  }

  Future<KdjxPayment> retryDelivery(
    String token,
    KdjxPaymentRequest request,
  ) async {
    return _paymentFromResponse(
      await _authorizedJsonRequest(
        token: token,
        method: 'POST',
        path:
            '/games/kdjx/payments/${Uri.encodeComponent(request.gameOrderId)}/retry',
        body: const <String, dynamic>{},
        operation: '支付',
      ),
      request,
    );
  }

  Future<Map<String, dynamic>> _authorizedJsonRequest({
    required String token,
    required String method,
    required String path,
    required String operation,
    Map<String, dynamic>? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (token.trim().isEmpty) {
      throw KdjxGameException('请先登录后再进行$operation');
    }
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final request = http.Request(method, Uri.parse('$_apiBaseUri$path'))
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
          .timeout(const Duration(seconds: 20));
      final decoded = await _decodeJsonResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded['error']?.toString().trim() ?? '';
        final message = decoded['message']?.toString().trim() ?? '';
        throw KdjxGameException(
          operation == '支付'
              ? _paymentErrorMessage(code)
              : operation == '授权'
              ? _authorizationErrorMessage(code)
              : (message.isNotEmpty ? message : '游戏登录失败，请稍后重试'),
        );
      }
      return decoded;
    } on KdjxGameException {
      rethrow;
    } on TimeoutException {
      throw KdjxGameException('无法连接游戏$operation服务，请稍后重试');
    } on http.ClientException {
      throw KdjxGameException('无法连接游戏$operation服务，请稍后重试');
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeJsonResponse(
    http.StreamedResponse response,
  ) async {
    final body = await _readLimitedBytes(
      response,
      limit: _maximumJsonBytes,
      errorMessage: '游戏服务返回异常',
    );
    try {
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
      return decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{};
    } on FormatException {
      throw const KdjxGameException('游戏服务返回异常');
    }
  }

  Future<Uint8List> _readLimitedBytes(
    http.StreamedResponse response, {
    required int limit,
    required String errorMessage,
  }) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > limit) {
      throw KdjxGameException(errorMessage);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw KdjxGameException(errorMessage);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  KdjxPayment _paymentFromResponse(
    Map<String, dynamic> response,
    KdjxPaymentRequest request,
  ) {
    final rawItem = response['item'] ?? response['data'];
    final item = rawItem is Map ? rawItem.cast<String, dynamic>() : response;
    final payment = KdjxPayment.fromJson(item);
    if (payment.gameOrderId != request.gameOrderId ||
        payment.sakuraOrderId != 'sakura_${request.gameOrderId}' ||
        payment.productId != request.productId ||
        payment.productName.isEmpty ||
        payment.moneyCents <= 0 ||
        payment.coinCost <= 0 ||
        payment.moneyCents != payment.coinCost * 10 ||
        payment.balance < 0 ||
        !_isYuanPrice(payment.displayPrice)) {
      throw const KdjxGameException('支付价格校验失败，已停止支付');
    }
    return payment;
  }

  bool _isExpectedPaymentPreview(
    KdjxPayment preview,
    KdjxPaymentRequest request,
  ) {
    return preview.gameOrderId == request.gameOrderId &&
        preview.sakuraOrderId == 'sakura_${request.gameOrderId}' &&
        preview.productId == request.productId &&
        preview.productName.isNotEmpty &&
        preview.moneyCents > 0 &&
        preview.coinCost > 0 &&
        preview.moneyCents == preview.coinCost * 10 &&
        preview.balance >= 0 &&
        _isYuanPrice(preview.displayPrice);
  }

  String _paymentErrorMessage(String code) {
    return switch (code) {
      'insufficient_balance' || 'coins_not_enough' => '樱花币余额不足',
      'product_not_found' || 'invalid_product' => '游戏商品不存在',
      'order_conflict' => '游戏订单信息冲突',
      'order_owner_mismatch' => '订单不属于当前账号',
      'payment_quote_changed' ||
      'payment_price_changed' ||
      'price_changed' => '支付报价已变化，请重新确认',
      'unauthorized' => '登录状态已失效，请重新登录',
      'delivery_unavailable' => '游戏发货服务暂时不可用',
      _ => code.isEmpty ? '支付请求失败，请稍后重试' : '支付请求失败：$code',
    };
  }

  String _authorizationErrorMessage(String code) {
    return switch (code) {
      'invalid_device_code' || 'invalid_user_code' => '这次游戏授权请求无效',
      'expired_device_code' => '这次游戏授权请求已过期，请返回游戏重试',
      'device_authorization_already_decided' => '这次游戏授权已经处理',
      'device_authorization_rate_limited' => '授权操作过于频繁，请稍后重试',
      'unauthorized' => '登录状态已失效，请重新登录',
      _ => '游戏授权失败，请稍后重试',
    };
  }

  void _validateManifest(KdjxGameManifest manifest) {
    if (!_isSha256(_expectedSigningCertificateSha256)) {
      throw const KdjxGameException('游戏正式签名尚未配置，已阻止下载');
    }
    if (manifest.packageName != KdjxGameManifest.expectedPackageName ||
        manifest.versionName.isEmpty ||
        manifest.versionCode <= 0 ||
        (manifest.apkUrls.isEmpty && manifest.parts.isEmpty) ||
        manifest.sizeBytes <= 0 ||
        manifest.sizeBytes > maximumApkBytes ||
        manifest.apkUrls.any((uri) => !_isTrustedApkUri(uri, manifest)) ||
        !_areTrustedParts(manifest) ||
        !_isSha256(manifest.sha256) ||
        manifest.signingCertificateSha256 !=
            _expectedSigningCertificateSha256) {
      throw const KdjxGameException('游戏版本信息无效');
    }
  }

  bool _isTrustedApkUri(Uri uri, KdjxGameManifest manifest) =>
      uri.scheme == 'https' &&
      _trustedDownloadHosts.contains(uri.host.toLowerCase()) &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      uri.fragment.isEmpty &&
      !uri.hasQuery &&
      uri.path ==
          '/games/kdjx/kdjx-${manifest.versionCode}-'
              '${manifest.sha256.substring(0, 12)}.apk';

  bool _areTrustedParts(KdjxGameManifest manifest) {
    if (manifest.parts.isEmpty) return true;
    if (manifest.parts.length != 5) return false;
    var total = 0;
    for (var index = 0; index < manifest.parts.length; index++) {
      final part = manifest.parts[index];
      if (part.index != index ||
          part.sizeBytes <= 0 ||
          !_isSha256(part.sha256) ||
          !_isTrustedPartUri(part, manifest)) {
        return false;
      }
      total += part.sizeBytes;
    }
    return total == manifest.sizeBytes;
  }

  bool _isTrustedPartUri(KdjxApkPart part, KdjxGameManifest manifest) {
    final expectedSuffix = '.part-${part.index.toString().padLeft(3, '0')}.apk';
    final expectedPrefix =
        '/games/kdjx/kdjx-${manifest.versionCode}-${manifest.sha256.substring(0, 12)}';
    return part.url.scheme == 'https' &&
        _trustedDownloadHosts.contains(part.url.host.toLowerCase()) &&
        (!part.url.hasPort || part.url.port == 443) &&
        part.url.userInfo.isEmpty &&
        part.url.fragment.isEmpty &&
        !part.url.hasQuery &&
        part.url.path == '$expectedPrefix$expectedSuffix';
  }

  static Set<String> _buildDownloadHosts() => const {_primaryDownloadHost};

  static Set<String> _validatedDownloadHosts(Iterable<String> rawHosts) {
    final hosts = rawHosts
        .map((host) => host.trim().toLowerCase())
        .where((host) => host.isNotEmpty)
        .toSet();
    if (hosts.length != 1 || !hosts.contains(_primaryDownloadHost)) {
      throw ArgumentError.value(
        rawHosts,
        'trustedDownloadHosts',
        'must contain only the production TLS download host',
      );
    }
    return Set<String>.unmodifiable(hosts);
  }

  static Uri _validatedApiBaseUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        !_trustedApiHosts.contains(uri.host.toLowerCase()) ||
        (uri.hasPort && uri.port != 443) ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.hasQuery ||
        uri.path != '/novel-api') {
      throw ArgumentError.value(
        value,
        'apiBaseUrl',
        'must use the owned Novel API HTTPS entry point',
      );
    }
    return uri;
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

bool _isIdentifier(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

bool _isCanonicalUserId(String value) {
  final parsed = int.tryParse(value);
  return parsed != null && parsed > 0 && parsed.toString() == value;
}

bool _isDeviceCode(String value) =>
    value.startsWith('kdjx_device_') &&
    value.length >= 52 &&
    value.length <= 140 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String? _normalizeUserCode(String value) {
  final normalized = value.trim().toUpperCase();
  if (!RegExp(
    r'^(?:[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}|'
    r'[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-'
    r'[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4})$',
  ).hasMatch(normalized)) {
    return null;
  }
  final compact = normalized.replaceAll('-', '');
  return '${compact.substring(0, 4)}-${compact.substring(4)}';
}

bool _isAuthorizationStatus(String value) =>
    const {'approved', 'denied', 'cancelled'}.contains(value);

bool _isIdempotencyKey(String value) =>
    value.length >= 16 &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

bool _isPaymentReturnNonce(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

bool _isPaymentStatus(String value) => const {
  'cancelled',
  'pending',
  'paid',
  'processing',
  'fulfilling',
  'delivered',
  'fulfilled',
  'success',
  'delivery_failed',
  'failed',
  'refunded',
}.contains(value);

bool _isYuanPrice(String value) =>
    RegExp(r'^(?:0|[1-9][0-9]{0,6})(?:\.[0-9]{1,2})?元$').hasMatch(value);

String _formatYuanPrice(int moneyCents) {
  if (moneyCents <= 0) return '';
  if (moneyCents % 100 == 0) return '${moneyCents ~/ 100}元';
  return '${(moneyCents / 100).toStringAsFixed(2)}元';
}
