part of '../profile_screen.dart';

class _MemberCenterPage extends StatelessWidget {
  const _MemberCenterPage({required this.user});

  final InteractionUser user;

  @override
  Widget build(BuildContext context) {
    final growth = user.growth;
    final rows = growth.effects.isEmpty
        ? _levelPlanFor(growth.level)
        : growth.effects;
    final level = growth.level.clamp(1, 7);
    final style = _LevelVisualStyle.forLevel(level);
    final growthStatusText = _growthStatusText(growth);
    return Scaffold(
      appBar: AppBar(
        title: const Text('成长中心'),
        actions: [TextButton(onPressed: () {}, child: const Text('规则说明'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _GrowthCenterHeroCard(
            growth: growth,
            level: level,
            style: style,
            statusText: growthStatusText,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const _SectionTitle(title: '等级成长'),
              const Spacer(),
              Text(
                '成长值 ${_formatThousands(growth.points)}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _LevelGrowthPath(rows: rows, currentLevel: level, growth: growth),
          const SizedBox(height: 16),
          Row(
            children: [
              const _SectionTitle(title: '等级权益'),
              const Spacer(),
              Text(
                '已解锁 ${level.clamp(1, rows.length)}/${rows.length} 级',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _LevelBenefitsPanel(rows: rows, currentLevel: level, growth: growth),
        ],
      ),
    );
  }
}

class _GrowthCenterHeroCard extends StatelessWidget {
  const _GrowthCenterHeroCard({
    required this.growth,
    required this.level,
    required this.style,
    required this.statusText,
  });

  final UserGrowth growth;
  final int level;
  final _LevelVisualStyle style;
  final String statusText;

  @override
  Widget build(BuildContext context) {
    final nextPoints = _displayNextGrowthPoints(growth);
    final progressText =
        '${_formatThousands(growth.points)}/${_formatThousands(nextPoints)}';
    final cardAsset = _memberCardAsset(level);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fallbackWidth =
            MediaQuery.sizeOf(context).width - _profileHorizontalPadding * 2;
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : fallbackWidth;
        final isTablet = MediaQuery.sizeOf(context).width >= 720;
        final maxCardWidth = isTablet ? 620.0 : 560.0;
        final cardWidth = availableWidth.clamp(0.0, maxCardWidth).toDouble();
        final cardHeight = (cardWidth / _memberCenterCardCompactAspectRatio)
            .clamp(196.0, 340.0)
            .toDouble();
        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: cardWidth,
            height: cardHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_profileCardRadius),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      cardAsset,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.black.withValues(alpha: 0.62),
                            Colors.black.withValues(alpha: 0.34),
                            Colors.black.withValues(alpha: 0.12),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: style.borderColor, width: 1),
                        borderRadius: BorderRadius.circular(_profileCardRadius),
                        boxShadow: [
                          BoxShadow(
                            color: style.glowColor.withValues(alpha: 0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 18,
                    top: 18,
                    right: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'LV$level ${growth.levelName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: style.titleColor,
                                  fontSize: 28,
                                  height: 1.02,
                                  fontWeight: FontWeight.w700,
                                  fontFamilyFallback: _profileFontFallback,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.36,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                statusText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: style.subtitleColor.withValues(
                                    alpha: 0.95,
                                  ),
                                  fontSize: 13,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                  fontFamilyFallback: _profileFontFallback,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        _MemberCardChip(style: style),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 18,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.7,
                          child: _MemberCardProgress(
                            label: '成长值 $progressText',
                            value: _displayGrowthProgress(growth),
                            style: style,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Icon(
                              Icons.local_florist_rounded,
                              color: style.badgeColor,
                              size: 17,
                            ),
                            const SizedBox(width: 7),
                            Text(
                              '今日成长值 ${_formatThousands(growth.dailyPointsEarned)}/${_formatThousands(growth.dailyPointCap)}',
                              style: TextStyle(
                                color: style.subtitleColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFamilyFallback: _profileFontFallback,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CoinShopPage extends StatefulWidget {
  const _CoinShopPage({
    required this.token,
    required this.user,
    required this.items,
    required this.ownedItemIds,
    required this.service,
  });

  final String token;
  final InteractionUser user;
  final List<ShopItem> items;
  final Set<String> ownedItemIds;
  final InteractionService service;

  @override
  State<_CoinShopPage> createState() => _CoinShopPageState();
}

class _CoinShopPageState extends State<_CoinShopPage> {
  late InteractionUser _user = widget.user;
  late final List<ShopItem> _items = widget.items;
  late final Set<String> _ownedItemIds = {...widget.ownedItemIds};
  final Set<String> _busyItems = {};
  String _selectedCategory = 'all';
  UserProfile? _updatedProfile;

  @override
  Widget build(BuildContext context) {
    final visibleItems = _items.where(_matchesCategory).toList();
    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _updatedProfile);
        return false;
      },
      child: Scaffold(
        backgroundColor: _profileBottomBackground,
        appBar: AppBar(
          title: const Text('樱花币商店'),
          backgroundColor: _profileTopBackground,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _ShopBalanceHero(user: _user, ownedCount: _ownedItemIds.length),
            const SizedBox(height: 14),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _shopCategories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final category = _shopCategories[index];
                  return _ShopTab(
                    label: category.label,
                    selected: _selectedCategory == category.id,
                    onTap: () =>
                        setState(() => _selectedCategory = category.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            if (visibleItems.isEmpty)
              const InteractionEmptyState(
                icon: Icons.storefront_outlined,
                title: '商店暂无商品',
                subtitle: '稍后刷新看看新的空间装扮。',
              )
            else
              for (final item in visibleItems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ShopItemCard(
                    item: item,
                    owned:
                        _ownedItemIds.contains(item.id) ||
                        item.acquiredAt.isNotEmpty,
                    busy: _busyItems.contains(item.id),
                    userLevel: _user.growth.level,
                    onRedeem: () => _redeem(item),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  bool _matchesCategory(ShopItem item) {
    return switch (_selectedCategory) {
      'chat' =>
        item.itemType == 'chat_bubble' || item.itemType == 'sticker_pack',
      'avatar' =>
        item.itemType == 'avatar_frame' || item.itemType == 'avatar_privilege',
      'skin' => item.itemType == 'profile_skin',
      'effect' => item.itemType == 'danmaku_style',
      _ => true,
    };
  }

  Future<void> _redeem(ShopItem item) async {
    setState(() => _busyItems.add(item.id));
    try {
      final profile = await widget.service.redeemShopItem(
        token: widget.token,
        itemId: item.id,
      );
      if (!mounted) return;
      setState(() {
        _user = profile.user;
        _ownedItemIds.add(item.id);
        _updatedProfile = profile;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${item.name} 已加入装扮库')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法兑换，检查等级或樱花币')));
      }
    } finally {
      if (mounted) setState(() => _busyItems.remove(item.id));
    }
  }
}

class _MyDressUpPage extends StatefulWidget {
  const _MyDressUpPage({
    required this.profile,
    required this.token,
    required this.service,
    required this.onProfileChanged,
  });

  final UserProfile profile;
  final String token;
  final InteractionService service;
  final Future<void> Function(UserProfile profile) onProfileChanged;

  @override
  State<_MyDressUpPage> createState() => _MyDressUpPageState();
}

class _MyDressUpPageState extends State<_MyDressUpPage> {
  late UserProfile _profile = widget.profile;
  final Set<String> _busyItems = <String>{};

  Future<void> _equip(ShopItem item) async {
    final slot = _equipmentSlotForShopItem(item);
    if (slot.isEmpty || _busyItems.contains(item.id)) return;
    final equipped = _isEquipped(item);
    setState(() => _busyItems.add(item.id));
    try {
      final next = await widget.service.equipShopItem(
        token: widget.token,
        slot: slot,
        itemId: equipped ? '' : item.id,
      );
      if (!mounted) return;
      setState(() => _profile = next);
      await widget.onProfileChanged(next);
      _message(equipped ? '${item.name} 已解除' : '${item.name} 已使用');
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busyItems.remove(item.id));
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _profile.inventory;
    return Scaffold(
      backgroundColor: _profileBottomBackground,
      appBar: AppBar(
        title: const Text('我的装扮'),
        backgroundColor: _profileTopBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _ShopBalanceHero(user: _profile.user, ownedCount: items.length),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const InteractionEmptyState(
              icon: Icons.auto_awesome_motion_outlined,
              title: '装扮库还是空的',
              subtitle: '去商城兑换头像框、聊天气泡、表情包和空间皮肤',
            )
          else
            _SurfaceCard(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 6, 14, 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '装扮库',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          fontFamilyFallback: _profileFontFallback,
                        ),
                      ),
                    ),
                  ),
                  for (var index = 0; index < items.length; index++) ...[
                    _DressUpInventoryTile(
                      item: items[index],
                      equipped: _isEquipped(items[index]),
                      isBusy: _busyItems.contains(items[index].id),
                      onEquip: () => _equip(items[index]),
                    ),
                    if (index != items.length - 1)
                      const Divider(
                        height: 1,
                        indent: 86,
                        color: AppTheme.dividerColor,
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _isEquipped(ShopItem item) {
    final slot = _equipmentSlotForShopItem(item);
    if (slot.isEmpty) return false;
    return _profile.equippedItem(slot)?.id == item.id;
  }
}

class _DressUpInventoryTile extends StatelessWidget {
  const _DressUpInventoryTile({
    required this.item,
    required this.equipped,
    required this.isBusy,
    required this.onEquip,
  });

  final ShopItem item;
  final bool equipped;
  final bool isBusy;
  final VoidCallback onEquip;

  @override
  Widget build(BuildContext context) {
    final color = _shopAccentColor(item);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: _ShopItemPreview(item: item, color: color),
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
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          fontFamilyFallback: _profileFontFallback,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _MiniTag(label: _shopTypeLabel(item)),
                  ],
                ),
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.2,
                      fontFamilyFallback: _profileFontFallback,
                    ),
                  ),
                ],
                if (item.acquiredAt.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  const Text(
                    '已拥有',
                    style: TextStyle(
                      color: Color(0xFF0EA774),
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      fontFamilyFallback: _profileFontFallback,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonal(
            onPressed: isBusy ? null : onEquip,
            style: FilledButton.styleFrom(
              minimumSize: const Size(70, 34),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(isBusy ? '...' : (equipped ? '解除' : '使用')),
          ),
        ],
      ),
    );
  }
}
