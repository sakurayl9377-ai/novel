import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../config/theme.dart';
import '../models/anime.dart';
import '../models/anime_watch_history.dart';
import '../services/storage_service.dart';

class AnimePlayerScreen extends StatefulWidget {
  final Anime anime;
  final AnimePlaySource source;
  final AnimeEpisode episode;
  final bool resumeFromHistory;

  const AnimePlayerScreen({
    super.key,
    required this.anime,
    required this.source,
    required this.episode,
    this.resumeFromHistory = false,
  });

  @override
  State<AnimePlayerScreen> createState() => _AnimePlayerScreenState();
}

class _AnimePlayerScreenState extends State<AnimePlayerScreen> {
  final StorageService _storageService = StorageService();
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  Timer? _progressSaveTimer;

  late AnimeEpisode _currentEpisode;
  AnimeWatchHistory? _resumeHistory;
  bool _isLoading = true;
  String? _errorMessage;
  bool _hasAppliedVideoVolume = false;

  List<AnimeEpisode> get _episodes => widget.source.episodes;

  int get _currentIndex =>
      _episodes.indexWhere((episode) => episode.url == _currentEpisode.url);

  @override
  void initState() {
    super.initState();
    _currentEpisode = widget.episode;
    unawaited(_openInitialPlaylist());
  }

  @override
  void dispose() {
    _progressSaveTimer?.cancel();
    unawaited(_saveHistory());
    unawaited(_disposePlayer());
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  Future<void> _openInitialPlaylist() async {
    final history = widget.resumeFromHistory
        ? await _loadResumeHistory()
        : null;
    final resumeEpisode = history?.episode;
    if (resumeEpisode != null &&
        _episodes.any((item) => item.url == resumeEpisode.url)) {
      _currentEpisode = resumeEpisode;
      _resumeHistory = history;
    }
    await _loadEpisode(_currentEpisode, resumeHistory: _resumeHistory);
  }

  Future<AnimeWatchHistory?> _loadResumeHistory() async {
    final histories = await _storageService.getAnimeWatchHistory();
    for (final history in histories) {
      if (history.animeId == widget.anime.id) return history;
    }
    return null;
  }

  Future<void> _loadEpisode(
    AnimeEpisode episode, {
    AnimeWatchHistory? resumeHistory,
  }) async {
    _progressSaveTimer?.cancel();
    await _saveHistory();

    if (mounted) {
      setState(() {
        _currentEpisode = episode;
        _isLoading = true;
        _errorMessage = null;
      });
    }

    await _disposePlayer();
    _hasAppliedVideoVolume = false;

    final startAt = _shouldResume(episode, resumeHistory)
        ? resumeHistory!.position
        : null;
    final videoController = VideoPlayerController.networkUrl(
      Uri.parse(episode.url),
      httpHeaders: _videoHeaders(episode.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    unawaited(videoController.setVolume(_AnimeVideoVolume.current));

    final chewieController = ChewieController(
      videoPlayerController: videoController,
      aspectRatio: 16 / 9,
      autoInitialize: true,
      autoPlay: true,
      startAt: startAt,
      draggableProgressBar: true,
      allowFullScreen: true,
      allowMuting: false,
      allowPlaybackSpeedChanging: true,
      allowedScreenSleep: false,
      showControlsOnInitialize: true,
      hideControlsTimer: const Duration(seconds: 3),
      progressIndicatorDelay: const Duration(days: 1),
      playbackSpeeds: const [0.75, 1, 1.25, 1.5, 2],
      customControls: const _AnimeVideoControls(),
      materialProgressColors: ChewieProgressColors(
        playedColor: AppTheme.primaryColor,
        handleColor: AppTheme.primaryColor,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
      placeholder: const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      ),
      bufferingBuilder: (context) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      },
      errorBuilder: (context, message) {
        return _buildErrorOverlay(message: message);
      },
      deviceOrientationsOnEnterFullScreen: const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      deviceOrientationsAfterFullScreen: const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      systemOverlaysAfterFullScreen: SystemUiOverlay.values,
    );

    _videoController = videoController;
    _chewieController = chewieController;
    videoController.addListener(_handleVideoChanged);
    _resumeHistory = null;
    _startProgressSaveTimer();

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _disposePlayer() async {
    final chewieController = _chewieController;
    final videoController = _videoController;
    _chewieController = null;
    _videoController = null;
    chewieController?.dispose();
    videoController?.removeListener(_handleVideoChanged);
    await videoController?.dispose();
  }

  Map<String, String> _videoHeaders(String url) {
    final uri = Uri.tryParse(url);
    final origin = uri == null || uri.host.isEmpty
        ? ''
        : '${uri.scheme}://${uri.host}/';
    return {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Referer': origin.isNotEmpty ? origin : 'https://www.yinhuadm.xyz/',
    };
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  bool _shouldResume(AnimeEpisode episode, AnimeWatchHistory? history) {
    if (history == null || history.episodeUrl != episode.url) return false;
    if (history.positionMs <= 5000) return false;
    if (history.durationMs <= 0) return true;
    return history.durationMs - history.positionMs > 15000;
  }

  void _handleVideoChanged() {
    final controller = _videoController;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (value.isInitialized && !_hasAppliedVideoVolume) {
      _hasAppliedVideoVolume = true;
      unawaited(controller.setVolume(_AnimeVideoVolume.current));
    }
    if (value.hasError && _errorMessage == null) {
      setState(() => _errorMessage = value.errorDescription ?? '鎾斁澶辫触锛岃閲嶈瘯');
    }
    if (value.isInitialized && _isLoading) {
      setState(() => _isLoading = false);
    }
    if (value.isCompleted) {
      unawaited(_saveHistory());
    }
  }

  void _startProgressSaveTimer() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_saveHistory());
    });
  }

