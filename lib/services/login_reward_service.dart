import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/login_reward_notice.dart';
import 'interaction_auth_service.dart';

class LoginRewardServiceException implements Exception {
  const LoginRewardServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LoginRewardService {
  LoginRewardService({this.httpClient, this.versionCodeLoader});

  static final http.Client _sharedHttpClient = http.Client();

  final http.Client? httpClient;
  final Future<int> Function()? versionCodeLoader;

  Future<LoginRewardSyncResult> sync({required String token}) async {
    if (token.isEmpty) {
      return const LoginRewardSyncResult(balance: 0);
    }
    final versionCode = await _loadVersionCode();
    final json = await _post(
      '/growth/login-rewards/sync',
      token: token,
      body: {'versionCode': versionCode},
    );
    return LoginRewardSyncResult.fromJson(json);
  }

  Future<void> acknowledge({
    required String token,
    required int noticeId,
  }) async {
    if (token.isEmpty || noticeId <= 0) return;
    await _post(
      '/growth/login-rewards/$noticeId/ack',
      token: token,
      body: const {},
    );
  }

  Future<int> _loadVersionCode() async {
    final loader = versionCodeLoader;
    if (loader != null) return loader();
    final package = await PackageInfo.fromPlatform();
    return int.tryParse(package.buildNumber) ?? 0;
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    required String token,
    required Map<String, dynamic> body,
  }) async {
    final response = await (httpClient ?? _sharedHttpClient)
        .post(
          Uri.parse('${InteractionAuthService.baseUrl}$path'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    final decoded = _decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LoginRewardServiceException(
        decoded['message']?.toString() ??
            decoded['error']?.toString() ??
            'login_reward_request_failed',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decode(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      // Fall through to the stable service error below.
    }
    throw const LoginRewardServiceException('login_reward_response_invalid');
  }
}
