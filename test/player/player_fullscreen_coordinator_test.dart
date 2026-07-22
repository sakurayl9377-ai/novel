import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_fullscreen_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('com.novel.novel_app/player');

  test('uses landscape only while Android auto rotation is enabled', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(playerChannel, (call) async {
          if (call.method == 'isAutoRotationEnabled') return true;
          return null;
        });
    addTearDown(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(playerChannel, null);
    });

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
    'does not request orientation while Android rotation is locked',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(playerChannel, (call) async {
        if (call.method == 'isAutoRotationEnabled') return false;
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(playerChannel, null);
      });

      final coordinator = PlayerFullscreenCoordinator();
      await coordinator.enter(wasPlaying: false);
      await coordinator.exit(wasPlaying: false);

      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setPreferredOrientations',
        ),
        isEmpty,
      );
    },
  );
}
