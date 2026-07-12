part of '../profile_screen.dart';

class _LevelBenefitDetailCard extends StatelessWidget {
  const _LevelBenefitDetailCard({
    super.key,
    required this.row,
    required this.currentLevel,
    required this.growth,
  });

  final UserLevelEffect row;
  final int currentLevel;
  final UserGrowth growth;

  @override
  Widget build(BuildContext context) {
    final style = _LevelVisualStyle.forLevel(row.level);
    final unlocked = currentLevel >= row.level;
    final isCurrent = currentLevel == row.level;
    final need = (row.points - growth.points).clamp(0, 1 << 30).toInt();
    final unlockProgress = row.points <= 0
        ? 1.0
        : (growth.points / row.points).clamp(0.0, 1.0).toDouble();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: unlocked
              ? [
                  Color.lerp(style.buttonColor, Colors.white, 0.9)!,
                  Colors.white,
                  Color.lerp(style.glowColor, Colors.white, 0.94)!,
                ]
              : const [Color(0xFFF7F9FC), Colors.white, Color(0xFFF9FAFC)],
          stops: const [0, 0.5, 1],
        ),
        borderRadius: BorderRadius.circular(_profileCardRadius),
        border: Border.all(
          color: unlocked
              ? style.buttonColor.withValues(alpha: 0.3)
              : AppTheme.dividerColor,
        ),
        boxShadow: [
          BoxShadow(
            color: unlocked
                ? style.glowColor.withValues(alpha: 0.12)
                : const Color(0x08000000),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_profileCardRadius),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SakuraDecorPainter(
                    tint: style.buttonColor,
                    specs: _SakuraDecorPainter.cardSpecs,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _BenefitEmblem(
                        row: row,
                        style: style,
                        unlocked: unlocked,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 16,
                                height: 1.1,
                                fontWeight: FontWeight.w900,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              row.effect,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                                height: 1.15,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _BenefitStatePill(
                        unlocked: unlocked,
                        isCurrent: isCurrent,
                        color: style.buttonColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _BenefitStatTile(
                          icon: Icons.local_florist_rounded,
                          label: '门槛成长值',
                          value: _formatThousands(row.points),
                          color: style.buttonColor,
                          unlocked: unlocked,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _BenefitStatTile(
                          icon: Icons.bolt_rounded,
                          label: '每日成长上限',
                          value: '${row.dailyPointCap}',
                          color: style.buttonColor,
                          unlocked: unlocked,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _BenefitStatTile(
                          icon: Icons.schedule_rounded,
                          label: '参考达成',
                          value: row.targetDays <= 0
                              ? '注册即得'
                              : '约 ${row.targetDays} 天',
                          color: style.buttonColor,
                          unlocked: unlocked,
                        ),
                      ),
                    ],
                  ),
                  if (!unlocked) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '距离解锁还差 ${_formatThousands(need)} 成长值',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: style.buttonColor,
                              fontSize: 12,
                              height: 1,
                              fontWeight: FontWeight.w700,
                              fontFamilyFallback: _profileFontFallback,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_formatThousands(growth.points)}/${_formatThousands(row.points)}',
                          style: const TextStyle(
                            color: AppTheme.textHint,
                            fontSize: 11,
                            height: 1,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    _GradientProgressBar(
                      value: unlockProgress,
                      color: style.buttonColor,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 13,
                        color: unlocked ? style.buttonColor : AppTheme.textHint,
                      ),
                      const SizedBox(width: 5),
                      const Text(
                        '专属权益',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          fontFamilyFallback: _profileFontFallback,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: unlocked
                              ? style.buttonColor.withValues(alpha: 0.1)
                              : const Color(0xFFF0F2F5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '共 ${row.permissions.length} 项',
                          style: TextStyle(
                            color: unlocked
                                ? style.buttonColor
                                : AppTheme.textHint,
                            fontSize: 10,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  if (row.permissions.isEmpty)
                    const Text(
                      '该等级权益即将上线，敬请期待',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cellWidth = (constraints.maxWidth - 8) / 2;
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final permission in row.permissions)
                              SizedBox(
                                width: cellWidth,
                                child: _BenefitPermissionTile(
                                  label: permission,
                                  color: style.buttonColor,
                                  unlocked: unlocked,
                                ),
                              ),
                          ],
                        );
                      },
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

class _BenefitEmblem extends StatelessWidget {
  const _BenefitEmblem({
    required this.row,
    required this.style,
    required this.unlocked,
  });

  final UserLevelEffect row;
  final _LevelVisualStyle style;
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: unlocked
              ? [
                  style.buttonColor.withValues(alpha: 0.38),
                  style.buttonColor.withValues(alpha: 0.1),
                ]
              : const [Color(0xFFE9EEF5), Color(0xFFF6F8FB)],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
        ),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: unlocked
                  ? [
                      Color.lerp(style.buttonColor, Colors.white, 0.18)!,
                      Color.lerp(style.glowColor, Colors.black, 0.04)!,
                    ]
                  : const [Color(0xFFF1F4F8), Color(0xFFE1E7EF)],
            ),
            boxShadow: [
              BoxShadow(
                color: unlocked
                    ? style.glowColor.withValues(alpha: 0.3)
                    : const Color(0x0F000000),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                unlocked ? Icons.workspace_premium_rounded : Icons.lock_rounded,
                size: 14,
                color: unlocked ? Colors.white : AppTheme.textHint,
              ),
              const SizedBox(height: 1),
              Text(
                'LV${row.level}',
                style: TextStyle(
                  color: unlocked ? Colors.white : AppTheme.textHint,
                  fontSize: 9,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BenefitStatePill extends StatelessWidget {
  const _BenefitStatePill({
    required this.unlocked,
    required this.isCurrent,
    required this.color,
  });

  final bool unlocked;
  final bool isCurrent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final String label;
    final Color fg;
    Color? bg;
    Gradient? gradient;
    List<BoxShadow>? shadow;
    if (isCurrent) {
      icon = Icons.star_rounded;
      label = '当前等级';
      fg = Colors.white;
      gradient = LinearGradient(
        colors: [Color.lerp(color, Colors.white, 0.18)!, color],
      );
      shadow = [
        BoxShadow(
          color: color.withValues(alpha: 0.35),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];
    } else if (unlocked) {
      icon = Icons.check_circle_rounded;
      label = '已解锁';
      fg = color;
      bg = color.withValues(alpha: 0.12);
    } else {
      icon = Icons.lock_rounded;
      label = '未解锁';
      fg = AppTheme.textHint;
      bg = const Color(0xFFF0F2F5);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        gradient: gradient,
        borderRadius: BorderRadius.circular(999),
        boxShadow: shadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w800,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitStatTile extends StatelessWidget {
  const _BenefitStatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.unlocked,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    final accent = unlocked ? color : AppTheme.textHint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            unlocked
                ? Color.lerp(color, Colors.white, 0.94)!
                : const Color(0xFFF7F9FC),
          ],
        ),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: unlocked
              ? color.withValues(alpha: 0.16)
              : const Color(0xFFE8EDF4),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 12, color: accent),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textHint,
              fontSize: 10.5,
              height: 1.1,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitPermissionTile extends StatelessWidget {
  const _BenefitPermissionTile({
    required this.label,
    required this.color,
    required this.unlocked,
  });

  final String label;
  final Color color;
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    final iconColor = unlocked ? color : AppTheme.textHint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: unlocked
              ? color.withValues(alpha: 0.22)
              : const Color(0xFFE4E9F0),
        ),
        boxShadow: [
          BoxShadow(
            color: unlocked
                ? color.withValues(alpha: 0.08)
                : const Color(0x05000000),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: unlocked
                    ? [
                        color.withValues(alpha: 0.2),
                        color.withValues(alpha: 0.08),
                      ]
                    : const [Color(0xFFF1F4F8), Color(0xFFF7F9FC)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_permissionIcon(label), size: 14, color: iconColor),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: unlocked ? AppTheme.textPrimary : AppTheme.textSecondary,
                fontSize: 11.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: _profileFontFallback,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            unlocked ? Icons.check_rounded : Icons.lock_rounded,
            size: unlocked ? 12 : 11,
            color: unlocked ? color.withValues(alpha: 0.55) : AppTheme.textHint,
          ),
        ],
      ),
    );
  }
}

class _GradientProgressBar extends StatelessWidget {
  const _GradientProgressBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 6,
        color: color.withValues(alpha: 0.1),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0.0, 1.0).toDouble(),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: LinearGradient(
                colors: [Color.lerp(color, Colors.white, 0.35)!, color],
              ),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _permissionIcon(String label) {
  if (label.contains('气泡')) return Icons.chat_rounded;
  if (label.contains('弹幕')) return Icons.subtitles_outlined;
  if (label.contains('入场')) return Icons.celebration_outlined;
  if (label.contains('表情')) return Icons.emoji_emotions_outlined;
  if (label.contains('皮肤') || label.contains('背景')) {
    return Icons.wallpaper_rounded;
  }
  if (label.contains('铭牌')) return Icons.military_tech_rounded;
  if (label.contains('高亮') || label.contains('特效') || label.contains('微光')) {
    return Icons.auto_awesome_rounded;
  }
  if (label.contains('评论')) return Icons.chat_bubble_outline_rounded;
  if (label.contains('聊天室') || label.contains('消息')) {
    return Icons.forum_outlined;
  }
  if (label.contains('照片')) return Icons.photo_library_outlined;
  if (label.contains('商店') || label.contains('兑换')) {
    return Icons.storefront_outlined;
  }
  if (label.contains('头像')) return Icons.account_circle_outlined;
  if (label.contains('关注')) return Icons.person_add_alt_1;
  if (label.contains('资料卡') || label.contains('边框')) {
    return Icons.badge_outlined;
  }
  return Icons.stars_rounded;
}
