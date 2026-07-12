part of '../profile_screen.dart';

class _PhotoSlot extends StatelessWidget {
  const _PhotoSlot({required this.imageUrl, required this.onTap});

  final String imageUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: imageUrl.isEmpty
            ? Container(
                height: 74,
                color: const Color(0xFFF4F7FB),
                child: const Icon(Icons.add_rounded, color: AppTheme.textHint),
              )
            : Image.network(
                imageUrl,
                height: 74,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 74,
                  color: const Color(0xFFF4F7FB),
                  child: const Icon(Icons.broken_image_outlined),
                ),
              ),
      ),
    );
  }
}

class _BannerImage extends StatelessWidget {
  const _BannerImage({required this.url, required this.height});

  final String url;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        height: height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFD8E9FF), Color(0xFFFFDDE8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }
    return Image.network(
      url,
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          Container(height: height, color: const Color(0xFFEAF1FA)),
    );
  }
}

class _ShopTab extends StatelessWidget {
  const _ShopTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppTheme.textSecondary,
        fontWeight: FontWeight.w800,
        fontFamilyFallback: _profileFontFallback,
      ),
      selectedColor: AppTheme.primaryColor,
      backgroundColor: Colors.white,
      side: BorderSide(
        color: selected ? AppTheme.primaryColor : AppTheme.dividerColor,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    );
  }
}

Color _shopAccentColor(ShopItem item) {
  return switch (item.itemType) {
    'chat_bubble' => _shopBubbleColors(item.assetValue).last,
    'sticker_pack' => const Color(0xFFFF6B9F),
    'profile_skin' => const Color(0xFF7B61FF),
    'chat_room_theme' => const Color(0xFF4A9DFF),
    'avatar_privilege' || 'avatar_frame' => const Color(0xFF2F80ED),
    'dynamic_avatar' => const Color(0xFF00A6A6),
    'danmaku_style' => const Color(0xFFFF8A3D),
    _ => AppTheme.primaryColor,
  };
}

String _shopTypeLabel(ShopItem item) {
  return switch (item.itemType) {
    'chat_bubble' => '聊天气泡',
    'sticker_pack' => '表情包',
    'profile_skin' => '空间皮肤',
    'chat_room_theme' => '聊天室装修',
    'avatar_privilege' => '头像权益',
    'avatar_frame' => '头像框',
    'dynamic_avatar' => '动态头像',
    'danmaku_style' => '弹幕特效',
    _ => '装扮',
  };
}

String _equipmentSlotForShopItem(ShopItem item) {
  return switch (item.itemType) {
    'avatar_frame' => 'avatar_frame',
    'chat_bubble' => 'chat_bubble',
    'chat_room_theme' => 'chat_room_theme',
    'profile_skin' => 'profile_skin',
    'sticker_pack' => 'sticker_pack',
    _ => '',
  };
}

List<Color> _shopBubbleColors(String value) {
  return switch (value) {
    'night_sakura' => const [Color(0xFF3B2B67), Color(0xFFFF7AAD)],
    'sakura_pink' => const [Color(0xFFFF8AB6), Color(0xFFFFB7D1)],
    'moon_blue' => const [Color(0xFF4F7DFF), Color(0xFF8A6DFF)],
    'mint_leaf' => const [Color(0xFF00BFA5), Color(0xFF7BE7C7)],
    'gold_aurora' => const [Color(0xFFFFB84D), Color(0xFFFF6F91)],
    _ => const [AppTheme.primaryColor, Color(0xFF65A9FF)],
  };
}

List<String> _shopStickerAssets(String pack) {
  return switch (pack) {
    'moon_pack' => const [
      'assets/stickers/chat/moon_hi.svg',
      'assets/stickers/chat/moon_star.svg',
      'assets/stickers/chat/moon_shy.svg',
    ],
    _ => const [
      'assets/stickers/chat/sakura_wave.svg',
      'assets/stickers/chat/sakura_love.svg',
      'assets/stickers/chat/sakura_sleep.svg',
    ],
  };
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.primaryColor,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
    );
  }
}

