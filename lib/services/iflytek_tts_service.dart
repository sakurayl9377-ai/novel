import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/tts_settings.dart';
import 'interaction_auth_service.dart';

class IflytekTtsService {
  IflytekTtsService({this.httpClient});

  static final http.Client _sharedHttpClient = http.Client();
  final http.Client? httpClient;

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
    final response = await (httpClient ?? _sharedHttpClient)
        .post(
          Uri.parse('${InteractionAuthService.baseUrl}/speech/tts'),
          headers: {
            'Accept': 'audio/mpeg',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${authToken.trim()}',
          },
          body: jsonEncode({
            'text': text,
            'voice': settings.iflytekVoiceName,
            'rate': rate,
            'volume': volume,
            'pitch': pitch,
          }),
        )
        .timeout(const Duration(seconds: 35));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.bodyBytes.isEmpty) throw StateError('讯飞语音合成结果为空');
      return response.bodyBytes;
    }
    var error = '';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) error = decoded['error']?.toString() ?? '';
    } catch (_) {}
    throw StateError(_friendlyError(error, response.statusCode));
  }

  String _friendlyError(String error, int statusCode) {
    return switch (error) {
      'speech_tts_config_missing' => '科大讯飞朗读暂未启用，请联系管理员配置',
      'speech_tts_text_invalid' => '朗读文本不符合要求',
      'speech_tts_voice_invalid' => '所选讯飞发音人不可用',
      'speech_tts_timeout' => '科大讯飞语音合成超时，请稍后重试',
      'speech_tts_rate_limited' => '朗读请求过于频繁，请稍后重试',
      'unauthorized' || 'account_banned' => '登录状态不可用，请重新登录',
      _ when statusCode == 401 || statusCode == 403 => '登录状态不可用，请重新登录',
      _ => '科大讯飞语音合成失败，请稍后重试',
    };
  }
}