  Future<void> _saveHistory() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    final position = controller.value.position;
    if (duration.inMilliseconds <= 0 && position.inMilliseconds <= 0) return;
    await _storageService.saveAnimeWatchHistory(
      AnimeWatchHistory(
        animeId: widget.anime.id,
        title: widget.anime.title,
        coverUrl: widget.anime.coverUrl,
        sourceName: widget.source.name,
        episodeTitle: _currentEpisode.title,
        episodeUrl: _currentEpisode.url,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        episodes: widget.source.episodes,
      ),
    );
  }

  Future<void> _playEpisode(AnimeEpisode episode) async {
    final index = _episodes.indexWhere((item) => item.url == episode.url);
    if (index < 0) return;
    await _loadEpisode(episode);
  }

  Future<void> _playByOffset(int offset) async {
    final index = _currentIndex;
    if (index < 0) return;
    final target = index + offset;
    if (target < 0 || target >= _episodes.length) return;
    await _loadEpisode(_episodes[target]);
  }

  Future<void> _retry() async {
    await _loadEpisode(_currentEpisode);
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return PopScope<void>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_saveHistory());
      },
      child: Scaffold(
        backgroundColor: isNight ? AppTheme.nightBackground : Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            '${widget.anime.title} ${_currentEpisode.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Column(
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: _buildPlayerArea()),
            Expanded(
              child: Container(
                color: isNight ? AppTheme.nightBackground : Colors.white,
                child: _buildEpisodeList(isNight),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerArea() {
    final chewieController = _chewieController;
    if (chewieController == null || _isLoading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Chewie(controller: chewieController),
          if (_errorMessage != null) _buildErrorOverlay(message: _errorMessage),
        ],
      ),
    );
  }

  Widget _buildErrorOverlay({String? message}) {
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 48),
          const SizedBox(height: 12),
          Text(
            message?.isNotEmpty == true ? message! : '鎾斁澶辫触锛岃閲嶈瘯鎴栧垏鎹㈡挱鏀炬簮',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('閲嶈瘯'),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeList(bool isNight) {
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex >= 0 && _currentIndex < _episodes.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.source.name,
                  style: TextStyle(
                    color: isNight ? Colors.white : AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '上一集',
                onPressed: canPrev ? () => _playByOffset(-1) : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton(
                tooltip: '下一集',
                onPressed: canNext ? () => _playByOffset(1) : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 2.2,
            ),
            itemCount: _episodes.length,
            itemBuilder: (context, index) {
              final episode = _episodes[index];
              final selected = episode.url == _currentEpisode.url;
              return OutlinedButton(
                onPressed: selected ? null : () => _playEpisode(episode),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  backgroundColor: selected
                      ? AppTheme.primaryColor.withValues(alpha: 0.12)
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(
                  episode.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? AppTheme.primaryColor : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnimeVideoControls extends StatefulWidget {
  const _AnimeVideoControls();

  @override
  State<_AnimeVideoControls> createState() => _AnimeVideoControlsState();
}

enum _VideoGestureMode { none, seek, volume }

class _AnimeVideoVolume {
  static const double defaultVolume = 0.5;
  static double current = defaultVolume;

  static void set(double volume) {
    current = volume.clamp(0.0, 1.0).toDouble();
  }
}

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chewieController = ChewieController.of(context);
    if (_chewieController == chewieController) return;
    _videoController?.removeListener(_handleVideoChanged);
    _chewieController = chewieController;
    _videoController = chewieController.videoPlayerController
      ..addListener(_handleVideoChanged);
    _currentVolume = _AnimeVideoVolume.current;
    unawaited(_videoController?.setVolume(_currentVolume));
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _videoController?.removeListener(_handleVideoChanged);
    super.dispose();
  }

  void _handleVideoChanged() {
    if (mounted) setState(() {});
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
      await controller.pause();
    } else {
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
    _restartHideTimer();
  }

  Future<void> _seekBy(Duration delta) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    _showControls();
    final value = controller.value;
    final targetMs = value.position.inMilliseconds + delta.inMilliseconds;
    final durationMs = value.duration.inMilliseconds;
    final clampedMs = targetMs.clamp(0, durationMs).toInt();
    await _seekToPosition(Duration(milliseconds: clampedMs));
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
    _volumePreview = null;
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
      if (startsInVolumeArea && vertical > horizontal) {
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

    final nextVolume = (_gestureStartVolume - offset.dy / size.height)
        .clamp(0.0, 1.0)
        .toDouble();
    _AnimeVideoVolume.set(nextVolume);
    _currentVolume = _AnimeVideoVolume.current;
    unawaited(controller.setVolume(_currentVolume));
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
    final shouldShowPauseIcon = value.isPlaying || _playAfterSeek;
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
                        if (chewieController.isFullScreen)
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
                                  chewieController.toggleFullScreen();
                                },
                              ),
                            ),
                          ),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _ControlButton(
                                tooltip: '后退 30 秒',
                                icon: Icons.replay_30_rounded,
                                onPressed: _isSeeking
                                    ? null
                                    : () =>
                                          _seekBy(const Duration(seconds: -30)),
                              ),
                              const SizedBox(width: 34),
                              _ControlButton(
                                tooltip: shouldShowPauseIcon ? '暂停' : '播放',
                                icon: shouldShowPauseIcon
                                    ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_fill_rounded,
                                size: 74,
                                iconSize: 58,
                                onPressed: _isSeeking ? null : _togglePlay,
                              ),
                              const SizedBox(width: 34),
                              _ControlButton(
                                tooltip: '快进 30 秒',
                                icon: Icons.forward_30_rounded,
                                onPressed: _isSeeking
                                    ? null
                                    : () =>
                                          _seekBy(const Duration(seconds: 30)),
                              ),
                            ],
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
                        _buildBottomControls(
                          chewieController: chewieController,
                          value: value,
                          durationMs: durationMs,
                          positionMs: positionMs,
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
  }) {
    final progress = durationMs <= 0 ? 0.0 : positionMs / durationMs;
    final bottom = chewieController.isFullScreen ? 18.0 : 8.0;

    return Positioned(
      left: 12,
      right: 8,
      bottom: bottom,
      child: Row(
        children: [
          Text(
            _formatDuration(Duration(milliseconds: positionMs.round())),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _ProgressTrack(progress: progress),
            ),
          ),
          Text(
            _formatDuration(value.duration),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
          IconButton(
            tooltip: chewieController.isFullScreen ? '退出全屏' : '全屏',
            onPressed: () {
              _showControls();
              chewieController.toggleFullScreen();
            },
            icon: Icon(
              chewieController.isFullScreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
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

class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final clampedProgress = progress.clamp(0.0, 1.0).toDouble();

    return SizedBox(
      height: 32,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0.0;
          final fillWidth = width * clampedProgress;
          final thumbMaxLeft = width > 12 ? width - 12 : 0.0;
          final thumbLeft = (fillWidth - 6).clamp(0.0, thumbMaxLeft).toDouble();

          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.center,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white38,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: clampedProgress,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: thumbLeft,
                top: 10,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: AppTheme.primaryColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 46,
    this.iconSize = 34,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}
