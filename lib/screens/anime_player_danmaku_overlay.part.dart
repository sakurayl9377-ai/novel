part of 'anime_player_screen.dart';

class _DanmakuOverlaySnapshot {
  const _DanmakuOverlaySnapshot({
    required this.videoController,
    required this.items,
    required this.settings,
  });

  final VideoPlayerController? videoController;
  final List<InteractionDanmaku> items;
  final _DanmakuDisplaySettings settings;
}

class _DanmakuOverlayHost extends StatelessWidget {
  const _DanmakuOverlayHost({
    required this.listenable,
    this.forceFullScreenLayout = false,
  });

  final ValueListenable<_DanmakuOverlaySnapshot> listenable;
  final bool forceFullScreenLayout;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_DanmakuOverlaySnapshot>(
      valueListenable: listenable,
      builder: (context, snapshot, _) {
        if (!snapshot.settings.enabled || snapshot.videoController == null) {
          return const SizedBox.shrink();
        }
        final currentUserId = context.watch<InteractionAuthProvider>().user?.id;
        return IgnorePointer(
          child: _DanmakuCanvasOverlay(
            videoController: snapshot.videoController,
            items: snapshot.items,
            settings: snapshot.settings,
            currentUserId: currentUserId,
            forceFullScreenLayout: forceFullScreenLayout,
          ),
        );
      },
    );
  }
}

class _DanmakuCanvasOverlay extends StatefulWidget {
  const _DanmakuCanvasOverlay({
    required this.videoController,
    required this.items,
    required this.settings,
    required this.currentUserId,
    required this.forceFullScreenLayout,
  });

  final VideoPlayerController? videoController;
  final List<InteractionDanmaku> items;
  final _DanmakuDisplaySettings settings;
  final int? currentUserId;
  final bool forceFullScreenLayout;

  @override
  State<_DanmakuCanvasOverlay> createState() => _DanmakuCanvasOverlayState();
}

class _DanmakuCanvasOverlayState extends State<_DanmakuCanvasOverlay> {
  static const int _maxPendingDanmaku = 64;
  static const int _maxDanmakuDrainPerFrame = 2;
  static const int _maxDanmakuPerSecond = 30;
  static const int _timelineTickIntervalMs = 72;
  static const Duration _danmakuDrainInterval = Duration(milliseconds: 48);

  DanmakuController<int>? _danmakuController;
  VideoPlayerController? _videoController;
  Timer? _danmakuDrainTimer;
  int _nextIndex = 0;
  int _lastPositionMs = 0;
  int _lastHandledPositionMs = -1;
  int _lastTimelineTickAt = 0;
  int _emitWindowStartedAt = 0;
  int _emittedInWindow = 0;
  bool _wasPlaying = false;
  final Set<int> _shownIds = <int>{};
  final Set<int> _queuedIds = <int>{};
  final ListQueue<InteractionDanmaku> _pendingDanmaku =
      ListQueue<InteractionDanmaku>();

  @override
  void initState() {
    super.initState();
    _attachVideoController(widget.videoController);
  }

