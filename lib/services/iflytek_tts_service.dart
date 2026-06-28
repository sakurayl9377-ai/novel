import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/tts_settings.dart';

class IflytekTtsService {
  static final Uri _apiUri = Uri.parse('wss://tts-api.xfyun.cn/v2/tts');

  Future<Uint8List> synthesize({
    required String text,
    required TtsSettings settings,
    required double rate,
    required double volume,
    required double pitch,
  }) async {
    if (!settings.hasIflytekCredentials) {
      throw StateError('科大讯飞语音配置不完整');
    }

    final wsUrl = _signedUrl(settings);
    final channel = WebSocketChannel.connect(wsUrl);
    final audioChunks = <int>[];
    final completer = Completer<Uint8List>();
    late final StreamSubscription subscription;
    Timer? timeout;

    void finishWithError(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      timeout?.cancel();
      unawaited(subscription.cancel());
      unawaited(channel.sink.close());
    }

    subscription = channel.stream.listen(
      (event) {
        try {
          final data = jsonDecode(event as String) as Map<String, dynamic>;
          final code = data['code'] as int? ?? -1;
          if (code != 0) {
            finishWithError(
              StateError(data['message']?.toString() ?? '讯飞合成失败'),
            );
            return;
          }

          final audio = data['data']?['audio'] as String?;
          if (audio != null && audio.isNotEmpty) {
            audioChunks.addAll(base64Decode(audio));
          }

          final status = data['data']?['status'] as int?;
          if (status == 2 && !completer.isCompleted) {
            completer.complete(Uint8List.fromList(audioChunks));
            timeout?.cancel();
            unawaited(subscription.cancel());
            unawaited(channel.sink.close());
          }
        } catch (e) {
          finishWithError(e);
        }
      },
      onError: finishWithError,
      onDone: () {
        if (!completer.isCompleted && audioChunks.isNotEmpty) {
          completer.complete(Uint8List.fromList(audioChunks));
        } else if (!completer.isCompleted) {
          completer.completeError(StateError('讯飞合成连接已关闭'));
        }
      },
      cancelOnError: true,
    );

    timeout = Timer(const Duration(seconds: 30), () {
      finishWithError(TimeoutException('讯飞合成超时'));
    });

    channel.sink.add(
      jsonEncode({
        'common': {'app_id': settings.iflytekAppId.trim()},
        'business': {
          'aue': 'lame',
          'sfl': 1,
          'tte': 'UTF8',
          'vcn': settings.iflytekVoiceName,
          'speed': _toIflytekValue(rate),
          'volume': _toIflytekValue(volume),
          'pitch': _toIflytekPitchValue(pitch),
        },
        'data': {'status': 2, 'text': base64Encode(utf8.encode(text))},
      }),
    );

    return completer.future;
  }

  Uri _signedUrl(TtsSettings settings) {
    final host = _apiUri.host;
    final path = _apiUri.path;
    final date = HttpDate.format(DateTime.now().toUtc());
    final signatureOrigin = 'host: $host\ndate: $date\nGET $path HTTP/1.1';
    final hmacSha256 = Hmac(
      sha256,
      utf8.encode(settings.iflytekApiSecret.trim()),
    );
    final signature = base64Encode(
      hmacSha256.convert(utf8.encode(signatureOrigin)).bytes,
    );
    final authorizationOrigin =
        'api_key="${settings.iflytekApiKey.trim()}", algorithm="hmac-sha256", headers="host date request-line", signature="$signature"';
    final authorization = base64Encode(utf8.encode(authorizationOrigin));

    return _apiUri.replace(
      queryParameters: {
        'authorization': authorization,
        'date': date,
        'host': host,
      },
    );
  }

  int _toIflytekValue(double value) =>
      (value.clamp(0.0, 1.0) * 100).round().clamp(0, 100);

  int _toIflytekPitchValue(double pitch) {
    final safePitch = pitch.clamp(0.5, 2.0);
    final value = safePitch <= 1.0
        ? (safePitch - 0.5) * 100
        : 50 + (safePitch - 1.0) * 50;
    return value.round().clamp(0, 100);
  }
}
