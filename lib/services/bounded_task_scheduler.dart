import 'dart:async';

/// Runs asynchronous best-effort work with a concurrency cap and priority.
/// Higher priority tasks start first; tasks with the same priority keep FIFO
/// order. It is intended for image/data prefetching, not user-visible jobs.
class BoundedTaskScheduler {
  BoundedTaskScheduler({required this.maxConcurrent})
    : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final List<_QueuedTask> _pending = <_QueuedTask>[];
  int _running = 0;
  int _sequence = 0;

  int get runningCount => _running;
  int get pendingCount => _pending.length;

  Future<T> schedule<T>(Future<T> Function() task, {int priority = 0}) {
    final completer = Completer<T>();
    _pending.add(
      _QueuedTask(
        priority: priority,
        sequence: _sequence++,
        run: () async {
          try {
            completer.complete(await task());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );
    _pending.sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.sequence.compareTo(b.sequence);
    });
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_running < maxConcurrent && _pending.isNotEmpty) {
      final queued = _pending.removeAt(0);
      _running += 1;
      unawaited(
        queued.run().whenComplete(() {
          _running -= 1;
          _drain();
        }),
      );
    }
  }
}

class _QueuedTask {
  const _QueuedTask({
    required this.priority,
    required this.sequence,
    required this.run,
  });

  final int priority;
  final int sequence;
  final Future<void> Function() run;
}
