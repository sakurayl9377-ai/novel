import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_models.dart';
import 'package:novel_app/player/source/external_track_service.dart';

void main() {
  late Directory directory;
  late ExternalTrackService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('external_track_test');
    service = ExternalTrackService();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('accepts supported local subtitle and audio files', () async {
    final subtitle = File('${directory.path}/zh.ass')
      ..writeAsStringSync('test');
    final audio = File('${directory.path}/commentary.m4a')
      ..writeAsBytesSync([1, 2, 3]);

    final subtitleSelection = await service.subtitle(
      subtitle.uri,
      title: '简体中文',
      language: 'zh',
    );
    final audioSelection = await service.audio(audio.uri, title: '评论音轨');

    expect(subtitleSelection.kind, PlayerTrackKind.subtitle);
    expect(subtitleSelection.language, 'zh');
    expect(audioSelection.kind, PlayerTrackKind.audio);
    expect(audioSelection.isExternal, isTrue);
  });

  test('rejects unsupported or empty tracks', () async {
    final unsupported = File('${directory.path}/subtitle.txt')
      ..writeAsStringSync('test');
    final empty = File('${directory.path}/empty.srt')..createSync();

    await expectLater(
      service.subtitle(unsupported.uri),
      throwsA(isA<ExternalTrackException>()),
    );
    await expectLater(
      service.subtitle(empty.uri),
      throwsA(isA<ExternalTrackException>()),
    );
  });
}
