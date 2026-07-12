part of 'chat_room_screen.dart';

class _UserProfileSheet extends StatefulWidget {
  const _UserProfileSheet({
    required this.profile,
    required this.isSelf,
    required this.onFollowChanged,
    this.onPrivateChat,
  });

  final UserProfile profile;
  final bool isSelf;
  final Future<UserProfile> Function(bool follow) onFollowChanged;
  final VoidCallback? onPrivateChat;

  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<_UserProfileSheet> {
  late UserProfile _profile;
  bool _isWorking = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
  }

  Future<void> _toggleFollow() async {
    setState(() => _isWorking = true);
    try {
      final next = await widget.onFollowChanged(!_profile.followedByMe);
      if (mounted) setState(() => _profile = next);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _profile.user;
    final growth = user.growth;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InteractionAvatar(label: user.nickname, size: 54),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user.signature.isEmpty ? '这个人还没有写签名' : user.signature,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _UserStat(label: 'Lv${growth.level}', value: growth.levelName),
                const SizedBox(width: 8),
                _UserStat(label: '${growth.points}', value: '积分'),
                const SizedBox(width: 8),
                _UserStat(label: '${_profile.stats.followers}', value: '粉丝'),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '当前特效：${growth.levelEffect}',
              style: const TextStyle(
                color: AppTheme.primaryColor,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (!widget.isSelf) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                        onPressed: _isWorking ? null : _toggleFollow,
                        icon: Icon(
                          _profile.followedByMe
                              ? Icons.person_remove_outlined
                              : Icons.person_add_alt_1_outlined,
                        ),
                        label: Text(_profile.followedByMe ? '取消关注' : '关注用户'),
                      ),
                    ),
                  ),
                  if (widget.onPrivateChat != null) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        onPressed: widget.onPrivateChat,
                        icon: const Icon(Icons.mail_outline_rounded),
                        label: const Text('私聊'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UserStat extends StatelessWidget {
  const _UserStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: AppTheme.primaryColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.primaryColor,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
