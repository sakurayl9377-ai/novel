import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:chewie/chewie.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../config/theme.dart';
import '../design/app_tokens.dart';
import '../models/anime.dart';
import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/anime_playback_source_selector.dart';
import '../services/app_telemetry_service.dart';
import '../services/interaction_service.dart';
import '../models/anime_watch_history.dart';
import '../player/player_fullscreen_transition_guard.dart';
import '../player/widgets/player_loading_view.dart';
import '../services/player_platform_service.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import '../widgets/interaction_ui.dart';
import 'comment_thread_screen.dart';
import 'interaction_auth_screen.dart';

part 'anime_player_content_widgets.part.dart';
part 'anime_player_models.part.dart';
part 'anime_player_danmaku_overlay.part.dart';
part 'anime_player_controls.part.dart';
part 'anime_player_controls_widgets.part.dart';
part 'anime_player_danmaku_actions.part.dart';
part 'anime_player_danmaku_settings.part.dart';
part 'anime_player_danmaku_sheet.part.dart';
part 'anime_player_helpers.part.dart';

class AnimePlayerScreen extends StatefulWidget {
  final Anime anime;
  final AnimePlaySource source;
  final AnimeEpisode episode;
  final bool resumeFromHistory;
  final String offlineOriginalUrl;
  final Future<String> Function(AnimeEpisode episode)? episodeUrlResolver;
  final bool requireLoginAfterFirstEpisode;

  const AnimePlayerScreen({
    super.key,
    required this.anime,
    required this.source,
    required this.episode,
    this.resumeFromHistory = false,
    this.offlineOriginalUrl = '',
    this.episodeUrlResolver,
    this.requireLoginAfterFirstEpisode = true,
  });

  @override
  State<AnimePlayerScreen> createState() => _AnimePlayerScreenState();
}

