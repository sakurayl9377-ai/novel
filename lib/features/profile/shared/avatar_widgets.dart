part of '../profile_screen.dart';

class _FramedAvatar extends StatelessWidget {
  const _FramedAvatar({
    required this.avatarUrl,
    required this.level,
    required this.size,
  });

  final String avatarUrl;
  final int level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarInset = size * _avatarFrameImageInsetRatio;
    final imageSize = math.max(1.0, size - avatarInset * 2);
    final frameAsset = _avatarFrameAsset(5);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFD99B31).withValues(alpha: 0.28),
                    blurRadius: size * 0.2,
                    offset: Offset(0, size * 0.08),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(avatarInset),
              child: ClipOval(
                child: avatarUrl.isEmpty
                    ? Image.asset(
                        defaultInteractionAvatarAsset,
                        width: imageSize,
                        height: imageSize,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      )
                    : Image.network(
                        avatarUrl,
                        width: imageSize,
                        height: imageSize,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (context, error, stackTrace) =>
                            Image.asset(
                              defaultInteractionAvatarAsset,
                              width: imageSize,
                              height: imageSize,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.high,
                            ),
                      ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Image.asset(
                frameAsset,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _RoyalAvatarFramePainter extends CustomPainter {
  const _RoyalAvatarFramePainter({required this.compact});

  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = shortest / 2;
    final ringRadius = radius - shortest * 0.095;
    final stroke = math.max(3.0, shortest * 0.064);
    final ringRect = Rect.fromCircle(center: center, radius: ringRadius);
    final goldShader = const SweepGradient(
      colors: [
        Color(0xFF8F5A12),
        Color(0xFFFFF0B8),
        Color(0xFFD79A2E),
        Color(0xFFFFFBDF),
        Color(0xFFA56A18),
        Color(0xFFFFD979),
        Color(0xFF8F5A12),
      ],
      stops: [0, 0.14, 0.32, 0.5, 0.68, 0.86, 1],
    ).createShader(ringRect);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = goldShader
      ..strokeCap = StrokeCap.round;
    final shadowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.18
      ..color = const Color(0xFF6D3C10).withValues(alpha: 0.18)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, shortest * 0.028);
    canvas.drawCircle(center, ringRadius, shadowPaint);
    canvas.drawCircle(center, ringRadius, ringPaint);

    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, stroke * 0.18)
      ..color = Colors.white.withValues(alpha: 0.76);
    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.3, stroke * 0.22)
      ..color = const Color(0xFF7C4314).withValues(alpha: 0.55);
    canvas
      ..drawCircle(center, ringRadius - stroke * 0.58, innerPaint)
      ..drawCircle(center, ringRadius + stroke * 0.54, outerPaint);

    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, stroke * 0.22)
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFFFF5C4).withValues(alpha: 0.9);
    canvas.drawArc(
      ringRect,
      -math.pi * 0.82,
      math.pi * 0.42,
      false,
      highlightPaint,
    );
    highlightPaint.color = const Color(0xFFFFE28A).withValues(alpha: 0.58);
    canvas.drawArc(
      ringRect,
      math.pi * 0.18,
      math.pi * 0.28,
      false,
      highlightPaint,
    );

    if (!compact) {
      _paintWings(canvas, center, ringRadius, shortest);
      _paintCrown(canvas, center, ringRadius, shortest);
    }
    _paintGem(canvas, center, ringRadius, shortest, top: !compact);
    _paintGem(canvas, center, ringRadius, shortest, top: false);
  }

  void _paintWings(
    Canvas canvas,
    Offset center,
    double ringRadius,
    double size,
  ) {
    final wingPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.6, size * 0.018)
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFFFE5A2).withValues(alpha: 0.92);
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.9, size * 0.008)
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF8D5719).withValues(alpha: 0.52);

    for (final side in const [-1.0, 1.0]) {
      for (var i = 0; i < 4; i++) {
        final shift = i * size * 0.035;
        final path = Path()
          ..moveTo(
            center.dx + side * ringRadius * (0.16 + i * 0.03),
            center.dy - ringRadius * 0.88 + shift,
          )
          ..quadraticBezierTo(
            center.dx + side * ringRadius * (0.52 + i * 0.08),
            center.dy - ringRadius * (1.17 - i * 0.045),
            center.dx + side * ringRadius * (0.93 + i * 0.015),
            center.dy - ringRadius * (0.76 - i * 0.055),
          );
        canvas.drawPath(path, edgePaint);
        canvas.drawPath(path, wingPaint);
      }
    }
  }

  void _paintCrown(
    Canvas canvas,
    Offset center,
    double ringRadius,
    double size,
  ) {
    final crownRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy - ringRadius),
      width: size * 0.34,
      height: size * 0.2,
    );
    final crownPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFF0B8), Color(0xFFD39126), Color(0xFF8B4F13)],
      ).createShader(crownRect);
    final y = center.dy - ringRadius - size * 0.055;
    final crown = Path()
      ..moveTo(center.dx, y - size * 0.07)
      ..lineTo(center.dx + size * 0.055, y)
      ..lineTo(center.dx + size * 0.14, y - size * 0.032)
      ..lineTo(center.dx + size * 0.08, y + size * 0.065)
      ..lineTo(center.dx - size * 0.08, y + size * 0.065)
      ..lineTo(center.dx - size * 0.14, y - size * 0.032)
      ..lineTo(center.dx - size * 0.055, y)
      ..close();
    canvas.drawShadow(crown, Colors.black.withValues(alpha: 0.16), 2, true);
    canvas.drawPath(crown, crownPaint);
  }

  void _paintGem(
    Canvas canvas,
    Offset center,
    double ringRadius,
    double size, {
    required bool top,
  }) {
    final gemRadius = math.max(3.2, size * (top ? 0.035 : 0.043));
    final gemCenter = Offset(
      center.dx,
      top ? center.dy - ringRadius - size * 0.005 : center.dy + ringRadius,
    );
    final bezelPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFFFFE7A6);
    final gemPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFA0A5), Color(0xFFD9283B), Color(0xFF80121C)],
        stops: [0.0, 0.58, 1],
      ).createShader(Rect.fromCircle(center: gemCenter, radius: gemRadius));

    canvas
      ..drawCircle(gemCenter, gemRadius * 1.42, bezelPaint)
      ..drawCircle(
        gemCenter,
        gemRadius * 1.42,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, size * 0.007)
          ..color = const Color(0xFF7D4812).withValues(alpha: 0.72),
      )
      ..drawCircle(gemCenter, gemRadius, gemPaint)
      ..drawCircle(
        gemCenter.translate(-gemRadius * 0.28, -gemRadius * 0.32),
        gemRadius * 0.26,
        Paint()..color = Colors.white.withValues(alpha: 0.72),
      );
  }

  @override
  bool shouldRepaint(covariant _RoyalAvatarFramePainter oldDelegate) {
    return oldDelegate.compact != compact;
  }
}

