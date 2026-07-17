import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../features/novel_reader/novel_reader.dart';
import '../features/reader_core/reader_core.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../models/novel_bookmark.dart';
import '../models/reading_progress.dart';
import '../models/reading_settings.dart';
import '../models/tts_settings.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/reading_provider.dart';
import '../providers/book_source_provider.dart';
import '../providers/interaction_auth_provider.dart';
import '../providers/tts_provider.dart';
import '../services/tts_media_control_service.dart';
import '../services/app_telemetry_service.dart';
import '../services/novel_offline_cache_service.dart';
import '../services/reader_platform_service.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import '../utils/reading_text_range.dart';
import '../widgets/reading_settings_panel.dart';
import '../widgets/continuous_chapter_view.dart';

class ReadingScreen extends StatefulWidget {
  static const routeName = '/novel/reading';

  final Novel novel;
  final List<Chapter> chapters;
  final bool chaptersAreProvisional;
  final int startChapterIndex;
  final int startCharPosition;
  final double startScrollPosition;

  const ReadingScreen({
    super.key,
    required this.novel,
    this.chapters = const [],
    this.chaptersAreProvisional = false,
    this.startChapterIndex = 0,
    this.startCharPosition = 0,
    this.startScrollPosition = 0,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen>
    with WidgetsBindingObserver {
  int _currentChapterIndex = 0;
  late List<Chapter> _chapters;
  int _currentPageIndex = 0;
  int _restoreCharPosition = 0;
  String _content = '';
  String? _contentError;
  bool _isLoadingContent = false;
  bool _showControls = false;
  bool _showTtsPanel = false;
  Future<List<TtsSystemVoice>>? _ttsSystemVoices;
  bool _isLeaving = false;
  int _lastCharPosition = 0;
  double _lastScrollPosition = 0;
  int? _pausedTtsChapterIndex;
  int? _pausedTtsPageIndex;
  int? _pausedTtsCharPosition;
  bool _ttsMediaControlsBound = false;
  bool _readerPlatformBound = false;
  bool _handlingTtsMediaChapterChange = false;
  bool _isAutoReading = false;
  int _continuousReaderSession = 0;
  TtsMediaControlService? _ttsMediaControlService;
  TtsProvider? _ttsProvider;
  String get _ttsOwnerKey => 'novel:${widget.novel.id}';
  late ReadingProvider _readingProvider;
  late BookshelfProvider _bookshelfProvider;
  Future<void> _progressSaveChain = Future.value();
  final LatestWins _chapterLoadGuard = LatestWins();
  final StorageService _storage = StorageService();
  final NovelPagedViewController _pagedViewController =
      NovelPagedViewController();
  final ContinuousChapterViewController _continuousViewController =
      ContinuousChapterViewController();
  final ValueNotifier<int> _novelChapterProgress = ValueNotifier<int>(0);
  final ValueNotifier<double> _novelBookProgress = ValueNotifier<double>(0);
  List<NovelBookmark> _bookmarks = const [];
  Timer? _pagedAutoReadTimer;
  StreamSubscription<ReaderPageCommand>? _readerPageCommandSubscription;
  bool? _appliedVolumeKeyPaging;
  bool? _appliedKeepScreenOn;
  bool? _appliedUseSystemBrightness;
  double? _appliedBrightness;
  int _platformSettingsGeneration = 0;
  double? _pendingBookProgress;
  late final AppTelemetryScreenTrace _telemetryTrace;
  static const int _guestChapterLimit = 10;

  @override
  void initState() {
    super.initState();
    _telemetryTrace = AppTelemetryService.instance.openScreen(
      'novel_reader',
      metadata: {
        'contentId': widget.novel.id,
        'sourceId': widget.novel.sourceId,
        'local': widget.novel.isLocal,
        'startChapter': widget.startChapterIndex,
        'provisionalCatalog': widget.chaptersAreProvisional,
      },
    );
    _chapters = List<Chapter>.of(widget.chapters);
    _currentChapterIndex = widget.startChapterIndex
        .clamp(0, _chapters.isEmpty ? 0 : _chapters.length - 1)
        .toInt();
    _restoreCharPosition = widget.startCharPosition;
    _lastCharPosition = widget.startCharPosition;
    _lastScrollPosition = widget.startScrollPosition;
    _currentPageIndex = 0;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _readingProvider.setChapters(_chapters);
    });
    _loadCurrentChapter();
    unawaited(_loadBookmarks());
    if (widget.chaptersAreProvisional) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_hydrateChapterCatalog());
      });
    }
  }

  Future<void> _hydrateChapterCatalog() async {
    if (widget.novel.isLocal) return;
    try {
      final chapters = await context.read<BookSourceProvider>().getChapterList(
        widget.novel,
      );
      if (!mounted || chapters.isEmpty) return;
      final currentIndex = _currentChapterIndex.clamp(0, chapters.length - 1);
      setState(() {
        _chapters = chapters;
        _currentChapterIndex = currentIndex;
        _continuousReaderSession++;
      });
      final readingProvider = context.read<ReadingProvider>();
      readingProvider.setChapters(chapters);
      readingProvider.setCurrentChapter(chapters[currentIndex]);
    } catch (_) {
      // The provisional chapter remains readable when the catalog is offline.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    // Persist the exact visible anchor whenever Android backgrounds the app.
    // Relying only on scroll-end callbacks loses the intra-chapter position
    // when the process is reclaimed before the reader route is popped.
    unawaited(_saveVisibleProgressNow());
    final ttsProvider = _ttsProvider;
    if (ttsProvider == null) return;
    final ttsActive =
        ttsProvider.isSpeaking ||
        ttsProvider.isPaused ||
        ttsProvider.isStarting;
    if (!ttsActive) return;
    unawaited(_showTtsMediaControls(playing: !ttsProvider.isPaused));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Keep stable references for the final asynchronous progress write. A
    // route can be disposed before that write reaches the provider lookup, at
    // which point using its BuildContext would be unsafe.
    _readingProvider = context.read<ReadingProvider>();
    _bookshelfProvider = context.read<BookshelfProvider>();
    if (!_ttsMediaControlsBound) {
      _ttsMediaControlsBound = true;
      final ttsProvider = context.read<TtsProvider>();
      _ttsProvider = ttsProvider;
      if ((ttsProvider.isSpeaking ||
              ttsProvider.isPaused ||
              ttsProvider.isStarting) &&
          !ttsProvider.isOwnedBy(_ttsOwnerKey)) {
        unawaited(ttsProvider.stopSpeaking());
      }
      final mediaControlService = ttsProvider.mediaControlService;
      _ttsMediaControlService = mediaControlService;
      mediaControlService.bindControls(
        owner: this,
        onPrevious: _handleMediaPrevious,
        onPlay: _handleMediaPlay,
        onPause: _handleMediaPause,
        onNext: _handleMediaNext,
        onStop: _stopTts,
      );
      ttsProvider.bindSleepTimer(
        owner: this,
        onElapsed: _handleSleepTimerElapsed,
      );
      ttsProvider.bindCompletion(
        owner: this,
        onComplete: _handleTtsChapterComplete,
      );
    }
    if (!_readerPlatformBound) {
      _readerPlatformBound = true;
      _readerPageCommandSubscription = ReaderPlatformService
          .instance
          .pageCommands
          .listen(_handleReaderPageCommand);
    }
  }

  void _handleReaderPageCommand(ReaderPageCommand command) {
    if (!mounted || _isLoadingContent || _content.isEmpty) return;
    final settings = context.read<ReadingProvider>().settings;
    final direction = command == ReaderPageCommand.previousPage ? -1 : 1;
    if (settings.pageMode == NovelPageMode.verticalScroll) {
      unawaited(_continuousViewController.moveByViewport(direction));
    } else if (direction < 0) {
      unawaited(_pagedViewController.previousPage());
    } else {
      unawaited(_pagedViewController.nextPage());
    }
  }

  void _syncReaderPlatformSettings(ReadingSettings settings) {
    final brightnessChanged =
        _appliedUseSystemBrightness != settings.useSystemBrightness ||
        (!settings.useSystemBrightness &&
            _appliedBrightness != settings.brightness);
    if (_appliedVolumeKeyPaging == settings.volumeKeyTurnPage &&
        _appliedKeepScreenOn == settings.keepScreenOn &&
        !brightnessChanged) {
      return;
    }
    _appliedVolumeKeyPaging = settings.volumeKeyTurnPage;
    _appliedKeepScreenOn = settings.keepScreenOn;
    _appliedUseSystemBrightness = settings.useSystemBrightness;
    _appliedBrightness = settings.brightness;
    final generation = ++_platformSettingsGeneration;
    unawaited(_applyReaderPlatformSettings(settings, generation));
  }

  Future<void> _applyReaderPlatformSettings(
    ReadingSettings settings,
    int generation,
  ) async {
    final platform = ReaderPlatformService.instance;
    await platform.configureReaderSession(
      volumeKeyTurnPage: settings.volumeKeyTurnPage,
      keepScreenOn: settings.keepScreenOn,
    );
    if (!mounted || generation != _platformSettingsGeneration) return;
    if (settings.useSystemBrightness) {
      await platform.resetScreenBrightness();
    } else {
      await platform.setScreenBrightness(settings.brightness);
    }
  }

  Future<void> _loadCurrentChapter() async {
    final loadToken = _chapterLoadGuard.begin();
    final chapterIndex = _currentChapterIndex;
    final stopwatch = Stopwatch()..start();
    final canOpen = await _ensureChapterUnlocked(chapterIndex, showError: true);
    if (!canOpen || !mounted || !loadToken.isCurrent) return;

    if (widget.novel.isLocal) {
      if (_chapters.isNotEmpty && chapterIndex < _chapters.length) {
        final chapter = _chapters[chapterIndex];
        final restorePosition = _restoreCharPosition
            .clamp(0, chapter.content.length)
            .toInt();
        final pageIndex = _pageIndexForCharPosition(
          chapter.content,
          restorePosition,
        );
        loadToken.commit(() {
          setState(() {
            _content = chapter.content;
            _contentError = chapter.content.isEmpty ? '该章节暂无正文。' : null;
            _restoreCharPosition = restorePosition;
            _lastCharPosition = restorePosition;
            _lastScrollPosition = restorePosition == 0
                ? 0
                : _lastScrollPosition;
            _currentPageIndex = pageIndex;
            _continuousReaderSession++;
          });
          _publishReadingProgress();
          context.read<ReadingProvider>().setCurrentChapter(chapter);
        });
      }
      if (loadToken.isCurrent) {
        AppTelemetryService.instance.trackEvent(
          'content_load',
          screen: 'novel_reader',
          durationMs: stopwatch.elapsedMilliseconds,
          success: _content.isNotEmpty,
          metadata: {
            'contentType': 'novel',
            'local': true,
            'chapterIndex': chapterIndex,
            'characters': _content.length,
          },
        );
      }
      return;
    }

    loadToken.commit(() {
      setState(() {
        _isLoadingContent = true;
        _contentError = null;
      });
    });

    try {
      if (_chapters.isNotEmpty && chapterIndex < _chapters.length) {
        final chapter = _chapters[chapterIndex];
        final sourceProvider = context.read<BookSourceProvider>();
        final content = await sourceProvider.getChapterContent(
          widget.novel,
          chapter,
        );
        final formattedContent = _formatChapterContent(content);

        if (!mounted || !loadToken.isCurrent) return;

        final restorePosition = _restoreCharPosition
            .clamp(0, formattedContent.length)
            .toInt();
        final pageIndex = _pageIndexForCharPosition(
          formattedContent,
          restorePosition,
        );
        loadToken.commit(() {
          context.read<ReadingProvider>().setCurrentChapter(chapter);
          setState(() {
            _content = formattedContent;
            _contentError = formattedContent.isEmpty
                ? '章节内容暂时不可用，请稍后重试或更换书源。'
                : null;
            _restoreCharPosition = restorePosition;
            _lastCharPosition = restorePosition;
            _lastScrollPosition = restorePosition == 0
                ? 0
                : _lastScrollPosition;
            _currentPageIndex = pageIndex;
            _continuousReaderSession++;
          });
          _publishReadingProgress();
          unawaited(sourceProvider.pinCurrentChapter(widget.novel, chapter));
        });
        AppTelemetryService.instance.trackEvent(
          'content_load',
          screen: 'novel_reader',
          durationMs: stopwatch.elapsedMilliseconds,
          success: formattedContent.isNotEmpty,
          metadata: {
            'contentType': 'novel',
            'local': false,
            'chapterIndex': chapterIndex,
            'characters': formattedContent.length,
          },
        );
      } else {
        loadToken.commit(() {
          setState(() {
            _content = '';
            _contentError = '暂无章节可读。';
          });
        });
      }
    } catch (error) {
      if (!loadToken.isCurrent) return;
      AppTelemetryService.instance.trackEvent(
        'content_load',
        screen: 'novel_reader',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {
          'contentType': 'novel',
          'local': false,
          'chapterIndex': chapterIndex,
          'errorType': error.runtimeType.toString(),
        },
      );
      if (mounted && loadToken.isCurrent) {
        setState(() {
          _content = '';
          _contentError = '章节内容加载失败，请稍后重试。';
        });
      }
    } finally {
      if (mounted && loadToken.isCurrent) {
        setState(() => _isLoadingContent = false);
      }
    }
  }

  int _currentProgressPosition([TtsProvider? ttsProvider]) {
    final tts = ttsProvider ?? context.read<TtsProvider>();
    if (tts.isOwnedBy(_ttsOwnerKey) &&
        (tts.isSpeaking || tts.isPaused || tts.isStarting) &&
        tts.currentStartOffset >= 0) {
      return tts.currentStartOffset.clamp(0, _content.length).toInt();
    }
    if (_lastCharPosition > 0) {
      return _lastCharPosition.clamp(0, _content.length).toInt();
    }
    final settings = context.read<ReadingProvider>().settings;
    return _pageStartOffsetForPage(
      _currentPageIndex,
      settings.fontSize,
      settings.lineHeight,
    ).clamp(0, _content.length).toInt();
  }

  int _captureVisibleProgressPosition([TtsProvider? ttsProvider]) {
    final tts = ttsProvider ?? _ttsProvider;
    if (tts != null &&
        tts.isOwnedBy(_ttsOwnerKey) &&
        (tts.isSpeaking || tts.isPaused || tts.isStarting) &&
        tts.currentStartOffset >= 0) {
      return tts.currentStartOffset.clamp(0, _content.length).toInt();
    }

    final anchor = _continuousViewController.captureAnchor();
    if (anchor != null &&
        anchor.chapterIndex >= 0 &&
        anchor.chapterIndex < _chapters.length &&
        anchor.content.isNotEmpty) {
      final capturedPosition = anchor.chapterIndex == _currentChapterIndex
          ? anchor.charPosition.clamp(_lastCharPosition, anchor.content.length)
          : anchor.charPosition.clamp(0, anchor.content.length);
      _currentChapterIndex = anchor.chapterIndex;
      _content = anchor.content;
      _restoreCharPosition = capturedPosition;
      _lastCharPosition = capturedPosition;
      _lastScrollPosition = 0;
      _currentPageIndex = _pageIndexForCharPosition(
        anchor.content,
        capturedPosition,
      );
      return capturedPosition;
    }
    return _currentProgressPosition(tts);
  }

  Future<void> _saveVisibleProgressNow([TtsProvider? ttsProvider]) {
    return _saveProgressNow(
      charPosition: _captureVisibleProgressPosition(ttsProvider),
    );
  }

  Future<void> _saveProgressNow({
    int? charPosition,
    double? scrollPosition,
  }) async {
    if (_content.isEmpty) return;

    final position = (charPosition ?? _lastCharPosition)
        .clamp(0, _content.length)
        .toInt();
    _lastCharPosition = position;
    _lastScrollPosition = (scrollPosition ?? _lastScrollPosition).clamp(
      0.0,
      double.infinity,
    );
    _publishReadingProgress();

    final progress = ReadingProgress(
      novelId: widget.novel.id,
      chapterIndex: _currentChapterIndex,
      scrollPosition: _lastScrollPosition,
      charPosition: position,
      chapterTitle: _currentChapterTitle,
      chapterUrl:
          _chapters.isNotEmpty &&
              _currentChapterIndex >= 0 &&
              _currentChapterIndex < _chapters.length
          ? _chapters[_currentChapterIndex].url
          : '',
    );

    _progressSaveChain = _progressSaveChain
        .catchError((_) {})
        .then((_) => _persistProgress(progress));
    await _progressSaveChain;
  }

  Future<void> _persistProgress(ReadingProgress progress) async {
    final updatedNovel = widget.novel.copyWith(
      currentChapterIndex: progress.chapterIndex,
      lastReadAt: DateTime.now(),
    );
    await _readingProvider.saveProgress(widget.novel, progress);
    await _bookshelfProvider.updateNovel(updatedNovel);
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await _storage.getNovelBookmarks(widget.novel);
    if (!mounted) return;
    setState(() => _bookmarks = bookmarks);
  }

  NovelBookmark? get _bookmarkAtCurrentPosition {
    for (final bookmark in _bookmarks) {
      if (bookmark.chapterIndex == _currentChapterIndex &&
          (bookmark.charPosition - _lastCharPosition).abs() <= 96) {
        return bookmark;
      }
    }
    return null;
  }

  Future<void> _toggleBookmark() async {
    if (_content.isEmpty || _chapters.isEmpty) return;
    final existing = _bookmarkAtCurrentPosition;
    if (existing != null) {
      await _storage.deleteNovelBookmark(widget.novel, existing.id);
      if (!mounted) return;
      setState(() {
        _bookmarks = _bookmarks
            .where((bookmark) => bookmark.id != existing.id)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('书签已移除')));
      return;
    }

    final position = _currentProgressPosition();
    final contextStart = (position - 36).clamp(0, _content.length).toInt();
    final contextEnd = (position + 72).clamp(0, _content.length).toInt();
    final chapter = _chapters[_currentChapterIndex];
    final bookmark = await _storage.createNovelBookmark(
      novel: widget.novel,
      chapterIndex: _currentChapterIndex,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      charPosition: position,
      contextText: _content
          .substring(contextStart, contextEnd)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
      contentDigest: sha256.convert(utf8.encode(_content)).toString(),
    );
    if (!mounted) return;
    setState(() => _bookmarks = [..._bookmarks, bookmark]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('书签已添加')));
  }

  Future<void> _jumpToBookmark(NovelBookmark bookmark) async {
    var targetIndex = _chapters.indexWhere(
      (chapter) => chapter.id == bookmark.chapterId,
    );
    if (targetIndex < 0) {
      targetIndex = bookmark.chapterIndex
          .clamp(0, _chapters.length - 1)
          .toInt();
    }
    await _jumpToChapterPosition(targetIndex, bookmark.charPosition);
  }

  Future<void> _jumpToChapterPosition(int targetIndex, int charPosition) async {
    if (_chapters.isEmpty) return;
    targetIndex = targetIndex.clamp(0, _chapters.length - 1).toInt();
    final canOpen = await _ensureChapterUnlocked(targetIndex);
    if (!canOpen || !mounted) return;
    final ttsProvider = context.read<TtsProvider>();
    await _saveProgressNow(charPosition: _currentProgressPosition(ttsProvider));
    await ttsProvider.stopSpeaking();
    _stopAutoReading();
    if (!mounted) return;
    setState(() {
      _currentChapterIndex = targetIndex;
      _resetChapterPosition();
      _restoreCharPosition = charPosition;
      _lastCharPosition = charPosition;
      _showControls = false;
      _showTtsPanel = false;
    });
    await _loadCurrentChapter();
    if (mounted && _content.isNotEmpty) {
      final safe = charPosition.clamp(0, _content.length).toInt();
      setState(() {
        _restoreCharPosition = safe;
        _lastCharPosition = safe;
        _continuousReaderSession++;
      });
      await _saveProgressNow(charPosition: safe, scrollPosition: 0);
    }
  }

  void _toggleControls() {
    setState(() {
      if (_showControls) {
        // 关闭时同时关闭设置面板和听书面板
        context.read<ReadingProvider>().hideSettings();
        _showTtsPanel = false;
      }
      _showControls = !_showControls;
    });
  }

  void _showTtsControls() {
    context.read<ReadingProvider>().hideSettings();
    setState(() => _showTtsPanel = true);
  }

  Future<void> _showReadingSettings() async {
    if (!mounted) return;

    final readingProvider = context.read<ReadingProvider>();
    readingProvider.hideSettings();
    var latest = readingProvider.settings.copyWith();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return ReadingSettingsPanel(
          settings: latest,
          onPreviewChanged: (settings) {
            _captureAnchorBeforePageModeChange(latest, settings);
            latest = settings;
            readingProvider.previewSettings(settings);
            _syncPagedAutoReadTimer(settings);
          },
        );
      },
    );
    if (!mounted) return;
    await readingProvider.saveSettings(latest);
    _syncPagedAutoReadTimer(latest);
  }

  void _captureAnchorBeforePageModeChange(
    ReadingSettings previous,
    ReadingSettings next,
  ) {
    if (previous.pageMode == next.pageMode) return;
    if (previous.pageMode == NovelPageMode.verticalScroll) {
      final anchor = _continuousViewController.captureAnchor();
      if (anchor != null) {
        _currentChapterIndex = anchor.chapterIndex;
        _content = anchor.content;
        _lastCharPosition = anchor.charPosition;
        _restoreCharPosition = anchor.charPosition;
        _currentPageIndex = _pageIndexForCharPosition(
          anchor.content,
          anchor.charPosition,
        );
      }
    } else {
      final charPosition = _pagedViewController.currentCharPosition;
      if (charPosition != null) {
        _lastCharPosition = charPosition.clamp(0, _content.length).toInt();
        _restoreCharPosition = _lastCharPosition;
        _currentPageIndex = _pageIndexForCharPosition(
          _content,
          _lastCharPosition,
        );
      }
    }
    _lastScrollPosition = 0;
    if (next.pageMode == NovelPageMode.verticalScroll) {
      _continuousReaderSession++;
    }
  }

  Future<void> _toggleAutoReading() async {
    if (_isAutoReading) {
      _stopAutoReading();
      return;
    }
    final ttsProvider = context.read<TtsProvider>();
    if (ttsProvider.isSpeaking ||
        ttsProvider.isPaused ||
        ttsProvider.isStarting) {
      await ttsProvider.stopSpeaking();
      _clearPausedTtsAnchor();
    }
    if (!mounted) return;
    setState(() {
      _isAutoReading = true;
      _showControls = false;
      _showTtsPanel = false;
    });
    _syncPagedAutoReadTimer(context.read<ReadingProvider>().settings);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('自动阅读已开启，点击“更多”可停止'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _stopAutoReading() {
    _pagedAutoReadTimer?.cancel();
    _pagedAutoReadTimer = null;
    if (!_isAutoReading) return;
    if (mounted) {
      setState(() => _isAutoReading = false);
    } else {
      _isAutoReading = false;
    }
  }

  void _syncPagedAutoReadTimer(ReadingSettings settings) {
    _pagedAutoReadTimer?.cancel();
    _pagedAutoReadTimer = null;
    if (!_isAutoReading || settings.pageMode == NovelPageMode.verticalScroll) {
      return;
    }
    final milliseconds = (5200 / settings.autoReadSpeed)
        .clamp(1700, 9000)
        .round();
    _pagedAutoReadTimer = Timer.periodic(
      Duration(milliseconds: milliseconds),
      (_) => unawaited(_pagedViewController.nextPage()),
    );
  }

  double _autoReadPixelsPerSecond(ReadingSettings settings) {
    if (!_isAutoReading || settings.pageMode != NovelPageMode.verticalScroll) {
      return 0;
    }
    return 18 + settings.autoReadSpeed * 15;
  }

  void _resetChapterPosition() {
    _currentPageIndex = 0;
    _restoreCharPosition = 0;
    _lastCharPosition = 0;
    _lastScrollPosition = 0;
    _novelChapterProgress.value = 0;
    _novelBookProgress.value = _chapters.isEmpty
        ? 0
        : (_currentChapterIndex / _chapters.length).clamp(0.0, 1.0);
    _clearPausedTtsAnchor();
  }

  int _chapterProgressPercentForPosition(int charPosition) {
    if (_content.isEmpty) return 0;
    final safePosition = charPosition.clamp(0, _content.length).toInt();
    return ((safePosition / _content.length) * 100).clamp(0.0, 100.0).round();
  }

  double get _bookProgress {
    if (_chapters.isEmpty) return 0;
    final chapterFraction = _content.isEmpty
        ? 0.0
        : (_lastCharPosition / _content.length).clamp(0.0, 1.0);
    return ((_currentChapterIndex + chapterFraction) / _chapters.length).clamp(
      0.0,
      1.0,
    );
  }

  void _publishReadingProgress() {
    final chapterProgress = _chapterProgressPercentForPosition(
      _lastCharPosition,
    );
    if (_novelChapterProgress.value != chapterProgress) {
      _novelChapterProgress.value = chapterProgress;
    }
    final bookProgress = _bookProgress;
    if ((_novelBookProgress.value - bookProgress).abs() >= 0.0001) {
      _novelBookProgress.value = bookProgress;
    }
  }

  Future<void> _jumpToBookProgress(double value) async {
    if (_chapters.isEmpty) return;
    final safeValue = value.clamp(0.0, 1.0).toDouble();
    final scaled = safeValue * _chapters.length;
    final targetIndex = scaled.floor().clamp(0, _chapters.length - 1).toInt();
    final fraction = targetIndex == _chapters.length - 1 && safeValue >= 1
        ? 1.0
        : (scaled - targetIndex).clamp(0.0, 1.0);
    final canOpen = await _ensureChapterUnlocked(targetIndex);
    if (!canOpen || !mounted) {
      setState(() => _pendingBookProgress = null);
      return;
    }

    final ttsProvider = context.read<TtsProvider>();
    await _saveProgressNow(charPosition: _currentProgressPosition(ttsProvider));
    await ttsProvider.stopSpeaking();
    _stopAutoReading();
    if (!mounted) return;
    setState(() {
      _currentChapterIndex = targetIndex;
      _resetChapterPosition();
      _showTtsPanel = false;
    });
    await _loadCurrentChapter();
    if (!mounted || _content.isEmpty) return;
    final position = (_content.length * fraction)
        .round()
        .clamp(0, _content.length)
        .toInt();
    setState(() {
      _restoreCharPosition = position;
      _lastCharPosition = position;
      _lastScrollPosition = 0;
      _currentPageIndex = _pageIndexForCharPosition(_content, position);
      _continuousReaderSession++;
      _pendingBookProgress = null;
    });
    await _saveProgressNow(charPosition: position, scrollPosition: 0);
  }

  void _updateReadingPosition(
    int page,
    int charPosition,
    double scrollPosition,
  ) {
    _currentPageIndex = page;
    _lastCharPosition = charPosition.clamp(0, _content.length).toInt();
    _lastScrollPosition = scrollPosition;
    _publishReadingProgress();
  }

  Future<String> _loadContinuousChapterContent(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return '';

    // Do not show a login dialog merely because a neighbouring chapter is
    // being prefetched. Explicit chapter navigation still uses the normal
    // login gate below.
    final canPreview =
        chapterIndex < _guestChapterLimit ||
        context.read<InteractionAuthProvider>().isLoggedIn;
    if (!canPreview) return '';

    final chapter = _chapters[chapterIndex];
    if (widget.novel.isLocal) return chapter.content;

    final content = await context.read<BookSourceProvider>().getChapterContent(
      widget.novel,
      chapter,
    );
    return _formatChapterContent(content);
  }

  void _updateContinuousReadingPosition(
    int chapterIndex,
    String content,
    int charPosition, {
    required bool settled,
  }) {
    if (!mounted ||
        chapterIndex < 0 ||
        chapterIndex >= _chapters.length ||
        content.isEmpty) {
      return;
    }

    final safePosition = charPosition.clamp(0, content.length).toInt();
    final chapterChanged = chapterIndex != _currentChapterIndex;
    // While a finger is moving, rebuilding the entire reader for every
    // position change only introduces jank. Keep the
    // position current in memory, then rebuild once when the gesture settles
    // so the visible percentage cannot remain stale.
    final shouldRebuild = chapterChanged || settled;

    void applyPosition() {
      _currentChapterIndex = chapterIndex;
      _content = content;
      _restoreCharPosition = safePosition;
      _lastCharPosition = safePosition;
      // A continuous scroll offset spans several chapters and must not be
      // reused when this chapter is opened on a later app launch.
      _lastScrollPosition = 0;
      _currentPageIndex = _pageIndexForCharPosition(content, safePosition);
    }

    if (shouldRebuild) {
      setState(applyPosition);
    } else {
      applyPosition();
    }
    _publishReadingProgress();

    if (chapterChanged) {
      context.read<ReadingProvider>().setCurrentChapter(
        _chapters[chapterIndex],
      );
      if (!widget.novel.isLocal) {
        unawaited(
          context.read<BookSourceProvider>().pinCurrentChapter(
            widget.novel,
            _chapters[chapterIndex],
          ),
        );
      }
      final ttsProvider = context.read<TtsProvider>();
      if (ttsProvider.isSpeaking ||
          ttsProvider.isPaused ||
          ttsProvider.isStarting) {
        unawaited(ttsProvider.stopSpeaking());
      }
    }

    if (settled) {
      unawaited(
        _saveProgressNow(charPosition: safePosition, scrollPosition: 0),
      );
    }
  }

  Widget _buildContinuousChapterSection({
    required Chapter chapter,
    required int chapterIndex,
    required String content,
    required double fontSize,
    required String? fontFamily,
    required Color color,
    required double lineHeight,
    required double paragraphSpacing,
    required double horizontalPadding,
    required bool isNight,
    required TtsProvider ttsProvider,
    required Key textKey,
  }) {
    final isActiveChapter = chapterIndex == _currentChapterIndex;
    final text = isActiveChapter
        ? _buildReaderText(
            pageContent: content,
            pageStartOffset: 0,
            fontSize: fontSize,
            fontFamily: fontFamily,
            color: color,
            lineHeight: lineHeight,
            paragraphSpacing: paragraphSpacing,
            isNight: isNight,
            ttsProvider: ttsProvider,
            key: textKey,
          )
        : RichText(
            key: textKey,
            textScaler: TextScaler.noScaling,
            textAlign: TextAlign.justify,
            softWrap: true,
            overflow: TextOverflow.clip,
            text: NovelTextLayout.buildSpan(
              text: content,
              style: TextStyle(
                fontSize: fontSize,
                fontFamily: fontFamily,
                color: color,
                height: lineHeight,
              ),
              paragraphSpacing: paragraphSpacing,
            ),
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        34,
        horizontalPadding,
        30,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chapter.title.trim().isNotEmpty) ...[
            Text(
              chapter.title,
              textScaler: TextScaler.noScaling,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: fontSize + 2,
                fontFamily: fontFamily,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Divider(
              height: 1,
              color: (isNight ? Colors.white : Colors.black).withValues(
                alpha: 0.12,
              ),
            ),
            const SizedBox(height: 22),
          ],
          text,
        ],
      ),
    );
  }

  Future<void> _goToNextChapter() async {
    if (_currentChapterIndex < _chapters.length - 1) {
      final targetIndex = _currentChapterIndex + 1;
      final canOpen = await _ensureChapterUnlocked(targetIndex);
      if (!canOpen) return;
      if (!mounted) return;
      final ttsProvider = context.read<TtsProvider>();
      await _saveProgressNow(
        charPosition: _currentProgressPosition(ttsProvider),
      );
      unawaited(ttsProvider.stopSpeaking());
      setState(() {
        _currentChapterIndex = targetIndex;
        _showControls = false;
        _showTtsPanel = false;
        _resetChapterPosition();
      });
      await _loadCurrentChapter();
      if (mounted && _content.isNotEmpty) {
        await _saveProgressNow(charPosition: 0, scrollPosition: 0);
      }
    }
  }

  Future<void> _goToPrevChapter() async {
    if (_currentChapterIndex > 0) {
      final targetIndex = _currentChapterIndex - 1;
      final canOpen = await _ensureChapterUnlocked(targetIndex);
      if (!canOpen) return;
      if (!mounted) return;
      final ttsProvider = context.read<TtsProvider>();
      await _saveProgressNow(
        charPosition: _currentProgressPosition(ttsProvider),
      );
      unawaited(ttsProvider.stopSpeaking());
      setState(() {
        _currentChapterIndex = targetIndex;
        _showControls = false;
        _showTtsPanel = false;
        _resetChapterPosition();
      });
      await _loadCurrentChapter();
      if (mounted && _content.isNotEmpty) {
        // Returning to a previous chapter should meet its ending, so the
        // reader continues naturally into the current chapter when scrolling
        // down again instead of restarting the older chapter at 0%.
        final endPosition = _content.length;
        setState(() {
          _restoreCharPosition = endPosition;
          _lastCharPosition = endPosition;
          _lastScrollPosition = 0;
          _currentPageIndex = _pageIndexForCharPosition(_content, endPosition);
          _continuousReaderSession++;
        });
        await _saveProgressNow(charPosition: endPosition, scrollPosition: 0);
      }
    }
  }

  String get _currentChapterTitle {
    if (_chapters.isNotEmpty && _currentChapterIndex < _chapters.length) {
      return _chapters[_currentChapterIndex].title;
    }
    return '语音朗读';
  }

  Future<void> _showTtsMediaControls({required bool playing}) async {
    final service =
        _ttsMediaControlService ??
        context.read<TtsProvider>().mediaControlService;
    await service.show(
      novel: widget.novel,
      chapterTitle: _currentChapterTitle,
      playing: playing,
    );
  }

  Future<void> _handleMediaPlay() async {
    if (!mounted) return;
    final ttsProvider = context.read<TtsProvider>();
    if (ttsProvider.isPaused || _pausedTtsCharPosition != null) {
      await _resumeTtsFromCurrentPosition();
    } else if (!ttsProvider.isSpeaking && !ttsProvider.isStarting) {
      await _startTts(startPosition: _lastCharPosition);
    } else {
      await _showTtsMediaControls(playing: true);
    }
  }

  Future<void> _handleMediaPause() async {
    if (!mounted) return;
    final ttsProvider = context.read<TtsProvider>();
    if (ttsProvider.isSpeaking && !ttsProvider.isPaused) {
      await _pauseTts();
    }
  }

  Future<void> _handleMediaPrevious() => _handleMediaChapterChange(-1);

  Future<void> _handleMediaNext() => _handleMediaChapterChange(1);

  Future<void> _handleMediaChapterChange(int delta) async {
    if (!mounted || _handlingTtsMediaChapterChange || delta == 0) return;
    final targetIndex = _currentChapterIndex + delta;
    if (targetIndex < 0 || targetIndex >= _chapters.length) {
      final ttsProvider = context.read<TtsProvider>();
      await _showTtsMediaControls(
        playing: ttsProvider.isSpeaking && !ttsProvider.isPaused,
      );
      return;
    }

    _handlingTtsMediaChapterChange = true;
    try {
      final canOpen = await _ensureChapterUnlocked(targetIndex);
      if (!canOpen || !mounted) return;

      final ttsProvider = context.read<TtsProvider>();
      await _saveProgressNow(
        charPosition: _currentProgressPosition(ttsProvider),
      );
      await ttsProvider.stopSpeaking(clearSleepTimer: false);
      _clearPausedTtsAnchor();
      if (!mounted) return;

      setState(() {
        _currentChapterIndex = targetIndex;
        _showControls = false;
        _showTtsPanel = true;
        _resetChapterPosition();
      });
      await _loadCurrentChapter();
      if (!mounted || _content.isEmpty) return;

      await _saveProgressNow(charPosition: 0, scrollPosition: 0);
      await _startTts(startPosition: 0);
    } finally {
      _handlingTtsMediaChapterChange = false;
    }
  }

  Future<bool> _handleTtsChapterComplete() async {
    if (!mounted) return false;

    final hasNext = _currentChapterIndex < _chapters.length - 1;
    if (!hasNext) {
      await _saveProgressNow(
        charPosition: _content.length,
        scrollPosition: _lastScrollPosition,
      );
      if (mounted) {
        setState(() => _showTtsPanel = false);
      }
      return false;
    }

    final nextChapterIndex = _currentChapterIndex + 1;
    final canOpen = await _ensureChapterUnlocked(nextChapterIndex);
    if (!canOpen) {
      if (mounted) {
        setState(() => _showTtsPanel = false);
      }
      return false;
    }

    await _saveProgressNow(
      charPosition: _content.length,
      scrollPosition: _lastScrollPosition,
    );
    if (!mounted) return false;

    setState(() {
      _currentChapterIndex = nextChapterIndex;
      _showControls = false;
      _showTtsPanel = true;
      _resetChapterPosition();
    });

    await _loadCurrentChapter();
    if (!mounted || _content.isEmpty) return false;

    await _saveProgressNow(charPosition: 0, scrollPosition: 0);
    return _startTts(startPosition: 0);
  }

  Future<bool> _startTts({int? startPosition}) async {
    if (_content.isEmpty) return false;

    if (_content.isNotEmpty) {
      _stopAutoReading();
      final ttsProvider = context.read<TtsProvider>();
      final messenger = ScaffoldMessenger.of(context);
      final startOffset =
          startPosition ?? (_lastCharPosition > 0 ? _lastCharPosition : 0);
      final speechStartOffset = _cleanSpeechStartOffset(startOffset);
      final textToRead = _content.substring(
        speechStartOffset.clamp(0, _content.length),
      );
      setState(() => _showTtsPanel = true);
      await _showTtsMediaControls(playing: true);
      final started = await ttsProvider.startSpeaking(
        textToRead,
        startOffset: speechStartOffset,
        ownerKey: _ttsOwnerKey,
      );
      if (started) {
        await _showTtsMediaControls(playing: true);
      }
      if (!started && mounted) {
        await ttsProvider.mediaControlService.stop();
        final message = ttsProvider.lastErrorMessage.isNotEmpty
            ? ttsProvider.lastErrorMessage
            : '语音朗读启动失败，请检查语音设置';
        setState(() => _showTtsPanel = false);
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
      return started;
    }
    return false;
  }

  Future<void> _stopTts() async {
    final ttsProvider = context.read<TtsProvider>();
    await _saveProgressNow(charPosition: _currentProgressPosition(ttsProvider));
    await ttsProvider.stopSpeaking();
    _clearPausedTtsAnchor();
    setState(() => _showTtsPanel = false);
  }

  Future<void> _handleSleepTimerElapsed() async {
    if (!mounted) return;
    final ttsProvider = context.read<TtsProvider>();
    await _saveProgressNow(charPosition: _currentProgressPosition(ttsProvider));
    _clearPausedTtsAnchor();
    if (mounted) {
      setState(() => _showTtsPanel = false);
    }
  }

  Future<void> _pauseTts() async {
    final ttsProvider = context.read<TtsProvider>();
    final currentPosition = _currentProgressPosition(ttsProvider);
    _pausedTtsChapterIndex = _currentChapterIndex;
    _pausedTtsPageIndex = _currentPageIndex;
    _pausedTtsCharPosition = currentPosition;
    await _saveProgressNow(charPosition: currentPosition);
    final paused = await ttsProvider.pauseSpeaking();
    if (paused) {
      await _showTtsMediaControls(playing: false);
    } else {
      _clearPausedTtsAnchor();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂停失败，请重试')));
      }
    }
  }

  Future<void> _resumeTtsFromCurrentPosition() async {
    final ttsProvider = context.read<TtsProvider>();
    final currentPageStart = _lastCharPosition;
    final movedWhilePaused =
        _pausedTtsChapterIndex != _currentChapterIndex ||
        _pausedTtsPageIndex != _currentPageIndex ||
        _pausedTtsCharPosition != _lastCharPosition;
    final currentVisiblePosition = movedWhilePaused
        ? (_pausedTtsCharPosition != _lastCharPosition
              ? _lastCharPosition
              : currentPageStart)
        : (_lastCharPosition > 0 ? _lastCharPosition : currentPageStart);

    if (movedWhilePaused) {
      await ttsProvider.stopSpeaking();
      _clearPausedTtsAnchor();
      await _startTts(startPosition: currentVisiblePosition);
      return;
    }

    _clearPausedTtsAnchor();
    final resumed = await ttsProvider.resumeSpeaking();
    if (resumed) {
      await _showTtsMediaControls(playing: true);
      return;
    }

    await ttsProvider.stopSpeaking();
    await _startTts(startPosition: currentVisiblePosition);
  }

  void _clearPausedTtsAnchor() {
    _pausedTtsChapterIndex = null;
    _pausedTtsPageIndex = null;
    _pausedTtsCharPosition = null;
  }

  @override
  void dispose() {
    _pagedAutoReadTimer?.cancel();
    _chapterLoadGuard.dispose();
    unawaited(_readerPageCommandSubscription?.cancel() ?? Future.value());
    unawaited(ReaderPlatformService.instance.releaseReaderSession());
    if (!_isLeaving) {
      final ttsProvider = _ttsProvider;
      final finalCharPosition =
          ttsProvider != null &&
              ttsProvider.isOwnedBy(_ttsOwnerKey) &&
              (ttsProvider.isSpeaking ||
                  ttsProvider.isPaused ||
                  ttsProvider.isStarting) &&
              ttsProvider.currentStartOffset >= 0
          ? ttsProvider.currentStartOffset.clamp(0, _content.length).toInt()
          : _captureVisibleProgressPosition(ttsProvider);
      // _saveProgressNow publishes to the live ValueNotifiers synchronously,
      // then finishes through the provider references captured above. This
      // must be started before the notifiers are disposed.
      unawaited(
        _saveProgressNow(charPosition: finalCharPosition).catchError((_) {}),
      );
    }
    _novelChapterProgress.dispose();
    _novelBookProgress.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _ttsMediaControlService?.unbindControls(this);
    _ttsProvider?.unbindSleepTimer(this);
    _ttsProvider?.unbindCompletion(this);
    _telemetryTrace.close(
      metadata: {
        'chapterIndex': _currentChapterIndex,
        'progressPercent': _chapterProgressPercentForPosition(
          _lastCharPosition,
        ),
        'ttsUsed': _ttsProvider != null,
      },
    );
    super.dispose();
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  String? _getFontFamily(String name) {
    return name == ReadingSettings.systemFont ? null : name;
  }

  int _charsPerPage(double fontSize, double lineHeight) {
    return (500 *
            (18 / fontSize).clamp(0.65, 1.35) *
            (1.6 / lineHeight).clamp(0.75, 1.2))
        .clamp(220, 650)
        .round();
  }

  int _pageStartOffsetForPage(
    int pageIndex,
    double fontSize,
    double lineHeight,
  ) {
    if (_content.isEmpty || pageIndex <= 0) return 0;

    final starts = _pageStartsForContent(_content, fontSize, lineHeight);
    if (starts.isEmpty) return 0;
    return starts[pageIndex.clamp(0, starts.length - 1)];
  }

  List<int> _pageStartsForContent(
    String content,
    double fontSize,
    double lineHeight,
  ) {
    if (content.isEmpty) return const [0];
    final charsPerPage = _charsPerPage(fontSize, lineHeight);
    final paragraphs = content.split('\n');
    final starts = <int>[];
    var currentPage = '';
    var currentStart = 0;
    var cursor = 0;

    for (final para in paragraphs) {
      if ((currentPage.length + para.length) > charsPerPage * 1.5 &&
          currentPage.isNotEmpty) {
        starts.add(currentStart);
        currentPage = para;
        currentStart = cursor;
      } else {
        currentPage += (currentPage.isEmpty ? '' : '\n') + para;
      }
      cursor += para.length + 1;
    }
    if (currentPage.isNotEmpty) {
      starts.add(currentStart);
    }
    return starts.isEmpty ? const [0] : starts;
  }

  int _pageIndexForCharPosition(String content, int charPosition) {
    if (content.isEmpty || charPosition <= 0) return 0;
    final settings = context.read<ReadingProvider>().settings;
    final starts = _pageStartsForContent(
      content,
      settings.fontSize,
      settings.lineHeight,
    );
    for (var i = starts.length - 1; i >= 0; i--) {
      if (charPosition >= starts[i]) return i;
    }
    return 0;
  }

  int _cleanSpeechStartOffset(int offset) {
    var start = offset.clamp(0, _content.length);
    while (start < _content.length) {
      final char = _content[start];
      final code = char.codeUnitAt(0);
      final isInvisible =
          code <= 0x20 ||
          code == 0x7F ||
          code == 0xFEFF ||
          (code >= 0x200B && code <= 0x200D);
      if (!isInvisible) break;
      start++;
    }
    return start;
  }

  String _formatChapterContent(String content) {
    return content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(
          (line) =>
              line.startsWith('\u3000\u3000') ? line : '\u3000\u3000$line',
        )
        .join('\n\n');
  }

  Future<void> _handleBack() async {
    final ttsProvider = context.read<TtsProvider>();
    await _saveVisibleProgressNow(ttsProvider);
    await ttsProvider.stopSpeaking();
    if (!mounted) return;
    _isLeaving = true;
    Navigator.pop(context);
  }

  Widget _buildReaderText({
    required String pageContent,
    required int pageStartOffset,
    required double fontSize,
    required String? fontFamily,
    required Color color,
    required double lineHeight,
    required double paragraphSpacing,
    required bool isNight,
    required TtsProvider ttsProvider,
    Key? key,
  }) {
    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: color,
      height: lineHeight,
    );

    final range = ttsProvider.isSpeaking && ttsProvider.currentStartOffset >= 0
        ? paragraphRangeForOffset(_content, ttsProvider.currentStartOffset)
        : TextRange.empty;
    final highlightColor = isNight
        ? AppTheme.primaryColor.withValues(alpha: 0.35)
        : AppTheme.primaryColor.withValues(alpha: 0.18);

    return RichText(
      key: key,
      textScaler: TextScaler.noScaling,
      textAlign: TextAlign.justify,
      softWrap: true,
      overflow: TextOverflow.clip,
      text: NovelTextLayout.buildSpan(
        text: pageContent,
        globalStartOffset: pageStartOffset,
        style: baseStyle,
        paragraphSpacing: paragraphSpacing,
        highlightRange: range,
        highlightColor: highlightColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readingProvider = context.watch<ReadingProvider>();
    final settings = readingProvider.settings;
    _syncReaderPlatformSettings(settings);
    final ttsRenderState = context.select<TtsProvider, (bool, int, int)>((tts) {
      final ownedSpeaking = tts.isOwnedBy(_ttsOwnerKey) && tts.isSpeaking;
      final range = ownedSpeaking
          ? paragraphRangeForOffset(_content, tts.currentStartOffset)
          : TextRange.empty;
      return (ownedSpeaking, range.start, range.end);
    });
    final ttsProvider = context.read<TtsProvider>();
    final bgColor = _parseColor(settings.backgroundColor);
    final isNight = settings.nightMode;
    final activeTtsParagraph = ttsRenderState.$1
        ? TextRange(start: ttsRenderState.$2, end: ttsRenderState.$3)
        : TextRange.empty;
    final activeTtsParagraphOffset = activeTtsParagraph.isValid
        ? activeTtsParagraph.start
        : null;
    final fontFamily = _getFontFamily(settings.fontFamily);
    final textColor = isNight ? AppTheme.nightText : const Color(0xFF2F2114);
    final viewport = _isLoadingContent
        ? Center(
            child: CircularProgressIndicator(
              color: isNight ? Colors.white54 : null,
            ),
          )
        : _content.isEmpty
        ? _buildEmptyContent(isNight)
        : settings.pageMode == NovelPageMode.verticalScroll
        ? ContinuousChapterView(
            key: ValueKey(
              'continuous-reader-${widget.novel.id}-$_continuousReaderSession',
            ),
            chapters: _chapters,
            initialChapterIndex: _currentChapterIndex,
            initialContent: _content,
            initialTextOffset: _lastCharPosition,
            activeChapterIndex: ttsRenderState.$1 ? _currentChapterIndex : null,
            activeTextOffset: ttsRenderState.$1
                ? activeTtsParagraphOffset
                : null,
            controller: _continuousViewController,
            layoutKey: Object.hash(
              settings.fontSize,
              settings.fontFamily,
              settings.lineHeight,
              settings.paragraphSpacing,
              settings.horizontalPadding,
            ),
            autoReadPixelsPerSecond: _autoReadPixelsPerSecond(settings),
            loadChapterContent: _loadContinuousChapterContent,
            sectionBuilder: (chapter, chapterIndex, chapterContent, textKey) {
              return _buildContinuousChapterSection(
                chapter: chapter,
                chapterIndex: chapterIndex,
                content: chapterContent,
                fontSize: settings.fontSize,
                fontFamily: fontFamily,
                color: textColor,
                lineHeight: settings.lineHeight,
                paragraphSpacing: settings.paragraphSpacing,
                horizontalPadding: settings.horizontalPadding,
                isNight: isNight,
                ttsProvider: ttsProvider,
                textKey: textKey,
              );
            },
            onReadingPositionChanged:
                (chapterIndex, chapterContent, charPosition) {
                  _updateContinuousReadingPosition(
                    chapterIndex,
                    chapterContent,
                    charPosition,
                    settled: false,
                  );
                },
            onReadingPositionSettled:
                (chapterIndex, chapterContent, charPosition) {
                  _updateContinuousReadingPosition(
                    chapterIndex,
                    chapterContent,
                    charPosition,
                    settled: true,
                  );
                },
            onTap: _toggleControls,
          )
        : NovelPagedView(
            key: ValueKey(
              'novel-paged-${widget.novel.id}-$_currentChapterIndex',
            ),
            controller: _pagedViewController,
            content: _content,
            chapterTitle: _currentChapterTitle,
            mode: settings.pageMode,
            textStyle: TextStyle(
              fontSize: settings.fontSize,
              fontFamily: fontFamily,
              color: textColor,
              height: settings.lineHeight,
            ),
            paragraphSpacing: settings.paragraphSpacing,
            horizontalPadding: settings.horizontalPadding,
            initialTextOffset: _lastCharPosition,
            activeTextRange: activeTtsParagraph,
            singleHandMode: settings.singleHandMode,
            pageBackgroundColor: bgColor,
            onPositionChanged: (page, charPosition) {
              _updateReadingPosition(page, charPosition, 0);
            },
            onPositionSettled: (page, charPosition) {
              _updateReadingPosition(page, charPosition, 0);
              unawaited(
                _saveProgressNow(charPosition: charPosition, scrollPosition: 0),
              );
            },
            onNeedNextChapter: _goToNextChapter,
            onNeedPreviousChapter: _goToPrevChapter,
            onToggleControls: _toggleControls,
          );

    return PopScope(
      canPop: _isLeaving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBack();
      },
      child: ReaderShell(
        backgroundColor: bgColor,
        chromeVisible: _showControls,
        contentSemanticLabel: '小说正文',
        content: NovelReaderBackdrop(
          color: bgColor,
          child: SafeArea(
            minimum: const EdgeInsets.only(top: 34, bottom: 28),
            child: KeyedSubtree(
              key: const ValueKey('reading-content-area'),
              child: viewport,
            ),
          ),
        ),
        topChrome: _buildTopChrome(),
        // The TTS controls own the bottom surface while expanded. Keeping the
        // normal reader chrome mounted above them hid the timer row and made
        // the book-progress slider look like part of the speech controls.
        bottomChrome: _showTtsPanel ? null : _buildBottomChrome(),
        progressHud: _content.isEmpty || _showControls || _showTtsPanel
            ? null
            : _NovelReaderProgressHud(
                contentLength: _content.length,
                fallbackProgress: _novelChapterProgress,
                autoReading: _isAutoReading,
              ),
        progressHudPadding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        overlays: [
          if (!_showControls && !_showTtsPanel && _content.isNotEmpty)
            Positioned.fill(
              child: _ReaderAmbientStatus(
                chapterTitle: _currentChapterTitle,
                fallbackProgress: _novelBookProgress,
                chapterIndex: _currentChapterIndex,
                chapterCount: _chapters.length,
                contentLength: _content.length,
                pageMode: settings.pageMode,
                backgroundColor: bgColor,
              ),
            ),
          if (_showTtsPanel)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Builder(
                builder: (context) {
                  context.select<TtsProvider, (bool, bool, bool)>(
                    (tts) => (tts.isSpeaking, tts.isPaused, tts.isStarting),
                  );
                  return _buildTtsPanel(context.read<TtsProvider>());
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopChrome() {
    final bookmarked = _bookmarkAtCurrentPosition != null;
    return ReaderChrome.top(
      child: Row(
        children: [
          ReaderChromeAction(
            icon: Icons.arrow_back_rounded,
            label: '返回',
            onPressed: _handleBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _currentChapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          ReaderChromeAction(
            icon: bookmarked
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            label: bookmarked ? '移除书签' : '添加书签',
            selected: bookmarked,
            onPressed: () => unawaited(_toggleBookmark()),
          ),
          ReaderChromeAction(
            icon: Icons.more_horiz_rounded,
            label: '更多',
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomChrome() {
    return Selector<TtsProvider, (bool, bool)>(
      selector: (_, tts) =>
          (tts.isSpeaking || tts.isPaused || tts.isStarting, tts.isStarting),
      builder: (context, ttsState, _) {
        final ttsActive = ttsState.$1;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBookProgressControl(),
            ReaderChrome.bottom(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _ReaderBottomAction(
                    icon: Icons.format_list_bulleted_rounded,
                    label: '目录',
                    onPressed: _showChapterList,
                  ),
                  _ReaderBottomAction(
                    icon: context.read<ReadingProvider>().settings.nightMode
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    label: context.read<ReadingProvider>().settings.nightMode
                        ? '日间'
                        : '夜间',
                    onPressed: () =>
                        context.read<ReadingProvider>().toggleNightMode(),
                  ),
                  _ReaderBottomAction(
                    icon: ttsActive
                        ? Icons.record_voice_over_rounded
                        : Icons.headphones_rounded,
                    label: ttsState.$2 ? '启动中' : '朗读',
                    selected: ttsActive,
                    onPressed: ttsActive
                        ? _showTtsControls
                        : () => unawaited(_startTts()),
                  ),
                  _ReaderBottomAction(
                    icon: Icons.text_fields_rounded,
                    label: '设置',
                    onPressed: () => unawaited(_showReadingSettings()),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBookProgressControl() {
    return Selector<TtsProvider, int>(
      selector: (_, tts) =>
          (tts.isSpeaking || tts.isPaused || tts.isStarting) &&
              tts.currentStartOffset >= 0
          ? tts.currentStartOffset
          : -1,
      builder: (context, ttsOffset, _) {
        return ValueListenableBuilder<double>(
          valueListenable: _novelBookProgress,
          builder: (context, fallbackProgress, _) {
            var liveProgress = fallbackProgress;
            if (ttsOffset >= 0 && _content.isNotEmpty && _chapters.isNotEmpty) {
              final chapterFraction = (ttsOffset / _content.length).clamp(
                0.0,
                1.0,
              );
              liveProgress =
                  (_currentChapterIndex + chapterFraction) / _chapters.length;
            }
            final value = (_pendingBookProgress ?? liveProgress).clamp(
              0.0,
              1.0,
            );
            return Material(
              color: ReaderTokens.of(context).chromeSurface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
                child: Row(
                  children: [
                    ReaderChromeAction(
                      icon: Icons.skip_previous_rounded,
                      label: '上一章',
                      onPressed: _currentChapterIndex > 0
                          ? _goToPrevChapter
                          : null,
                    ),
                    Expanded(
                      child: Slider(
                        value: value,
                        min: 0,
                        max: 1,
                        onChanged: _chapters.isEmpty
                            ? null
                            : (next) =>
                                  setState(() => _pendingBookProgress = next),
                        onChangeEnd: _chapters.isEmpty
                            ? null
                            : (next) => unawaited(_jumpToBookProgress(next)),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '全书',
                            style: TextStyle(
                              color: ReaderTokens.of(
                                context,
                              ).onChrome.withValues(alpha: 0.72),
                              fontSize: 10,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${(value * 100).round()}%',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: ReaderTokens.of(context).onChrome,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ReaderChromeAction(
                      icon: Icons.skip_next_rounded,
                      label: '下一章',
                      onPressed: _currentChapterIndex < _chapters.length - 1
                          ? _goToNextChapter
                          : null,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showMoreMenu() async {
    final provider = context.read<ReadingProvider>();
    final settings = provider.settings;
    final isNight = settings.nightMode;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final textColor = isNight ? Colors.white : AppTheme.textPrimary;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.search_rounded),
                  title: Text('全文搜索', style: TextStyle(color: textColor)),
                  subtitle: const Text('搜索本地或已缓存章节'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showFullTextSearch();
                  },
                ),
                ListTile(
                  leading: Icon(
                    _isAutoReading
                        ? Icons.pause_circle_outline_rounded
                        : Icons.auto_mode_rounded,
                  ),
                  title: Text(
                    _isAutoReading ? '停止自动阅读' : '自动阅读',
                    style: TextStyle(color: textColor),
                  ),
                  subtitle: Text(
                    '当前速度 ${settings.autoReadSpeed.toStringAsFixed(1)}×，与朗读互斥',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_toggleAutoReading());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download_for_offline_outlined),
                  title: Text('批量缓存', style: TextStyle(color: textColor)),
                  subtitle: const Text('后 20 章、后 50 章或全本'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showBatchCacheSheet();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.bookmarks_outlined),
                  title: Text('书签', style: TextStyle(color: textColor)),
                  trailing: Text('${_bookmarks.length}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showBookmarkList();
                  },
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.screen_lock_portrait_outlined),
                  title: Text('屏幕常亮', style: TextStyle(color: textColor)),
                  value: settings.keepScreenOn,
                  onChanged: (value) async {
                    final next = provider.settings.copyWith(
                      keepScreenOn: value,
                    );
                    provider.previewSettings(next);
                    await provider.saveSettings(next);
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: Text('音量键翻页', style: TextStyle(color: textColor)),
                  value: settings.volumeKeyTurnPage,
                  onChanged: (value) async {
                    final next = provider.settings.copyWith(
                      volumeKeyTurnPage: value,
                    );
                    provider.previewSettings(next);
                    await provider.saveSettings(next);
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showBookmarkList() {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final textColor = isNight ? Colors.white : AppTheme.textPrimary;
        final ordered = [..._bookmarks]
          ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
        return SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '书签 · ${ordered.length}',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ordered.isEmpty
                      ? const Center(child: Text('还没有书签'))
                      : ListView.separated(
                          itemCount: ordered.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final bookmark = ordered[index];
                            return ListTile(
                              leading: const Icon(Icons.bookmark_rounded),
                              title: Text(
                                bookmark.chapterTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: textColor),
                              ),
                              subtitle: Text(
                                bookmark.contextText.isEmpty
                                    ? '位置 ${bookmark.charPosition}'
                                    : bookmark.contextText,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: '删除书签',
                                onPressed: () async {
                                  await _storage.deleteNovelBookmark(
                                    widget.novel,
                                    bookmark.id,
                                  );
                                  if (!mounted) return;
                                  setState(() {
                                    _bookmarks = _bookmarks
                                        .where((item) => item.id != bookmark.id)
                                        .toList(growable: false);
                                  });
                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                    _showBookmarkList();
                                  }
                                },
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_jumpToBookmark(bookmark));
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFullTextSearch() {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return _NovelSearchSheet(
          chapters: _chapters,
          isNight: isNight,
          loadContent: (index) async {
            final chapter = _chapters[index];
            if (widget.novel.isLocal) return chapter.content;
            final cached =
                await _storage.getPersistentNovelChapterContent(
                  widget.novel,
                  chapter,
                ) ??
                await _storage.getTemporaryNovelChapterContent(
                  widget.novel,
                  chapter,
                );
            if (cached == null || cached.isEmpty) return null;
            return _formatChapterContent(cached);
          },
          onSelected: (hit) {
            Navigator.pop(sheetContext);
            unawaited(
              _jumpToChapterPosition(hit.chapterIndex, hit.charPosition),
            );
          },
          onCacheAllRequested: () {
            Navigator.pop(sheetContext);
            _showBatchCacheSheet(initialFullBook: true);
          },
        );
      },
    );
  }

  void _showBatchCacheSheet({bool initialFullBook = false}) {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    final sourceProvider = context.read<BookSourceProvider>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return _NovelCacheSheet(
          novel: widget.novel,
          chapters: _chapters,
          currentChapterIndex: _currentChapterIndex,
          provider: sourceProvider,
          isNight: isNight,
          initialRange: initialFullBook
              ? NovelCacheBatchRange.full
              : NovelCacheBatchRange.next20,
          canStart: (range) async {
            if (widget.novel.isLocal) return true;
            final requiresLogin = range
                .chapterIndices(
                  chapterCount: _chapters.length,
                  startIndex: _currentChapterIndex,
                )
                .any((index) => index >= _guestChapterLimit);
            if (!requiresLogin ||
                context.read<InteractionAuthProvider>().isLoggedIn) {
              return true;
            }
            return ensureLoggedInForContent(
              context,
              allowed: false,
              title: '登录后批量缓存',
              message: '登录后可缓存试看范围之外的章节。',
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyContent(bool isNight) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: isNight ? Colors.white38 : AppTheme.textHint,
          ),
          const SizedBox(height: 12),
          Text(
            _contentError ?? '暂无内容',
            style: TextStyle(
              fontSize: 16,
              color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _loadCurrentChapter,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildTtsPanel(TtsProvider ttsProvider) {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    final timerText = ttsProvider.hasSleepTimer
        ? _formatSleepTimerRemaining(ttsProvider.sleepTimerRemaining)
        : null;
    return Container(
      key: const ValueKey('novel-tts-panel'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      decoration: BoxDecoration(
        color: isNight ? AppTheme.nightCard : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.volume_up,
                    color: isNight ? Colors.white : AppTheme.textPrimary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '朗读控制',
                          style: TextStyle(
                            color: isNight
                                ? Colors.white
                                : AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (timerText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '定时关闭 $timerText',
                              style: TextStyle(
                                color: AppTheme.primaryColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('novel-tts-panel-close'),
                    onPressed: () => setState(() => _showTtsPanel = false),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                    ),
                    label: const Text('收起'),
                    style: TextButton.styleFrom(
                      foregroundColor: isNight
                          ? Colors.white70
                          : AppTheme.textSecondary,
                      minimumSize: const Size(64, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    '语速',
                    style: TextStyle(
                      color: isNight ? Colors.white70 : AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: ttsProvider.speed,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      activeColor: AppTheme.primaryColor,
                      inactiveColor: isNight
                          ? Colors.white24
                          : AppTheme.dividerColor,
                      onChanged: (v) => ttsProvider.setSpeed(v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _buildTtsEngineControls(ttsProvider, isNight),
              const SizedBox(height: 8),
              _buildSleepTimerControl(ttsProvider, isNight),
              const SizedBox(height: 10),
              Divider(
                height: 1,
                color: isNight ? Colors.white12 : AppTheme.dividerColor,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ttsActionButton(
                    icon: ttsProvider.isPaused ? Icons.play_arrow : Icons.pause,
                    label: ttsProvider.isPaused ? '继续' : '暂停',
                    isNight: isNight,
                    onPressed: () {
                      if (ttsProvider.isPaused) {
                        _resumeTtsFromCurrentPosition();
                      } else {
                        _pauseTts();
                      }
                    },
                  ),
                  const SizedBox(width: 24),
                  _ttsActionButton(
                    icon: Icons.stop,
                    label: '结束朗读',
                    isNight: isNight,
                    onPressed: _stopTts,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTtsEngineControls(TtsProvider ttsProvider, bool isNight) {
    final settings = ttsProvider.settings;
    final secondary = isNight ? Colors.white70 : AppTheme.textSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('朗读引擎', style: TextStyle(color: secondary, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: TtsSettings.engineSystem,
                label: Text('系统 TTS'),
                icon: Icon(Icons.volume_up_outlined),
              ),
              ButtonSegment(
                value: TtsSettings.engineIflytek,
                label: Text('科大讯飞'),
                icon: Icon(Icons.cloud_outlined),
              ),
            ],
            selected: {settings.engine},
            onSelectionChanged: (values) => unawaited(
              ttsProvider.updateSettings(
                settings.copyWith(engine: values.first),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (settings.useIflytek)
          DropdownButtonFormField<String>(
            initialValue: settings.iflytekVoiceName,
            decoration: const InputDecoration(
              labelText: '讯飞发音人',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final voice in iflytekBasicVoices)
                DropdownMenuItem(
                  value: voice.name,
                  child: Text('${voice.label} · ${voice.language}'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              final voice = iflytekBasicVoices.firstWhere(
                (item) => item.name == value,
              );
              unawaited(
                ttsProvider.updateSettings(
                  settings.copyWith(
                    iflytekVoiceName: voice.name,
                    iflytekVoiceLabel: voice.label,
                  ),
                ),
              );
            },
          )
        else
          FutureBuilder<List<TtsSystemVoice>>(
            future: _ttsSystemVoices ??= ttsProvider.loadSystemVoices(),
            builder: (context, snapshot) {
              final voices = snapshot.data ?? const <TtsSystemVoice>[];
              if (snapshot.connectionState != ConnectionState.done &&
                  voices.isEmpty) {
                return const LinearProgressIndicator();
              }
              if (voices.isEmpty) {
                return Text(
                  '当前系统 TTS 未提供可选中文发音人',
                  style: TextStyle(color: secondary, fontSize: 12),
                );
              }
              final selected =
                  voices.any(
                    (voice) =>
                        voice.name == settings.systemVoiceName &&
                        voice.locale == settings.systemVoiceLocale,
                  )
                  ? '${settings.systemVoiceName}|${settings.systemVoiceLocale}'
                  : null;
              return DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: '系统发音人',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final voice in voices)
                    DropdownMenuItem(
                      value: '${voice.name}|${voice.locale}',
                      child: Text(voice.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final separator = value.lastIndexOf('|');
                  unawaited(
                    ttsProvider.updateSettings(
                      settings.copyWith(
                        systemVoiceName: value.substring(0, separator),
                        systemVoiceLocale: value.substring(separator + 1),
                      ),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }

  Widget _ttsActionButton({
    required IconData icon,
    required String label,
    required bool isNight,
    required VoidCallback onPressed,
  }) {
    final color = isNight ? Colors.white : AppTheme.textPrimary;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isNight ? Colors.white70 : AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSleepTimerControl(TtsProvider ttsProvider, bool isNight) {
    final hasTimer = ttsProvider.hasSleepTimer;
    final label = hasTimer
        ? '定时关闭 · ${_formatSleepTimerRemaining(ttsProvider.sleepTimerRemaining)}'
        : '定时关闭';
    return Material(
      color: isNight
          ? Colors.white.withValues(alpha: 0.06)
          : AppTheme.primaryColor.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _showSleepTimerSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 20,
                color: hasTimer
                    ? AppTheme.primaryColor
                    : isNight
                    ? Colors.white70
                    : AppTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasTimer
                        ? AppTheme.primaryColor
                        : isNight
                        ? Colors.white70
                        : AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: hasTimer ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (hasTimer)
                IconButton(
                  tooltip: '关闭定时',
                  visualDensity: VisualDensity.compact,
                  onPressed: ttsProvider.clearSleepTimer,
                  icon: const Icon(Icons.close, size: 18),
                  color: isNight ? Colors.white70 : AppTheme.textSecondary,
                )
              else
                Icon(
                  Icons.chevron_right,
                  color: isNight ? Colors.white38 : AppTheme.textHint,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSleepTimerSheet() async {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    final ttsProvider = context.read<TtsProvider>();
    final options = <_SleepTimerOption>[
      const _SleepTimerOption(label: '关闭定时', duration: Duration.zero),
      const _SleepTimerOption(label: '15 分钟后', duration: Duration(minutes: 15)),
      const _SleepTimerOption(label: '30 分钟后', duration: Duration(minutes: 30)),
      const _SleepTimerOption(label: '60 分钟后', duration: Duration(minutes: 60)),
      const _SleepTimerOption(label: '90 分钟后', duration: Duration(minutes: 90)),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      builder: (context) {
        final selectedMinutes = ttsProvider.hasSleepTimer
            ? (ttsProvider.sleepTimerRemaining.inMinutes + 1)
            : 0;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isNight ? Colors.white24 : AppTheme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: 20,
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '定时关闭',
                      style: TextStyle(
                        color: isNight ? Colors.white : AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              ...options.map((option) {
                final selected = option.duration == Duration.zero
                    ? !ttsProvider.hasSleepTimer
                    : selectedMinutes <= option.duration.inMinutes &&
                          selectedMinutes >
                              _previousSleepOptionMinutes(options, option);
                return ListTile(
                  leading: Icon(
                    option.duration == Duration.zero
                        ? Icons.timer_off_outlined
                        : Icons.timer_outlined,
                    color: selected
                        ? AppTheme.primaryColor
                        : isNight
                        ? Colors.white70
                        : AppTheme.textSecondary,
                  ),
                  title: Text(
                    option.label,
                    style: TextStyle(
                      color: selected
                          ? AppTheme.primaryColor
                          : isNight
                          ? Colors.white
                          : AppTheme.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  trailing: selected
                      ? const Icon(Icons.check, color: AppTheme.primaryColor)
                      : null,
                  onTap: () {
                    if (option.duration == Duration.zero) {
                      ttsProvider.clearSleepTimer();
                    } else {
                      ttsProvider.setSleepTimer(option.duration);
                    }
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  int _previousSleepOptionMinutes(
    List<_SleepTimerOption> options,
    _SleepTimerOption current,
  ) {
    final index = options.indexOf(current);
    if (index <= 1) return 0;
    return options[index - 1].duration.inMinutes;
  }

  String _formatSleepTimerRemaining(Duration remaining) {
    final totalSeconds = remaining.inSeconds;
    if (totalSeconds <= 0) return '即将停止';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _showChapterList() {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    final provider = context.read<BookSourceProvider>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return _ChapterDirectorySheet(
          chapters: _chapters,
          currentChapterIndex: _currentChapterIndex,
          bookmarks: _bookmarks,
          isNight: isNight,
          loadOfflineStatus: widget.novel.isLocal
              ? null
              : () => provider.getOfflineStatus(widget.novel),
          onSelected: (index) {
            Navigator.pop(sheetContext);
            unawaited(_jumpToChapterPosition(index, 0));
          },
        );
      },
    );
  }

  Future<bool> _ensureChapterUnlocked(
    int chapterIndex, {
    bool showError = false,
  }) async {
    final canOpen = await ensureLoggedInForContent(
      context,
      allowed: chapterIndex < _guestChapterLimit,
      title: '登录后继续阅读',
      message: '未登录可试看小说前 10 章，登录后可继续阅读后续章节。',
    );
    if (!canOpen && showError && mounted) {
      setState(() {
        _isLoadingContent = false;
        _content = '';
        _contentError = '登录后可继续阅读后续章节。';
      });
    }
    return canOpen;
  }
}

class _SleepTimerOption {
  const _SleepTimerOption({required this.label, required this.duration});

  final String label;
  final Duration duration;
}

class _ReaderBottomAction extends StatelessWidget {
  const _ReaderBottomAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final color = selected ? tokens.accent : tokens.onChrome;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onPressed,
        radius: 30,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 62, minHeight: 52),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 23),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NovelReaderProgressHud extends StatelessWidget {
  const _NovelReaderProgressHud({
    required this.contentLength,
    required this.fallbackProgress,
    required this.autoReading,
  });

  final int contentLength;
  final ValueListenable<int> fallbackProgress;
  final bool autoReading;

  @override
  Widget build(BuildContext context) {
    return Selector<TtsProvider, int>(
      selector: (_, tts) =>
          (tts.isSpeaking || tts.isPaused || tts.isStarting) &&
              tts.currentStartOffset >= 0 &&
              contentLength > 0
          ? ((tts.currentStartOffset / contentLength) * 100)
                .clamp(0.0, 100.0)
                .round()
          : -1,
      builder: (context, ttsProgress, _) {
        return ValueListenableBuilder<int>(
          valueListenable: fallbackProgress,
          builder: (context, progress, _) => ReaderProgressHud(
            label: '${ttsProgress >= 0 ? ttsProgress : progress}%',
            leading: autoReading ? const Icon(Icons.auto_mode_rounded) : null,
            announceChanges: false,
          ),
        );
      },
    );
  }
}

class _ReaderAmbientStatus extends StatefulWidget {
  const _ReaderAmbientStatus({
    required this.chapterTitle,
    required this.fallbackProgress,
    required this.chapterIndex,
    required this.chapterCount,
    required this.contentLength,
    required this.pageMode,
    required this.backgroundColor,
  });

  final String chapterTitle;
  final ValueListenable<double> fallbackProgress;
  final int chapterIndex;
  final int chapterCount;
  final int contentLength;
  final NovelPageMode pageMode;
  final Color backgroundColor;

  @override
  State<_ReaderAmbientStatus> createState() => _ReaderAmbientStatusState();
}

class _ReaderAmbientStatusState extends State<_ReaderAmbientStatus> {
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    final seconds = 60 - DateTime.now().second;
    _clockTimer = Timer(Duration(seconds: seconds), _startMinuteTicker);
  }

  void _startMinuteTicker() {
    if (!mounted) return;
    setState(() {});
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final darkText = widget.backgroundColor.computeLuminance() > 0.45;
    final color = (darkText ? const Color(0xFF5D5547) : Colors.white)
        .withValues(alpha: 0.58);
    final now = DateTime.now();
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 7),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.chevron_left_rounded, color: color, size: 20),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      widget.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.schedule_rounded, color: color, size: 14),
                  const SizedBox(width: 4),
                  Text(clock, style: TextStyle(color: color, fontSize: 11.5)),
                  const Spacer(),
                  Text(
                    widget.pageMode.label,
                    style: TextStyle(color: color, fontSize: 11),
                  ),
                  const SizedBox(width: 14),
                  Selector<TtsProvider, int>(
                    selector: (_, tts) =>
                        (tts.isSpeaking || tts.isPaused || tts.isStarting) &&
                            tts.currentStartOffset >= 0
                        ? tts.currentStartOffset
                        : -1,
                    builder: (context, ttsOffset, _) {
                      return ValueListenableBuilder<double>(
                        valueListenable: widget.fallbackProgress,
                        builder: (context, fallback, _) {
                          var progress = fallback;
                          if (ttsOffset >= 0 &&
                              widget.contentLength > 0 &&
                              widget.chapterCount > 0) {
                            final fraction = (ttsOffset / widget.contentLength)
                                .clamp(0.0, 1.0);
                            progress =
                                (widget.chapterIndex + fraction) /
                                widget.chapterCount;
                          }
                          return Text(
                            '${(progress * 100).toStringAsFixed(2)}%',
                            style: TextStyle(color: color, fontSize: 11.5),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NovelSearchHit {
  const _NovelSearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.charPosition,
    required this.preview,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int charPosition;
  final String preview;
}

class _NovelSearchSheet extends StatefulWidget {
  const _NovelSearchSheet({
    required this.chapters,
    required this.isNight,
    required this.loadContent,
    required this.onSelected,
    required this.onCacheAllRequested,
  });

  final List<Chapter> chapters;
  final bool isNight;
  final Future<String?> Function(int chapterIndex) loadContent;
  final ValueChanged<_NovelSearchHit> onSelected;
  final VoidCallback onCacheAllRequested;

  @override
  State<_NovelSearchSheet> createState() => _NovelSearchSheetState();
}

class _NovelSearchSheetState extends State<_NovelSearchSheet> {
  static const int _maxResults = 300;
  static const Duration _searchDebounce = Duration(milliseconds: 180);

  final TextEditingController _queryController = TextEditingController();
  final Set<int> _availableChapterIndexes = <int>{};
  List<_NovelSearchHit> _results = const [];
  int _scanned = 0;
  int _searchScanned = 0;
  int _searchGeneration = 0;
  bool _loading = true;
  bool _searching = false;
  Timer? _debounceTimer;

  int get _missingCount =>
      widget.chapters.length - _availableChapterIndexes.length;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCachedContent());
  }

  @override
  void dispose() {
    _searchGeneration++;
    _debounceTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadCachedContent() async {
    for (var index = 0; index < widget.chapters.length; index++) {
      String? content;
      try {
        content = await widget.loadContent(index);
      } catch (_) {
        // A single unreadable cache entry must not make the whole search
        // surface unusable.
      }
      if (!mounted) return;
      if (content != null && content.trim().isNotEmpty) {
        _availableChapterIndexes.add(index);
      }
      _scanned = index + 1;
      if (_scanned % 12 == 0 || _scanned == widget.chapters.length) {
        setState(() {});
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _scheduleSearch(immediate: true);
  }

  void _scheduleSearch({bool immediate = false}) {
    _debounceTimer?.cancel();
    final generation = ++_searchGeneration;
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _results = const [];
          _searching = false;
          _searchScanned = 0;
        });
      }
      return;
    }
    if (_loading) return;
    setState(() {
      _results = const [];
      _searching = true;
      _searchScanned = 0;
    });
    if (immediate) {
      unawaited(_runSearch(query, generation));
      return;
    }
    _debounceTimer = Timer(
      _searchDebounce,
      () => unawaited(_runSearch(query, generation)),
    );
  }

  Future<void> _runSearch(String query, int generation) async {
    final normalizedQuery = query.toLowerCase();
    final hits = <_NovelSearchHit>[];
    final indexes = _availableChapterIndexes.toList()..sort();
    for (var scanIndex = 0; scanIndex < indexes.length; scanIndex++) {
      final chapterIndex = indexes[scanIndex];
      String? content;
      try {
        content = await widget.loadContent(chapterIndex);
      } catch (_) {
        // Continue searching the remaining cached chapters.
      }
      if (!mounted || generation != _searchGeneration) return;
      _searchScanned = scanIndex + 1;
      if (content == null || content.trim().isEmpty) continue;
      final normalized = content.toLowerCase();
      var from = 0;
      while (from < normalized.length && hits.length < _maxResults) {
        final match = normalized.indexOf(normalizedQuery, from);
        if (match < 0) break;
        final previewStart = (match - 34).clamp(0, content.length).toInt();
        final previewEnd = (match + query.length + 54)
            .clamp(0, content.length)
            .toInt();
        hits.add(
          _NovelSearchHit(
            chapterIndex: chapterIndex,
            chapterTitle: widget.chapters[chapterIndex].title,
            charPosition: match,
            preview: content
                .substring(previewStart, previewEnd)
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim(),
          ),
        );
        from = match + normalizedQuery.length;
      }
      if (_searchScanned % 8 == 0 || hits.length >= _maxResults) {
        setState(() => _results = List<_NovelSearchHit>.of(hits));
      }
      if (hits.length >= _maxResults) break;
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _results = List<_NovelSearchHit>.unmodifiable(hits);
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isNight ? Colors.white : AppTheme.textPrimary;
    final secondary = widget.isNight ? Colors.white70 : AppTheme.textSecondary;
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '全文搜索',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _queryController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _scheduleSearch(),
                decoration: InputDecoration(
                  hintText: '输入关键词',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _queryController.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _queryController.clear();
                            _scheduleSearch();
                          },
                          icon: const Icon(Icons.clear_rounded),
                        ),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_loading)
              LinearProgressIndicator(
                value: widget.chapters.isEmpty
                    ? null
                    : _scanned / widget.chapters.length,
              )
            else if (_searching)
              LinearProgressIndicator(
                value: _availableChapterIndexes.isEmpty
                    ? null
                    : _searchScanned / _availableChapterIndexes.length,
              ),
            if (!_loading && _missingCount > 0)
              Material(
                color: AppTheme.primaryColor.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前仅搜索已缓存 ${_availableChapterIndexes.length}/${widget.chapters.length} 章；全本搜索请先缓存。',
                          style: TextStyle(color: secondary, fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: widget.onCacheAllRequested,
                        child: const Text('缓存全本'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _queryController.text.trim().isEmpty
                  ? Center(
                      child: Text(
                        _loading ? '正在读取本地缓存…' : '输入关键词开始搜索',
                        style: TextStyle(color: secondary),
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        _loading || _searching ? '正在继续搜索…' : '没有找到相关内容',
                        style: TextStyle(color: secondary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final hit = _results[index];
                        return ListTile(
                          title: Text(
                            hit.chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: textColor),
                          ),
                          subtitle: Text(
                            hit.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: secondary),
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => widget.onSelected(hit),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NovelCacheSheet extends StatefulWidget {
  const _NovelCacheSheet({
    required this.novel,
    required this.chapters,
    required this.currentChapterIndex,
    required this.provider,
    required this.isNight,
    required this.initialRange,
    required this.canStart,
  });

  final Novel novel;
  final List<Chapter> chapters;
  final int currentChapterIndex;
  final BookSourceProvider provider;
  final bool isNight;
  final NovelCacheBatchRange initialRange;
  final Future<bool> Function(NovelCacheBatchRange range) canStart;

  @override
  State<_NovelCacheSheet> createState() => _NovelCacheSheetState();
}

class _NovelCacheSheetState extends State<_NovelCacheSheet> {
  late NovelCacheBatchRange _range;
  NovelOfflineStatus? _status;
  NovelCacheBatchProgress? _progress;
  NovelCacheBatchResult? _result;
  bool _loadingStatus = true;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final status = await widget.provider.getOfflineStatus(widget.novel);
    if (!mounted) return;
    setState(() {
      _status = status;
      _loadingStatus = false;
    });
  }

  Future<void> _start() async {
    if (_running || widget.chapters.isEmpty || widget.novel.isLocal) return;
    if (_range == NovelCacheBatchRange.full) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('缓存全本？'),
          content: Text('将缓存 ${widget.chapters.length} 章到持久目录，不受临时缓存清理影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始缓存'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!await widget.canStart(_range) || !mounted) return;

    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _progress = null;
    });
    try {
      final currentIndex = widget.currentChapterIndex.clamp(
        0,
        widget.chapters.length - 1,
      );
      await widget.provider.pinCurrentChapter(
        widget.novel,
        widget.chapters[currentIndex],
      );
      final result = await widget.provider.cacheChapters(
        widget.novel,
        widget.chapters,
        range: _range,
        startIndex: currentIndex,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _result = result);
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '缓存失败，请检查网络后重试。');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _clearDownloads() async {
    if (_running || (_status?.downloadedChapterCount ?? 0) == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除已下载章节？'),
        content: const Text('当前阅读章节仍会作为固定章节保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.provider.clearDownloadedChapters(widget.novel);
    await _refreshStatus();
  }

  String _rangeLabel(NovelCacheBatchRange range) => switch (range) {
    NovelCacheBatchRange.next20 => '后 20 章',
    NovelCacheBatchRange.next50 => '后 50 章',
    NovelCacheBatchRange.full => '全本',
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isNight ? Colors.white : AppTheme.textPrimary;
    final secondary = widget.isNight ? Colors.white70 : AppTheme.textSecondary;
    final progressValue = _progress == null || _progress!.total <= 0
        ? null
        : _progress!.completed / _progress!.total;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '批量缓存',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _running ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (widget.novel.isLocal)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 26),
                child: Text(
                  '本地导入小说已完整保存在设备中，无需再次缓存。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: secondary),
                ),
              )
            else ...[
              if (_loadingStatus)
                const LinearProgressIndicator()
              else
                Text(
                  '已下载 ${_status?.downloadedChapterCount ?? 0}/${widget.chapters.length} 章'
                  ' · ${_formatBytes(_status?.totalBytes ?? 0)}',
                  style: TextStyle(color: secondary),
                ),
              const SizedBox(height: 16),
              SegmentedButton<NovelCacheBatchRange>(
                segments: NovelCacheBatchRange.values
                    .map(
                      (range) => ButtonSegment<NovelCacheBatchRange>(
                        value: range,
                        label: Text(_rangeLabel(range)),
                      ),
                    )
                    .toList(growable: false),
                selected: {_range},
                onSelectionChanged: _running
                    ? null
                    : (selection) => setState(() => _range = selection.first),
              ),
              const SizedBox(height: 18),
              if (_running) ...[
                LinearProgressIndicator(value: progressValue),
                const SizedBox(height: 8),
                Text(
                  _progress == null
                      ? '正在固定当前章节…'
                      : '正在缓存 ${_progress!.completed}/${_progress!.total} · ${_progress!.chapter.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondary, fontSize: 12),
                ),
                const SizedBox(height: 14),
              ],
              if (_result != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _result!.complete
                        ? '缓存完成：${_result!.saved} 章'
                        : '已缓存 ${_result!.saved}/${_result!.requested} 章，失败 ${_result!.failedChapterIds.length} 章',
                    style: TextStyle(
                      color: _result!.complete ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              FilledButton.icon(
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.download_rounded),
                label: Text('缓存${_rangeLabel(_range)}'),
              ),
              if ((_status?.downloadedChapterCount ?? 0) > 0) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _running ? null : _clearDownloads,
                  child: const Text('清除本书已下载章节'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ChapterDirectorySheet extends StatefulWidget {
  const _ChapterDirectorySheet({
    required this.chapters,
    required this.currentChapterIndex,
    required this.bookmarks,
    required this.isNight,
    required this.loadOfflineStatus,
    required this.onSelected,
  });

  final List<Chapter> chapters;
  final int currentChapterIndex;
  final List<NovelBookmark> bookmarks;
  final bool isNight;
  final Future<NovelOfflineStatus> Function()? loadOfflineStatus;
  final ValueChanged<int> onSelected;

  @override
  State<_ChapterDirectorySheet> createState() => _ChapterDirectorySheetState();
}

class _ChapterDirectorySheetState extends State<_ChapterDirectorySheet> {
  final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController;
  late final Map<int, int> _bookmarkCounts;
  Set<String> _cachedChapterIds = const <String>{};
  bool _reverse = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _bookmarkCounts = <int, int>{};
    for (final bookmark in widget.bookmarks) {
      _bookmarkCounts.update(
        bookmark.chapterIndex,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    _scrollController = ScrollController(
      initialScrollOffset: (widget.currentChapterIndex * 58.0 - 180).clamp(
        0.0,
        double.infinity,
      ),
    );
    if (widget.loadOfflineStatus != null) {
      unawaited(_loadStatus());
    }
  }

  Future<void> _loadStatus() async {
    try {
      final status = await widget.loadOfflineStatus!();
      if (mounted) {
        setState(() {
          _cachedChapterIds = status.chapters
              .map((entry) => entry.chapterId)
              .toSet();
        });
      }
    } catch (_) {
      // The directory remains usable when offline metadata cannot be read.
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<int> get _visibleIndexes {
    final normalized = _query.trim().toLowerCase();
    final indexes = <int>[
      for (var index = 0; index < widget.chapters.length; index++)
        if (normalized.isEmpty ||
            widget.chapters[index].title.toLowerCase().contains(normalized))
          index,
    ];
    if (_reverse) return indexes.reversed.toList(growable: false);
    return indexes;
  }

  int _bookmarkCount(int chapterIndex) => _bookmarkCounts[chapterIndex] ?? 0;

  bool _isCached(Chapter chapter) {
    if (widget.loadOfflineStatus == null) return true;
    return _cachedChapterIds.contains(chapter.id);
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isNight ? Colors.white : AppTheme.textPrimary;
    final secondary = widget.isNight ? Colors.white70 : AppTheme.textSecondary;
    final indexes = _visibleIndexes;
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: Column(
          children: [
            const SizedBox(height: 9),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: secondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '目录 · ${widget.chapters.length} 章',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _reverse ? '切换正序' : '切换倒序',
                    onPressed: () => setState(() => _reverse = !_reverse),
                    icon: Icon(
                      _reverse ? Icons.south_rounded : Icons.north_rounded,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: '搜索章节',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: indexes.isEmpty
                  ? Center(
                      child: Text('没有匹配章节', style: TextStyle(color: secondary)),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: indexes.length,
                      itemExtent: 58,
                      itemBuilder: (context, itemIndex) {
                        final index = indexes[itemIndex];
                        final chapter = widget.chapters[index];
                        final current = index == widget.currentChapterIndex;
                        final bookmarkCount = _bookmarkCount(index);
                        final cached = _isCached(chapter);
                        return Material(
                          color: current
                              ? AppTheme.primaryColor.withValues(alpha: 0.08)
                              : Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 36,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: current
                                      ? AppTheme.primaryColor
                                      : secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            title: Text(
                              chapter.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: current
                                    ? AppTheme.primaryColor
                                    : textColor,
                                fontWeight: current
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (bookmarkCount > 0) ...[
                                  const Icon(
                                    Icons.bookmark_rounded,
                                    size: 16,
                                    color: AppTheme.primaryColor,
                                  ),
                                  Text(
                                    '$bookmarkCount',
                                    style: const TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Icon(
                                  cached
                                      ? Icons.download_done_rounded
                                      : Icons.cloud_download_outlined,
                                  size: 17,
                                  color: cached ? Colors.green : secondary,
                                ),
                                if (current) ...[
                                  const SizedBox(width: 8),
                                  const Text(
                                    '当前',
                                    style: TextStyle(
                                      color: AppTheme.primaryColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            onTap: () => widget.onSelected(index),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
