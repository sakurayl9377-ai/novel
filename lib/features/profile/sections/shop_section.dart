part of '../profile_screen.dart';

class _ShopCategory {
  const _ShopCategory(this.id, this.label);

  final String id;
  final String label;
}

const List<_ShopCategory> _shopCategories = [
  _ShopCategory('all', '全部'),
  _ShopCategory('chat', '聊天装扮'),
  _ShopCategory('avatar', '头像相关'),
  _ShopCategory('skin', '空间皮肤'),
  _ShopCategory('effect', '弹幕特效'),
];

class _ShopBalanceHero extends StatelessWidget {
  const _ShopBalanceHero({required this.user, required this.ownedCount});

  final InteractionUser user;
  final int ownedCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_profileCardRadius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF173457), Color(0xFF8E5CF4), Color(0xFFFF8AAF)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22173457),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: const Icon(
              Icons.local_florist_rounded,
              color: Color(0xFFFFD86B),
              size: 32,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '可用樱花币',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${user.growth.sakuraCoins}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已拥有 $ownedCount 件装扮 · LV${user.growth.level} ${user.growth.levelName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: FontWeight.w500,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopItemCard extends StatelessWidget {
  const _ShopItemCard({
    required this.item,
    required this.owned,
    required this.busy,
    required this.userLevel,
    required this.onRedeem,
  });

  final ShopItem item;
  final bool owned;
  final bool busy;
  final int userLevel;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    final locked = userLevel < item.minLevel;
    final accent = _shopAccentColor(item);
    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShopItemPreview(item: item, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 16,
                                height: 1.15,
                                fontWeight: FontWeight.w800,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _MiniTag(label: _shopTypeLabel(item)),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        item.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.35,
                          fontWeight: FontWeight.w400,
                          fontFamilyFallback: _profileFontFallback,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _ShopMetaPill(
                            icon: Icons.local_florist_rounded,
                            label: '${item.priceCoins} 樱花币',
                            color: const Color(0xFFFF8A3D),
                          ),
                          _ShopMetaPill(
                            icon: Icons.lock_open_rounded,
                            label: 'LV${item.minLevel}',
                            color: accent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.dividerColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    owned
                        ? '已加入装扮库'
                        : locked
                        ? '达到 LV${item.minLevel} 后可兑换'
                        : '兑换后可在装扮中使用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: owned
                          ? AppTheme.primaryColor
                          : locked
                          ? AppTheme.textHint
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      fontFamilyFallback: _profileFontFallback,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 34,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      disabledBackgroundColor: const Color(0xFFE9EDF4),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: AppTheme.textHint,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: locked || owned || busy ? null : onRedeem,
                    child: busy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            owned
                                ? '已拥有'
                                : locked
                                ? '锁定'
                                : '兑换',
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopItemPreview extends StatelessWidget {
  const _ShopItemPreview({required this.item, required this.color});

  final ShopItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fallback = switch (item.itemType) {
      'chat_bubble' => _ShopBubblePreview(value: item.assetValue),
      'sticker_pack' => _ShopStickerPackPreview(pack: item.assetValue),
      _ => Icon(_shopIcon(item), color: color, size: 36),
    };
    return Container(
      width: 92,
      height: 104,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      clipBehavior: Clip.antiAlias,
      child: item.previewUrl.isEmpty
          ? Padding(padding: const EdgeInsets.all(10), child: fallback)
          : Image.network(
              item.previewUrl,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stackTrace) =>
                  Padding(padding: const EdgeInsets.all(10), child: fallback),
            ),
    );
  }
}

class _ShopBubblePreview extends StatelessWidget {
  const _ShopBubblePreview({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = _shopBubbleColors(value);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            width: 58,
            height: 28,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 42,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppTheme.dividerColor),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
                bottomLeft: Radius.circular(2),
                bottomRight: Radius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ShopStickerPackPreview extends StatelessWidget {
  const _ShopStickerPackPreview({required this.pack});

  final String pack;

  @override
  Widget build(BuildContext context) {
    final assets = _shopStickerAssets(pack);
    return Wrap(
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final asset in assets)
          Container(
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SvgPicture.asset(asset),
          ),
      ],
    );
  }
}

class _ShopMetaPill extends StatelessWidget {
  const _ShopMetaPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w700,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}
