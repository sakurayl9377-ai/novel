import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/interaction_user.dart';

class InteractionCard extends StatelessWidget {
  const InteractionCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: child,
    );
  }
}

class InteractionAvatar extends StatelessWidget {
  const InteractionAvatar({
    super.key,
    required this.label,
    this.icon,
    this.imageUrl = '',
    this.onTap,
    this.size = 38,
  });

  final String label;
  final IconData? icon;
  final String imageUrl;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: icon == null
          ? ClipOval(
              child: imageUrl.trim().isEmpty
                  ? Image.asset(
                      defaultInteractionAvatarAsset,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                    )
                  : Image.network(
                      imageUrl.trim(),
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Image.asset(
                        defaultInteractionAvatarAsset,
                        width: size,
                        height: size,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
            )
          : Icon(icon, color: AppTheme.primaryColor, size: size * 0.48),
    );
    if (onTap == null) return avatar;
    return GestureDetector(onTap: onTap, child: avatar);
  }
}

class InteractionEntryTile extends StatelessWidget {
  const InteractionEntryTile({
    super.key,
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
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: AppTheme.primaryColor, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: AppTheme.textHint,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InteractionEmptyState extends StatelessWidget {
  const InteractionEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InteractionAvatar(label: title, icon: icon, size: 54),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InteractionUserProfileSheet extends StatefulWidget {
  const InteractionUserProfileSheet({
    super.key,
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
  State<InteractionUserProfileSheet> createState() =>
      _InteractionUserProfileSheetState();
}

class _InteractionUserProfileSheetState
    extends State<InteractionUserProfileSheet> {
  late UserProfile _profile = widget.profile;
  bool _isWorking = false;

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
                InteractionAvatar(
                  label: user.nickname,
                  imageUrl: user.avatarUrl,
                  size: 54,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              user.nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (user.gender != 'private')
                            Icon(
                              user.gender == 'male'
                                  ? Icons.male_rounded
                                  : Icons.female_rounded,
                              size: 18,
                              color: user.gender == 'male'
                                  ? const Color(0xFF4B8DFF)
                                  : const Color(0xFFFF6F9F),
                            ),
                        ],
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
                _InteractionUserStat(
                  label: 'Lv${growth.level}',
                  value: growth.levelName,
                ),
                const SizedBox(width: 8),
                _InteractionUserStat(label: '${growth.points}', value: '积分'),
                const SizedBox(width: 8),
                _InteractionUserStat(
                  label: '${_profile.stats.followers}',
                  value: '粉丝',
                ),
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

class _InteractionUserStat extends StatelessWidget {
  const _InteractionUserStat({required this.label, required this.value});

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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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

InputDecoration interactionInputDecoration({
  required String hintText,
  IconData? icon,
}) {
  return InputDecoration(
    hintText: hintText,
    prefixIcon: icon == null ? null : Icon(icon, size: 20),
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppTheme.dividerColor),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppTheme.dividerColor),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.2),
    ),
  );
}
