import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_fullscreen_transition_guard.dart';

void main() {
  test('locks repeated toggles and keeps resume intent during grace', () {
    final guard = PlayerFullscreenTransitionGuard();

    expect(guard.begin(wasPlaying: true, nowMs: 1000), isTrue);
    expect(guard.begin(wasPlaying: true, nowMs: 1100), isFalse);
    expect(guard.suppressesLifecyclePause(2000), isTrue);
    expect(guard.shouldResume(2000), isTrue);

    guard.finishTransition();
    expect(guard.transitionActive, isFalse);
    expect(guard.suppressesLifecyclePause(4100), isTrue);
    expect(guard.shouldResume(4100), isTrue);

    guard.expire(4300);
    expect(guard.suppressesLifecyclePause(4300), isFalse);
    expect(guard.shouldResume(4300), isFalse);
  });

  test('manual pause cancels automatic resume during grace', () {
    final guard = PlayerFullscreenTransitionGuard();
    guard.begin(wasPlaying: true, nowMs: 1000);

    guard.recordPlaybackIntent(false);

    expect(guard.shouldResume(1200), isFalse);
    expect(guard.resumeAllowedUntilMs, 0);
  });
}
