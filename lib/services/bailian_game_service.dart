import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'interaction_auth_service.dart';

class BailianGameLaunch {
  const BailianGameLaunch({required this.launchUrl});
  final Uri launchUrl;
}

class BailianPayment {
  const BailianPayment({
    this.id = '',
    required this.gameOrderId,
    required this.productId,
    required this.productName,
    required this.moneyCents,
    required this.coinCost,
    required this.balance,
    required this.status,
    this.source = 'bailian',
    this.createdAt,
    this.fulfilledAt,
    this.refundedAt,
  });

  final String id;
  final String gameOrderId;
  final String productId;
  final String productName;
  final int moneyCents;
  final int coinCost;
  final int balance;
  final String status;
  final String source;
  final DateTime? createdAt;
  final DateTime? fulfilledAt;
  final DateTime? refundedAt;

  factory BailianPayment.fromJson(Map<String, dynamic> json) {
    int number(String key) => int.tryParse(json[key]?.toString() ?? '') ?? 0;
    return BailianPayment(
      id: json['id']?.toString() ?? '',
      gameOrderId: json['gameOrderId']?.toString() ?? '',
      productId: json['productId']?.toString() ?? '',
      productName:
          json['title']?.toString() ??
          json['productName']?.toString() ??
          '樱花币消费',
      moneyCents: number('moneyCents'),
      coinCost: number('coinCost'),
      balance: number('balance'),
      status: json['status']?.toString() ?? '',
      source: json['source']?.toString() ?? 'other',
      createdAt: _parseServerDateTime(json['createdAt']),
      fulfilledAt: _parseServerDateTime(json['fulfilledAt']),
      refundedAt: _parseServerDateTime(json['refundedAt']),
    );
  }
}

DateTime? _parseServerDateTime(Object? raw) {
  final normalized = raw?.toString().trim().replaceFirst(' ', 'T') ?? '';
  if (normalized.isEmpty) return null;
  final hasOffset = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(normalized);
  return DateTime.tryParse(hasOffset ? normalized : '${normalized}Z');
}

class BailianPaymentPage {
  const BailianPaymentPage({
    required this.items,
    required this.hasMore,
    this.snapshotMaxId = 0,
  });

  final List<BailianPayment> items;
  final bool hasMore;
  final int snapshotMaxId;
}

class BailianGameException implements Exception {
  const BailianGameException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BailianGameService {
  BailianGameService({http.Client? client, Uuid? uuid})
    : _client = client ?? http.Client(),
      _uuid = uuid ?? const Uuid();

  final http.Client _client;
  final Uuid _uuid;

  Future<BailianGameLaunch> createLaunch(String token) async {
    final decoded = await _request(
      token: token,
      method: 'POST',
      path: '/games/bailian/sso-ticket',
      body: const <String, dynamic>{},
    );
    final launchUrl = Uri.tryParse(decoded['launchUrl']?.toString() ?? '');
    if (launchUrl == null || !_isAllowedGameUri(launchUrl)) {
      throw const BailianGameException('游戏启动地址无效');
    }
    return BailianGameLaunch(launchUrl: launchUrl);
  }

  Future<BailianPayment> previewPayment(
    String token, {
    required String gameOrderId,
    required String productId,
  }) async => _payment(
    await _request(
      token: token,
      method: 'POST',
      path: '/games/bailian/payments/preview',
      body: {'gameOrderId': gameOrderId, 'productId': productId},
    ),
  );

  Future<BailianPayment> pay(
    String token, {
    required String gameOrderId,
    required String productId,
  }) async {
    final idempotencyKey = _uuid.v4();
    return _payment(
      await _request(
        token: token,
        method: 'POST',
        path: '/games/bailian/payments',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {
          'gameOrderId': gameOrderId,
          'productId': productId,
          'idempotencyKey': idempotencyKey,
        },
      ),
    );
  }

  Future<BailianPayment> paymentStatus(
    String token, {
    required String gameOrderId,
  }) async => _payment(
    await _request(
      token: token,
      method: 'GET',
      path: '/games/bailian/payments/${Uri.encodeComponent(gameOrderId)}',
    ),
  );

  Future<BailianPaymentPage> listPayments(
    String token, {
    int offset = 0,
    int limit = 20,
    int snapshotMaxId = 0,
  }) async {
    final pageSize = limit.clamp(1, 50);
    final query = <String, String>{
      'offset': offset.clamp(0, 1 << 30).toString(),
      'limit': pageSize.toString(),
    };
    if (snapshotMaxId > 0) {
      query['snapshotMaxId'] = snapshotMaxId.toString();
    }
    final decoded = await _request(
      token: token,
      method: 'GET',
      path: Uri(path: '/users/me/orders', queryParameters: query).toString(),
    );
    final rawItems = decoded['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (item) =>
                    BailianPayment.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(growable: false)
        : const <BailianPayment>[];
    final hasMore = decoded.containsKey('hasMore')
        ? decoded['hasMore'] == true
        : items.length >= pageSize;
    return BailianPaymentPage(
      items: items,
      hasMore: hasMore,
      snapshotMaxId:
          int.tryParse(decoded['snapshotMaxId']?.toString() ?? '') ?? 0,
    );
  }

  BailianPayment _payment(Map<String, dynamic> decoded) {
    final item = decoded['item'];
    return BailianPayment.fromJson(
      item is Map<String, dynamic> ? item : decoded,
    );
  }

  Future<Map<String, dynamic>> _request({
    required String token,
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
  }) async {
    if (token.trim().isEmpty) {
      throw const BailianGameException('请先登录后再进入游戏');
    }
    final uri = Uri.parse('${InteractionAuthService.baseUrl}$path');
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${token.trim()}',
        ...headers,
      });
    if (body != null) request.body = jsonEncode(body);
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamed);
    final decoded = _decode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BailianGameException(
        decoded['error']?.toString().trim().isNotEmpty == true
            ? decoded['error'].toString()
            : '请求失败，请稍后重试',
      );
    }
    return decoded;
  }

  static bool _isAllowedGameUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == '49.232.137.85' &&
      uri.path.startsWith('/bailian/');

  Map<String, dynamic> _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }
}