class _AnimePlayerScreenState extends State<AnimePlayerScreen>
    with WidgetsBindingObserver {
  final StorageService _storageService = StorageService();
  final InteractionService _interactionService = InteractionService();
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  Timer? _progressSaveTimer;
  Timer? _playbackWatchdogTimer;
  Timer? _automaticRecoveryTimer;
  Timer? _loadingOverlayFadeTimer;
  Timer? _fullScreenTransitionFinishTimer;
  Timer? _fullScreenResumeIntentTimer;
  Timer? _lifecyclePauseTimer;
  StreamSubscription<AudioInterruptionEvent>? _audioInterruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  int _episodeLoadGeneration = 0;
  int _backgroundPlaybackAllowedUntilMs = 0;
  final PlayerFullscreenTransitionGuard _fullScreenGuard =
      PlayerFullscreenTransitionGuard();
  bool _fullScreenLifecycleSeen = false;
  bool _appIsResumed = true;
  bool _managedFullScreenActive = false;
  bool _managedFullScreenRouteVisible = false;
  bool _managedFullScreenExitRequested = false;
  int _managedFullScreenEpoch = 0;
  int _managedFullScreenSessionGeneration = 0;
  int _managedFullScreenEnterBlockedUntilMs = 0;
  final ValueNotifier<_ManagedFullScreenSession> _managedFullScreenSession =
      ValueNotifier(const _ManagedFullScreenSession.loading(generation: 0));

  late AnimeEpisode _currentEpisode;
  late AnimePlaySource _currentSource;
  AnimeWatchHistory? _resumeHistory;
  bool _isLoading = true;
  String? _errorMessage;
  bool _hasAppliedVideoVolume = false;
  bool _autoPlayNext = true;
  bool _recoveringPlayback = false;
  bool _showLoadingOverlay = true;
  PlayerLoadingStatus _loadingStatus = PlayerLoadingStatus.initial;
  double _preferredPlaybackSpeed = 1;
  int _automaticRecoveryAttempts = 0;
  int _bufferingStartedAtMs = 0;
  int _lastStablePositionMs = 0;
  final Set<String> _failedPlaybackSources = <String>{};
  String _completionHandledEpisodeUrl = '';
  int _contentTabIndex = 0;
  List<InteractionDanmaku> _danmakuItems = const [];
  _DanmakuDisplaySettings _danmakuSettings = const _DanmakuDisplaySettings();
  final ValueNotifier<_DanmakuOverlaySnapshot> _danmakuOverlaySnapshot =
      ValueNotifier(
        const _DanmakuOverlaySnapshot(
          videoController: null,
          items: [],
          settings: _DanmakuDisplaySettings(),
        ),
      );
  late final AppTelemetryScreenTrace _telemetryTrace;

  List<AnimeEpisode> get _episodes => _currentSource.episodes;

  int get _currentIndex =>
      _episodes.indexWhere((episode) => episode.url == _currentEpisode.url);

  String get _currentDanmakuVideoId =>
      widget.offlineOriginalUrl.isNotEmpty &&
          _currentEpisode.url.startsWith('file:')
      ? widget.offlineOriginalUrl
      : _currentEpisode.url;

  @override
  void initState() {
    super.initState();
    _telemetryTrace = AppTelemetryService.instance.openScreen(
      'anime_player',
      metadata: {
        'contentId': widget.anime.id,
        'source': widget.source.name,
        'resumeFromHistory': widget.resumeFromHistory,
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _currentSource = widget.source;
    _currentEpisode = widget.episode;
    unawaited(_listenForAudioInterruptions());
    unawaited(_loadDanmakuSettings());
    unawaited(_openInitialPlaylist());
  }

  @override
  void dispose() {
    _episodeLoadGeneration++;
    _managedFullScreenEpoch++;
    _managedFullScreenActive = false;
    _progressSaveTimer?.cancel();
    _playbackWatchdogTimer?.cancel();
    _automaticRecoveryTimer?.cancel();
    _loadingOverlayFadeTimer?.cancel();
    _fullScreenTransitionFinishTimer?.cancel();
    _fullScreenResumeIntentTimer?.cancel();
    _lifecyclePauseTimer?.cancel();
    unawaited(_audioInterruptionSubscription?.cancel());
    unawaited(_becomingNoisySubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveHistory());
    _telemetryTrace.close(
      metadata: {
        'source': _currentSource.name,
        'episodeIndex': _currentIndex,
        'positionSeconds': _videoController?.value.position.inSeconds ?? 0,
        'automaticRecoveries': _automaticRecoveryAttempts,
      },
      success: _errorMessage == null,
    );
    unawaited(_disposePlayer());
    unawaited(_restoreSystemUi());
    unawaited(PlayerPlatformService.resetScreenBrightness());
    _danmakuOverlaySnapshot.dispose();
    _managedFullScreenSession.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appIsResumed = true;
      _lifecyclePauseTimer?.cancel();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_fullScreenGuard.suppressesLifecyclePause(now)) {
        _restorePlaybackAfterFullScreenTransition();
        _scheduleFullScreenTransitionFinish();
      }
      return;
    }
    _appIsResumed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_fullScreenGuard.suppressesLifecyclePause(now)) {
      _fullScreenLifecycleSeen = true;
      _fullScreenTransitionFinishTimer?.cancel();
      return;
    }
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    if (now < _backgroundPlaybackAllowedUntilMs) {
      return;
    }
    _lifecyclePauseTimer?.cancel();
    _lifecyclePauseTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _appIsResumed) return;
      final currentState = WidgetsBinding.instance.lifecycleState;
      if (currentState != AppLifecycleState.paused &&
          currentState != AppLifecycleState.detached) {
        return;
      }
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      if (_fullScreenGuard.suppressesLifecyclePause(currentTime) ||
          currentTime < _backgroundPlaybackAllowedUntilMs) {
        return;
      }
      unawaited(_pauseForLifecycle());
    });
  }

  Future<void> _listenForAudioInterruptions() async {
    final session = await AudioSession.instance;
    if (!mounted) return;
    _audioInterruptionSubscription = session.interruptionEventStream.listen((
      event,
    ) {
      if (event.begin) unawaited(_pauseForLifecycle());
    });
    _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
      unawaited(_pauseForLifecycle());
    });
  }

  Future<void> _pauseForLifecycle() async {
    final controller = _videoController;
    try {
      if (controller?.value.isPlaying == true) {
        await controller!.pause();
      }
    } catch (_) {
      // The native player may already be tearing down while the app backgrounds.
    }
    try {
      await _saveHistory();
    } catch (_) {
      // Lifecycle transitions should not surface persistence failures.
    }
  }

  Future<void> _openInitialPlaylist() async {
    await _loadPlayerPreferences();
    final history = widget.resumeFromHistory
        ? await _loadResumeHistory()
        : null;
    final resumeEpisode = history?.episode;
    if (resumeEpisode != null &&
        _episodes.any((item) => item.url == resumeEpisode.url)) {
      _currentEpisode = resumeEpisode;
      _resumeHistory = history;
    } else if (history != null &&
        widget.offlineOriginalUrl.isNotEmpty &&
        history.episodeUrl == widget.offlineOriginalUrl &&
        _currentEpisode.url.startsWith('file:')) {
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

  Future<void> _loadPlayerPreferences() async {
    final raw = _storageService.getString(_PlayerPreferences.key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final preferences = _PlayerPreferences.fromJson(
        decoded.cast<String, dynamic>(),
      );
      _autoPlayNext = preferences.autoPlayNext;
      _preferredPlaybackSpeed = preferences.playbackSpeed;
      _AnimeVideoVolume.set(preferences.volume);
    } catch (_) {
      // Ignore invalid settings left by an older build.
    }
  }

  Future<void> _savePlayerPreferences() {
    return _storageService.setString(
      _PlayerPreferences.key,
      jsonEncode(
        _PlayerPreferences(
          autoPlayNext: _autoPlayNext,
          playbackSpeed: _preferredPlaybackSpeed,
          volume: _AnimeVideoVolume.current,
        ).toJson(),
      ),
    );
  }

  Future<void> _loadEpisode(
    AnimeEpisode episode, {
    AnimeWatchHistory? resumeHistory,
    AnimePlaySource? source,
    Duration? startAtOverride,
    bool automaticRecovery = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final loadGeneration = ++_episodeLoadGeneration;
    final targetSource = source ?? _currentSource;
    final switchingSource =
        source != null && !identical(source, _currentSource);
    final targetEpisodeIndex = targetSource.episodes.indexWhere(
      (item) => item.url == episode.url,
    );
    final canOpen = await _ensureEpisodeUnlocked(
      targetEpisodeIndex,
      showError: _videoController == null,
    );
    if (!canOpen || !_isCurrentEpisodeLoad(loadGeneration)) return;

    _progressSaveTimer?.cancel();
    _playbackWatchdogTimer?.cancel();
    _automaticRecoveryTimer?.cancel();
    _loadingOverlayFadeTimer?.cancel();
    await _saveHistory();
    if (!_isCurrentEpisodeLoad(loadGeneration)) return;

    setState(() {
      _currentSource = targetSource;
      _currentEpisode = episode;
      _isLoading = true;
      _showLoadingOverlay = true;
      _loadingStatus = switchingSource
          ? PlayerLoadingStatus.switchingSource
          : automaticRecovery
          ? PlayerLoadingStatus.recovering
          : PlayerLoadingStatus.initial;
      _errorMessage = null;
      _danmakuItems = const [];
    });
    _completionHandledEpisodeUrl = '';
    _bufferingStartedAtMs = 0;
    _lastStablePositionMs = 0;
    if (!automaticRecovery) {
      _automaticRecoveryAttempts = 0;
      _failedPlaybackSources.clear();
    }
    _syncDanmakuOverlay();
    if (_managedFullScreenActive) {
      _publishManagedFullScreenLoading();
      // Let the persistent fullscreen route detach its controls, overlay and
      // VideoPlayer from the old native controller before it is disposed.
      await WidgetsBinding.instance.endOfFrame;
      if (!_isCurrentEpisodeLoad(loadGeneration)) return;
    }

    await _disposePlayer();
    if (!_isCurrentEpisodeLoad(loadGeneration)) return;
    _hasAppliedVideoVolume = false;

    final startAt =
        startAtOverride ??
        (_shouldResume(episode, resumeHistory)
            ? resumeHistory!.position
            : null);
    VideoPlayerController? videoController;
    try {
      final playbackUrl = widget.episodeUrlResolver == null
          ? episode.url
          : await widget.episodeUrlResolver!(episode);
      if (!_isCurrentEpisodeLoad(loadGeneration)) return;
      final episodeUri = Uri.parse(playbackUrl);
      final videoOptions = VideoPlayerOptions(mixWithOthers: false);
      videoController = episodeUri.scheme == 'file'
          ? VideoPlayerController.file(
              File(episodeUri.toFilePath()),
              videoPlayerOptions: videoOptions,
            )
          : VideoPlayerController.networkUrl(
              episodeUri,
              httpHeaders: _videoHeaders(playbackUrl),
              formatHint: _videoFormatHint(playbackUrl),
              videoPlayerOptions: videoOptions,
            );
      await videoController.initialize().timeout(const Duration(seconds: 10));
      if (!_isCurrentEpisodeLoad(loadGeneration)) {
        await videoController.dispose();
        return;
      }
      await videoController.setVolume(_AnimeVideoVolume.current);
      await videoController.setPlaybackSpeed(_preferredPlaybackSpeed);
      if (startAt != null && startAt > Duration.zero) {
        final maxPosition = videoController.value.duration;
        final target = startAt < maxPosition ? startAt : Duration.zero;
        await videoController.seekTo(target);
      }
      await videoController.play();
    } catch (error) {
      await videoController?.dispose();
      if (!_isCurrentEpisodeLoad(loadGeneration)) return;
      _failedPlaybackSources.add(targetSource.name);
      final fallback = _fallbackPlaybackTarget(
        failedSource: targetSource,
        episode: episode,
        episodeIndex: targetEpisodeIndex,
      );
      AppTelemetryService.instance.trackEvent(
        'video_start',
        screen: 'anime_player',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {
          'contentId': widget.anime.id,
          'source': targetSource.name,
          'episodeIndex': targetEpisodeIndex,
          'fallbackAvailable': fallback != null,
          'errorType': error.runtimeType.toString(),
        },
      );
      if (fallback != null) {
        await _loadEpisode(
          fallback.episode,
          source: fallback.source,
          startAtOverride: startAt,
          automaticRecovery: true,
        );
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _friendlyPlaybackError(error);
      });
      _publishManagedFullScreenError(_friendlyPlaybackError(error));
      _scheduleAutomaticRecovery(startAt ?? Duration.zero);
      return;
    }

    AppTelemetryService.instance.trackEvent(
      'video_start',
      screen: 'anime_player',
      durationMs: stopwatch.elapsedMilliseconds,
      success: true,
      metadata: {
        'contentId': widget.anime.id,
        'source': targetSource.name,
        'episodeIndex': targetEpisodeIndex,
        'resumed': startAt != null && startAt > Duration.zero,
      },
    );

    late final ChewieController chewieController;
    chewieController = ChewieController(
      videoPlayerController: videoController,
      // The inline player is constrained to 16:9 by the page. Fullscreen uses
      // a dedicated cover layout below, so the source is not letterboxed on
      // taller/wider phones.
      aspectRatio: 16 / 9,
      autoInitialize: false,
      autoPlay: false,
      draggableProgressBar: true,
      allowFullScreen: false,
      allowMuting: false,
      allowPlaybackSpeedChanging: true,
      allowedScreenSleep: false,
      showControlsOnInitialize: true,
      hideControlsTimer: const Duration(seconds: 3),
      progressIndicatorDelay: const Duration(days: 1),
      playbackSpeeds: const [0.75, 1, 1.25, 1.5, 2],
      customControls: _buildVideoControls(forceFullScreenLayout: false),
      overlay: _DanmakuOverlayHost(listenable: _danmakuOverlaySnapshot),
      materialProgressColors: ChewieProgressColors(
        playedColor: AppTheme.primaryColor,
        handleColor: AppTheme.primaryColor,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
      placeholder: PlayerLoadingView(
        coverUrl: widget.anime.coverUrl,
        status: _loadingStatus,
        onRetry: () => unawaited(_retry()),
        onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
      ),
      bufferingBuilder: (context) {
        return PlayerLoadingView(
          coverUrl: widget.anime.coverUrl,
          status: PlayerLoadingStatus.buffering,
          onRetry: () => unawaited(_retry()),
          onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
        );
      },
      errorBuilder: (context, message) {
        return _buildErrorOverlay(message: message);
      },
    );

    _videoController = videoController;
    _chewieController = chewieController;
    _syncDanmakuOverlay();
    videoController.addListener(_handleVideoChanged);
    _handleVideoChanged();
    _resumeHistory = null;
    _startProgressSaveTimer();
    _startPlaybackWatchdog();
    unawaited(_loadDanmakuItems(_currentDanmakuVideoId));

    if (!_isCurrentEpisodeLoad(loadGeneration)) return;
    setState(() => _isLoading = false);
    _publishManagedFullScreenReady(
      chewieController: chewieController,
      videoController: videoController,
    );
  }

  _AnimeVideoControls _buildVideoControls({
    required bool forceFullScreenLayout,
  }) {
    return _AnimeVideoControls(
      danmakuListenable: _danmakuOverlaySnapshot,
      onDanmakuPanelPressed: _openDanmakuPanel,
      onDanmakuComposePressed: _openDanmakuComposer,
      onDanmakuSettingsPressed: _openDanmakuSettingsPanel,
      onDanmakuEnabledChanged: (enabled) => _handleDanmakuSettingsChanged(
        _danmakuSettings.copyWith(enabled: enabled),
      ),
      onPictureInPicturePressed: () => unawaited(_enterPictureInPicture()),
      canPlayNext: _currentIndex >= 0 && _currentIndex < _episodes.length - 1,
      onNextEpisodePressed: () => unawaited(_playByOffset(1)),
      // Never share a toggle callback between the inline and fullscreen
      // controls. A delayed fullscreen exit tap must remain an exit-only no-op
      // after the route has already closed; it must never become a new enter.
      onFullScreenPressed: forceFullScreenLayout
          ? (_) => _requestManagedFullScreenExit()
          : _enterManagedFullScreen,
      onPlaybackIntentChanged: (playing) {
        _fullScreenGuard.recordPlaybackIntent(playing);
        if (!playing) _fullScreenResumeIntentTimer?.cancel();
      },
      onPlaybackSpeedChanged: (speed) {
        _preferredPlaybackSpeed = speed;
        unawaited(_savePlayerPreferences());
      },
      onVolumeChanged: (volume) {
        _AnimeVideoVolume.set(volume);
        unawaited(_savePlayerPreferences());
      },
      forceFullScreenLayout: forceFullScreenLayout,
    );
  }

  void _publishManagedFullScreenLoading() {
    if (!_managedFullScreenActive) return;
    _managedFullScreenSession.value = _ManagedFullScreenSession.loading(
      generation: ++_managedFullScreenSessionGeneration,
    );
  }

  void _publishManagedFullScreenError(String message) {
    if (!_managedFullScreenActive) return;
    _managedFullScreenSession.value = _ManagedFullScreenSession.error(
      message,
      generation: ++_managedFullScreenSessionGeneration,
    );
  }

  void _publishManagedFullScreenReady({
    required ChewieController chewieController,
    required VideoPlayerController videoController,
  }) {
    if (!_managedFullScreenActive) return;
    _managedFullScreenSession.value = _ManagedFullScreenSession.ready(
      chewieController: chewieController,
      videoController: videoController,
      generation: ++_managedFullScreenSessionGeneration,
    );
  }

  _PlaybackTarget? _fallbackPlaybackTarget({
    required AnimePlaySource failedSource,
    required AnimeEpisode episode,
    required int episodeIndex,
  }) {
    final sources =
        widget.anime.playSources
            .where(
              (source) =>
                  !identical(source, failedSource) &&
                  source.episodes.isNotEmpty &&
                  !_failedPlaybackSources.contains(source.name),
            )
            .toList()
          ..sort(
            (left, right) => AnimePlaybackSourceSelector.score(
              left,
            ).compareTo(AnimePlaybackSourceSelector.score(right)),
          );
    for (final source in sources) {
      return _PlaybackTarget(
        source,
        AnimePlaybackSourceSelector.episodeForSource(
          source: source,
          currentEpisode: episode,
          currentIndex: episodeIndex,
        ),
      );
    }
    return null;
  }

  bool _isCurrentEpisodeLoad(int generation) {
    return mounted && generation == _episodeLoadGeneration;
  }

  Future<void> _disposePlayer() async {
    final chewieController = _chewieController;
    final videoController = _videoController;
    _chewieController = null;
    _videoController = null;
    _syncDanmakuOverlay();
    chewieController?.dispose();
    videoController?.removeListener(_handleVideoChanged);
    await videoController?.dispose();
  }

  Future<void> _loadDanmakuSettings() async {
    final raw = _storageService.getString(_DanmakuDisplaySettings.key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final settings = _DanmakuDisplaySettings.fromJson(
        decoded.cast<String, dynamic>(),
      );
      if (mounted) {
        setState(() => _danmakuSettings = settings);
        _syncDanmakuOverlay();
      }
    } catch (_) {
      // Ignore invalid local settings.
    }
  }

  Future<void> _saveDanmakuSettings(_DanmakuDisplaySettings settings) async {
    await _storageService.setString(
      _DanmakuDisplaySettings.key,
      jsonEncode(settings.toJson()),
    );
  }

  Future<void> _loadDanmakuItems(String videoId) async {
    try {
      final items = await _interactionService.fetchDanmaku(
        videoId: videoId,
        animeId: widget.anime.id.toString(),
        animeTitle: widget.anime.title,
        episodeId: _currentEpisode.title,
        episodeTitle: _currentEpisode.title,
      );
      if (!mounted || videoId != _currentDanmakuVideoId) return;
      setState(() {
        _danmakuItems = [...items]
          ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
      });
      _syncDanmakuOverlay();
    } catch (_) {
      if (mounted && videoId == _currentDanmakuVideoId) {
        setState(() => _danmakuItems = const []);
        _syncDanmakuOverlay();
      }
    }
  }

  void _handleDanmakuSent(InteractionDanmaku item) {
    if (!mounted || !_isCurrentDanmakuItem(item)) return;
    setState(() {
      _danmakuItems = [..._danmakuItems, item]
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    });
    _syncDanmakuOverlay();
  }

  bool _isCurrentDanmakuItem(InteractionDanmaku item) {
    return item.videoId == _currentDanmakuVideoId ||
        (item.animeId == widget.anime.id.toString() &&
            item.episodeId == _currentEpisode.title);
  }

  void _handleDanmakuSettingsChanged(_DanmakuDisplaySettings settings) {
    setState(() => _danmakuSettings = settings);
    _syncDanmakuOverlay();
    unawaited(_saveDanmakuSettings(settings));
  }

  void _syncDanmakuOverlay() {
    _danmakuOverlaySnapshot.value = _DanmakuOverlaySnapshot(
      videoController: _videoController,
      items: _danmakuItems,
      settings: _danmakuSettings,
    );
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

  VideoFormat? _videoFormatHint(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8')) return VideoFormat.hls;
    if (path.endsWith('.mpd')) return VideoFormat.dash;
    return null;
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await PlayerPlatformService.setFullscreenSystemUi(false);
  }

  bool _shouldResume(AnimeEpisode episode, AnimeWatchHistory? history) {
    if (history == null) return false;
    final matchesEpisode = history.episodeUrl == episode.url;
    final matchesOfflineEpisode =
        widget.offlineOriginalUrl.isNotEmpty &&
        episode.url.startsWith('file:') &&
        history.episodeUrl == widget.offlineOriginalUrl;
    if (!matchesEpisode && !matchesOfflineEpisode) return false;
    if (history.positionMs <= 5000) return false;
    if (history.durationMs <= 0) return true;
    return history.durationMs - history.positionMs > 15000;
  }

  void _handleVideoChanged() {
    final controller = _videoController;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // Some Android/HLS backends keep isBuffering=true for a short time after
    // decoded frames and playback progress have already started. Progress is
    // stronger evidence than that sticky flag, so never cover a playing video
    // indefinitely once its clock is advancing.
    if (value.isInitialized &&
        value.isPlaying &&
        (!value.isBuffering || value.position > Duration.zero)) {
      _scheduleLoadingOverlayFade();
    }
    if (value.isInitialized && !_hasAppliedVideoVolume) {
      _hasAppliedVideoVolume = true;
      unawaited(controller.setVolume(_AnimeVideoVolume.current));
    }
    if (value.hasError && _errorMessage == null) {
      setState(
        () => _errorMessage = _friendlyPlaybackError(
          value.errorDescription ?? '播放失败，请重试',
        ),
      );
      _scheduleAutomaticRecovery(value.position);
    }
    if (value.isInitialized && _isLoading) {
      setState(() => _isLoading = false);
    }
    if (value.isCompleted) {
      unawaited(_saveHistory());
      if (_completionHandledEpisodeUrl != _currentEpisode.url) {
        _completionHandledEpisodeUrl = _currentEpisode.url;
        if (_autoPlayNext &&
            _currentIndex >= 0 &&
            _currentIndex < _episodes.length - 1) {
          final completedUrl = _currentEpisode.url;
          Future<void>.delayed(const Duration(milliseconds: 700), () async {
            if (!mounted || _currentEpisode.url != completedUrl) return;
            await _playByOffset(1);
          });
        }
      }
    }
  }

  void _scheduleLoadingOverlayFade() {
    if (!_showLoadingOverlay || _loadingOverlayFadeTimer?.isActive == true) {
      return;
    }
    _loadingOverlayFadeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || !_showLoadingOverlay) return;
      setState(() => _showLoadingOverlay = false);
    });
  }

  void _startProgressSaveTimer() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_saveHistory());
    });
  }

  void _startPlaybackWatchdog() {
    _playbackWatchdogTimer?.cancel();
    _playbackWatchdogTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final controller = _videoController;
      if (controller == null || !controller.value.isInitialized) return;
      final value = controller.value;
      final positionMs = value.position.inMilliseconds;
      if (positionMs > _lastStablePositionMs + 500) {
        _lastStablePositionMs = positionMs;
        _bufferingStartedAtMs = 0;
        _automaticRecoveryAttempts = 0;
      }
      if (value.hasError) {
        _scheduleAutomaticRecovery(value.position);
        return;
      }
      if (!value.isBuffering) {
        _bufferingStartedAtMs = 0;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      _bufferingStartedAtMs = _bufferingStartedAtMs == 0
          ? now
          : _bufferingStartedAtMs;
      if (now - _bufferingStartedAtMs >= 12000) {
        _bufferingStartedAtMs = now;
        unawaited(_recoverPlayback(value.position, automatic: true));
      }
    });
  }

  void _scheduleAutomaticRecovery(Duration position) {
    if (_automaticRecoveryAttempts >= 2 ||
        _automaticRecoveryTimer?.isActive == true ||
        _recoveringPlayback) {
      return;
    }
    _automaticRecoveryAttempts += 1;
    final delay = Duration(seconds: _automaticRecoveryAttempts * 2);
    _automaticRecoveryTimer = Timer(delay, () {
      if (!mounted) return;
      unawaited(_recoverPlayback(position, automatic: true));
    });
  }

  Future<void> _recoverPlayback(
    Duration position, {
    required bool automatic,
  }) async {
    if (_recoveringPlayback || !mounted) return;
    setState(() {
      _recoveringPlayback = true;
      _showLoadingOverlay = true;
      _loadingStatus = PlayerLoadingStatus.recovering;
    });
    try {
      await _loadEpisode(
        _currentEpisode,
        startAtOverride: position,
        automaticRecovery: automatic,
      );
    } finally {
      if (mounted) {
        setState(() => _recoveringPlayback = false);
      } else {
        _recoveringPlayback = false;
      }
    }
  }

  String _friendlyPlaybackError(Object error) {
    final text = error.toString();
    if (error is TimeoutException || text.toLowerCase().contains('timeout')) {
      return '视频连接超时，正在自动重试';
    }
    if (text.contains('404')) return '当前播放线路资源不存在，请切换线路';
    if (text.contains('403')) return '播放线路拒绝访问，请切换线路或稍后重试';
    if (text.toLowerCase().contains('source error')) {
      return '视频解码失败，请重试或切换线路';
    }
    return text.isEmpty ? '播放失败，请重试或切换线路' : text;
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
        sourceName: _currentSource.name,
        episodeTitle: _currentEpisode.title,
        episodeUrl: _currentDanmakuVideoId,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        episodes: widget.offlineOriginalUrl.isNotEmpty
            ? [
                AnimeEpisode(
                  title: _currentEpisode.title,
                  url: widget.offlineOriginalUrl,
                ),
              ]
            : _currentSource.episodes,
      ),
    );
  }

  Future<void> _playEpisode(AnimeEpisode episode) async {
    final index = _episodes.indexWhere((item) => item.url == episode.url);
    if (index < 0) return;
    await _loadEpisode(episode);
  }

  Future<void> _switchSource(AnimePlaySource source) async {
    if (identical(source, _currentSource) || source.episodes.isEmpty) return;
    final currentIndex = _currentIndex < 0 ? 0 : _currentIndex;
    final targetIndex = currentIndex.clamp(0, source.episodes.length - 1);
    final position = _videoController?.value.position ?? Duration.zero;
    await _loadEpisode(
      source.episodes[targetIndex],
      source: source,
      startAtOverride: position,
    );
  }

  Future<void> _playByOffset(int offset) async {
    final index = _currentIndex;
    if (index < 0) return;
    final target = index + offset;
    if (target < 0 || target >= _episodes.length) return;
    await _loadEpisode(_episodes[target]);
  }

  Future<bool> _ensureEpisodeUnlocked(
    int episodeIndex, {
    bool showError = false,
  }) async {
    if (!widget.requireLoginAfterFirstEpisode) return true;
    final canOpen = await ensureLoggedInForContent(
      context,
      allowed: episodeIndex == 0,
      title: '登录后继续观看',
      message: '未登录可试看动漫第一集，登录后可继续观看后续剧集。',
    );
    if (!canOpen && showError && mounted) {
      setState(() {
        _isLoading = false;
        _errorMessage = '登录后可继续观看后续剧集。';
      });
    }
    return canOpen;
  }

  Future<void> _retry() async {
    _automaticRecoveryAttempts = 0;
    final position = _videoController?.value.position ?? Duration.zero;
    await _loadEpisode(_currentEpisode, startAtOverride: position);
  }

  void _toggleAutoPlayNext() {
    setState(() => _autoPlayNext = !_autoPlayNext);
    unawaited(_savePlayerPreferences());
  }

  Widget _buildSourceMenu({Color? color}) {
    final sources = widget.anime.playSources
        .where((source) => source.episodes.isNotEmpty)
        .toList();
    if (sources.length <= 1) return const SizedBox.shrink();
    return PopupMenuButton<AnimePlaySource>(
      tooltip: '切换播放线路',
      initialValue: _currentSource,
      onSelected: (source) => unawaited(_switchSource(source)),
      itemBuilder: (context) => [
        for (final source in sources)
          PopupMenuItem<AnimePlaySource>(
            value: source,
            child: Row(
              children: [
                Icon(
                  identical(source, _currentSource)
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 18,
                  color: identical(source, _currentSource)
                      ? AppTokens.brand
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(source.name)),
                Text('${source.episodes.length}集'),
              ],
            ),
          ),
      ],
      icon: Icon(Icons.hd_rounded, color: color),
    );
  }

  Future<void> _openPlaybackSourcePicker() async {
    final sources = widget.anime.playSources
        .where((source) => source.episodes.isNotEmpty)
        .toList(growable: false);
    if (!mounted || sources.length <= 1) return;
    final selected = await showModalBottomSheet<AnimePlaySource>(
      context: context,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          const ListTile(title: Text('切换播放线路'), subtitle: Text('会保留当前播放位置')),
          for (final source in sources)
            ListTile(
              leading: Icon(
                identical(source, _currentSource)
                    ? Icons.check_circle_rounded
                    : Icons.play_circle_outline_rounded,
                color: identical(source, _currentSource)
                    ? AppTokens.brand
                    : null,
              ),
              title: Text(source.name),
              subtitle: Text('${source.episodes.length} 集'),
              enabled: !identical(source, _currentSource),
              onTap: identical(source, _currentSource)
                  ? null
                  : () => Navigator.of(context).pop(source),
            ),
        ],
      ),
    );
    if (selected != null && mounted) await _switchSource(selected);
  }

  Future<void> _enterPictureInPicture() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isPlaying) await controller.play();
    _backgroundPlaybackAllowedUntilMs =
        DateTime.now().millisecondsSinceEpoch + 5000;
    final entered = await PlayerPlatformService.enterPictureInPicture();
    if (!entered && mounted) {
      _backgroundPlaybackAllowedUntilMs = 0;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('当前设备不支持画中画')));
    }
  }

  Future<void> _enterManagedFullScreen(ChewieController _) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_managedFullScreenActive ||
        _managedFullScreenExitRequested ||
        nowMs < _managedFullScreenEnterBlockedUntilMs) {
      return;
    }
    final controller = _videoController;
    final chewieController = _chewieController;
    if (controller == null ||
        chewieController == null ||
        !controller.value.isInitialized) {
      return;
    }

    final fullScreenEpoch = ++_managedFullScreenEpoch;
    _managedFullScreenActive = true;
    _managedFullScreenExitRequested = false;
    _publishManagedFullScreenReady(
      chewieController: chewieController,
      videoController: controller,
    );
    _fullScreenTransitionFinishTimer?.cancel();
    _fullScreenResumeIntentTimer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    _fullScreenGuard.begin(wasPlaying: controller.value.isPlaying, nowMs: now);
    _fullScreenLifecycleSeen = false;
    _backgroundPlaybackAllowedUntilMs = _fullScreenGuard.resumeAllowedUntilMs;
    _fullScreenResumeIntentTimer = Timer(
      const Duration(milliseconds: 3300),
      () {
        if (!mounted) return;
        _fullScreenGuard.expire(DateTime.now().millisecondsSinceEpoch);
      },
    );
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await PlayerPlatformService.setFullscreenSystemUi(true);
    if (!mounted ||
        !_managedFullScreenActive ||
        fullScreenEpoch != _managedFullScreenEpoch) {
      return;
    }
    _scheduleFullScreenTransitionFinish();

    try {
      _managedFullScreenRouteVisible = true;
      await Navigator.of(context, rootNavigator: true).push<void>(
        PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 140),
          pageBuilder: (context, animation, secondaryAnimation) {
            return _ManagedAnimeFullScreen(
              sessionListenable: _managedFullScreenSession,
              coverUrl: widget.anime.coverUrl,
              controlsBuilder: () =>
                  _buildVideoControls(forceFullScreenLayout: true),
              overlayBuilder: () => _DanmakuOverlayHost(
                listenable: _danmakuOverlaySnapshot,
                forceFullScreenLayout: true,
              ),
              onRetry: () => unawaited(_retry()),
              onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
              onExit: () => unawaited(_requestManagedFullScreenExit()),
            );
          },
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    } finally {
      _managedFullScreenRouteVisible = false;
      _managedFullScreenActive = false;
      _managedFullScreenExitRequested = false;
      _managedFullScreenEnterBlockedUntilMs =
          DateTime.now().millisecondsSinceEpoch + 900;
      _managedFullScreenEpoch++;
      if (mounted) {
        _managedFullScreenSession.value = _ManagedFullScreenSession.loading(
          generation: ++_managedFullScreenSessionGeneration,
        );
      }
      _fullScreenGuard.finishTransition();
      _fullScreenLifecycleSeen = false;
      await _restoreSystemUi();
    }
  }

  Future<void> _requestManagedFullScreenExit() async {
    if (!_managedFullScreenActive || _managedFullScreenExitRequested) return;
    _managedFullScreenExitRequested = true;
    _managedFullScreenEnterBlockedUntilMs =
        DateTime.now().millisecondsSinceEpoch + 900;
    if (_managedFullScreenRouteVisible && mounted) {
      _managedFullScreenEpoch++;
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    _managedFullScreenActive = false;
    _managedFullScreenEpoch++;
    _managedFullScreenExitRequested = false;
    await _restoreSystemUi();
  }

  void _scheduleFullScreenTransitionFinish() {
    _fullScreenTransitionFinishTimer?.cancel();
    _fullScreenTransitionFinishTimer = Timer(
      Duration(milliseconds: _fullScreenLifecycleSeen ? 650 : 900),
      () {
        if (!mounted || !_appIsResumed || !_fullScreenGuard.transitionActive) {
          return;
        }
        if (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed) {
          return;
        }
        _restorePlaybackAfterFullScreenTransition();
        _fullScreenGuard.finishTransition();
        _fullScreenLifecycleSeen = false;
      },
    );
  }

  void _restorePlaybackAfterFullScreenTransition() {
    final controller = _videoController;
    if (_fullScreenGuard.shouldResume(DateTime.now().millisecondsSinceEpoch) &&
        controller != null &&
        controller.value.isInitialized &&
        !controller.value.isPlaying) {
      unawaited(controller.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return PopScope<void>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_saveHistory());
      },
      child: Scaffold(
        backgroundColor: AppTokens.canvasColor(context),
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            '${widget.anime.title} ${_currentEpisode.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '弹幕设置',
              onPressed: () => _openDanmakuSettingsPanel(context),
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: _buildPlayerArea()),
            Expanded(
              child: Container(
                color: AppTokens.canvasColor(context),
                child: _buildModernContentArea(isNight),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerArea() {
    final chewieController = _chewieController;
    if (chewieController == null) {
      return PlayerLoadingView(
        coverUrl: widget.anime.coverUrl,
        status: _loadingStatus,
        onRetry: () => unawaited(_retry()),
        onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Chewie(
            key: ValueKey<ChewieController>(chewieController),
            controller: chewieController,
          ),
          if (_errorMessage == null)
            PlayerLoadingView(
              coverUrl: widget.anime.coverUrl,
              status: _loadingStatus,
              visible: _showLoadingOverlay,
              onRetry: () => unawaited(_retry()),
              onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
            ),
          if (_errorMessage != null) _buildErrorOverlay(message: _errorMessage),
        ],
      ),
    );
  }

  Future<void> _openDanmakuComposer([BuildContext? sheetContext]) async {
    final controller = _videoController;
    final positionMs = controller?.value.position.inMilliseconds ?? 0;
    final hostContext = sheetContext ?? context;
    await showGeneralDialog<void>(
      context: hostContext,
      barrierDismissible: true,
      barrierLabel: '关闭弹幕输入',
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => _DanmakuComposerSheet(
        service: _interactionService,
        videoId: _currentDanmakuVideoId,
        animeId: widget.anime.id.toString(),
        animeTitle: widget.anime.title,
        episodeId: _currentEpisode.title,
        episodeTitle: _currentEpisode.title,
        currentTimeMs: () =>
            _videoController?.value.position.inMilliseconds ?? positionMs,
        color: _danmakuColorHex(_danmakuSettings.color),
        onDanmakuSent: _handleDanmakuSent,
      ),
      transitionBuilder: (context, animation, _, child) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, 0.08),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openDanmakuSettingsPanel([BuildContext? sheetContext]) async {
    final hostContext = sheetContext ?? context;
    final size = MediaQuery.sizeOf(hostContext);
    final isLandscape = size.width > size.height;

    if (isLandscape) {
      await showGeneralDialog<void>(
        context: hostContext,
        barrierDismissible: true,
        barrierLabel: '关闭弹幕设置',
        barrierColor: Colors.black.withValues(alpha: 0.36),
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (context, _, _) {
          final width = (MediaQuery.sizeOf(context).width * 0.42)
              .clamp(360.0, 560.0)
              .toDouble();
          return Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 14, 18, 14),
                child: SizedBox(
                  width: width,
                  child: _DanmakuSettingsSurface(
                    dark: true,
                    settings: _danmakuSettings,
                    onSettingsChanged: _handleDanmakuSettingsChanged,
                  ),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, animation, _, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0.12, 0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: hostContext,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DanmakuSettingsBottomSheet(
        settings: _danmakuSettings,
        onSettingsChanged: _handleDanmakuSettingsChanged,
      ),
    );
  }

  Future<void> _openDanmakuPanel([BuildContext? sheetContext]) async {
    final hostContext = sheetContext ?? context;
    final size = MediaQuery.sizeOf(hostContext);
    final isLandscape = size.width > size.height;
    if (isLandscape) {
      await showGeneralDialog<void>(
        context: hostContext,
        barrierDismissible: true,
        barrierLabel: '关闭弹幕面板',
        barrierColor: Colors.black.withValues(alpha: 0.28),
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (context, _, _) => _DanmakuControlSheet(
          count: _danmakuItems.length,
          enabled: _danmakuSettings.enabled,
          episodeTitle: _currentEpisode.title,
          onEnabledChanged: (enabled) => _handleDanmakuSettingsChanged(
            _danmakuSettings.copyWith(enabled: enabled),
          ),
          onCompose: () => _openDanmakuComposer(hostContext),
          onSettings: () => _openDanmakuSettingsPanel(hostContext),
        ),
        transitionBuilder: (context, animation, _, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0.1, 0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: hostContext,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => _DanmakuControlSheet(
        count: _danmakuItems.length,
        enabled: _danmakuSettings.enabled,
        episodeTitle: _currentEpisode.title,
        onEnabledChanged: (enabled) => _handleDanmakuSettingsChanged(
          _danmakuSettings.copyWith(enabled: enabled),
        ),
        onCompose: () => _openDanmakuComposer(hostContext),
        onSettings: () => _openDanmakuSettingsPanel(hostContext),
      ),
    );
  }

  Widget _buildErrorOverlay({String? message}) {
    return PlayerLoadingView(
      coverUrl: widget.anime.coverUrl,
      status: PlayerLoadingStatus.error,
      message: message ?? '播放失败，请重试或切换播放源',
      elapsedOverride: const Duration(seconds: 12),
      onRetry: () => unawaited(_retry()),
      onChangeSource: () => unawaited(_openPlaybackSourcePicker()),
    );
  }

  Widget _buildModernContentArea(bool isNight) {
    return Column(
      children: [
        _ModernVideoContentTabs(
          index: _contentTabIndex,
          onChanged: (index) => setState(() => _contentTabIndex = index),
        ),
        Expanded(
          child: IndexedStack(
            index: _contentTabIndex,
            children: [
              _buildModernEpisodeList(isNight),
              CommentInteractionPanel(
                key: ValueKey(
                  'anime-${widget.anime.id}-${_currentEpisode.title}',
                ),
                targetType: 'anime',
                targetId: widget.anime.id.toString(),
                targetTitle: widget.anime.title,
                episodeId: _currentEpisode.title,
                episodeTitle: _currentEpisode.title,
                inputHint: '发一条友善的评论',
                emptyTitle: '还没有评论',
                emptySubtitle: '来聊聊这一集',
                useSafeArea: false,
                compact: true,
                service: _interactionService,
              ),
              _buildDanmakuToolsPanel(),
              _buildRecommendationPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDanmakuToolsPanel() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D172033),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.subtitles_rounded, color: AppTokens.brand),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '弹幕',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Switch(
                    value: _danmakuSettings.enabled,
                    onChanged: (enabled) => _handleDanmakuSettingsChanged(
                      _danmakuSettings.copyWith(enabled: enabled),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '弹幕只在视频画面中展示，页面下方不铺开列表。',
                style: TextStyle(
                  color: AppTokens.secondaryText(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.brand,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => _openDanmakuComposer(context),
                      icon: const Icon(Icons.edit_rounded),
                      label: const Text('发弹幕'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openDanmakuSettingsPanel(context),
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('设置'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecommendationPanel() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        const Text(
          '周边推荐',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        for (final episode in _episodes.take(4))
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTokens.brandSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.play_circle_fill_rounded,
                    color: AppTokens.brand,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    episode.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildModernEpisodeList(bool isNight) {
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex >= 0 && _currentIndex < _episodes.length - 1;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: AppTokens.cardColor(context),
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            border: Border.all(color: AppTokens.borderColor(context)),
            boxShadow: Theme.of(context).brightness == Brightness.light
                ? AppTokens.softShadow
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppTokens.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
                child: const Icon(
                  Icons.play_circle_outline_rounded,
                  color: AppTokens.brand,
                  size: 22,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentEpisode.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTokens.primaryText(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_currentSource.name} · 共 ${_episodes.length} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTokens.secondaryText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildSourceMenu(color: AppTokens.secondaryText(context)),
              IconButton(
                tooltip: _autoPlayNext ? '已开启自动下一集' : '自动下一集已关闭',
                onPressed: _toggleAutoPlayNext,
                icon: Icon(
                  Icons.playlist_play_rounded,
                  color: _autoPlayNext ? AppTokens.brand : null,
                ),
              ),
              IconButton(
                tooltip: '上一集',
                onPressed: canPrev ? () => _playByOffset(-1) : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton.filledTonal(
                tooltip: '下一集',
                onPressed: canNext ? () => _playByOffset(1) : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '选集',
          style: TextStyle(
            color: AppTokens.primaryText(context),
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.35,
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
                    ? AppTokens.brand.withValues(alpha: 0.12)
                    : AppTokens.cardColor(context),
                side: BorderSide(
                  color: selected
                      ? AppTokens.brand
                      : AppTokens.borderColor(context),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
              ),
              child: Text(
                episode.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: selected
                      ? AppTokens.brand
                      : AppTokens.primaryText(context),
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildContentArea(bool isNight) {
    return Column(
      children: [
        _VideoContentTabs(
          index: _contentTabIndex,
          commentsLabel: '评论',
          onChanged: (index) => setState(() => _contentTabIndex = index),
        ),
        Expanded(
          child: IndexedStack(
            index: _contentTabIndex,
            children: [
              _buildEpisodeList(isNight),
              CommentInteractionPanel(
                key: ValueKey(
                  'anime-${widget.anime.id}-${_currentEpisode.title}',
                ),
                targetType: 'anime',
                targetId: widget.anime.id.toString(),
                targetTitle: widget.anime.title,
                episodeId: _currentEpisode.title,
                episodeTitle: _currentEpisode.title,
                inputHint: '发一条友善的评论',
                emptyTitle: '还没有评论',
                emptySubtitle: '来聊聊这一集',
                useSafeArea: false,
                compact: true,
                service: _interactionService,
              ),
            ],
          ),
        ),
      ],
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
                  _currentSource.name,
                  style: TextStyle(
                    color: isNight ? Colors.white : AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _buildSourceMenu(
                color: isNight ? Colors.white70 : AppTheme.textSecondary,
              ),
              IconButton(
                tooltip: _autoPlayNext ? '已开启自动下一集' : '自动下一集已关闭',
                onPressed: _toggleAutoPlayNext,
                icon: Icon(
                  Icons.playlist_play_rounded,
                  color: _autoPlayNext ? AppTheme.primaryColor : null,
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

/// Fullscreen deliberately has a different fit policy from the inline player:
/// inline stays 16:9, while fullscreen fills the physical display and clips
/// only the excess edge of the video. Chewie's stock fullscreen keeps the
/// controller aspect ratio and therefore leaves bars on modern wide phones.
class _ManagedAnimeFullScreen extends StatelessWidget {
  const _ManagedAnimeFullScreen({
    required this.sessionListenable,
    required this.coverUrl,
    required this.controlsBuilder,
    required this.overlayBuilder,
    required this.onRetry,
    required this.onChangeSource,
    required this.onExit,
  });

  final ValueListenable<_ManagedFullScreenSession> sessionListenable;
  final String coverUrl;
  final Widget Function() controlsBuilder;
  final Widget Function() overlayBuilder;
  final VoidCallback onRetry;
  final VoidCallback onChangeSource;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<_ManagedFullScreenSession>(
        valueListenable: sessionListenable,
        builder: (context, session, _) {
          final chewieController = session.chewieController;
          final videoController = session.videoController;
          if (chewieController == null || videoController == null) {
            return Stack(
              fit: StackFit.expand,
              children: [
                PlayerLoadingView(
                  coverUrl: coverUrl,
                  status: session.errorMessage.isEmpty
                      ? PlayerLoadingStatus.switchingSource
                      : PlayerLoadingStatus.error,
                  message: session.errorMessage,
                  onRetry: onRetry,
                  onChangeSource: onChangeSource,
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: SafeArea(
                    child: IconButton.filledTonal(
                      tooltip: '退出全屏',
                      onPressed: onExit,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                ),
              ],
            );
          }
          return ChewieControllerProvider(
            key: ValueKey<int>(session.generation),
            controller: chewieController,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: videoController,
                      builder: (context, value, _) {
                        final size = value.size;
                        final width = size.width > 0 ? size.width : 16.0;
                        final height = size.height > 0 ? size.height : 9.0;
                        return FittedBox(
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: width,
                            height: height,
                            child: VideoPlayer(videoController),
                          ),
                        );
                      },
                    ),
                  ),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: videoController,
                    builder: (context, value, _) {
                      final waitingForFirstFrame =
                          !value.isInitialized ||
                          value.position <= Duration.zero;
                      return PlayerLoadingView(
                        coverUrl: coverUrl,
                        status: PlayerLoadingStatus.switchingSource,
                        visible: waitingForFirstFrame,
                        onRetry: onRetry,
                        onChangeSource: onChangeSource,
                      );
                    },
                  ),
                  overlayBuilder(),
                  Positioned.fill(child: controlsBuilder()),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ManagedFullScreenSession {
  const _ManagedFullScreenSession.loading({required this.generation})
    : chewieController = null,
      videoController = null,
      errorMessage = '';

  const _ManagedFullScreenSession.error(
    this.errorMessage, {
    required this.generation,
  }) : chewieController = null,
       videoController = null;

  const _ManagedFullScreenSession.ready({
    required this.chewieController,
    required this.videoController,
    required this.generation,
  }) : errorMessage = '';

  final ChewieController? chewieController;
  final VideoPlayerController? videoController;
  final String errorMessage;
  final int generation;
}
