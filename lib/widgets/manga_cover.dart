import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../services/image_cache_service.dart';
import '../services/manga_image_service.dart';

class MangaCover extends StatefulWidget {
  const MangaCover({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
  final BoxFit fit;

  @override
  State<MangaCover> createState() => _MangaCoverState();
}

class _MangaCoverState extends State<MangaCover> {
  static const int _maxDecodeWidth = 1440;

  late List<String> _candidates;
  int _candidateIndex = 0;
  int _retryGeneration = 0;
  bool _advanceScheduled = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _candidates = mangaImageCandidates(widget.imageUrl);
  }

  @override
  void didUpdateWidget(covariant MangaCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _candidates = mangaImageCandidates(widget.imageUrl);
      _candidateIndex = 0;
      _retryGeneration++;
      _advanceScheduled = false;
      _retrying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl.trim().isEmpty) {
      return const _MangaCoverPlaceholder(empty: true);
    }
    if (_candidates.isEmpty) {
      return _MangaCoverFailure(onRetry: _retryAll);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth =
            constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width / 3;
        final cacheWidth =
            (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, _maxDecodeWidth)
                .toInt();
        final url = _candidates[_candidateIndex];

        return CachedNetworkImage(
          key: ValueKey('manga-cover:$url:$_retryGeneration'),
          imageUrl: url,
          cacheManager: AppImageCacheService.manager,
          fit: widget.fit,
          // Preserve the source aspect ratio. Supplying both dimensions made
          // valid cached JPEG covers fail to render on some Android decoders.
          memCacheWidth: cacheWidth,
          httpHeaders: mangaImageHeaders(imageUrl: url),
          fadeInDuration: const Duration(milliseconds: 120),
          fadeOutDuration: const Duration(milliseconds: 80),
          errorWidget: (context, failedUrl, error) {
            if (_candidateIndex + 1 < _candidates.length) {
              _scheduleNextCandidate(failedUrl);
              return const _MangaCoverPlaceholder();
            }
            return _MangaCoverFailure(retrying: _retrying, onRetry: _retryAll);
          },
          placeholder: (context, url) => const _MangaCoverPlaceholder(),
        );
      },
    );
  }

  void _scheduleNextCandidate(String failedUrl) {
    if (_advanceScheduled ||
        _candidates.isEmpty ||
        _candidates[_candidateIndex] != failedUrl) {
      return;
    }
    _advanceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _advanceScheduled = false;
      if (!mounted ||
          _candidateIndex + 1 >= _candidates.length ||
          _candidates[_candidateIndex] != failedUrl) {
        return;
      }
      setState(() => _candidateIndex++);
    });
  }

  Future<void> _retryAll() async {
    if (_retrying) return;
    if (mounted) setState(() => _retrying = true);

    for (final url in _candidates) {
      final headers = mangaImageHeaders(imageUrl: url);
      try {
        await CachedNetworkImageProvider(
          url,
          cacheManager: AppImageCacheService.manager,
          headers: headers,
        ).evict();
      } catch (_) {
        // A failed in-memory eviction must not disable manual retry.
      }
      try {
        await AppImageCacheService.manager.removeFile(url);
      } catch (_) {
        // Missing or concurrently-evicted entries are safe to ignore.
      }
    }

    if (!mounted) return;
    setState(() {
      _candidates = mangaImageCandidates(widget.imageUrl);
      _candidateIndex = 0;
      _retryGeneration++;
      _retrying = false;
    });
  }
}

class _MangaCoverPlaceholder extends StatelessWidget {
  const _MangaCoverPlaceholder({this.empty = false});

  final bool empty;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.dividerColor,
      child: empty
          ? const Center(child: Icon(Icons.image_outlined))
          : const SizedBox.expand(),
    );
  }
}

class _MangaCoverFailure extends StatelessWidget {
  const _MangaCoverFailure({required this.onRetry, this.retrying = false});

  final Future<void> Function() onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.dividerColor,
      child: Center(
        child: Semantics(
          button: true,
          label: '漫画封面加载失败，点击重试',
          child: IconButton(
            key: const ValueKey('manga-cover-retry'),
            tooltip: '重试封面',
            onPressed: retrying ? null : () => unawaited(onRetry()),
            icon: retrying
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ),
      ),
    );
  }
}
