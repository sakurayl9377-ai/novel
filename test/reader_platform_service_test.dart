import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/reader_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  const playerChannel = MethodChannel('com.novel.novel_app/player');
  late MethodChannel channel;
  late ReaderPlatformService service;
  late TestDefaultBinaryMessenger messenger;
  late List<MethodCall> outboundCalls;
  late List<MethodCall> playerCalls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    channel = MethodChannel(
      'com.novel.novel_app/reader_test_${DateTime.now().microsecondsSinceEpoch}',
    );
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    outboundCalls = <MethodCall>[];
    playerCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      outboundCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(playerChannel, (call) async {
      playerCalls.add(call);
      if (call.method == 'getScreenBrightness') return 0.7;
      return null;
    });
    service = ReaderPlatformService.forTesting(channel);
  });

  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(playerChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('configures and updates the native reader session', () async {
    expect(
      await service.configureReaderSession(
        volumeKeyTurnPage: true,
        keepScreenOn: false,
      ),
      isTrue,
    );
    expect(service.isSessionActive, isTrue);
    expect(outboundCalls, hasLength(1));
    expect(outboundCalls.single.method, 'configureReaderSession');
    expect(outboundCalls.single.arguments, {
      'volumeKeyTurnPage': true,
      'keepScreenOn': false,
    });

    expect(
      await service.configureReaderSession(
        volumeKeyTurnPage: false,
        keepScreenOn: true,
      ),
      isTrue,
    );
    expect(outboundCalls, hasLength(2));
    expect(outboundCalls.last.arguments, {
      'volumeKeyTurnPage': false,
      'keepScreenOn': true,
    });
  });

  test('emits one page command for each recognized volume-key event', () async {
    final commands = <ReaderPageCommand>[];
    final subscription = service.pageCommands.listen(commands.add);
    addTearDown(subscription.cancel);
    await service.configureReaderSession(
      volumeKeyTurnPage: true,
      keepScreenOn: false,
    );

    await _sendPlatformCall(
      messenger,
      channel,
      codec,
      const MethodCall('onVolumeKey', {'action': 'previous'}),
    );
    await _sendPlatformCall(
      messenger,
      channel,
      codec,
      const MethodCall('onVolumeKey', {'action': 'next'}),
    );
    await _sendPlatformCall(
      messenger,
      channel,
      codec,
      const MethodCall('onVolumeKey', {'action': 'unsupported'}),
    );

    expect(commands, [
      ReaderPageCommand.previousPage,
      ReaderPageCommand.nextPage,
    ]);
  });

  test('does not emit commands while volume paging is disabled', () async {
    final commands = <ReaderPageCommand>[];
    final subscription = service.pageCommands.listen(commands.add);
    addTearDown(subscription.cancel);
    await service.configureReaderSession(
      volumeKeyTurnPage: false,
      keepScreenOn: true,
    );

    await _sendPlatformCall(
      messenger,
      channel,
      codec,
      const MethodCall('onVolumeKey', {'action': 'next'}),
    );

    expect(commands, isEmpty);
  });

  test('release is idempotent and ignores late native events', () async {
    final commands = <ReaderPageCommand>[];
    final subscription = service.pageCommands.listen(commands.add);
    addTearDown(subscription.cancel);
    await service.configureReaderSession(
      volumeKeyTurnPage: true,
      keepScreenOn: true,
    );

    await service.releaseReaderSession();
    await service.releaseReaderSession();
    await _sendPlatformCall(
      messenger,
      channel,
      codec,
      const MethodCall('onVolumeKey', {'action': 'previous'}),
    );

    expect(service.isSessionActive, isFalse);
    expect(commands, isEmpty);
    expect(
      outboundCalls.where((call) => call.method == 'releaseReaderSession'),
      hasLength(2),
    );
  });

  test(
    'a late configure response cannot reactivate a released session',
    () async {
      final configureResult = Completer<bool>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        outboundCalls.add(call);
        if (call.method == 'configureReaderSession') {
          return configureResult.future;
        }
        return true;
      });

      final configuring = service.configureReaderSession(
        volumeKeyTurnPage: true,
        keepScreenOn: true,
      );
      await Future<void>.delayed(Duration.zero);
      await service.releaseReaderSession();
      configureResult.complete(true);

      expect(await configuring, isFalse);
      expect(service.isSessionActive, isFalse);
    },
  );

  test('platform failures leave the session inactive', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'configureReaderSession') {
        throw PlatformException(code: 'DETACHED');
      }
      return true;
    });

    expect(
      await service.configureReaderSession(
        volumeKeyTurnPage: true,
        keepScreenOn: true,
      ),
      isFalse,
    );
    expect(service.isSessionActive, isFalse);
  });

  test(
    'brightness uses the existing player channel only during a session',
    () async {
      await service.setScreenBrightness(0.3);
      expect(playerCalls, isEmpty);

      await service.configureReaderSession(
        volumeKeyTurnPage: false,
        keepScreenOn: false,
      );
      expect(await service.getScreenBrightness(), 0.7);
      await service.setScreenBrightness(1.5);

      expect(playerCalls.map((call) => call.method), [
        'getScreenBrightness',
        'setScreenBrightness',
      ]);
      expect(playerCalls.last.arguments, {'value': 1.0});

      await service.releaseReaderSession();
      expect(playerCalls.last.method, 'resetScreenBrightness');
      final callCountAfterRelease = playerCalls.length;

      await service.resetScreenBrightness();
      expect(playerCalls, hasLength(callCountAfterRelease));
    },
  );
}

Future<void> _sendPlatformCall(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  MethodCodec codec,
  MethodCall call,
) async {
  await messenger.handlePlatformMessage(
    channel.name,
    codec.encodeMethodCall(call),
    null,
  );
}
