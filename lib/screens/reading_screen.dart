import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../models/reading_settings.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/reading_provider.dart';
import '../providers/book_source_provider.dart';
import '../providers/tts_provider.dart';
import '../services/tts_media_control_service.dart';
import '../widgets/reading_settings_panel.dart';
import '../widgets/page_turn_view.dart';

class ReadingScreen extends StatefulWidget {
  static const routeName = '/novel/reading';

  final Novel novel;
  final List<Chapter> chapters;
  final int startChapterIndex;
  final int startCharPosition;
  final double startScrollPosition;

  const ReadingScreen({
    super.key,
    required this.novel,
    this.chapters = const [],
    this.startChapterIndex = 0,
    this.startCharPosition = 0,
    this.startScrollPosition = 0,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen>
    with SingleTickerProviderStateMixin {
  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  int _restoreCharPosition = 0;
  String _content = '';
  String? _contentError;
  bool _isLoadingContent = false;
  bool _showControls = false;
  bool _showTtsPanel = false;
  bool _isLeaving = false;
  int _lastCharPosition = 0;
  double _lastScrollPosition = 0;
  int? _pausedTtsChapterIndex;
  int? _pausedTtsPageIndex;
  int? _pausedTtsCharPosition;
  bool _ttsMediaControlsBound = false;
  TtsMediaControlService? _ttsMediaControlService;
  TtsProvider? _ttsProvider;
  Future<void> _progressSaveChain = Future.value();
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.startChapterIndex
        .clamp(0, widget.chapters.isEmpty ? 0 : widget.chapters.length - 1)
        .toInt();
    _restoreCharPosition = widget.startCharPosition;
    _lastCharPosition = widget.startCharPosition;
    _lastScrollPosition = widget.startScrollPosition;
    _currentPageIndex = 0;
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    _loadCurrentChapter();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ttsMediaControlsBound) return;
    _ttsMediaControlsBound = true;
    final ttsProvider = context.read<TtsProvider>();
    _ttsProvider = ttsProvider;
    final mediaControlService = ttsProvider.mediaControlService;
    _ttsMediaControlService = mediaControlService;
    mediaControlService.bindControls(
      owner: this,
      onPlay: _handleMediaPlay,
      onPause: _handleMediaPause,
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

  Future<void> _loadCurrentChapter() async {
    if (widget.novel.isLocal) {
      if (widget.chapters.isNotEmpty &&
          _currentChapterIndex < widget.chapters.length) {
        final chapter = widget.chapters[_currentChapterIndex];
        final restorePosition = _restoreCharPosition
            .clamp(0, chapter.content.length)
            .toInt();
        final pageIndex = _pageIndexForCharPosition(
          chapter.content,
          restorePosition,
        );
        setState(() {
          _content = chapter.content;
          _restoreCharPosition = restorePosition;
          _lastCharPosition = restorePosition;
          _lastScrollPosition = restorePosition == 0 ? 0 : _lastScrollPosition;
          _currentPageIndex = pageIndex;
        });
      }
      return;
    }

    setState(() {
      _isLoadingContent = true;
      _contentError = null;
    });

    try {
      if (widget.chapters.isNotEmpty &&
          _currentChapterIndex < widget.chapters.length) {
        final chapter = widget.chapters[_currentChapterIndex];
        final sourceProvider = context.read<BookSourceProvider>();
        final content = await sourceProvider.getChapterContent(
          widget.novel,
          chapter,
        );
        final formattedContent = _formatChapterContent(content);

        if (!mounted) return;
        context.read<ReadingProvider>().setCurrentChapter(chapter);

        final restorePosition = _restoreCharPosition
            .clamp(0, formattedContent.length)
            .toInt();
        final pageIndex = _pageIndexForCharPosition(
          formattedContent,
          restorePosition,
        );
        setState(() {
          _content = formattedContent;
          _contentError = formattedContent.isEmpty
              ? '章节内容暂时不可用，请稍后重试或更换书源。'
              : null;
          _restoreCharPosition = restorePosition;
          _lastCharPosition = restorePosition;
          _lastScrollPosition = restorePosition == 0 ? 0 : _lastScrollPosition;
          _currentPageIndex = pageIndex;
        });
      } else if (mounted) {
        setState(() {
          _content = '';
          _contentError = '暂无章节可读。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _content = '';
          _contentError = '章节内容加载失败，请稍后重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingContent = false);
      }
    }
  }

  int _currentProgressPosition([TtsProvider? ttsProvider]) {
    final tts = ttsProvider ?? context.read<TtsProvider>();
    if ((tts.isSpeaking || tts.isPaused || tts.isStarting) &&
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

    final progress = ReadingProgress(
      novelId: widget.novel.id,
      chapterIndex: _currentChapterIndex,
      scrollPosition: _lastScrollPosition,
      charPosition: position,
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
    final readingProvider = context.read<ReadingProvider>();
    final bookshelfProvider = context.read<BookshelfProvider>();
    await readingProvider.saveProgress(widget.novel.id, progress);
    await bookshelfProvider.updateNovel(updatedNovel);
  }

  void _toggleControls() {
    setState(() {
      if (_showControls) {
        // 关闭时同时关闭设置面板和听书面板
        context.read<ReadingProvider>().hideSettings();
        _showTtsPanel = false;
      }
      _showControls = !_showControls;
      if (_showControls) {
        _animController.forward();
      } else {
        _animController.reverse();
      }
    });
  }

  void _showTtsControls() {
    context.read<ReadingProvider>().hideSettings();
    setState(() => _showTtsPanel = true);
  }

  void _resetChapterPosition() {
    _currentPageIndex = 0;
    _restoreCharPosition = 0;
    _lastCharPosition = 0;
    _lastScrollPosition = 0;
    _clearPausedTtsAnchor();
  }

  Future<void> _goToNextChapter() async {
    if (_currentChapterIndex < widget.chapters.length - 1) {
      final ttsProvider = context.read<TtsProvider>();
      await _saveProgressNow(
        charPosition: _currentProgressPosition(ttsProvider),
      );
      unawaited(ttsProvider.stopSpeaking());
      setState(() {
        _currentChapterIndex++;
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
      final ttsProvider = context.read<TtsProvider>();
      await _saveProgressNow(
        charPosition: _currentProgressPosition(ttsProvider),
      );
      unawaited(ttsProvider.stopSpeaking());
      setState(() {
        _currentChapterIndex--;
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

  String get _currentChapterTitle {
    if (widget.chapters.isNotEmpty &&
        _currentChapterIndex < widget.chapters.length) {
      return widget.chapters[_currentChapterIndex].title;
    }
    return '语音朗读';
  }

  Future<void> _showTtsMediaControls({required bool playing}) async {
    await context.read<TtsProvider>().mediaControlService.show(
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

  Future<bool> _handleTtsChapterComplete() async {
    if (!mounted) return false;

    final hasNext = _currentChapterIndex < widget.chapters.length - 1;
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

    await _saveProgressNow(
      charPosition: _content.length,
      scrollPosition: _lastScrollPosition,
    );
    if (!mounted) return false;

    setState(() {
      _currentChapterIndex++;
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
      final readingProvider = context.read<ReadingProvider>();
      final ttsProvider = context.read<TtsProvider>();
      final notificationAllowed = await ttsProvider.mediaControlService
          .ensureNotificationPermission();
      if (!notificationAllowed && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('允许通知权限后，锁屏播放器才能显示')));
      }
      if (readingProvider.settings.pageTurnMode !=
          ReadingSettings.defaultPageTurnMode) {
        await readingProvider.updatePageTurnMode(
          ReadingSettings.defaultPageTurnMode,
        );
      }
      final startOffset =
          startPosition ??
          (_lastCharPosition > 0
              ? _lastCharPosition
              : _pageStartOffsetForPage(
                  _currentPageIndex,
                  readingProvider.settings.fontSize,
                  readingProvider.settings.lineHeight,
                ));
      final speechStartOffset = _cleanSpeechStartOffset(startOffset);
      final textToRead = _content.substring(
        speechStartOffset.clamp(0, _content.length),
      );
      setState(() => _showTtsPanel = true);
      final started = await ttsProvider.startSpeaking(
        textToRead,
        startOffset: speechStartOffset,
      );
      if (started) {
        await _showTtsMediaControls(playing: true);
      }
      if (!started && mounted) {
        final message = ttsProvider.lastErrorMessage.isNotEmpty
            ? ttsProvider.lastErrorMessage
            : '语音朗读启动失败，请检查语音设置';
        setState(() => _showTtsPanel = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
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
    }
  }

  Future<void> _resumeTtsFromCurrentPosition() async {
    final ttsProvider = context.read<TtsProvider>();
    final readingProvider = context.read<ReadingProvider>();
    final currentPageStart = _pageStartOffsetForPage(
      _currentPageIndex,
      readingProvider.settings.fontSize,
      readingProvider.settings.lineHeight,
    );
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
    if (!_isLeaving) {
      unawaited(_saveProgressNow(charPosition: _lastCharPosition));
    }
    _ttsMediaControlService?.unbindControls(this);
    _ttsProvider?.unbindSleepTimer(this);
    _ttsProvider?.unbindCompletion(this);
    _animController.dispose();
    super.dispose();
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  String? _getFontFamily(String name) {
    switch (name) {
      case '苹方':
        return 'PingFang SC';
      case '宋体':
        return 'SimSun';
      case '楷体':
        return 'KaiTi';
      case '黑体':
        return 'SimHei';
      default:
        return null;
    }
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
    await _saveProgressNow(charPosition: _currentProgressPosition(ttsProvider));
    await ttsProvider.stopSpeaking();
    if (!mounted) return;
    _isLeaving = true;
    Navigator.pop(context);
  }

  TextRange _sentenceRangeForOffset(int offset) {
    if (_content.isEmpty || offset < 0) {
      return TextRange.empty;
    }

    final safeOffset = offset.clamp(0, _content.length - 1);
    var start = safeOffset;
    while (start > 0 && !_isSentenceBoundary(_content[start - 1])) {
      start--;
    }
    while (start < _content.length &&
        (_content[start].trim().isEmpty ||
            _isClosingPunctuation(_content[start]))) {
      start++;
    }

    var end = safeOffset;
    while (end < _content.length && !_isSentenceBoundary(_content[end])) {
      end++;
    }
    if (end < _content.length) end++;
    while (end < _content.length && _isClosingPunctuation(_content[end])) {
      end++;
    }
    while (end > start && _content[end - 1].trim().isEmpty) {
      end--;
    }

    return TextRange(start: start, end: end.clamp(start, _content.length));
  }

  bool _isSentenceBoundary(String char) {
    const boundaries = '。！？!?；;\n';
    return boundaries.contains(char);
  }

  bool _isClosingPunctuation(String char) {
    const closings = '”’』」》）)]}';
    return closings.contains(char);
  }

  Widget _buildReaderText({
    required String pageContent,
    required int pageStartOffset,
    required double fontSize,
    required String? fontFamily,
    required Color color,
    required double lineHeight,
    required bool isNight,
    required TtsProvider ttsProvider,
  }) {
    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontFamily: fontFamily,
      color: color,
      height: lineHeight,
    );

    if (!ttsProvider.isSpeaking || ttsProvider.currentStartOffset < 0) {
      return Text(
        pageContent,
        softWrap: true,
        overflow: TextOverflow.clip,
        style: baseStyle,
      );
    }

    final range = _sentenceRangeForOffset(ttsProvider.currentStartOffset);
    final pageEndOffset = pageStartOffset + pageContent.length;
    if (!range.isValid ||
        range.end <= pageStartOffset ||
        range.start >= pageEndOffset) {
      return Text(
        pageContent,
        softWrap: true,
        overflow: TextOverflow.clip,
        style: baseStyle,
      );
    }

    final localStart = (range.start - pageStartOffset).clamp(
      0,
      pageContent.length,
    );
    final localEnd = (range.end - pageStartOffset).clamp(
      localStart,
      pageContent.length,
    );

    final highlightColor = isNight
        ? AppTheme.primaryColor.withValues(alpha: 0.35)
        : AppTheme.primaryColor.withValues(alpha: 0.18);

    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          if (localStart > 0)
            TextSpan(text: pageContent.substring(0, localStart)),
          TextSpan(
            text: pageContent.substring(localStart, localEnd),
            style: baseStyle.copyWith(backgroundColor: highlightColor),
          ),
          if (localEnd < pageContent.length)
            TextSpan(text: pageContent.substring(localEnd)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readingProvider = context.watch<ReadingProvider>();
    final settings = readingProvider.settings;
    final ttsProvider = context.watch<TtsProvider>();
    final bgColor = _parseColor(settings.backgroundColor);
    final isNight = settings.nightMode;

    return PopScope(
      canPop: _isLeaving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: bgColor,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  if (_showControls)
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: _buildTopBar(isNight),
                    ),
                  Expanded(
                    key: const ValueKey('reading-content-area'),
                    child: _isLoadingContent
                        ? Center(
                            child: CircularProgressIndicator(
                              color: isNight ? Colors.white54 : null,
                            ),
                          )
                        : _content.isEmpty
                        ? _buildEmptyContent(isNight)
                        : PageTurnView(
                            key: ValueKey(
                              'reader-${widget.novel.id}-$_currentChapterIndex',
                            ),
                            content: _content,
                            activeTextOffset: ttsProvider.isSpeaking
                                ? ttsProvider.currentStartOffset
                                : null,
                            initialTextOffset: _lastCharPosition,
                            initialScrollPosition: _lastScrollPosition,
                            pageBuilder: (pageContent, pageStartOffset) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                child: _buildReaderText(
                                  pageContent: pageContent,
                                  pageStartOffset: pageStartOffset,
                                  fontSize: settings.fontSize,
                                  fontFamily: _getFontFamily(
                                    settings.fontFamily,
                                  ),
                                  color: isNight
                                      ? AppTheme.nightText
                                      : AppTheme.textPrimary,
                                  lineHeight: settings.lineHeight,
                                  isNight: isNight,
                                  ttsProvider: ttsProvider,
                                ),
                              );
                            },
                            totalPages: 10,
                            currentPage: _currentPageIndex,
                            fontSize: settings.fontSize,
                            lineHeight: settings.lineHeight,
                            isNightMode: isNight,
                            onReadingPositionChanged:
                                (page, charPosition, scrollPosition) {
                                  _currentPageIndex = page;
                                  _lastCharPosition = charPosition;
                                  _lastScrollPosition = scrollPosition;
                                },
                            onReadingPositionSettled:
                                (page, charPosition, scrollPosition) {
                                  _currentPageIndex = page;
                                  unawaited(
                                    _saveProgressNow(
                                      charPosition: charPosition,
                                      scrollPosition: scrollPosition,
                                    ),
                                  );
                                },
                            onNeedNextChapter: _goToNextChapter,
                            onNeedPrevChapter: _goToPrevChapter,
                            onTap: _toggleControls,
                          ),
                  ),
                  if (_showControls)
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: _buildBottomBar(isNight, ttsProvider),
                    ),
                  if (_showTtsPanel) _buildTtsPanel(ttsProvider),
                ],
              ),
            ),
            if (readingProvider.showSettings)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    readingProvider.hideSettings();
                    setState(() {
                      _showControls = false;
                      _showTtsPanel = false;
                    });
                    _animController.reverse();
                  },
                  child: Container(
                    color: Colors.transparent,
                    alignment: Alignment.bottomCenter,
                    child: ReadingSettingsPanel(
                      settings: settings,
                      onFontSizeChanged: (size) =>
                          readingProvider.updateFontSize(size),
                      onFontFamilyChanged: (family) =>
                          readingProvider.updateFontFamily(family),
                      onBackgroundChanged: (color) =>
                          readingProvider.updateBackgroundColor(color),
                      onPageTurnModeChanged: (mode) =>
                          readingProvider.updatePageTurnMode(mode),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
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

  Widget _buildTopBar(bool isNight) {
    final chapterTitle =
        widget.chapters.isNotEmpty &&
            _currentChapterIndex < widget.chapters.length
        ? widget.chapters[_currentChapterIndex].title
        : '加载中...';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      height: 48,
      decoration: BoxDecoration(
        color: (isNight ? AppTheme.nightCard : Colors.white).withValues(
          alpha: 0.97,
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 24),
            onPressed: _handleBack,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: isNight ? AppTheme.nightText : AppTheme.textPrimary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              chapterTitle,
              style: TextStyle(
                fontSize: 15,
                color: isNight ? AppTheme.nightText : AppTheme.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Consumer<ReadingProvider>(
            builder: (ctx, rp, _) => IconButton(
              icon: Icon(
                rp.settings.nightMode ? Icons.light_mode : Icons.dark_mode,
                size: 22,
              ),
              onPressed: () => rp.toggleNightMode(),
              color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(bool isNight, TtsProvider ttsProvider) {
    final hasNext = _currentChapterIndex < widget.chapters.length - 1;
    final hasPrev = _currentChapterIndex > 0;
    final ttsActive =
        ttsProvider.isSpeaking ||
        ttsProvider.isPaused ||
        ttsProvider.isStarting;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: (isNight ? AppTheme.nightCard : Colors.white).withValues(
          alpha: 0.97,
        ),
        border: Border(
          top: BorderSide(color: AppTheme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ctrlBtn(
              Icons.skip_previous,
              '上一章',
              hasPrev,
              isNight,
              _goToPrevChapter,
            ),
            _ctrlBtn(
              Icons.chrome_reader_mode_outlined,
              '目录',
              true,
              isNight,
              _showChapterList,
            ),
            Consumer<ReadingProvider>(
              builder: (ctx, rp, _) => _ctrlBtn(
                Icons.text_fields,
                '设置',
                true,
                isNight,
                () => rp.toggleSettings(),
              ),
            ),
            _ctrlBtn(
              ttsActive
                  ? Icons.record_voice_over_outlined
                  : Icons.volume_up_outlined,
              ttsProvider.isStarting ? '启动中' : '朗读',
              true,
              isNight,
              ttsActive ? _showTtsControls : () => unawaited(_startTts()),
            ),
            _ctrlBtn(
              Icons.skip_next,
              '下一章',
              hasNext,
              isNight,
              _goToNextChapter,
            ),
          ],
        ),
      ),
    );
  }

  Widget _ctrlBtn(
    IconData icon,
    String label,
    bool enabled,
    bool isNight,
    VoidCallback? onTap,
  ) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isNight ? AppTheme.nightText : AppTheme.textPrimary,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTtsPanel(TtsProvider ttsProvider) {
    final isNight = context.read<ReadingProvider>().settings.nightMode;
    final timerText = ttsProvider.hasSleepTimer
        ? _formatSleepTimerRemaining(ttsProvider.sleepTimerRemaining)
        : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: isNight ? AppTheme.nightCard : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: SafeArea(
        top: false,
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
                        '朗读设置',
                        style: TextStyle(
                          color: isNight ? Colors.white : AppTheme.textPrimary,
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
                GestureDetector(
                  onTap: () => setState(() => _showTtsPanel = false),
                  child: const Icon(
                    Icons.close,
                    color: AppTheme.textHint,
                    size: 20,
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
                  label: '停止',
                  isNight: isNight,
                  onPressed: _stopTts,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildSleepTimerControl(ttsProvider, isNight),
          ],
        ),
      ),
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
    showModalBottomSheet(
      context: context,
      backgroundColor: isNight ? AppTheme.nightCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textHint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Text(
                        '章节列表',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '共 ${widget.chapters.length} 章',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: widget.chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = widget.chapters[index];
                      final isCurrent = index == _currentChapterIndex;
                      return ListTile(
                        selected: isCurrent,
                        selectedTileColor: AppTheme.primaryColor.withValues(
                          alpha: 0.06,
                        ),
                        title: Text(
                          chapter.title,
                          style: TextStyle(
                            fontSize: 14,
                            color: isCurrent
                                ? AppTheme.primaryColor
                                : AppTheme.textPrimary,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: isCurrent
                            ? const Text(
                                '当前',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.primaryColor,
                                ),
                              )
                            : null,
                        onTap: () async {
                          Navigator.pop(context);
                          final ttsProvider = context.read<TtsProvider>();
                          await _saveProgressNow(
                            charPosition: _currentProgressPosition(ttsProvider),
                          );
                          unawaited(ttsProvider.stopSpeaking());
                          if (!mounted) return;
                          setState(() {
                            _currentChapterIndex = index;
                            _resetChapterPosition();
                          });
                          await _loadCurrentChapter();
                          if (mounted && _content.isNotEmpty) {
                            await _saveProgressNow(
                              charPosition: 0,
                              scrollPosition: 0,
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SleepTimerOption {
  const _SleepTimerOption({required this.label, required this.duration});

  final String label;
  final Duration duration;
}
