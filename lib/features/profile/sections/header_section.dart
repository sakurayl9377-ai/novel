part of '../profile_screen.dart';

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.badgeCount = 0,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon, size: 21, color: const Color(0xFF4F5A6A)),
          if (badgeCount > 0)
            Positioned(
              right: -7,
              top: -7,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE11D48),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.user,
    required this.stats,
    required this.isLoggedIn,
    required this.onLogin,
    required this.onEdit,
    required this.onFollowers,
    required this.onFollowing,
  });

  final InteractionUser? user;
  final UserProfileStats stats;
  final bool isLoggedIn;
  final Future<bool> Function() onLogin;
  final VoidCallback onEdit;
  final VoidCallback onFollowers;
  final VoidCallback onFollowing;

  @override
  Widget build(BuildContext context) {
    final nickname = isLoggedIn ? (user?.nickname ?? 'Sakura') : '立即登录';
    final growth = user?.growth ?? const UserGrowth();
    final tagline = isLoggedIn
        ? (user?.signature.isNotEmpty == true
              ? user!.signature
              : user?.bio.isNotEmpty == true
              ? user!.bio
              : '初入书海，愿与君共赏好书')
        : '登录后同步评论、弹幕和等级成长';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isLoggedIn ? onEdit : () => unawaited(onLogin()),
      child: SizedBox(
        height: 116,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LevelAvatar(user: user, size: _profileHeaderAvatarSize),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                height: 1.12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0,
                                color: AppTheme.textPrimary,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ),
                          if (isLoggedIn) ...[
                            const SizedBox(width: 7),
                            if (user?.gender != 'private') ...[
                              _ProfileGenderIcon(
                                gender: user?.gender ?? 'private',
                              ),
                              const SizedBox(width: 6),
                            ],
                            _ProfileLevelPill(growth: growth),
                          ],
                        ],
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              tagline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF667085),
                                fontSize: 13,
                                height: 1.22,
                                fontWeight: FontWeight.w400,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ),
                          if (isLoggedIn) ...[
                            const SizedBox(width: 5),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onEdit,
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.edit_rounded,
                                  size: 13,
                                  color: Color(0xFFB7C0CC),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _ProfileHeaderMiniAction(
                              icon: Icons.groups_2_outlined,
                              label: '${_compactNumber(stats.followers)} 粉丝',
                              onTap: isLoggedIn
                                  ? onFollowers
                                  : () => unawaited(onLogin()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ProfileHeaderMiniAction(
                              icon: Icons.favorite_border_rounded,
                              label: '${_compactNumber(stats.following)} 关注',
                              onTap: isLoggedIn
                                  ? onFollowing
                                  : () => unawaited(onLogin()),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _ProfileHeaderMiniAction extends StatelessWidget {
  const _ProfileHeaderMiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Ink(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.34),
                Colors.white.withValues(alpha: 0.16),
              ],
            ),
            borderRadius: radius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.54)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5C7EA8).withValues(alpha: 0.1),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: _profileAccentBlue),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: _profileFontFallback,
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

class _SakuraPetalField extends StatelessWidget {
  const _SakuraPetalField({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SakuraPetalPainter(animation),
      child: const SizedBox.expand(),
    );
  }
}

class _SakuraPetalPainter extends CustomPainter {
  _SakuraPetalPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;
  final Paint _paint = Paint()..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final progress = animation.value;
    final count = (size.width * size.height / 22000).clamp(18, 40).round();

    for (var i = 0; i < count; i++) {
      final speed = 0.55 + _rand(i, 1) * 0.72;
      final phase = (progress * speed + _rand(i, 2)) % 1.0;
      final sway = math.sin((progress * math.pi * 2) + _rand(i, 3) * 6.28);
      final x =
          (_rand(i, 4) * size.width + sway * (16 + _rand(i, 5) * 28)) %
          size.width;
      final y = phase * (size.height + 72) - 52;
      final petalWidth = 4.5 + _rand(i, 6) * 5.5;
      final petalHeight = petalWidth * (1.55 + _rand(i, 7) * 0.55);
      final opacity = 0.16 + _rand(i, 8) * 0.34;
      final angle =
          progress * math.pi * (0.8 + _rand(i, 9) * 1.6) +
          _rand(i, 10) * math.pi;

      _paint.color = Color.lerp(
        const Color(0xFFFFD5E4),
        const Color(0xFFFFFFFF),
        _rand(i, 11) * 0.48,
      )!.withValues(alpha: opacity);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: petalWidth,
          height: petalHeight,
        ),
        _paint,
      );
      canvas.restore();
    }
  }

  double _rand(int index, int salt) {
    final value = math.sin(index * 37.719 + salt * 19.371) * 43758.5453;
    return value - value.floorToDouble();
  }

  @override
  bool shouldRepaint(covariant _SakuraPetalPainter oldDelegate) {
    return oldDelegate.animation != animation;
  }
}

