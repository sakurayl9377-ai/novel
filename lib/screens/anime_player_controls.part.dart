part of 'anime_player_screen.dart';

class _AnimeVideoControlsState extends State<_AnimeVideoControls> {
  ChewieController? _chewieController;
  VideoPlayerController? _videoController;
  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _isSeeking = false;
  bool _playAfterSeek = false;
  double? _dragPositionMs;
  int? _gesturePointer;
  Offset? _gestureStartLocal;
  _VideoGestureMode _gestureMode = _VideoGestureMode.none;
  double _gestureStartPositionMs = 0;
  double _gesturePreviewPositionMs = 0;
  double _gestureStartVolume = _AnimeVideoVolume.defaultVolume;
  double _currentVolume = _AnimeVideoVolume.current;
  double? _volumePreview;
  bool _brightnessLoaded = false;
  bool? _lastKnownFullScreen;
  double _gestureStartBrightness = 0.5;
  double _currentBrightness = 0.5;
  double? _brightnessPreview;

  bool get _usesFullScreenLayout =>
      widget.forceFullScreenLayout ||
      (_chewieController?.isFullScreen ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chewieController = ChewieController.of(context);
    if (_chewieController == chewieController) return;
    _chewieController?.removeListener(_handleChewieChanged);
    _videoController?.removeListener(_handleVideoChanged);
    _chewieController = chewieController;
    _lastKnownFullScreen = chewieController.isFullScreen;
    chewieController.addListener(_handleChewieChanged);
    _videoController = chewieController.videoPlayerController
      ..addListener(_handleVideoChanged);
    _currentVolume = _AnimeVideoVolume.current;
    unawaited(_videoController?.setVolume(_currentVolume));
    if (!_brightnessLoaded) unawaited(_loadBrightness());
    _restartHideTimer();
  }

  Future<void> _loadBrightness() async {
    final value = await PlayerPlatformService.getScreenBrightness();
    if (!mounted) return;
    _brightnessLoaded = true;
    _currentBrightness = value;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _chewieController?.removeListener(_handleChewieChanged);
    _videoController?.removeListener(_handleVideoChanged);
    super.dispose();
  }

  void _handleVideoChanged() {
    if (mounted) setState(() {});
  }

  void _handleChewieChanged() {
    final isFullScreen = _chewieController?.isFullScreen;
    if (!mounted ||
        isFullScreen == null ||
        isFullScreen == _lastKnownFullScreen) {
      return;
    }
    _lastKnownFullScreen = isFullScreen;
    setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _restartHideTimer();
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _restartHideTimer();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    final controller = _videoController;
    if (!_controlsVisible ||
        controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlay() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    _showControls();
    if (controller.value.isPlaying) {
      widget.onPlaybackIntentChanged(false);
      await controller.pause();
    } else {
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
      }
      widget.onPlaybackIntentChanged(true);
      await controller.play();
    }
    _restartHideTimer();
  }

