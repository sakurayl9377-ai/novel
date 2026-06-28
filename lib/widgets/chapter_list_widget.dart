import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/novel.dart';
import '../models/chapter.dart';

class ChapterListWidget extends StatefulWidget {
  final Novel novel;
  final List<Chapter> chapters;
  final int currentChapter;
  final Function(Chapter) onTap;

  const ChapterListWidget({
    super.key,
    required this.novel,
    required this.chapters,
    required this.currentChapter,
    required this.onTap,
  });

  @override
  State<ChapterListWidget> createState() => _ChapterListWidgetState();
}

class _ChapterListWidgetState extends State<ChapterListWidget> {
  static const double _chapterItemExtent = 52;

  late final ScrollController _scrollController;
  late double _sliderValue;
  bool _isDraggingSlider = false;

  @override
  void initState() {
    super.initState();
    _sliderValue = _safeChapterIndex(widget.currentChapter).toDouble();
    _scrollController = ScrollController(
      initialScrollOffset: _sliderValue * _chapterItemExtent,
    )..addListener(_syncSliderFromScroll);
  }

  @override
  void didUpdateWidget(covariant ChapterListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentChapter != widget.currentChapter ||
        oldWidget.chapters.length != widget.chapters.length) {
      final nextValue = _safeChapterIndex(widget.currentChapter).toDouble();
      setState(() => _sliderValue = nextValue);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToChapter(nextValue);
      });
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_syncSliderFromScroll)
      ..dispose();
    super.dispose();
  }

  int _safeChapterIndex(int index) {
    if (widget.chapters.isEmpty) return 0;
    return index.clamp(0, widget.chapters.length - 1).toInt();
  }

  void _syncSliderFromScroll() {
    if (_isDraggingSlider ||
        !_scrollController.hasClients ||
        widget.chapters.isEmpty) {
      return;
    }

    final nextIndex = (_scrollController.offset / _chapterItemExtent)
        .round()
        .clamp(0, widget.chapters.length - 1)
        .toInt();
    if (nextIndex != _sliderValue.round()) {
      setState(() => _sliderValue = nextIndex.toDouble());
    }
  }

  void _jumpToChapter(double value) {
    if (!_scrollController.hasClients || widget.chapters.isEmpty) return;

    final target = (value.round() * _chapterItemExtent).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book_outlined, size: 48, color: AppTheme.textHint),
            SizedBox(height: 12),
            Text('暂无章节', style: TextStyle(color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildQuickJump(),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemExtent: _chapterItemExtent,
            itemCount: widget.chapters.length,
            itemBuilder: (context, index) {
              return _buildChapterItem(index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildQuickJump() {
    final currentIndex = _safeChapterIndex(widget.currentChapter);
    final sliderIndex = _safeChapterIndex(_sliderValue.round());
    final max = (widget.chapters.length - 1).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.list_alt,
                size: 18,
                color: AppTheme.primaryColor,
              ),
              const SizedBox(width: 6),
              Text(
                '共 ${widget.chapters.length} 章',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '上次读到第 ${currentIndex + 1} 章',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '第 ${sliderIndex + 1} 章',
                style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
              ),
              Expanded(
                child: Slider(
                  value: _sliderValue.clamp(0.0, max),
                  min: 0,
                  max: max == 0 ? 1 : max,
                  divisions: widget.chapters.length <= 500 && max > 0
                      ? max.toInt()
                      : null,
                  label: '第 ${sliderIndex + 1} 章',
                  activeColor: AppTheme.primaryColor,
                  inactiveColor: AppTheme.dividerColor,
                  onChanged: max == 0
                      ? null
                      : (value) {
                          setState(() {
                            _isDraggingSlider = true;
                            _sliderValue = value;
                          });
                          _jumpToChapter(value);
                        },
                  onChangeEnd: (_) => _isDraggingSlider = false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChapterItem(int index) {
    final chapter = widget.chapters[index];
    final isCurrent = index == _safeChapterIndex(widget.currentChapter);
    final isLoaded = chapter.isLoaded;

    return Material(
      color: isCurrent
          ? AppTheme.primaryColor.withValues(alpha: 0.06)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onTap(chapter),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: isCurrent
                      ? AppTheme.primaryColor
                      : isLoaded
                      ? AppTheme.primaryColor.withValues(alpha: 0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isCurrent ? Colors.white : AppTheme.textSecondary,
                      fontWeight: isCurrent
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  chapter.title,
                  style: TextStyle(
                    fontSize: 15,
                    color: isCurrent
                        ? AppTheme.primaryColor
                        : AppTheme.textPrimary,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '正在读',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              if (!isLoaded)
                const Icon(
                  Icons.cloud_download_outlined,
                  size: 16,
                  color: AppTheme.textHint,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