class _ProfileGenderIcon extends StatelessWidget {
  const _ProfileGenderIcon({required this.gender});

  final String gender;

  @override
  Widget build(BuildContext context) {
    final isMale = gender == 'male';
    return Container(
      width: 15,
      height: 15,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isMale ? const Color(0xFF5A9CFF) : const Color(0xFFFF7AA5),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.2),
      ),
      child: Icon(
        isMale ? Icons.male_rounded : Icons.female_rounded,
        size: 10,
        color: Colors.white,
      ),
    );
  }
}

class _ProfileLevelPill extends StatefulWidget {
  const _ProfileLevelPill({required this.growth});

  final UserGrowth growth;

  @override
  State<_ProfileLevelPill> createState() => _ProfileLevelPillState();
}

class _ProfileLevelPillState extends State<_ProfileLevelPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shineController;

  @override
  void initState() {
    super.initState();
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _shineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final growth = widget.growth;
    final level = growth.level.clamp(1, 7).toInt();
    final style = _LevelVisualStyle.forLevel(level);
    final isLv7 = level >= 7;
    final foregroundColor = isLv7
        ? const Color(0xFF3F2605)
        : style.emblemIconColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 20,
        constraints: const BoxConstraints(maxWidth: 104),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              style.buttonColor.withValues(alpha: isLv7 ? 0.98 : 0.95),
              style.glowColor.withValues(alpha: isLv7 ? 0.86 : 0.72),
              style.buttonColor.withValues(alpha: isLv7 ? 0.88 : 0.78),
            ],
          ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: (isLv7 ? const Color(0xFFFFF0A8) : Colors.white).withValues(
              alpha: 0.76,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: style.glowColor.withValues(alpha: isLv7 ? 0.34 : 0.22),
              blurRadius: isLv7 ? 12 : 9,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: isLv7 ? 0.24 : 0.16),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _shineController,
                builder: (context, child) {
                  return Align(
                    alignment: Alignment(
                      -1.35 + (_shineController.value * 2.7),
                      0,
                    ),
                    child: child,
                  );
                },
                child: Transform.rotate(
                  angle: -0.42,
                  child: Container(
                    width: 14,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0),
                          Colors.white.withValues(alpha: isLv7 ? 0.74 : 0.52),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLv7 ? Icons.diamond_rounded : _levelIcon(level),
                    size: isLv7 ? 12 : 11,
                    color: foregroundColor,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      'LV$level ${growth.levelName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 10.5,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                        letterSpacing: 0,
                        fontFamilyFallback: _profileFontFallback,
                        shadows: [
                          Shadow(
                            color: Colors.white.withValues(alpha: 0.34),
                            offset: const Offset(0, 0.6),
                            blurRadius: 0,
                          ),
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            offset: const Offset(0, -0.35),
                            blurRadius: 0.8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _LevelEmblem extends StatelessWidget {
  // ignore: unused_element_parameter
  const _LevelEmblem({required this.level, this.large = false, this.style});

  final int level;
  final bool large;
  final _LevelVisualStyle? style;

  @override
  Widget build(BuildContext context) {
    final size = large ? 64.0 : 58.0;
    final visual = style ?? _LevelVisualStyle.forLevel(level);
    if (level >= 7) {
      return Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF090807),
          border: Border.all(color: visual.glowColor.withValues(alpha: 0.76)),
          boxShadow: [
            BoxShadow(
              color: visual.glowColor.withValues(alpha: 0.42),
              blurRadius: 18,
            ),
          ],
        ),
        child: ClipOval(
          child: Image.asset(
            'assets/images/profile/lv7_badge_float.png',
            fit: BoxFit.contain,
            alignment: Alignment.center,
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: visual.emblemColors),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: visual.glowColor.withValues(alpha: 0.28),
            blurRadius: 14,
          ),
        ],
      ),
      child: Icon(
        _levelIcon(level),
        color: visual.emblemIconColor,
        size: size * 0.52,
      ),
    );
  }
}

