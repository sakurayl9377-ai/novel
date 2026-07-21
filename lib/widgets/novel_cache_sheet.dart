import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chapter.dart';
import '../models/novel.dart';
import '../providers/book_source_provider.dart';
import '../services/novel_offline_cache_service.dart';

typedef NovelCacheStartGuard =
    Future<bool> Function(NovelCacheBatchRange range);

class NovelCacheSheet extends StatefulWidget {
  const NovelCacheSheet({
    super.key,
    required this.novel,
    required this.chapters,
    required this.currentChapterIndex,
    required this.provider,
    this.initialRange = NovelCacheBatchRange.full,
    this.canStart,
  });

  final Novel novel;
  final List<Chapter> chapters;
  final int currentChapterIndex;
  final BookSourceProvider provider;
  final NovelCacheBatchRange initialRange;
  final NovelCacheStartGuard? canStart;

  @override
  State<NovelCacheSheet> createState() => _NovelCacheSheetState();
}

class _NovelCacheSheetState extends State<NovelCacheSheet> {
  late NovelCacheBatchRange _range;
  NovelOfflineStatus? _status;
  NovelCacheBatchProgress? _progress;
  NovelCacheBatchResult? _result;
  bool _loadingStatus = true;
  bool _running = false;
  bool _cancelRequested = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await widget.provider.getOfflineStatus(widget.novel);
      if (!mounted) return;
      setState(() {
        _status = status;
        _loadingStatus = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingStatus = false;
        _error = '无法读取本地下载状态';
      });
    }
  }

  Future<void> _start({bool retry = false}) async {
    if (_running || widget.chapters.isEmpty || widget.novel.isLocal) return;
    if (!retry && _range == NovelCacheBatchRange.full) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('下载整书？'),
          content: Text('将下载 ${widget.chapters.length} 章到本机。已完好的章节会自动跳过。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始下载'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final canStart = widget.canStart;
    if (canStart != null && !await canStart(_range)) return;
    if (!mounted) return;

    setState(() {
      _running = true;
      _cancelRequested = false;
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
        shouldCancel: () => _cancelRequested,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _result = result);
      await _refreshStatus();
    } catch (_) {
      if (mounted) setState(() => _error = '下载失败，请检查网络后继续下载。');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _cancelRequested = false;
        });
      }
    }
  }

  void _requestCancel() {
    if (!_running || _cancelRequested) return;
    setState(() => _cancelRequested = true);
  }

  Future<void> _clearDownloads() async {
    if (_running || (_status?.downloadedChapterCount ?? 0) == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本书下载？'),
        content: const Text('已下载章节会被删除，当前阅读章节仍会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.provider.clearDownloadedChapters(widget.novel);
    if (!mounted) return;
    setState(() {
      _result = null;
      _progress = null;
      _error = null;
    });
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
    final theme = Theme.of(context);
    final progressValue = _progress == null || _progress!.total <= 0
        ? null
        : _progress!.completed / _progress!.total;
    final canContinue =
        _result?.cancelled == true ||
        (_result?.failedChapterIds.isNotEmpty ?? false) ||
        _error != null;
    return PopScope(
      canPop: !_running,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '整书下载',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _running ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (widget.novel.isLocal)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Text('本地导入小说已经完整保存在设备中。', textAlign: TextAlign.center),
                )
              else ...[
                if (_loadingStatus)
                  const LinearProgressIndicator()
                else
                  Text(
                    '已下载 ${_status?.downloadedChapterCount ?? 0}/${widget.chapters.length} 章'
                    ' · ${_formatBytes(_status?.totalBytes ?? 0)}',
                    style: theme.textTheme.bodySmall,
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
                    _cancelRequested
                        ? '正在停止，当前章节完成后结束…'
                        : _progress == null
                        ? '正在准备下载…'
                        : '${_progress!.skipped ? '已校验' : '正在下载'} '
                              '${_progress!.completed}/${_progress!.total} · '
                              '${_progress!.chapter.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                ],
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _result!.cancelled
                          ? '已停止，已保留 ${_result!.saved}/${_result!.requested} 章'
                          : _result!.complete
                          ? '下载完成：${_result!.saved} 章'
                          : '已下载 ${_result!.saved}/${_result!.requested} 章，'
                                '失败 ${_result!.failedChapterIds.length} 章',
                      style: TextStyle(
                        color: _result!.complete
                            ? Colors.green
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (_running)
                  OutlinedButton.icon(
                    onPressed: _cancelRequested ? null : _requestCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(_cancelRequested ? '正在停止' : '停止下载'),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => _start(retry: canContinue),
                    icon: Icon(
                      canContinue
                          ? Icons.refresh_rounded
                          : Icons.download_rounded,
                    ),
                    label: Text(
                      canContinue ? '继续下载' : '下载${_rangeLabel(_range)}',
                    ),
                  ),
                if (!_running &&
                    (_status?.downloadedChapterCount ?? 0) > 0) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _clearDownloads,
                    child: const Text('删除本书下载'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
