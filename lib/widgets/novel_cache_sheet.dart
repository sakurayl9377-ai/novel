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
  bool _loadingStatus = true;
  bool _wasRunning = false;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    final download = widget.provider.downloadStateFor(widget.novel);
    _range = download?.range ?? widget.initialRange;
    _wasRunning = download?.running ?? false;
    widget.provider.addListener(_handleProviderChanged);
    unawaited(_refreshStatus());
  }

  @override
  void didUpdateWidget(covariant NovelCacheSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider == widget.provider &&
        oldWidget.novel == widget.novel) {
      return;
    }
    oldWidget.provider.removeListener(_handleProviderChanged);
    widget.provider.addListener(_handleProviderChanged);
    final download = widget.provider.downloadStateFor(widget.novel);
    _range = download?.range ?? widget.initialRange;
    _wasRunning = download?.running ?? false;
    _status = null;
    _loadingStatus = true;
    _statusError = null;
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    widget.provider.removeListener(_handleProviderChanged);
    super.dispose();
  }

  void _handleProviderChanged() {
    if (!mounted) return;
    final running =
        widget.provider.downloadStateFor(widget.novel)?.running ?? false;
    final finished = _wasRunning && !running;
    _wasRunning = running;
    setState(() {});
    if (finished) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await widget.provider.getOfflineStatus(widget.novel);
      if (!mounted) return;
      setState(() {
        _status = status;
        _loadingStatus = false;
        _statusError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingStatus = false;
        _statusError = '无法读取本地下载状态';
      });
    }
  }

  Future<void> _start({bool retry = false}) async {
    final download = widget.provider.downloadStateFor(widget.novel);
    if (download?.running == true ||
        widget.chapters.isEmpty ||
        widget.novel.isLocal) {
      return;
    }
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

    await widget.provider.startNovelCacheDownload(
      widget.novel,
      widget.chapters,
      range: _range,
      startIndex: widget.currentChapterIndex,
    );
    if (mounted) await _refreshStatus();
  }

  void _requestCancel() {
    widget.provider.cancelNovelCacheDownload(widget.novel);
  }

  Future<void> _clearDownloads() async {
    if (widget.provider.downloadStateFor(widget.novel)?.running == true ||
        (_status?.downloadedChapterCount ?? 0) == 0) {
      return;
    }
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
    setState(() => _statusError = null);
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
    final download = widget.provider.downloadStateFor(widget.novel);
    final running = download?.running ?? false;
    final cancelRequested = download?.cancelRequested ?? false;
    final progress = download?.progress;
    final result = download?.result;
    final downloadError = download?.error != null ? '下载失败，请检查网络后继续下载。' : null;
    final progressValue = progress == null || progress.total <= 0
        ? null
        : progress.completed / progress.total;
    final canContinue =
        result?.cancelled == true ||
        (result?.failedChapterIds.isNotEmpty ?? false) ||
        downloadError != null;
    final selectedRange = running ? download!.range : _range;
    return SafeArea(
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
                  onPressed: () => Navigator.pop(context),
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
                selected: {selectedRange},
                onSelectionChanged: running
                    ? null
                    : (selection) => setState(() => _range = selection.first),
              ),
              const SizedBox(height: 18),
              if (running) ...[
                LinearProgressIndicator(value: progressValue),
                const SizedBox(height: 8),
                Text(
                  cancelRequested
                      ? '正在停止，等待进行中的章节完成…'
                      : progress == null
                      ? '正在准备下载…'
                      : '${progress.skipped ? '已校验' : '正在下载'} '
                            '${progress.completed}/${progress.total} · '
                            '${progress.chapter.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
              ],
              if (result != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    result.cancelled
                        ? '已停止，已保留 ${result.saved}/${result.requested} 章'
                        : result.complete
                        ? '下载完成：${result.saved} 章'
                        : '已下载 ${result.saved}/${result.requested} 章，'
                              '失败 ${result.failedChapterIds.length} 章',
                    style: TextStyle(
                      color: result.complete
                          ? Colors.green
                          : theme.colorScheme.error,
                    ),
                  ),
                ),
              if (downloadError != null || _statusError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    downloadError ?? _statusError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (running)
                OutlinedButton.icon(
                  onPressed: cancelRequested ? null : _requestCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(cancelRequested ? '正在停止' : '停止下载'),
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
              if (!running && (_status?.downloadedChapterCount ?? 0) > 0) ...[
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
    );
  }
}