class _MemberHeroCard extends StatelessWidget {
  const _MemberHeroCard({required this.user});

  final InteractionUser? user;

  @override
  Widget build(BuildContext context) {
    final growth = user?.growth ?? const UserGrowth();
    final cardLevel = growth.level.clamp(1, 7).toInt();
    final cardLevelName = growth.levelName;
    final style = _LevelVisualStyle.forLevel(cardLevel);
    final cardAsset = _memberCardAsset(cardLevel);
    final nextPoints = _displayNextGrowthPoints(growth);
    final progressText =
        '${_formatThousands(growth.points)}/${_formatThousands(nextPoints)}';
    final progressValue = _displayGrowthProgress(growth);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fallbackWidth =
            MediaQuery.sizeOf(context).width - _profileHorizontalPadding * 2;
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : fallbackWidth;
        final isTablet = MediaQuery.sizeOf(context).width >= 720;
        final maxCardWidth = isTablet ? 560.0 : 520.0;
        final cardWidth = availableWidth.clamp(0.0, maxCardWidth).toDouble();
        final cardHeight = (cardWidth / _memberCardCompactAspectRatio)
            .clamp(168.0, 300.0)
            .toDouble();
        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: cardWidth,
            height: cardHeight,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              padding: EdgeInsets.zero,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: style.cardColors,
                ),
                borderRadius: BorderRadius.circular(_profileCardRadius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.4),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: style.glowColor.withValues(alpha: 0.26),
                    blurRadius: 26,
                    offset: const Offset(0, 16),
                  ),
                  BoxShadow(
                    color: const Color(0xFF173457).withValues(alpha: 0.13),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.36),
                    blurRadius: 0,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      cardAsset,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.black.withValues(alpha: 0.46),
                            Colors.black.withValues(alpha: 0.2),
                            Colors.black.withValues(alpha: 0.06),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.26),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.58],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 18,
                    top: 18,
                    right: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'LV$cardLevel $cardLevelName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: style.titleColor,
                                  fontSize: 24,
                                  height: 1.02,
                                  letterSpacing: 0,
                                  fontWeight: FontWeight.w700,
                                  fontFamilyFallback: _profileFontFallback,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _MemberCardChip(style: style),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 18,
                    right: 0,
                    bottom: 18,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: 0.58,
                        child: _MemberCardProgress(
                          label: '成长值 $progressText',
                          value: progressValue,
                          style: style,
                        ),
                      ),
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

class _MemberCardChip extends StatelessWidget {
  const _MemberCardChip({required this.style});

  final _LevelVisualStyle style;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 12, color: style.badgeColor),
            const SizedBox(width: 4),
            Text(
              style.effectLabel,
              style: TextStyle(
                color: style.subtitleColor,
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: _profileFontFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberCardProgress extends StatelessWidget {
  const _MemberCardProgress({
    required this.label,
    required this.value,
    required this.style,
  });

  final String label;
  final double value;
  final _LevelVisualStyle style;

  @override
  Widget build(BuildContext context) {
    final widthFactor = value.clamp(0, 1).toDouble();
    final fillColor = style.level <= 1
        ? const Color(0xFF7FCBFF)
        : style.progressColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: style.subtitleColor.withValues(alpha: 0.96),
            fontSize: 13,
            height: 1.15,
            fontWeight: FontWeight.w600,
            fontFamilyFallback: _profileFontFallback,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.26),
                blurRadius: 8,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final fillWidth = (constraints.maxWidth * widthFactor)
                .clamp(0.0, constraints.maxWidth)
                .toDouble();
            return SizedBox(
              height: 12,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    top: 2,
                    bottom: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.26),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.42),
                          width: 0.8,
                        ),
                      ),
                    ),
                  ),
                  if (fillWidth > 0)
                    Positioned(
                      left: 0,
                      width: fillWidth,
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: fillColor,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