class _FeatureEntry {
  const _FeatureEntry(this.icon, this.title, this.subtitle, this.onTap);

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

String _compactNumber(int value) {
  if (value >= 10000) {
    final text = (value / 10000).toStringAsFixed(1);
    final cleanText = text.endsWith('.0')
        ? text.substring(0, text.length - 2)
        : text;
    return '${cleanText}w';
  }
  return value.toString();
}

String _formatThousands(int value) {
  final source = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < source.length; i += 1) {
    final remaining = source.length - i;
    buffer.write(source[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}

int _displayNextGrowthPoints(UserGrowth growth) {
  if (growth.nextLevelPoints > growth.currentLevelPoints) {
    return growth.nextLevelPoints;
  }
  if (growth.level >= growth.maxLevel) {
    return _currentMaxGrowthCap;
  }
  return growth.points;
}

double _displayGrowthProgress(UserGrowth growth) {
  final current = growth.currentLevelPoints;
  final next = _displayNextGrowthPoints(growth);
  if (next <= current) return 1;
  return ((growth.points - current) / (next - current)).clamp(0, 1).toDouble();
}

String _growthStatusText(UserGrowth growth) {
  final next = _displayNextGrowthPoints(growth);
  final remaining = (next - growth.points).clamp(0, 1 << 30);
  if (growth.level >= growth.maxLevel) {
    return remaining <= 0
        ? '已达到当前成长上限'
        : '距离成长上限还差 ${_formatThousands(remaining)} 成长值';
  }
  return '再获得 ${_formatThousands(remaining)} 成长值可升级';
}

String _commentContextText(InteractionComment comment) {
  final target = comment.targetTitle.isNotEmpty
      ? comment.targetTitle
      : _interactionTargetFallback(comment.targetType, comment.targetId);
  final detail = comment.chapterTitle.isNotEmpty
      ? comment.chapterTitle
      : comment.episodeTitle.isNotEmpty
      ? comment.episodeTitle
      : comment.chapterId.isNotEmpty
      ? comment.chapterId
      : comment.episodeId.isNotEmpty
      ? comment.episodeId
      : '';
  return [target, if (detail.isNotEmpty) detail].join(' · ');
}

String _danmakuContextText(InteractionDanmaku danmaku) {
  final target = danmaku.animeTitle.isNotEmpty
      ? danmaku.animeTitle
      : _interactionTargetFallback('anime', danmaku.animeId);
  final episode = danmaku.episodeTitle.isNotEmpty
      ? danmaku.episodeTitle
      : danmaku.episodeId;
  return [target, if (episode.isNotEmpty) episode].join(' · ');
}

String _interactionTargetFallback(String type, String id) {
  final label = switch (type) {
    'novel' => '小说',
    'manga' => '漫画',
    'anime' => '动漫',
    'chapter' => '章节',
    'episode' => '剧集',
    _ => '作品',
  };
  return id.isEmpty ? label : '$label $id';
}

String _interactionRelativeTime(String raw) {
  if (raw.trim().isEmpty) return '';
  final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (parsed == null) return raw;
  final now = DateTime.now();
  final diff = now.difference(parsed.toLocal());
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${parsed.year}.${_twoDigits(parsed.month)}.${_twoDigits(parsed.day)}';
}

String _formatDanmakuTime(int ms) {
  if (ms < 0) return '';
  final totalSeconds = ms ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
  }
  return '$minutes:${_twoDigits(seconds)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

List<int> _dailyRewardPoints(int level) {
  if (level >= 7) return const [20, 20, 30, 30, 40, 40, 60];
  if (level >= 4) return const [10, 10, 15, 15, 20, 20, 30];
  return const [5, 5, 10, 10, 15, 15, 20];
}

int _displayStreakDays(UserGrowth growth) {
  return growth.signInStreakDays;
}

int _signInActiveDay(int streakDays, bool signedToday) {
  final todayStep = signedToday ? streakDays : streakDays + 1;
  return todayStep.clamp(1, 7).toInt();
}

int _signInCompletedDays(int streakDays, bool signedToday) {
  final completedDays = signedToday && streakDays <= 0 ? 1 : streakDays;
  return completedDays.clamp(0, 7).toInt();
}

List<DailyRewardProgress> _fallbackDailyRewards() {
  return const [
    DailyRewardProgress(
      action: 'daily_signin',
      description: '每日签到',
      points: 20,
      coins: 3,
      dailyLimit: 1,
    ),
    DailyRewardProgress(
      action: 'profile_complete',
      description: '完善个人资料',
      points: 40,
      coins: 5,
      once: true,
    ),
    DailyRewardProgress(
      action: 'comment_post',
      description: '发布评论',
      points: 8,
      coins: 1,
      dailyLimit: 5,
    ),
    DailyRewardProgress(
      action: 'danmaku_post',
      description: '发送弹幕',
      points: 3,
      coins: 0,
      dailyLimit: 20,
    ),
    DailyRewardProgress(
      action: 'chat_message',
      description: '参与聊天室',
      points: 2,
      coins: 0,
      dailyLimit: 20,
    ),
    DailyRewardProgress(
      action: 'follow_user',
      description: '关注用户',
      points: 2,
      coins: 0,
      dailyLimit: 10,
    ),
  ];
}

List<UserLevelEffect> _levelPlanFor(int currentLevel) {
  final level = currentLevel.clamp(1, 7);
  return [
    UserLevelEffect(
      level: 1,
      name: '初樱',
      effect: '基础头像框',
      dailyPointCap: 60,
      targetDays: 0,
      points: 0,
      unlocked: level >= 1,
      permissions: const ['评论', '普通弹幕', '聊天室文字消息', '照片墙基础位'],
    ),
    UserLevelEffect(
      level: 2,
      name: '晴樱',
      effect: '空间资料卡微光',
      dailyPointCap: 70,
      targetDays: 7,
      points: 420,
      unlocked: level >= 2,
      permissions: const ['空间皮肤预览', '樱花币商店基础兑换', '照片墙 3 张'],
    ),
    UserLevelEffect(
      level: 3,
      name: '绯樱',
      effect: '评论昵称高亮',
      dailyPointCap: 85,
      targetDays: 30,
      points: 2030,
      unlocked: level >= 3,
      permissions: const ['关注展示增强', '评论高亮标识', '聊天室图片 URL 消息'],
    ),
    UserLevelEffect(
      level: 4,
      name: '夜樱',
      effect: '聊天室入场提示',
      dailyPointCap: 100,
      targetDays: 90,
      points: 7130,
      unlocked: level >= 4,
      permissions: const ['聊天室入场特效', '表情包快捷发送', '照片墙 6 张'],
    ),
    UserLevelEffect(
      level: 5,
      name: '星樱',
      effect: '动态头像和高级弹幕',
      dailyPointCap: 120,
      targetDays: 240,
      points: 22130,
      unlocked: level >= 5,
      permissions: const ['动态头像展示位', '高级弹幕样式', '稀有商店物品兑换'],
    ),
    UserLevelEffect(
      level: 6,
      name: '月樱',
      effect: '个人空间背景特效',
      dailyPointCap: 140,
      targetDays: 365,
      points: 37130,
      unlocked: level >= 6,
      permissions: const ['空间背景特效', '专属资料卡边框', '照片墙 9 张'],
    ),
    UserLevelEffect(
      level: 7,
      name: '曜樱',
      effect: '顶级头像框和专属聊天气泡',
      dailyPointCap: 160,
      targetDays: 540,
      points: 61630,
      unlocked: level >= 7,
      permissions: const ['顶级头像框', '专属聊天气泡', '全商店兑换资格', '等级满级铭牌'],
    ),
  ];
}

class _LevelVisualStyle {
  const _LevelVisualStyle({
    required this.level,
    required this.cardColors,
    required this.emblemColors,
    required this.titleColor,
    required this.subtitleColor,
    required this.progressColor,
    required this.glowColor,
    required this.borderColor,
    required this.badgeColor,
    required this.buttonColor,
    required this.emblemIconColor,
    required this.effectLabel,
  });

  final int level;
  final List<Color> cardColors;
  final List<Color> emblemColors;
  final Color titleColor;
  final Color subtitleColor;
  final Color progressColor;
  final Color glowColor;
  final Color borderColor;
  final Color badgeColor;
  final Color buttonColor;
  final Color emblemIconColor;
  final String effectLabel;

  factory _LevelVisualStyle.forLevel(int level) {
    if (level >= 7) {
      return const _LevelVisualStyle(
        level: 7,
        cardColors: [Color(0xFF1B1510), Color(0xFF5B3B12), Color(0xFF101014)],
        emblemColors: [Color(0xFFFFF0A8), Color(0xFFE6A437)],
        titleColor: Color(0xFFFFE28A),
        subtitleColor: Color(0xFFF3DFB5),
        progressColor: Color(0xFFE6A437),
        glowColor: Color(0xFFFFC94A),
        borderColor: Color(0x77E6A437),
        badgeColor: Color(0xFFFFE078),
        buttonColor: Color(0xFFD9A12F),
        emblemIconColor: Color(0xFF1B1205),
        effectLabel: '曜樱金辉',
      );
    }
    if (level >= 6) {
      return const _LevelVisualStyle(
        level: 6,
        cardColors: [Color(0xFF2B2942), Color(0xFF6E6785), Color(0xFF2B2634)],
        emblemColors: [Color(0xFFFFF3C6), Color(0xFFD8B96A)],
        titleColor: Color(0xFFFFF7D6),
        subtitleColor: Color(0xFFEEE5C4),
        progressColor: Color(0xFFD8B96A),
        glowColor: Color(0xFFD8B96A),
        borderColor: Color(0x66D8B96A),
        badgeColor: Color(0xFFF4D98A),
        buttonColor: Color(0xFFBFA45B),
        emblemIconColor: Color(0xFF2B2410),
        effectLabel: '月樱银辉',
      );
    }
    if (level >= 5) {
      return const _LevelVisualStyle(
        level: 5,
        cardColors: [Color(0xFF091F48), Color(0xFF1854A0), Color(0xFF2E1F64)],
        emblemColors: [Color(0xFFDCEEFF), Color(0xFF4DA3FF)],
        titleColor: Colors.white,
        subtitleColor: Color(0xFFD8EBFF),
        progressColor: Color(0xFF65B8FF),
        glowColor: Color(0xFF4DA3FF),
        borderColor: Color(0x664DA3FF),
        badgeColor: Color(0xFFB9E1FF),
        buttonColor: Color(0xFF3B8FEF),
        emblemIconColor: Colors.white,
        effectLabel: '星樱流星',
      );
    }
    if (level >= 4) {
      return const _LevelVisualStyle(
        level: 4,
        cardColors: [Color(0xFF171B4E), Color(0xFF45338A), Color(0xFF24194C)],
        emblemColors: [Color(0xFFE8DEFF), Color(0xFF7C5CFF)],
        titleColor: Colors.white,
        subtitleColor: Color(0xFFE6DDFF),
        progressColor: Color(0xFF9B82FF),
        glowColor: Color(0xFF7C5CFF),
        borderColor: Color(0x667C5CFF),
        badgeColor: Color(0xFFD9CCFF),
        buttonColor: Color(0xFF7357F2),
        emblemIconColor: Colors.white,
        effectLabel: '夜樱幽辉',
      );
    }
    if (level >= 3) {
      return const _LevelVisualStyle(
        level: 3,
        cardColors: [Color(0xFF4A193A), Color(0xFFB94772), Color(0xFF2C274B)],
        emblemColors: [Color(0xFFFFE1ED), Color(0xFFFF6F9D)],
        titleColor: Colors.white,
        subtitleColor: Color(0xFFFFD8E8),
        progressColor: Color(0xFFFF7EAA),
        glowColor: Color(0xFFFF6F9D),
        borderColor: Color(0x66FF6F9D),
        badgeColor: Color(0xFFFFC5DA),
        buttonColor: Color(0xFFE95C8E),
        emblemIconColor: Colors.white,
        effectLabel: '绯樱霞光',
      );
    }
    if (level >= 2) {
      return const _LevelVisualStyle(
        level: 2,
        cardColors: [Color(0xFF0E4E66), Color(0xFF32B9D8), Color(0xFF103F55)],
        emblemColors: [Color(0xFFE0FAFF), Color(0xFF36B6D9)],
        titleColor: Colors.white,
        subtitleColor: Color(0xFFDDF8FF),
        progressColor: Color(0xFF63D5EC),
        glowColor: Color(0xFF36B6D9),
        borderColor: Color(0x5536B6D9),
        badgeColor: Color(0xFFBDF4FF),
        buttonColor: Color(0xFF20A8CB),
        emblemIconColor: Color(0xFF073044),
        effectLabel: '晴樱天光',
      );
    }
    return const _LevelVisualStyle(
      level: 1,
      cardColors: [Color(0xFF294763), Color(0xFF6E9ECE), Color(0xFF223B5C)],
      emblemColors: [Color(0xFFEAF4FF), Color(0xFF8FB8E8)],
      titleColor: Colors.white,
      subtitleColor: Color(0xFFDCEBFA),
      progressColor: Color(0xFF8FB8E8),
      glowColor: Color(0xFF8FB8E8),
      borderColor: Color(0x558FB8E8),
      badgeColor: Color(0xFFDDEEFF),
      buttonColor: Color(0xFF6F9ED6),
      emblemIconColor: Color(0xFF1D3C5C),
      effectLabel: '初樱微光',
    );
  }
}

// ignore: unused_element
class _LevelCardPainter extends CustomPainter {
  const _LevelCardPainter(this.style);

  final _LevelVisualStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final glow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.78, -0.18),
        radius: 0.9,
        colors: [
          style.glowColor.withValues(alpha: style.level >= 7 ? 0.28 : 0.18),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, glow);

    final leftPanel = RRect.fromRectAndRadius(
      Rect.fromLTWH(10, 10, size.width * 0.72, size.height - 20),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      leftPanel,
      Paint()..color = Colors.black.withValues(alpha: 0.18),
    );
    canvas.drawRRect(
      leftPanel,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.06)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final topLine = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          style.glowColor.withValues(alpha: 0.5),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 1))
      ..strokeWidth = 1;
    canvas.drawLine(Offset(18, 12), Offset(size.width - 18, 12), topLine);
    canvas.drawLine(
      Offset(18, size.height - 12),
      Offset(size.width - 18, size.height - 12),
      topLine,
    );

