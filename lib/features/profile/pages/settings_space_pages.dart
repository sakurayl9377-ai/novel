part of '../profile_screen.dart';

class _ProfileSettingsPage extends StatelessWidget {
  const _ProfileSettingsPage({
    required this.profile,
    required this.onReload,
    required this.onEditProfile,
  });

  final UserProfile? profile;
  final Future<void> Function() onReload;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final authUser = auth.user;
    final user = auth.isLoggedIn ? authUser ?? profile?.user : null;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsActionTile(
                  icon: Icons.switch_account_outlined,
                  title: '账号管理',
                  subtitle: user == null
                      ? '登录、切换账号'
                      : '${user.nickname} · ID ${user.id}',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _AccountSettingsPage(
                          profile: profile,
                          onReload: onReload,
                          onEditProfile: onEditProfile,
                        ),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, color: AppTheme.dividerColor),
                _SettingsActionTile(
                  icon: Icons.record_voice_over_outlined,
                  title: '语音朗读',
                  subtitle: 'TTS 引擎、讯飞密钥和发音人',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TtsSettingsScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, color: AppTheme.dividerColor),
                _SettingsActionTile(
                  icon: Icons.tune_outlined,
                  title: '阅读设置',
                  subtitle: '字体、深色模式等阅读偏好',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const SettingsScreen(initialCategory: '阅读设置'),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, color: AppTheme.dividerColor),
                _SettingsActionTile(
                  icon: Icons.system_update_alt_outlined,
                  title: '应用维护',
                  subtitle: '缓存、更新和版本信息',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const SettingsScreen(initialCategory: '应用维护'),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountSettingsPage extends StatelessWidget {
  const _AccountSettingsPage({
    required this.profile,
    required this.onReload,
    required this.onEditProfile,
  });

  final UserProfile? profile;
  final Future<void> Function() onReload;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final authUser = auth.user;
    final user = auth.isLoggedIn ? authUser ?? profile?.user : null;
    return Scaffold(
      appBar: AppBar(title: const Text('账号管理')),
      bottomNavigationBar: auth.isLoggedIn
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await auth.logout();
                    await onReload();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('退出登录'),
                ),
              ),
            )
          : null,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, auth.isLoggedIn ? 96 : 28),
        children: [
          if (user != null) ...[
            _AccountCard(
              user: user,
              selected: true,
              subtitle: 'ID: ${user.id}',
              onTap: onEditProfile,
            ),
            const SizedBox(height: 12),
          ],
          const Text(
            '其他账号',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          _SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final account in auth.accounts.where(
                  (item) => item.user.id != auth.user?.id,
                ))
                  _AccountListTile(
                    account: account,
                    onTap: () async {
                      try {
                        await auth.switchAccount(account);
                        await onReload();
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(content: Text('账号登录已过期，请重新添加')),
                          );
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('添加账号'),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const InteractionAuthScreen(),
                      ),
                    );
                    await onReload();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSpacePage extends StatelessWidget {
  const _ProfileSpacePage({
    required this.profile,
    required this.onReload,
    required this.onEditProfile,
  });

  final UserProfile? profile;
  final Future<void> Function() onReload;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    final user = profile?.user ?? context.watch<InteractionAuthProvider>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('我的空间')),
      body: RefreshIndicator(
        onRefresh: onReload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '我的空间',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                ),
                TextButton(onPressed: onEditProfile, child: const Text('编辑')),
              ],
            ),
            const SizedBox(height: 8),
            _SpacePreviewCard(
              user: user,
              profile: profile,
              onOpen: () {},
              onEdit: onEditProfile,
            ),
            const SizedBox(height: 12),
            if (profile != null)
              _SurfaceCard(
                child: Row(
                  children: [
                    _HeroStat(label: '关注', value: profile!.stats.following),
                    _HeroStat(label: '粉丝', value: profile!.stats.followers),
                    _HeroStat(label: '评论', value: profile!.stats.comments),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  const _SettingsActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryColor),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _RewardListTile extends StatelessWidget {
  const _RewardListTile({
    required this.reward,
    required this.showDivider,
    required this.busy,
    required this.onTap,
  });

  final DailyRewardProgress reward;
  final bool showDivider;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final limit = reward.dailyLimit ?? (reward.once ? 1 : 1);
    final doneText = '${reward.count}/$limit';
    final completed = reward.completed;
    final progress = limit <= 0
        ? 0.0
        : (reward.count / limit).clamp(0, 1).toDouble();
    final rewardText =
        '+${reward.points} 成长值${reward.coins > 0 ? ' +${reward.coins} 樱花币' : ''}';
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: completed || busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  _RewardIcon(action: reward.action),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reward.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          rewardText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF0EA774),
                            fontSize: 12,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                            fontFamilyFallback: _profileFontFallback,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 5,
                                  color: completed
                                      ? const Color(0xFF34C47C)
                                      : AppTheme.primaryColor,
                                  backgroundColor: const Color(0xFFE9EDF3),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              doneText,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                                height: 1,
                                fontWeight: FontWeight.w700,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 84,
                    height: 34,
                    child: FilledButton(
                      onPressed: completed || busy ? null : onTap,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: completed
                            ? const Color(0xFFE6F6EF)
                            : AppTheme.primaryColor,
                        foregroundColor: completed
                            ? const Color(0xFF16945D)
                            : Colors.white,
                        disabledBackgroundColor: completed
                            ? const Color(0xFFE6F6EF)
                            : const Color(0xFFE9EDF3),
                        disabledForegroundColor: completed
                            ? const Color(0xFF16945D)
                            : AppTheme.textHint,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              completed ? '已完成' : _rewardButton(reward),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 72, color: AppTheme.dividerColor),
      ],
    );
  }
}

class _RewardPreviewTile extends StatelessWidget {
  const _RewardPreviewTile({required this.reward, this.onSignIn});

  final DailyRewardProgress reward;
  final Future<UserProfile?> Function()? onSignIn;

  @override
  Widget build(BuildContext context) {
    final completed = reward.completed;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: completed ? const Color(0xFFEAF9F3) : const Color(0xFFF7F9FD),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: completed ? const Color(0xFF9DE4C9) : const Color(0xFFE5EAF1),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RewardIcon(action: reward.action, large: true),
          const SizedBox(height: 8),
          Text(
            reward.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            '+${reward.points}成长值',
            style: const TextStyle(
              color: Color(0xFF0EA774),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 28,
            child: FilledButton(
              onPressed: completed || onSignIn == null
                  ? null
                  : () => unawaited(onSignIn!()),
              child: Text(completed ? '已完成' : _rewardButton(reward)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentRewardCard extends StatelessWidget {
  const _RecentRewardCard({required this.items, this.compact = true});

  final List<RewardEvent> items;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _SurfaceCard(
        child: Text(
          compact ? '完成任务后会在这里显示最近成长记录' : '暂无奖励记录',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }
    final visible = compact ? items.take(3).toList() : items;
    return _SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          if (compact)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 6, 14, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '最近成长记录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          for (final item in visible)
            ListTile(
              dense: true,
              title: Text(item.description),
              subtitle: Text(item.createdAt),
              trailing: Text(
                '+${item.points} / +${item.coins}币',
                style: const TextStyle(
                  color: Color(0xFF0EA774),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