// ignore: unused_element
class _LevelStatusMedallion extends StatelessWidget {
  const _LevelStatusMedallion({required this.style});

  final _LevelVisualStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF172945).withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: style.glowColor.withValues(alpha: 0.48)),
        boxShadow: [
          BoxShadow(
            color: style.glowColor.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: 15, color: style.progressColor),
          const SizedBox(width: 5),
          Text(
            '最高等级',
            style: TextStyle(
              color: style.titleColor,
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    this.valueText,
    this.onTap,
  });

  final String label;
  final int value;
  final String? valueText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        children: [
          Text(
            valueText ?? _compactNumber(value),
            style: const TextStyle(
              fontSize: 18,
              height: 1.05,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.15,
              fontWeight: FontWeight.w400,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
    return Expanded(
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(_profileCardRadius),
                child: content,
              ),
            ),
    );
  }
}

class _ColoredIcon extends StatelessWidget {
  const _ColoredIcon({required this.icon, required this.color, this.size = 38});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.96),
            Color.lerp(color, Colors.black, 0.14)!,
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.24),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 7,
            top: 6,
            child: Container(
              width: size * 0.26,
              height: size * 0.16,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.36),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Center(
            child: Icon(icon, color: Colors.white, size: size * 0.5),
          ),
        ],
      ),
    );
  }
}

class _RewardIcon extends StatelessWidget {
  const _RewardIcon({required this.action, this.large = false});

  final String action;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (action) {
      'daily_signin' => (Icons.event_available_rounded, AppTheme.primaryColor),
      'profile_complete' => (Icons.person_rounded, const Color(0xFF45C46A)),
      'comment_post' => (Icons.chat_bubble_rounded, const Color(0xFFFF8A3D)),
      'danmaku_post' => (Icons.video_chat_rounded, const Color(0xFF8D63F7)),
      'chat_message' => (Icons.forum_rounded, const Color(0xFF5B9BFF)),
      'follow_user' => (Icons.favorite_rounded, const Color(0xFFE95F8D)),
      _ => (Icons.star_rounded, AppTheme.primaryColor),
    };
    return _ColoredIcon(icon: icon, color: color, size: large ? 54 : 38);
  }
}
