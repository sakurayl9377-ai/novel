part of '../profile_screen.dart';

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.user,
    required this.isLoggedIn,
    required this.stats,
    required this.onLogin,
    required this.onEdit,
    required this.onMemberCenter,
    required this.onComments,
    required this.onDanmaku,
  });

  final InteractionUser? user;
  final bool isLoggedIn;
  final UserProfileStats stats;
  final Future<bool> Function() onLogin;
  final VoidCallback onEdit;
  final VoidCallback onMemberCenter;
  final VoidCallback onComments;
  final VoidCallback onDanmaku;

  @override
  Widget build(BuildContext context) {
    final growth = user?.growth ?? const UserGrowth();
    final level = growth.level.clamp(1, 7);
    final style = _LevelVisualStyle.forLevel(level);
    final memberButtonColor = style.buttonColor;

    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(8, 13, 8, 10),
      child: Column(
        children: [
          Row(
            children: [
              _HeroStat(
                label: '成长值',
                value: growth.points,
                valueText: _formatThousands(growth.points),
              ),
              const _ProfileShortDivider(),
              _HeroStat(label: '评论', value: stats.comments, onTap: onComments),
              const _ProfileShortDivider(),
              _HeroStat(label: '弹幕', value: stats.danmaku, onTap: onDanmaku),
              const _ProfileShortDivider(),
              _HeroStat(label: '樱花币', value: growth.sakuraCoins),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: isLoggedIn ? onEdit : () => unawaited(onLogin()),
                    icon: const Icon(Icons.person_outline_rounded, size: 17),
                    label: const Text('编辑资料'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _profileAccentBlue,
                      side: const BorderSide(color: _profileAccentBlue),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(_profileCardRadius),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    onPressed: isLoggedIn
                        ? onMemberCenter
                        : () => unawaited(onLogin()),
                    icon: const Icon(
                      Icons.workspace_premium_outlined,
                      size: 17,
                    ),
                    label: const Text('成长中心'),
                    style: FilledButton.styleFrom(
                      backgroundColor: memberButtonColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(_profileCardRadius),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileShortcutAction extends StatelessWidget {
  const _ProfileShortcutAction({
    required this.entry,
    this.iconSize = 27,
    this.labelSize = 12.5,
  });

  final _ProfileShortcutEntry entry;
  final double iconSize;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    final color = entry.color ?? _profileAccentBlue;
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(_profileCardRadius),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [Icon(entry.icon, size: iconSize, color: color)],
          ),
          const SizedBox(height: 7),
          Text(
            entry.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: labelSize,
              height: 1.1,
              fontWeight: FontWeight.w400,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileShortcutEntry {
  const _ProfileShortcutEntry(this.icon, this.label, this.onTap, {this.color});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
}

class _DailySignInCard extends StatelessWidget {
  const _DailySignInCard({
    required this.user,
    required this.rewards,
    required this.onOpen,
    required this.onSignIn,
  });

  final InteractionUser? user;
  final List<DailyRewardProgress> rewards;
  final VoidCallback onOpen;
  final Future<UserProfile?> Function() onSignIn;

  @override
  Widget build(BuildContext context) {
    final growth = user?.growth ?? const UserGrowth();
    final level = growth.level.clamp(1, 7);
    final style = _LevelVisualStyle.forLevel(level);
    final rewardPoints = _dailyRewardPoints(level);
    DailyRewardProgress? signInReward;
    for (final reward in rewards) {
      if (reward.action == 'daily_signin') {
        signInReward = reward;
        break;
      }
    }
    final signedToday = signInReward?.completed == true;
    final todayPoints = signInReward?.points ?? rewardPoints.first;
    final todayCoins = signInReward?.coins ?? 0;
    final streakDays = _displayStreakDays(growth);
    final activeDay = _signInActiveDay(streakDays, signedToday);
    final completedDays = _signInCompletedDays(streakDays, signedToday);
    final selectedColor = style.buttonColor;

    return _SurfaceCard(
      onTap: onOpen,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('每日签到', style: _profileSectionTitleStyle),
              ),
              Text(
                '连续签到 $streakDays 天',
                style: TextStyle(
                  color: selectedColor,
                  fontSize: 13,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const _ProfileSectionDivider(),
          const SizedBox(height: 12),
          SizedBox(
            height: 82,
            child: Row(
              children: List.generate(7, (index) {
                final day = index + 1;
                final selected = day == activeDay;
                final completed = day <= completedDays;
                final points = selected ? todayPoints : rewardPoints[index];
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: index == 6 ? 0 : 7),
                    child: _SignInDayTile(
                      day: day,
                      points: points,
                      selected: selected,
                      completed: completed,
                      isToday: selected,
                      color: selectedColor,
                      gift: index == 6,
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: signedToday ? onOpen : () => unawaited(onSignIn()),
              style: FilledButton.styleFrom(
                backgroundColor: selectedColor,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_profileCardRadius),
                ),
              ),
              child: Text(
                signedToday
                    ? '已签到 · 查看今日奖励'
                    : '签到领取 $todayPoints 成长值${todayCoins > 0 ? ' + $todayCoins 樱花币' : ''}',
                style: const TextStyle(
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SignInDayTile extends StatelessWidget {
  const _SignInDayTile({
    required this.day,
    required this.points,
    required this.selected,
    required this.completed,
    required this.isToday,
    required this.color,
    this.gift = false,
  });

  final int day;
  final int points;
  final bool selected;
  final bool completed;
  final bool isToday;
  final bool gift;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.1)
            : const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? color.withValues(alpha: 0.45) : Colors.transparent,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            isToday ? '今天' : '$day天',
            style: TextStyle(
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontSize: 12,
              height: 1.1,
              fontWeight: FontWeight.w500,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
          const SizedBox(height: 6),
          _SignInRewardIcon(
            color: color,
            completed: completed,
            gift: gift,
            emphasized: selected,
          ),
          const SizedBox(height: 4),
          Text(
            '+$points',
            style: const TextStyle(
              fontSize: 12,
              height: 1.1,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignInRewardIcon extends StatelessWidget {
  const _SignInRewardIcon({
    required this.color,
    required this.completed,
    required this.gift,
    required this.emphasized,
  });

  final Color color;
  final bool completed;
  final bool gift;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final bgAlpha = completed
        ? 1.0
        : emphasized
        ? 0.18
        : 0.14;
    final iconColor = completed
        ? Colors.white
        : emphasized
        ? color
        : color.withValues(alpha: 0.62);
    final icon = completed
        ? Icons.check_rounded
        : gift
        ? Icons.card_giftcard_rounded
        : Icons.star_rounded;

    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: bgAlpha),
        shape: BoxShape.circle,
        border: Border.all(
          color: completed || emphasized
              ? color.withValues(alpha: 0.72)
              : Colors.transparent,
        ),
      ),
      child: Icon(icon, color: iconColor, size: gift ? 15 : 14),
    );
  }
}

// ignore: unused_element
class _DailyRewardPreview extends StatelessWidget {
  const _DailyRewardPreview({
    required this.user,
    required this.rewards,
    required this.onOpen,
    required this.onSignIn,
  });

  final InteractionUser? user;
  final List<DailyRewardProgress> rewards;
  final VoidCallback onOpen;
  final Future<UserProfile?> Function() onSignIn;

  @override
  Widget build(BuildContext context) {
    final growth = user?.growth ?? const UserGrowth();
    final style = _LevelVisualStyle.forLevel(growth.level.clamp(1, 7));
    final items = rewards.isEmpty ? _fallbackDailyRewards() : rewards;
    final visible = items.take(4).toList();
    return _SurfaceCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ColoredIcon(
                icon: Icons.event_available_outlined,
                color: style.buttonColor,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '每日奖励',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                '${growth.dailyPointsEarned}/${growth.dailyPointCap}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: growth.dailyPointCap <= 0
                  ? 0
                  : (growth.dailyPointsEarned / growth.dailyPointCap).clamp(
                      0,
                      1,
                    ),
              minHeight: 10,
              color: style.progressColor,
              backgroundColor: style.progressColor.withValues(alpha: 0.14),
            ),
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visible.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.28,
            ),
            itemBuilder: (context, index) => _RewardPreviewTile(
              reward: visible[index],
              onSignIn: visible[index].action == 'daily_signin'
                  ? onSignIn
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
