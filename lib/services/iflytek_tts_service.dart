import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/tts_settings.dart';
import 'interaction_auth_service.dart';

class IflytekTtsService {
  IflytekTtsService({
    this.httpClient,
    this.requestTimeout = const Duration(seconds: 26),
    this.retryDelay = const Duration(milliseconds: 400),
    this.maxAttempts = 2,
  }) : assert(maxAttempts > 0);

  static final http.Client _sharedHttpClient = http.Client();
  final http.Client? httpClient;
  final Duration requestTimeout;
  final Duration retryDelay;
  final int maxAttempts;

  Future<Uint8List> synthesize({
    required String text,
    required TtsSettings settings,
    required String authToken,
    required double rate,
    required double volume,
    required double pitch,
  }) async {
    if (authToken.trim().isEmpty) {
      throw StateError('使用科大讯飞朗读需要先登录');
    }
    final uri = Uri.parse('${InteractionAuthService.baseUrl}/speech/tts');
    final headers = {
      'Accept': 'audio/mpeg',
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${authToken.trim()}',
    };
    final body = jsonEncode({
      'text': text,
      'voice': settings.iflytekVoiceName,
      'rate': rate,
      'volume': volume,
      'pitch': pitch,
    });

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _synthesizeOnce(uri, headers, body);
      } on IflytekTtsException catch (error) {
        if (!error.isRetryable || attempt >= maxAttempts) rethrow;
        if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
      }
    }
    throw const IflytekTtsException(
      code: 'speech_tts_failed',
      message: '科大讯飞语音合成失败，请稍后重试',
    );
  }

  Future<Uint8List> _synthesizeOnce(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    late http.Response response;
    try {
      response = await (httpClient ?? _sharedHttpClient)
          .post(uri, headers: headers, body: body)
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const IflytekTtsException(
        code: 'speech_tts_client_timeout',
        message: '科大讯飞响应超时，请检查网络后点击继续',
        isRetryable: true,
      );
    } on http.ClientException {
      throw const IflytekTtsException(
        code: 'speech_tts_connection_failed',
        message: '网络连接不稳定，请检查网络后点击继续',
        isRetryable: true,
      );
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.bodyBytes.isEmpty) {
        throw const IflytekTtsException(
          code: 'speech_tts_empty',
          message: '科大讯飞未返回语音，请点击继续重试',
          isRetryable: true,
        );
      }
      return response.bodyBytes;
    }
    var error = '';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) error = decoded['error']?.toString() ?? '';
    } catch (_) {}
    throw IflytekTtsException(
      code: error.isEmpty ? 'speech_tts_failed' : error,
      message: _friendlyError(error, response.statusCode),
      isRetryable: _isRetryable(error, response.statusCode),
    );
  }

  bool _isRetryable(String error, int statusCode) {
    return statusCode == 408 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504 ||
        error == 'speech_tts_timeout' ||
        error == 'speech_tts_connection_closed' ||
        error == 'speech_tts_connection_failed';
  }

  String _friendlyError(String error, int statusCode) {
    return switch (error) {
      'speech_tts_config_missing' => '科大讯飞朗读暂未启用，请联系管理员配置',
      'speech_tts_text_invalid' => '朗读文本不符合要求',
      'speech_tts_voice_invalid' => '所选讯飞发音人不可用',
      'speech_tts_timeout' => '科大讯飞响应超时，请检查网络后点击继续',
      'speech_tts_connection_closed' ||
      'speech_tts_connection_failed' => '网络连接不稳定，请检查网络后点击继续',
      'speech_tts_rate_limited' => '朗读请求过于频繁，请稍后重试',
      'unauthorized' || 'account_banned' => '登录状态不可用，请重新登录',
      _ when statusCode == 401 || statusCode == 403 => '登录状态不可用，请重新登录',
      _ => '科大讯飞语音合成失败，请稍后重试',
    };
  }
}

class IflytekTtsException implements Exception {
  const IflytekTtsException({
    required this.code,
    required this.message,
    this.isRetryable = false,
  });

  final String code;
  final String message;
  final bool isRetryable;

  @override
  String toString() => message;
}
