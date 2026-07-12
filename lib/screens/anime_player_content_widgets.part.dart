part of 'anime_player_screen.dart';

class _ModernVideoContentTabs extends StatelessWidget {
  const _ModernVideoContentTabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: AppTokens.canvasColor(context),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppTokens.cardColor(context),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          border: Border.all(color: AppTokens.borderColor(context)),
        ),
        child: Row(
          children: [
            Expanded(
              child: _ModernVideoContentTab(
                label: '详情',
                active: index == 0,
                onTap: () => onChanged(0),
              ),
            ),
            Expanded(
              child: _ModernVideoContentTab(
                label: '评论',
                active: index == 1,
                onTap: () => onChanged(1),
              ),
            ),
            Expanded(
              child: _ModernVideoContentTab(
                label: '弹幕',
                active: index == 2,
                onTap: () => onChanged(2),
              ),
            ),
            Expanded(
              child: _ModernVideoContentTab(
                label: '推荐',
                active: index == 3,
                onTap: () => onChanged(3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModernVideoContentTab extends StatelessWidget {
  const _ModernVideoContentTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusXs),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppTokens.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(AppTokens.radiusXs),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? Colors.white : AppTokens.secondaryText(context),
            fontSize: 14,
            fontWeight: active ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _VideoContentTabs extends StatelessWidget {
  const _VideoContentTabs({
    required this.index,
    required this.commentsLabel,
    required this.onChanged,
  });

  final int index;
  final String commentsLabel;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Row(
        children: [
          _VideoContentTab(
            label: '剧集',
            active: index == 0,
            onTap: () => onChanged(0),
          ),
          const SizedBox(width: 22),
          _VideoContentTab(
            label: commentsLabel,
            active: index == 1,
            onTap: () => onChanged(1),
          ),
        ],
      ),
    );
  }
}

class _VideoContentTab extends StatelessWidget {
  const _VideoContentTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: double.infinity,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: active ? AppTheme.primaryColor : AppTheme.textSecondary,
                fontSize: 15,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 7),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: active ? 28 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
