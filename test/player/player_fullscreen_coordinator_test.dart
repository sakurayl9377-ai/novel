import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_fullscreen_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forces landscape even when Android rotation lock is enabled', () async {
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
    ]);
    expect(orientationCalls.last.arguments, <String>[
      'DeviceOrientation.portraitUp',
    ]);
    expect(coordinator.isFullscreen, isFalse);
    expect(coordinator.consumeResumeIntent(), isTrue);
  });
}