    final streak = Paint()
      ..shader = LinearGradient(
        colors: [
          style.glowColor.withValues(alpha: 0),
          style.glowColor.withValues(alpha: 0.34),
          style.glowColor.withValues(alpha: 0),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    final path = Path()
      ..moveTo(size.width * 0.16, size.height * 0.78)
      ..quadraticBezierTo(
        size.width * 0.55,
        size.height * 0.22,
        size.width * 1.04,
        size.height * 0.5,
      );
    canvas.drawPath(path, streak);

    final hairline = Paint()
      ..color = style.glowColor.withValues(alpha: 0.09)
      ..strokeWidth = 1;
    for (var i = -2; i < 6; i++) {
      final startX = size.width * (0.16 * i);
      canvas.drawLine(
        Offset(startX, size.height),
        Offset(startX + size.width * 0.52, 0),
        hairline,
      );
    }

    final particle = Paint()
      ..color = style.progressColor.withValues(alpha: 0.56);
    for (final offset in const [
      Offset(0.82, 0.16),
      Offset(0.76, 0.24),
      Offset(0.66, 0.66),
      Offset(0.9, 0.7),
    ]) {
      canvas.drawCircle(
        Offset(size.width * offset.dx, size.height * offset.dy),
        2.1,
        particle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LevelCardPainter oldDelegate) {
    return oldDelegate.style != style;
  }
}

Color _levelColor(int level) {
  return _LevelVisualStyle.forLevel(level).buttonColor;
}

// ignore: unused_element
String _avatarFrameAsset(int level) {
  final safeLevel = level.clamp(1, 7).toInt();
  return 'assets/images/profile/avatar_frame_lv$safeLevel.png';
}

String _memberCardAsset(int level) {
  final safeLevel = level.clamp(1, 7).toInt();
  return 'assets/images/profile/member_card_lv${safeLevel}_static.png';
}

IconData _levelIcon(int level) {
  return switch (level.clamp(1, 7)) {
    1 => Icons.spa_outlined,
    2 => Icons.local_florist_outlined,
    3 => Icons.auto_awesome_outlined,
    4 => Icons.bubble_chart_outlined,
    5 => Icons.nightlight_round,
    6 => Icons.workspace_premium_outlined,
    _ => Icons.diamond_outlined,
  };
}

IconData _shopIcon(ShopItem item) {
  return switch (item.itemType) {
    'profile_skin' => Icons.wallpaper_outlined,
    'dynamic_avatar' => Icons.motion_photos_on_outlined,
    'danmaku_style' => Icons.subtitles_outlined,
    'chat_bubble' => Icons.chat_bubble_outline,
    _ => Icons.filter_vintage_outlined,
  };
}

String _rewardButton(DailyRewardProgress reward) {
  return switch (reward.action) {
    'daily_signin' => '去签到',
    'profile_complete' => '去完善',
    'comment_post' => '去评论',
    'danmaku_post' => '发弹幕',
    'chat_message' => '去聊天',
    'follow_user' => '去关注',
    _ => '去完成',
  };
}

int _photoLimit(int level) {
  if (level >= 6) return 9;
  if (level >= 4) return 6;
  if (level >= 2) return 3;
  return 1;
}
