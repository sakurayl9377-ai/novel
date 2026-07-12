part of '../profile_screen.dart';

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.user,
    required this.selected,
    required this.subtitle,
    required this.onTap,
  });

  final InteractionUser user;
  final bool selected;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFEAF4FF),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _LevelAvatar(user: user, size: 58),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
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
                        if (selected) ...[
                          const SizedBox(width: 8),
                          const _MiniTag(label: '当前账号'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'LV${user.growth.level} ${user.growth.levelName}',
                      style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountListTile extends StatelessWidget {
  const _AccountListTile({required this.account, required this.onTap});

  final InteractionAccountSession account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _LevelAvatar(user: account.user, size: 42),
      title: Text(account.user.nickname),
      subtitle: Text(
        'LV${account.user.growth.level} ${account.user.growth.levelName}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _EditRow extends StatelessWidget {
  const _EditRow({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.chevron_right),
        border: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppTheme.dividerColor),
        ),
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppTheme.dividerColor),
        ),
      ),
    );
  }
}

class _GenderPicker extends StatelessWidget {
  const _GenderPicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    const items = [
      ('male', Icons.male_rounded, '男'),
      ('female', Icons.female_rounded, '女'),
      ('private', Icons.visibility_off_outlined, '隐私'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '性别',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 9),
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.textSecondary),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  Expanded(
                    child: _GenderSegment(
                      icon: items[index].$2,
                      label: items[index].$3,
                      selected: value == items[index].$1,
                      onTap: () => onChanged(items[index].$1),
                    ),
                  ),
                  if (index != items.length - 1)
                    Container(width: 1, color: AppTheme.textSecondary),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GenderSegment extends StatelessWidget {
  const _GenderSegment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? const Color(0xFFDCE4FF).withValues(alpha: 0.78)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: AppTheme.textPrimary),
              const SizedBox(width: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  height: 1,
                  fontWeight: FontWeight.w700,
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

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.label,
    required this.value,
    required this.color,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final String label;
  final String value;
  final Color color;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: locked ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? AppTheme.primaryColor : Colors.transparent,
                width: 2,
              ),
            ),
            child: Icon(
              locked
                  ? Icons.lock_outline_rounded
                  : selected
                  ? Icons.check_rounded
                  : Icons.palette_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: locked ? AppTheme.textHint : AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(_profileCardRadius);
    final content = SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.028),
              Colors.white.withValues(alpha: 0.012),
              Colors.white.withValues(alpha: 0.004),
            ],
            stops: const [0, 0.58, 1],
          ),
          borderRadius: radius,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.58),
            width: 1.1,
          ),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
    final card = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5E8E).withValues(alpha: 0.038),
            blurRadius: 16,
            spreadRadius: -12,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.3),
            blurRadius: 0,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: radius, child: content),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: radius, child: card),
    );
  }
}
