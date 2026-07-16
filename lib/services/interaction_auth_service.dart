import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/interaction_user.dart';

class CaptchaInfo {
  const CaptchaInfo({
    required this.captchaId,
    required this.imageSvg,
    required this.expiresIn,
  });

  final String captchaId;
  final String imageSvg;
  final int expiresIn;
}

class InteractionAuthResult {
  const InteractionAuthResult({required this.token, required this.user});

  final String token;
  final InteractionUser user;
}

class EmailAvailability {
  const EmailAvailability({
    required this.available,
    required this.registered,
    required this.message,
  });

  final bool available;
  final bool registered;
  final String message;
}

class InteractionAuthException implements Exception {
  const InteractionAuthException(
    this.message, {
    this.retryAfter,
    this.statusCode,
  });

  final String message;
  final int? retryAfter;
  final int? statusCode;

  @override
  String toString() => message;
}

class InteractionAuthService {
  InteractionAuthService({this.client, bool? betaTestSessionEnabled})
    : betaTestSessionEnabled =
          betaTestSessionEnabled ?? betaTestSessionBuildEnabled;

  static const bool betaTestSessionBuildEnabled =
      bool.fromEnvironment('READER_BETA') &&
      bool.fromEnvironment('READER_BETA_TEST_ACCOUNT');

  static final http.Client _sharedHttpClient = http.Client();

  static const String baseUrl = String.fromEnvironment(
    'NOVEL_API_BASE_URL',
    defaultValue: 'https://49.232.137.85/novel-api',
  );

  final http.Client? client;
  final bool betaTestSessionEnabled;

  Future<InteractionAuthResult> createBetaTestSession() async {
    if (!betaTestSessionEnabled) {
      throw const InteractionAuthException('测试账号仅在专用测试版中可用');
    }
    try {
      final json = await _request(
        'POST',
        '/auth/beta-session',
        betaTestBootstrap: true,
      );
      return _authResultFromJson(json);
    } on InteractionAuthException catch (error) {
      if (error.statusCode == 404) {
        throw const InteractionAuthException(
          '本地或测试服务尚未开启测试账号入口',
          statusCode: 404,
        );
      }
      rethrow;
    }
  }

  Future<CaptchaInfo> fetchCaptcha() async {
    final json = await _request('GET', '/auth/captcha');
    return CaptchaInfo(
      captchaId: _asString(json['captchaId']),
      imageSvg: _asString(json['imageSvg']),
      expiresIn: _asInt(json['expiresIn']),
    );
  }

  Future<int> sendEmailCode({
    required String email,
    required String captchaId,
    required String captchaCode,
    String purpose = 'register',
  }) async {
    final json = await _request(
      'POST',
      '/auth/email-code',
      body: {
        'email': email,
        'purpose': purpose,
        'captchaId': captchaId,
        'captchaCode': captchaCode,
      },
    );
    return _asInt(json['retryAfter'], fallback: 60);
  }

  Future<EmailAvailability> checkEmailStatus({
    required String email,
    String purpose = 'register',
  }) async {
    final query = Uri(
      queryParameters: {'email': email, 'purpose': purpose},
    ).query;
    final json = await _request('GET', '/auth/email-status?$query');
    return EmailAvailability(
      available: json['available'] == true,
      registered: json['registered'] == true,
      message: _friendlyError(_asString(json['message'])),
    );
  }

  Future<InteractionAuthResult> register({
    required String email,
    required String password,
    required String emailCode,
    String nickname = '',
  }) async {
    final json = await _request(
      'POST',
      '/auth/register',
      body: {
        'email': email,
        'password': password,
        'emailCode': emailCode,
        if (nickname.trim().isNotEmpty) 'nickname': nickname.trim(),
      },
    );
    return _authResultFromJson(json);
  }

  Future<InteractionAuthResult> resetPassword({
    required String email,
    required String password,
    required String emailCode,
  }) async {
    final json = await _request(
      'POST',
      '/auth/reset-password',
      body: {'email': email, 'password': password, 'emailCode': emailCode},
    );
    return _authResultFromJson(json);
  }

  Future<InteractionAuthResult> login({
    required String email,
    required String password,
  }) async {
    final json = await _request(
      'POST',
      '/auth/login',
      body: {'email': email, 'password': password},
    );
    return _authResultFromJson(json);
  }

  Future<InteractionUser> me(String token) async {
    final json = await _request('GET', '/auth/me', token: token);
    final user = json['user'];
    if (user is! Map) throw const InteractionAuthException('账号信息异常');
    return InteractionUser.fromJson(user.cast<String, dynamic>());
  }

  Future<void> reportAppInstall({
    required String token,
    required String installId,
    required String versionName,
    required int versionCode,
    required String platform,
    String osVersion = '',
    String deviceModel = '',
  }) async {
    await _request(
      'POST',
      '/users/me/app-install',
      token: token,
      body: {
        'installId': installId,
        'versionName': versionName,
        'versionCode': versionCode,
        'platform': platform,
        'osVersion': osVersion,
        'deviceModel': deviceModel,
      },
    );
  }

  Future<void> logout(String token) async {
    await _request('POST', '/auth/logout', token: token);
  }

  InteractionAuthResult _authResultFromJson(Map<String, dynamic> json) {
    final token = _asString(json['token']);
    final user = json['user'];
    if (token.isEmpty || user is! Map) {
      throw const InteractionAuthException('登录结果异常');
    }
    return InteractionAuthResult(
      token: token,
      user: InteractionUser.fromJson(user.cast<String, dynamic>()),
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool betaTestBootstrap = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null || method == 'POST') 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (betaTestBootstrap) 'X-Sakura-Reader-Beta': '1',
    };
    final httpClient = client ?? _sharedHttpClient;
    final response = switch (method) {
      'GET' =>
        await httpClient
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15)),
      'POST' =>
        await httpClient
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 15)),
      _ => throw ArgumentError('Unsupported method $method'),
    };
    final decoded = _decodeJson(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw InteractionAuthException(
        _friendlyError(_asString(decoded['error'])),
        retryAfter: _asInt(decoded['retryAfter'], fallback: 0),
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeJson(List<int> bytes) {
    final body = utf8.decode(bytes, allowMalformed: true);
    if (body.trimLeft().startsWith('<')) {
      throw const InteractionAuthException('互动服务暂不可用，请检查服务器配置');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const InteractionAuthException('服务响应格式异常');
    }
    if (decoded is! Map) throw const InteractionAuthException('服务响应异常');
    return decoded.cast<String, dynamic>();
  }

  String _friendlyError(String error) {
    return switch (error) {
      'email already registered' || 'email already registered' => '邮箱已注册',
      'email available' => '邮箱可用',
      'email registered' => '邮箱已注册',
      'email not registered' => '邮箱尚未注册',
      'registration ip banned' => '当前网络环境暂时无法注册',
      'email_code_cooldown' => '验证码发送太频繁，请稍后再试',
      'email_code_daily_limit' => '今天验证码发送次数已达上限，请明天再试',
      'captcha invalid' => '图片验证码不正确',
      'email code invalid' => '邮箱验证码不正确或已过期',
      'invalid_credentials' => '邮箱或密码不正确',
      'account_banned' => '账号已被封禁',
      'unauthorized' => '登录已过期',
      _ => error.isEmpty ? '请求失败，请稍后再试' : error,
    };
  }
}

String _asString(dynamic value) => value?.toString().trim() ?? '';

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