  @override
  void didUpdateWidget(covariant _DanmakuCanvasOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoController != widget.videoController) {
      _attachVideoController(widget.videoController);
      _resetTimeline();
    }
    if (oldWidget.settings != widget.settings) {
      _danmakuController?.updateOption(widget.settings.toOption());
    }
    if (oldWidget.items != widget.items) {
      _syncIndexToCurrentPosition();
    }
  }

  @override
  void dispose() {
    _danmakuDrainTimer?.cancel();
    _videoController?.removeListener(_handleVideoTick);
    super.dispose();
  }

  void _attachVideoController(VideoPlayerController? controller) {
    _videoController?.removeListener(_handleVideoTick);
    _videoController = controller;
    _videoController?.addListener(_handleVideoTick);
  }

  void _resetTimeline() {
    _danmakuController?.clear();
    _shownIds.clear();
    _queuedIds.clear();
    _pendingDanmaku.clear();
    _danmakuDrainTimer?.cancel();
    _danmakuDrainTimer = null;
    _nextIndex = 0;
    _lastPositionMs = 0;
    _lastHandledPositionMs = -1;
    _lastTimelineTickAt = 0;
    _emitWindowStartedAt = 0;
    _emittedInWindow = 0;
    _wasPlaying = false;
    _syncIndexToCurrentPosition();
  }

  void _syncIndexToCurrentPosition() {
    final value = _videoController?.value;
    if (value == null || !value.isInitialized) return;
    final positionMs = value.position.inMilliseconds;
    _nextIndex = _firstIndexAfter(positionMs - 800);
  }

  int _firstIndexAfter(int positionMs) {
    final items = widget.items;
    var low = 0;
    var high = items.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (items[mid].timeMs < positionMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _handleVideoTick() {
    final value = _videoController?.value;
    if (value == null || !value.isInitialized) return;
    if (!value.isPlaying) {
      if (_wasPlaying) {
        _wasPlaying = false;
        _danmakuDrainTimer?.cancel();
        _danmakuDrainTimer = null;
      }
      return;
    }
    _wasPlaying = true;
    final positionMs = value.position.inMilliseconds;
    final jumped =
        positionMs + 1200 < _lastPositionMs ||
        positionMs - _lastPositionMs > 5000;
    if (jumped) {
      _danmakuController?.clear();
      _shownIds.clear();
      _queuedIds.clear();
      _pendingDanmaku.clear();
      _danmakuDrainTimer?.cancel();
      _danmakuDrainTimer = null;
      _nextIndex = _firstIndexAfter(positionMs - 800);
    }
    _lastPositionMs = positionMs;

    final wallClockMs = DateTime.now().millisecondsSinceEpoch;
    if (!jumped &&
        wallClockMs - _lastTimelineTickAt < _timelineTickIntervalMs &&
        (positionMs - _lastHandledPositionMs).abs() < _timelineTickIntervalMs) {
      return;
    }
    _lastTimelineTickAt = wallClockMs;
    _lastHandledPositionMs = positionMs;

    final items = widget.items;
    final untilMs = positionMs + 520;
    var queued = false;
    while (_nextIndex < items.length && items[_nextIndex].timeMs <= untilMs) {
      final item = items[_nextIndex];
      if (item.timeMs >= positionMs - 1000 &&
          !_shownIds.contains(item.id) &&
          _queuedIds.add(item.id)) {
        _pendingDanmaku.add(item);
        queued = true;
      }
      _nextIndex++;
    }
    _trimPendingDanmaku();
    if (queued) _ensureDanmakuDrainTimer();
    _drainPendingDanmaku(maxItems: 1);
    if (_shownIds.length > 2000) _pruneShownIds(positionMs);
  }

  void _ensureDanmakuDrainTimer() {
    if (_danmakuDrainTimer != null || _pendingDanmaku.isEmpty) return;
    _danmakuDrainTimer = Timer.periodic(_danmakuDrainInterval, (_) {
      _drainPendingDanmaku(maxItems: _maxDanmakuDrainPerFrame);
      if (_pendingDanmaku.isEmpty) {
        _danmakuDrainTimer?.cancel();
        _danmakuDrainTimer = null;
      }
    });
  }

  void _trimPendingDanmaku() {
    while (_pendingDanmaku.length > _maxPendingDanmaku) {
      final dropped = _pendingDanmaku.removeFirst();
      _queuedIds.remove(dropped.id);
      _shownIds.add(dropped.id);
    }
  }

  void _drainPendingDanmaku({required int maxItems}) {
    final controller = _videoController;
    final value = controller?.value;
    final danmakuController = _danmakuController;
    if (value == null ||
        !value.isInitialized ||
        !value.isPlaying ||
        danmakuController == null) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_emitWindowStartedAt == 0 || now - _emitWindowStartedAt >= 1000) {
      _emitWindowStartedAt = now;
      _emittedInWindow = 0;
    }
    final remainingBudget = _maxDanmakuPerSecond - _emittedInWindow;
    if (remainingBudget <= 0) return;
    final allowed = maxItems < remainingBudget ? maxItems : remainingBudget;

    var emitted = 0;
    while (_pendingDanmaku.isNotEmpty && emitted < allowed) {
      final item = _pendingDanmaku.removeFirst();
      _queuedIds.remove(item.id);
      final lateByMs = value.position.inMilliseconds - item.timeMs;
      if (lateByMs > 1800 || !_shownIds.add(item.id)) continue;
      emitted++;
      danmakuController.addDanmaku(
        DanmakuContentItem<int>(
          item.content,
          color: _danmakuColorFromHex(item.color),
          type: _danmakuItemTypeFromMode(item.mode),
          selfSend:
              widget.currentUserId != null &&
              item.user.id == widget.currentUserId,
          extra: item.id,
        ),
      );
    }
    _emittedInWindow += emitted;
  }

  void _pruneShownIds(int positionMs) {
    final minTimeMs = positionMs - 60000;
    final maxTimeMs = positionMs + 1500;
    final recentIds = <int>{};
    for (final item in widget.items) {
      if (item.timeMs < minTimeMs) continue;
      if (item.timeMs > maxTimeMs) break;
      recentIds.add(item.id);
    }
    _shownIds.retainAll(recentIds);
  }

  @override
  Widget build(BuildContext context) {
    final isFullScreen =
        widget.forceFullScreenLayout ||
        ChewieController.of(context).isFullScreen;
    return Padding(
      padding: EdgeInsets.only(
        top: isFullScreen ? 12 : 4,
        bottom: isFullScreen ? 64 : 40,
      ),
      child: RepaintBoundary(
        child: DanmakuScreen<int>(
          option: widget.settings.toOption(),
          createdController: (controller) {
            _danmakuController = controller;
            _danmakuController?.updateOption(widget.settings.toOption());
            _syncIndexToCurrentPosition();
          },
        ),
      ),
    );
  }
}
