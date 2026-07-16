import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/latest_wins.dart';

void main() {
  test('a newer token immediately makes older work stale', () {
    final guard = LatestWins();
    final first = guard.begin();
    final second = guard.begin();

    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isTrue);
    expect(first.generation, 1);
    expect(second.generation, 2);
  });

  test('commit applies state only for the newest token', () {
    final guard = LatestWins();
    var value = 'initial';
    final oldToken = guard.begin();
    final currentToken = guard.begin();

    expect(oldToken.commit(() => value = 'old'), isFalse);
    expect(currentToken.commit(() => value = 'new'), isTrue);
    expect(value, 'new');
  });

  test('run drops a late successful result', () async {
    final guard = LatestWins();
    final oldResult = Completer<String>();
    final newResult = Completer<String>();

    final oldRun = guard.run((_) => oldResult.future);
    final newRun = guard.run((_) => newResult.future);

    newResult.complete('new chapter');
    expect(await newRun, 'new chapter');

    oldResult.complete('old chapter');
    expect(await oldRun, isNull);
  });

  test('invalidate and dispose make outstanding work stale', () {
    final guard = LatestWins();
    final token = guard.begin();

    guard.invalidate();
    expect(token.isCurrent, isFalse);

    final next = guard.begin();
    guard.dispose();
    expect(next.isCurrent, isFalse);
    expect(guard.isDisposed, isTrue);
    expect(guard.begin, throwsStateError);
  });
}
