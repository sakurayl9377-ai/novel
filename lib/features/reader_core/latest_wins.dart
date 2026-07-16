import 'dart:async';

/// A small generation guard for async reader operations.
///
/// Starting a new operation immediately makes every older token stale. This
/// does not attempt to cancel I/O; it prevents late results from mutating the
/// current chapter/page state.
final class LatestWins {
  int _generation = 0;
  bool _disposed = false;

  int get generation => _generation;
  bool get isDisposed => _disposed;

  LatestWinsToken begin() {
    if (_disposed) {
      throw StateError('Cannot begin an operation after LatestWins.dispose().');
    }
    _generation += 1;
    return LatestWinsToken._(this, _generation);
  }

  /// Makes every issued token stale without starting another operation.
  void invalidate() {
    if (_disposed) return;
    _generation += 1;
  }

  /// Runs [operation] and returns its value only if it is still the newest.
  ///
  /// Errors are intentionally not swallowed. Callers can use the supplied
  /// token in their error handler when stale failures should be ignored.
  Future<T?> run<T>(
    FutureOr<T> Function(LatestWinsToken token) operation,
  ) async {
    final token = begin();
    final value = await operation(token);
    return token.isCurrent ? value : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
  }
}

final class LatestWinsToken {
  const LatestWinsToken._(this._owner, this.generation);

  final LatestWins _owner;
  final int generation;

  bool get isCurrent {
    return !_owner._disposed && _owner._generation == generation;
  }

  /// Executes [action] synchronously only while this token is current.
  bool commit(void Function() action) {
    if (!isCurrent) return false;
    action();
    return true;
  }
}
