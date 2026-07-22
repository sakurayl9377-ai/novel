import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlayerPlatformService {
  PlayerPlatformService._();

  static const MethodChannel _channel = MethodChannel(
    'com.novel.novel_app/player',
  );

  static bool get _supportsNativePlayerActions =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> isPictureInPictureSupported() async {
    if (!_supportsNativePlayerActions) return false;
    try {
      return await _channel.invokeMethod<bool>('isPictureInPictureSupported') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> isAutoRotationEnabled() async {
    if (!_supportsNativePlayerActions) return false;
    try {
      return await _channel.invokeMethod<bool>('isAutoRotationEnabled') ??
          false;
    } on Exception {
      // A failed lookup must preserve the user's rotation lock.
      return false;
    }
  }

  static Future<bool> enterPictureInPicture({
    int aspectWidth = 16,
    int aspectHeight = 9,
  }) async {
    if (!_supportsNativePlayerActions) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPictureInPicture', {
            'aspectWidth': aspectWidth,
            'aspectHeight': aspectHeight,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<double> getScreenBrightness() async {
    if (!_supportsNativePlayerActions) return 0.5;
    try {
      final value = await _channel.invokeMethod<double>('getScreenBrightness');
      return (value ?? 0.5).clamp(0.01, 1).toDouble();
    } on PlatformException {
      return 0.5;
    }
  }

  static Future<void> setScreenBrightness(double value) async {
    if (!_supportsNativePlayerActions) return;
    try {
      await _channel.invokeMethod<void>('setScreenBrightness', {
        'value': value.clamp(0.01, 1).toDouble(),
      });
    } on PlatformException {
      // Brightness gestures should remain optional on unsupported devices.
    }
  }

  static Future<void> resetScreenBrightness() async {
    if (!_supportsNativePlayerActions) return;
    try {
      await _channel.invokeMethod<void>('resetScreenBrightness');
    } on PlatformException {
      // The activity may already be detached during app shutdown.
    }
  }

  static Future<void> setFullscreenSystemUi(bool enabled) async {
    if (!_supportsNativePlayerActions) return;
    try {
      await _channel.invokeMethod<void>('setFullscreenSystemUi', {
        'enabled': enabled,
      });
    } on PlatformException {
      // Flutter's SystemChrome remains the fallback on non-standard devices.
    }
  }
}
