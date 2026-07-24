import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_fullscreen_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forces landscape without changing the Android rotation lock', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final coordinator = PlayerFullscreenCoordinator();
    await coordinator.enter(wasPlaying: true);
    await coordinator.exit(wasPlaying: true);

    final orientationCalls = calls
        .where((call) => call.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(orientationCalls, hasLength(2));
    expect(orientationCalls.first.arguments, <String>[
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(orientationCalls.last.arguments, isEmpty);
    expect(coordinator.isFullscreen, isFalse);
    expect(coordinator.consumeResumeIntent(), isTrue);
  });

  test(
    'does not leave an orientation override after fullscreen exits',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final coordinator = PlayerFullscreenCoordinator();
      await coordinator.enter(wasPlaying: false);
      await coordinator.exit(wasPlaying: false);

      final orientationCalls = calls
          .where(
            (call) => call.method == 'SystemChrome.setPreferredOrientations',
          )
          .toList();
      expect(orientationCalls, hasLength(2));
      expect(orientationCalls.last.arguments, isEmpty);
      expect(coordinator.isFullscreen, isFalse);
      expect(coordinator.consumeResumeIntent(), isFalse);
    },
  );
}
