import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SuibianSessionException implements Exception {
  const SuibianSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SuibianSessionService {
  SuibianSessionService({
    http.Client? client,
    this.apiBaseUrl = const String.fromEnvironment(
      'SUIBIAN_VIDEO_API_BASE_URL',
      defaultValue: 'https://dfyc.cc.cd/video-api',
    ),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiBaseUrl;
  final http.Client _client;
  final bool _ownsClient;

  Future<String> exchangeNovelToken(String novelToken) async {
    final normalizedToken = novelToken.trim();
    if (normalizedToken.isEmpty) {
      throw const SuibianSessionException('Novel 登录状态已失效，请重新登录');
    }

    final baseUri = Uri.parse(apiBaseUrl);
    final exchangeUri = baseUri.replace(
      path:
          '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}/auth/novel-exchange',
    );

    try {
      final response = await _client
          .post(
            exchangeUri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'token': normalizedToken}),
          )
          .timeout(const Duration(seconds: 15));

      final payload = _decodePayload(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SuibianSessionException(
          _readMessage(payload) ?? '随便看登录失败（${response.statusCode}）',
        );
      }

      final token = payload['token']?.toString().trim() ?? '';
      if (token.isEmpty) {
        throw const SuibianSessionException('视频站未返回有效登录凭证');
      }
      return token;
    } on TimeoutException {
      throw const SuibianSessionException('连接随便看超时，请检查网络后重试');
    } on SuibianSessionException {
      rethrow;
    } on FormatException {
      throw const SuibianSessionException('视频站返回了无法识别的数据');
    } catch (_) {
      throw const SuibianSessionException('暂时无法连接随便看，请稍后重试');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, dynamic> _decodePayload(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    return decoded;
  }

  String? _readMessage(Map<String, dynamic> payload) {
    for (final key in const ['message', 'error']) {
      final value = payload[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}
