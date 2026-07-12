part of '../profile_screen.dart';

class _DailyRewardsPage extends StatefulWidget {
  const _DailyRewardsPage({
    required this.initialProfile,
    required this.onSignIn,
    required this.onRefresh,
    required this.onEditProfile,
    required this.onOpenCommentTask,
    required this.onOpenDanmakuTask,
    required this.onOpenChatTask,
  });

  final UserProfile initialProfile;
  final Future<UserProfile?> Function() onSignIn;
  final Future<UserProfile?> Function() onRefresh;
  final Future<UserProfile?> Function() onEditProfile;
  final Future<void> Function() onOpenCommentTask;
  final Future<void> Function() onOpenDanmakuTask;
  final Future<void> Function() onOpenChatTask;

  @override
  State<_DailyRewardsPage> createState() => _DailyRewardsPageState();
}

class _DailyRewardsPageState extends State<_DailyRewardsPage> {
  late UserProfile _profile = widget.initialProfile;
  String? _busyAction;

  @override
  Widget build(BuildContext context) {
    final user = _profile.user;
    final growth = user.growth;
    final style = _LevelVisualStyle.forLevel(growth.level.clamp(1, 7));
    final rewards = _profile.dailyRewards.isEmpty
        ? _fallbackDailyRewards()
        : _profile.dailyRewards;
    return Scaffold(
      backgroundColor: _profileBottomBackground,
      appBar: AppBar(
        toolbarHeight: 50,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '每日奖励',
          style: TextStyle(
            fontSize: 19,
            height: 1,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        backgroundColor: _profileTopBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _profileTopBackground,
              _profileMidBackground,
              _profileBottomBackground,
            ],
            stops: [0, 0.32, 1],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              _profileHorizontalPadding,
              4,
              _profileHorizontalPadding,
              28,
            ),
            children: [
              _SurfaceCard(
                child: Row(
                  children: [
                    _ColoredIcon(
                      icon: Icons.fact_check_outlined,
                      color: style.buttonColor,
                      size: 48,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '今日成长',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                              fontFamilyFallback: _profileFontFallback,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${growth.dailyPointsEarned}/${growth.dailyPointCap}',
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 26,
                              height: 1,
                              fontWeight: FontWeight.w800,
                              fontFamilyFallback: _profileFontFallback,
                            ),
                          ),
                          const SizedBox(height: 9),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: growth.dailyPointCap <= 0
                                  ? 0
                                  : (growth.dailyPointsEarned /
                                            growth.dailyPointCap)
                                        .clamp(0, 1),
                              minHeight: 8,
                              color: style.progressColor,
                              backgroundColor: style.progressColor.withValues(
                                alpha: 0.14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '连续 ${_displayStreakDays(growth)} 天',
                          style: TextStyle(
                            color: style.buttonColor,
                            fontSize: 13,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '+${growth.dailyCoinsEarned} 樱花币',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                            height: 1.1,
                            fontWeight: FontWeight.w600,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: _profileModuleGap),
              const _SectionTitle(title: '每日任务'),
              const SizedBox(height: 8),
              _SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < rewards.length; i++)
                      _RewardListTile(
                        reward: rewards[i],
                        showDivider: i != rewards.length - 1,
                        busy: _busyAction == rewards[i].action,
                        onTap: () => _handleRewardTap(rewards[i]),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: _profileModuleGap),
              const _SectionTitle(title: '奖励记录'),
              const SizedBox(height: 8),
              _RecentRewardCard(items: _profile.recentRewards, compact: false),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    final next = await widget.onRefresh();
    if (!mounted || next == null) return;
    setState(() => _profile = next);
  }

  Future<void> _runRewardAction(
    DailyRewardProgress reward,
    Future<void> Function() action,
  ) async {
    setState(() => _busyAction = reward.action);
    try {
      await action();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _handleRewardTap(DailyRewardProgress reward) async {
    if (reward.completed || _busyAction != null) return;
    switch (reward.action) {
      case 'daily_signin':
        setState(() => _busyAction = reward.action);
        try {
          final next = await widget.onSignIn();
          if (!mounted) return;
          if (next != null) {
            setState(() => _profile = next);
          } else {
            await _refresh();
          }
        } finally {
          if (mounted) setState(() => _busyAction = null);
        }
        return;
      case 'profile_complete':
        await _runRewardAction(reward, () async {
          final next = await widget.onEditProfile();
          if (mounted && next != null) setState(() => _profile = next);
        });
        return;
      case 'comment_post':
        await _runRewardAction(reward, widget.onOpenCommentTask);
        return;
      case 'danmaku_post':
        await _runRewardAction(reward, widget.onOpenDanmakuTask);
        return;
      case 'chat_message':
      case 'follow_user':
        await _runRewardAction(reward, widget.onOpenChatTask);
        return;
      default:
        await _refresh();
    }
  }
}
