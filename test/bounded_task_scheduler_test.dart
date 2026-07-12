import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/bounded_task_scheduler.dart';

void main() {
  test('caps concurrency and starts queued high priority work first', () async {
    final scheduler = BoundedTaskScheduler(maxConcurrent: 1);
    final blocker = Completer<void>();
    final order = <String>[];

    final first = scheduler.schedule(() async {
      order.add('running');
      await blocker.future;
    });
    final low = scheduler.schedule(() async => order.add('low'), priority: 1);
    final high = scheduler.schedule(
      () async => order.add('high'),
      priority: 100,
    );

    expect(scheduler.runningCount, 1);
    expect(scheduler.pendingCount, 2);
    blocker.complete();
    await Future.wait([first, low, high]);

    expect(order, ['running', 'high', 'low']);
    expect(scheduler.runningCount, 0);
  });
}
