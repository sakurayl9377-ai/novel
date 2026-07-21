import 'dart:convert';

import 'package:http/http.dart' as http;

import 'interaction_auth_service.dart';

class BailianGameLaunch {
  const BailianGameLaunch({required this.launchUrl});

  final Uri launchUrl;
}

class BailianGameException implements Exception {
  const BailianGameException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BailianGameService {
  BailianGameService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<BailianGameLaunch> createLaunch(String token) async {
    if (token.trim().isEmpty) {
      throw const BailianGameException('请先登录后再进入游戏');
    }

    final response = await _client
        .post(
          Uri.parse(
            '${InteractionAuthService.baseUrl}/games/bailian/sso-ticket',
          ),
          headers: <String, String>{
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${token.trim()}',
          },
          body: '{}',
        )
        .timeout(const Duration(seconds: 15));

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final decoded = _decode(body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BailianGameException(
        decoded['error']?.toString().trim().isNotEmpty == true
            ? decoded['error'].toString()
            : '游戏登录凭证获取失败',
      );
    }

    final launchUrl = Uri.tryParse(decoded['launchUrl']?.toString() ?? '');
    if (launchUrl == null ||
        launchUrl.scheme != 'https' ||
        launchUrl.host != '49.232.137.85' ||
        !launchUrl.path.startsWith('/bailian/')) {
      throw const BailianGameException('游戏启动地址无效');
    }
    return BailianGameLaunch(launchUrl: launchUrl);
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }
}
