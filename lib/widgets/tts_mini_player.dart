import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../providers/tts_provider.dart';
import 'book_cover_widget.dart';

class TtsMiniPlayer extends StatelessWidget {
  const TtsMiniPlayer({super.key, required this.onOpenReader});

  final VoidCallback onOpenReader;

  @override
  Widget build(BuildContext context) {
    return Consumer<TtsProvider>(
      builder: (context, tts, _) {
        final novel = tts.activeNovel;
        if (!tts.hasActiveReadingSession || novel == null) {
          return const SizedBox.shrink();
        }

        final colorScheme = Theme.of(context).colorScheme;
        final playing = tts.isSpeaking && !tts.isPaused;
        final updating = tts.isStarting || tts.isUpdatingSettings;
        return SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            key: const ValueKey('tts-mini-player'),
            color: colorScheme.surfaceContainerHigh,
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: 0.22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: 76,
              child: Column(
                children: [
                  LinearProgressIndicator(
                    key: const ValueKey('tts-mini-progress'),
                    minHeight: 3,
                    value: tts.activeChapterProgress,
                    color: AppTheme.primaryColor,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            key: const ValueKey('tts-mini-open-reader'),
                            onTap: onOpenReader,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 40,
                                    height: 54,
                                    child: BookCoverWidget.fill(novel: novel),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          novel.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          tts.activeChapterTitle.isEmpty
                                              ? '语音朗读'
                                              : tts.activeChapterTitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _MiniPlayerButton(
                          key: const ValueKey('tts-mini-previous'),
                          tooltip: '上一章',
                          icon: Icons.skip_previous_rounded,
                          onPressed: !updating && tts.canSkipToPreviousChapter
                              ? () => unawaited(tts.skipReadingChapter(-1))
                              : null,
                        ),
                        _MiniPlayerButton(
                          key: const ValueKey('tts-mini-play-pause'),
                          tooltip: playing ? '暂停朗读' : '继续朗读',
                          icon: playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          emphasized: true,
                          loading: updating,
                          onPressed: updating
                              ? null
                              : () {
                                  if (playing) {
                                    unawaited(tts.pauseSpeaking());
                                  } else {
                                    unawaited(tts.playReadingSession());
                                  }
                                },
                        ),
                        _MiniPlayerButton(
                          key: const ValueKey('tts-mini-next'),
                          tooltip: '下一章',
                          icon: Icons.skip_next_rounded,
                          onPressed: !updating && tts.canSkipToNextChapter
                              ? () => unawaited(tts.skipReadingChapter(1))
                              : null,
                        ),
                        _MiniPlayerButton(
                          key: const ValueKey('tts-mini-close'),
                          tooltip: '结束朗读',
                          icon: Icons.close_rounded,
                          onPressed: () => unawaited(tts.stopSpeaking()),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayerButton extends StatelessWidget {
  const _MiniPlayerButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.emphasized = false,
    this.loading = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool emphasized;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 38,
      height: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        onPressed: onPressed,
        style: emphasized
            ? IconButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppTheme.primaryColor.withValues(
                  alpha: 0.45,
                ),
                disabledForegroundColor: Colors.white70,
              )
            : null,
        icon: loading
            ? const SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                icon,
                size: emphasized ? 24 : 22,
                color: emphasized && onPressed != null
                    ? null
                    : onPressed == null
                    ? colorScheme.onSurface.withValues(alpha: 0.3)
                    : colorScheme.onSurfaceVariant,
              ),
      ),
    );
  }
}
