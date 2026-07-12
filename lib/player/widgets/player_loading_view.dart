import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

enum PlayerLoadingStatus {
  initial,
  buffering,
  switchingSource,
  recovering,
  error,
}

class PlayerLoadingView extends StatefulWidget {
  const PlayerLoadingView({
    super.key,
    required this.coverUrl,
    this.status = PlayerLoadingStatus.initial,
    this.visible = true,
    this.message = '',
    this.onRetry,
    this.onChangeSource,
    this.elapsedOverride,
  });

  final String coverUrl;
  final PlayerLoadingStatus status;
  final bool visible;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onChangeSource;
  final Duration? elapsedOverride;

  @override
  State<PlayerLoadingView> createState() => _PlayerLoadingViewState();
}

class _PlayerLoadingViewState extends State<PlayerLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  Timer? _timer;
  DateTime _startedAt = DateTime.now();
  Duration _elapsed = Duration.zero;
  bool? _animationsDisabled;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _restartTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_animationsDisabled == disabled) return;
    _animationsDisabled = disabled;
    if (disabled) {
      _animation.stop();
      _animation.value = 0.35;
    } else if (widget.visible) {
      _animation.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PlayerLoadingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _restartTimer();
    }
    if (oldWidget.visible != widget.visible) {
      if (widget.visible && _animationsDisabled != true) {
        _animation.repeat();
      } else {
        _animation.stop();
      }
    }
    if (oldWidget.elapsedOverride != widget.elapsedOverride) {
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.elapsedOverride != null) {
      _elapsed = widget.elapsedOverride!;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(_startedAt));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.elapsedOverride ?? _elapsed;
    final showSlowNetwork = elapsed >= const Duration(seconds: 8);
    final showActions =
        widget.status == PlayerLoadingStatus.error ||
        elapsed >= const Duration(seconds: 12);
    final title = _titleForStatus(widget.status);
    final detail = widget.message.trim().isNotEmpty
        ? widget.message.trim()
        : showSlowNetwork
        ? '网络较慢，正在继续连接'
        : _detailForStatus(widget.status);

    return IgnorePointer(
      // Before recovery actions appear, taps should still reach the player so
      // users can reveal or operate its controls while a stream is buffering.
      ignoring: !widget.visible || !showActions,
      child: AnimatedOpacity(
        key: const Key('player-loading-opacity'),
        opacity: widget.visible ? 1 : 0,
        duration: _animationsDisabled == true
            ? Duration.zero
            : const Duration(milliseconds: 260),
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _LoadingBackground(coverUrl: widget.coverUrl),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.28),
                      const Color(0xFF160E22).withValues(alpha: 0.66),
                      Colors.black.withValues(alpha: 0.84),
                    ],
                  ),
                ),
              ),
              if (_animationsDisabled == true)
                const CustomPaint(
                  key: Key('player-loading-static-petals'),
                  painter: _SakuraPainter(0.35),
                )
              else
                AnimatedBuilder(
                  key: const Key('player-loading-animated-petals'),
                  animation: _animation,
                  builder: (_, _) =>
                      CustomPaint(painter: _SakuraPainter(_animation.value)),
                ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _BreathingDots(
                          animation: _animation,
                          staticMode: _animationsDisabled == true,
                        ),
                        const SizedBox(height: 17),
                        Text(
                          title,
                          key: const Key('player-loading-title'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          detail,
                          key: const Key('player-loading-detail'),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.74),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                        if (showActions &&
                            (widget.onRetry != null ||
                                widget.onChangeSource != null)) ...[
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              if (widget.onRetry != null)
                                FilledButton.tonalIcon(
                                  key: const Key('player-loading-retry'),
                                  onPressed: widget.onRetry,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试'),
                                ),
                              if (widget.onChangeSource != null)
                                OutlinedButton.icon(
                                  key: const Key(
                                    'player-loading-change-source',
                                  ),
                                  onPressed: widget.onChangeSource,
                                  icon: const Icon(Icons.swap_horiz_rounded),
                                  label: const Text('换线路'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.54,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
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
}

String _titleForStatus(PlayerLoadingStatus status) => switch (status) {
  PlayerLoadingStatus.initial => '正在准备播放',
  PlayerLoadingStatus.buffering => '正在缓冲',
  PlayerLoadingStatus.switchingSource => '正在切换线路',
  PlayerLoadingStatus.recovering => '正在恢复播放',
  PlayerLoadingStatus.error => '暂时无法播放',
};

String _detailForStatus(PlayerLoadingStatus status) => switch (status) {
  PlayerLoadingStatus.initial => '正在连接视频资源',
  PlayerLoadingStatus.buffering => '已为你保留当前播放位置',
  PlayerLoadingStatus.switchingSource => '当前线路不稳定，正在尝试其他线路',
  PlayerLoadingStatus.recovering => '正在从刚才的位置继续',
  PlayerLoadingStatus.error => '可以重试或换一条播放线路',
};

class _LoadingBackground extends StatelessWidget {
  const _LoadingBackground({required this.coverUrl});

  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = const DecoratedBox(
      key: Key('player-loading-fallback'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF39264C), Color(0xFF1B1227), Color(0xFF08070C)],
        ),
      ),
    );
    if (coverUrl.trim().isEmpty) return fallback;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Transform.scale(
        scale: 1.08,
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(
            Color(0xAA111111),
            BlendMode.darken,
          ),
          child: Image.network(
            coverUrl,
            key: const Key('player-loading-cover'),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      ),
    );
  }
}

class _BreathingDots extends StatelessWidget {
  const _BreathingDots({required this.animation, required this.staticMode});

  final Animation<double> animation;
  final bool staticMode;

  @override
  Widget build(BuildContext context) {
    Widget dots(double value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        final phase = (value + index * 0.18) % 1;
        final scale = staticMode
            ? 1.0
            : 0.72 + math.sin(phase * math.pi) * 0.38;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: const Color(
                  0xFFFFB7D5,
                ).withValues(alpha: staticMode ? 0.82 : 0.55 + scale * 0.25),
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(color: Color(0x66FF78B1), blurRadius: 8),
                ],
              ),
            ),
          ),
        );
      }),
    );
    if (staticMode) {
      return KeyedSubtree(
        key: const Key('player-loading-static-dots'),
        child: dots(0.35),
      );
    }
    return AnimatedBuilder(
      key: const Key('player-loading-animated-dots'),
      animation: animation,
      builder: (_, _) => dots(animation.value),
    );
  }
}

class _SakuraPainter extends CustomPainter {
  const _SakuraPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x55FFC0D9);
    for (var index = 0; index < 8; index++) {
      final seed = index * 0.137;
      final x =
          ((seed * 7 + progress * (0.08 + index * 0.006)) % 1) * size.width;
      final y =
          ((seed * 11 + progress * (0.22 + index * 0.01)) % 1) * size.height;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(progress * math.pi * 2 + index);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: 5 + index % 3,
          height: 9 + index % 4,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _SakuraPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