  Future<void> _seekToPosition(Duration target) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    _hideTimer?.cancel();
    final shouldKeepPlaying = controller.value.isPlaying || _playAfterSeek;
    setState(() {
      _isSeeking = true;
      _playAfterSeek = shouldKeepPlaying;
    });
    try {
      await controller.seekTo(target);
      if (_playAfterSeek && !controller.value.isPlaying) {
        await controller.play();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSeeking = false;
          _playAfterSeek = false;
          _dragPositionMs = null;
        });
        _restartHideTimer();
      }
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final controller = _videoController;
    if (controller == null) return;
    await controller.setPlaybackSpeed(speed);
    widget.onPlaybackSpeedChanged(speed);
    _showControls();
  }

  void _handlePointerDown(PointerDownEvent event) {
    final controller = _videoController;
    final size = context.size;
    if (_gesturePointer != null ||
        controller == null ||
        !controller.value.isInitialized ||
        size == null ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }

    if (event.localPosition.dy >= size.height - 86) return;

    _gesturePointer = event.pointer;
    _gestureStartLocal = event.localPosition;
    _gestureMode = _VideoGestureMode.none;
    _gestureStartPositionMs = controller.value.position.inMilliseconds
        .toDouble();
    _gesturePreviewPositionMs = _gestureStartPositionMs;
    _gestureStartVolume = _currentVolume;
    _gestureStartBrightness = _currentBrightness;
    _volumePreview = null;
    _brightnessPreview = null;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_gesturePointer != event.pointer) return;
    final controller = _videoController;
    final start = _gestureStartLocal;
    final size = context.size;
    if (controller == null ||
        !controller.value.isInitialized ||
        start == null ||
        size == null ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }

    final offset = event.localPosition - start;
    var mode = _gestureMode;
    if (mode == _VideoGestureMode.none) {
      final horizontal = offset.dx.abs();
      final vertical = offset.dy.abs();
      if (horizontal < 10 && vertical < 10) return;

      final startsInVolumeArea = start.dx >= size.width * 0.66;
      final startsInBrightnessArea = start.dx <= size.width * 0.34;
      if (startsInBrightnessArea && vertical > horizontal) {
        mode = _VideoGestureMode.brightness;
      } else if (startsInVolumeArea && vertical > horizontal) {
        mode = _VideoGestureMode.volume;
      } else if (horizontal > vertical) {
        mode = _VideoGestureMode.seek;
      } else {
        return;
      }
      _hideTimer?.cancel();
    }

    if (mode == _VideoGestureMode.seek) {
      final durationMs = controller.value.duration.inMilliseconds;
      if (durationMs <= 0) return;
      final targetMs =
          (_gestureStartPositionMs + durationMs * offset.dx / size.width)
              .clamp(0.0, durationMs.toDouble())
              .toDouble();
      setState(() {
        _controlsVisible = true;
        _gestureMode = mode;
        _gesturePreviewPositionMs = targetMs;
        _dragPositionMs = targetMs;
      });
      return;
    }

    if (mode == _VideoGestureMode.brightness) {
      final nextBrightness = (_gestureStartBrightness - offset.dy / size.height)
          .clamp(0.01, 1.0)
          .toDouble();
      _currentBrightness = nextBrightness;
      unawaited(PlayerPlatformService.setScreenBrightness(nextBrightness));
      setState(() {
        _controlsVisible = true;
        _gestureMode = mode;
        _brightnessPreview = nextBrightness;
      });
      return;
    }

    final nextVolume = (_gestureStartVolume - offset.dy / size.height)
        .clamp(0.0, 1.0)
        .toDouble();
    _AnimeVideoVolume.set(nextVolume);
    _currentVolume = _AnimeVideoVolume.current;
    unawaited(controller.setVolume(_currentVolume));
    widget.onVolumeChanged(_currentVolume);
    setState(() {
      _controlsVisible = true;
      _gestureMode = mode;
      _volumePreview = _currentVolume;
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_gesturePointer != event.pointer) return;
    _finishPointerGesture(commitSeek: true);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_gesturePointer != event.pointer) return;
    _finishPointerGesture(commitSeek: false);
  }

  void _finishPointerGesture({required bool commitSeek}) {
    final mode = _gestureMode;
    final targetMs = _gesturePreviewPositionMs;
    _gesturePointer = null;
    _gestureStartLocal = null;
    _gestureMode = _VideoGestureMode.none;
    _volumePreview = null;
    _brightnessPreview = null;

    if (!mounted) return;
    setState(() {
      if (mode != _VideoGestureMode.seek || !commitSeek) {
        _dragPositionMs = null;
      }
    });

    if (mode == _VideoGestureMode.seek && commitSeek) {
      unawaited(_seekToPosition(Duration(milliseconds: targetMs.round())));
    } else {
      _restartHideTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chewieController = _chewieController;
    final controller = _videoController;
    if (chewieController == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return const SizedBox.expand();
    }

    final value = controller.value;
    final durationMs = value.duration.inMilliseconds;
    final positionMs = (_dragPositionMs ?? value.position.inMilliseconds)
        .clamp(0, durationMs)
        .toDouble();

    return SizedBox.expand(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_usesFullScreenLayout)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: SafeArea(
                              child: _ControlButton(
                                tooltip: '退出全屏',
                                icon: Icons.arrow_back_rounded,
                                size: 48,
                                iconSize: 32,
                                onPressed: () {
                                  _showControls();
                                  unawaited(
                                    widget.onFullScreenPressed(
                                      chewieController,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        if (_usesFullScreenLayout)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: SafeArea(
                              child: _FullScreenQuickButton(
                                icon: Icons.tune_rounded,
                                label: '设置',
                                onPressed: () {
                                  _showControls();
                                  widget.onDanmakuSettingsPressed(context);
                                },
                              ),
                            ),
                          ),
                        if (_isSeeking)
                          const Center(
                            child: SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              ),
                            ),
                          ),
                        if (_gestureMode == _VideoGestureMode.seek)
                          _buildSeekPreview(value),
                        if (_gestureMode == _VideoGestureMode.volume &&
                            _volumePreview != null)
                          _buildVolumePreview(_volumePreview!),
                        if (_gestureMode == _VideoGestureMode.brightness &&
                            _brightnessPreview != null)
                          _buildBrightnessPreview(_brightnessPreview!),
                        ValueListenableBuilder<_DanmakuOverlaySnapshot>(
                          valueListenable: widget.danmakuListenable,
                          builder: (context, snapshot, _) {
                            return _buildBottomControls(
                              chewieController: chewieController,
                              value: value,
                              durationMs: durationMs,
                              positionMs: positionMs,
                              danmakuSettings: snapshot.settings,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls({
    required ChewieController chewieController,
    required VideoPlayerValue value,
    required int durationMs,
    required double positionMs,
    required _DanmakuDisplaySettings danmakuSettings,
  }) {
    final progress = durationMs <= 0 ? 0.0 : positionMs / durationMs;
    final useWideFullScreenControls =
        _usesFullScreenLayout && MediaQuery.sizeOf(context).width >= 600;
    if (useWideFullScreenControls) {
      return _buildFullScreenBottomControls(
        chewieController: chewieController,
        value: value,
        durationMs: durationMs,
        positionMs: positionMs,
        progress: progress,
        danmakuSettings: danmakuSettings,
      );
    }

    final mediaQuery = MediaQuery.of(context);
    final protectedBottom = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    );
    final bottom = _usesFullScreenLayout
        ? math.max(12.0, protectedBottom + 6)
        : 8.0;

    return Positioned(
      left: 12,
      right: 8,
      bottom: bottom,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                _formatDuration(Duration(milliseconds: positionMs.round())),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _buildProgressSeekBar(
                    durationMs: durationMs,
                    progress: progress,
                  ),
                ),
              ),
              Text(
                _formatDuration(value.duration),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 40,
                ),
                tooltip: value.isPlaying ? '暂停' : '播放',
                onPressed: _isSeeking ? null : _togglePlay,
                icon: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 40,
                ),
                tooltip: '下一集',
                onPressed: widget.canPlayNext
                    ? () {
                        _showControls();
                        widget.onNextEpisodePressed();
                      }
                    : null,
                icon: const Icon(Icons.skip_next_rounded),
                color: Colors.white,
                disabledColor: Colors.white30,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 40,
                ),
                tooltip: danmakuSettings.enabled ? '关闭弹幕' : '开启弹幕',
                onPressed: () {
                  _showControls();
                  widget.onDanmakuEnabledChanged(!danmakuSettings.enabled);
                },
                icon: Icon(
                  danmakuSettings.enabled
                      ? Icons.subtitles_rounded
                      : Icons.subtitles_off_rounded,
                  color: danmakuSettings.enabled
                      ? AppTheme.primaryColor
                      : Colors.white,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _CompactDanmakuInputButton(
                  onPressed: () {
                    _showControls();
                    widget.onDanmakuComposePressed(context);
                  },
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<double>(
                tooltip: '播放速度',
                onOpened: _showControls,
                onSelected: _setPlaybackSpeed,
                itemBuilder: (context) => chewieController.playbackSpeeds
                    .map(
                      (speed) =>
                          PopupMenuItem(value: speed, child: Text('${speed}x')),
                    )
                    .toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 10,
                  ),
                  child: Text(
                    '${value.playbackSpeed}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (MediaQuery.sizeOf(context).width >= 520)
                IconButton(
                  tooltip: '弹幕',
                  onPressed: () {
                    _showControls();
                    widget.onDanmakuPanelPressed(context);
                  },
                  icon: const Icon(
                    Icons.subtitles_outlined,
                    color: Colors.white,
                  ),
                ),
              if (MediaQuery.sizeOf(context).width >= 520)
                IconButton(
                  tooltip: '画中画',
                  onPressed: () {
                    _showControls();
                    widget.onPictureInPicturePressed();
                  },
                  icon: const Icon(
                    Icons.picture_in_picture_alt_rounded,
                    color: Colors.white,
                  ),
                ),
              IconButton(
                tooltip: _usesFullScreenLayout ? '退出全屏' : '全屏',
                onPressed: () {
                  _showControls();
                  unawaited(widget.onFullScreenPressed(chewieController));
                },
                icon: Icon(
                  _usesFullScreenLayout
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFullScreenBottomControls({
    required ChewieController chewieController,
    required VideoPlayerValue value,
    required int durationMs,
    required double positionMs,
    required double progress,
    required _DanmakuDisplaySettings danmakuSettings,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final protectedBottom = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    );
    return Positioned(
      left: 22,
      right: 22,
      bottom: math.max(16.0, protectedBottom + 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  _formatDuration(Duration(milliseconds: positionMs.round())),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: _buildProgressSeekBar(
                    durationMs: durationMs,
                    progress: progress,
                  ),
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  _formatDuration(value.duration),
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              _FullScreenRoundIconButton(
                tooltip: value.isPlaying ? '暂停' : '播放',
                icon: value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                onPressed: _isSeeking ? null : () => unawaited(_togglePlay()),
              ),
              const SizedBox(width: 8),
              _FullScreenRoundIconButton(
                tooltip: '下一集',
                icon: Icons.skip_next_rounded,
                onPressed: widget.canPlayNext
                    ? () {
                        _showControls();
                        widget.onNextEpisodePressed();
                      }
                    : null,
              ),
              const SizedBox(width: 8),
              _FullScreenRoundIconButton(
                tooltip: danmakuSettings.enabled ? '关闭弹幕' : '开启弹幕',
                icon: danmakuSettings.enabled
                    ? Icons.subtitles_rounded
                    : Icons.subtitles_off_rounded,
                active: danmakuSettings.enabled,
                onPressed: () {
                  _showControls();
                  widget.onDanmakuEnabledChanged(!danmakuSettings.enabled);
                },
              ),
              const SizedBox(width: 8),
              _FullScreenRoundIconButton(
                tooltip: '画中画',
                icon: Icons.picture_in_picture_alt_rounded,
                onPressed: () {
                  _showControls();
                  widget.onPictureInPicturePressed();
                },
              ),
              const SizedBox(width: 8),
              _FullScreenRoundIconButton(
                tooltip: '弹幕设置',
                icon: Icons.tune_rounded,
                onPressed: () {
                  _showControls();
                  widget.onDanmakuSettingsPressed(context);
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _FullScreenDanmakuInputButton(
                  onPressed: () {
                    _showControls();
                    widget.onDanmakuComposePressed(context);
                  },
                ),
              ),
              const SizedBox(width: 10),
              PopupMenuButton<double>(
                tooltip: '播放速度',
                onOpened: _showControls,
                onSelected: _setPlaybackSpeed,
                itemBuilder: (context) => chewieController.playbackSpeeds
                    .map(
                      (speed) =>
                          PopupMenuItem(value: speed, child: Text('${speed}x')),
                    )
                    .toList(),
                child: _FullScreenPillText('${value.playbackSpeed}x'),
              ),
              const SizedBox(width: 8),
              _FullScreenRoundIconButton(
                tooltip: '退出全屏',
                icon: Icons.fullscreen_exit_rounded,
                onPressed: () {
                  _showControls();
                  unawaited(widget.onFullScreenPressed(chewieController));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSeekBar({
    required int durationMs,
    required double progress,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final canSeek = durationMs > 0 && trackWidth > 0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: canSeek
              ? (details) => _previewProgressSeek(
                  details.localPosition.dx,
                  trackWidth,
                  durationMs,
                )
              : null,
          onTapUp: canSeek ? (_) => _commitProgressSeek() : null,
          onTapCancel: canSeek ? _cancelProgressSeek : null,
          onHorizontalDragStart: canSeek
              ? (details) => _previewProgressSeek(
                  details.localPosition.dx,
                  trackWidth,
                  durationMs,
                )
              : null,
          onHorizontalDragUpdate: canSeek
              ? (details) => _previewProgressSeek(
                  details.localPosition.dx,
                  trackWidth,
                  durationMs,
                )
              : null,
          onHorizontalDragEnd: canSeek ? (_) => _commitProgressSeek() : null,
          onHorizontalDragCancel: canSeek ? _cancelProgressSeek : null,
          child: _ProgressTrack(progress: progress),
        );
      },
    );
  }

  void _previewProgressSeek(double localDx, double trackWidth, int durationMs) {
    if (durationMs <= 0 || trackWidth <= 0) return;
    final targetMs =
        durationMs * (localDx / trackWidth).clamp(0.0, 1.0).toDouble();
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _controlsVisible = true;
      _dragPositionMs = targetMs;
      _gesturePreviewPositionMs = targetMs;
    });
  }

  void _commitProgressSeek() {
    final targetMs = _dragPositionMs;
    if (targetMs == null) {
      _restartHideTimer();
      return;
    }
    unawaited(_seekToPosition(Duration(milliseconds: targetMs.round())));
  }

  void _cancelProgressSeek() {
    if (!mounted) return;
    setState(() => _dragPositionMs = null);
    _restartHideTimer();
  }

  Widget _buildSeekPreview(VideoPlayerValue value) {
    final durationMs = value.duration.inMilliseconds;
    final progress = durationMs <= 0
        ? 0.0
        : (_gesturePreviewPositionMs / durationMs).clamp(0.0, 1.0).toDouble();
    final target = Duration(milliseconds: _gesturePreviewPositionMs.round());
    final deltaMs = (_gesturePreviewPositionMs - _gestureStartPositionMs)
        .round();
    final delta = Duration(milliseconds: deltaMs.abs());
    final deltaLabel = '${deltaMs >= 0 ? '+' : '-'}${_formatDuration(delta)}';

    return Positioned(
      top: 28,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: 196,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(
                        Icons.movie_filter_rounded,
                        color: Colors.white70,
                        size: 30,
                      ),
                      Positioned(
                        right: 8,
                        bottom: 6,
                        child: Text(
                          deltaLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_formatDuration(target)} / ${_formatDuration(value.duration)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    color: AppTheme.primaryColor,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVolumePreview(double volume) {
    final volumePercent = (volume * 100).round();
    final icon = volume <= 0.01
        ? Icons.volume_off_rounded
        : volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    return Positioned(
      top: 0,
      right: 22,
      bottom: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: 58,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(height: 10),
                SizedBox(
                  width: 7,
                  height: 78,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Container(
                        width: 7,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      FractionallySizedBox(
                        heightFactor: volume,
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          width: 7,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$volumePercent%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrightnessPreview(double brightness) {
    final percent = (brightness * 100).round();
    return Positioned(
      top: 0,
      left: 22,
      bottom: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: 58,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.wb_sunny_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: 7,
                  height: 78,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Container(
                        width: 7,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      FractionallySizedBox(
                        heightFactor: brightness,
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          width: 7,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$percent%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60) % 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
