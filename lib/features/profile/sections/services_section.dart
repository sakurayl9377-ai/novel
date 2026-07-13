part of '../profile_screen.dart';

// Kept for the compact profile variant used by smaller layouts.
// ignore: unused_element
class _QuickFeatureGrid extends StatelessWidget {
  const _QuickFeatureGrid({
    required this.onEditProfile,
    required this.onMemberCenter,
    required this.onShop,
    required this.onSpace,
  });

  final VoidCallback onEditProfile;
  final VoidCallback onMemberCenter;
  final VoidCallback onShop;
  final VoidCallback onSpace;

  @override
  Widget build(BuildContext context) {
    final entries = [
      _FeatureEntry(Icons.edit_outlined, '编辑资料', '头像、签名、照片墙', onEditProfile),
      _FeatureEntry(
        Icons.workspace_premium_outlined,
        '成长中心',
        '等级权益和成长路线',
        onMemberCenter,
      ),
      _FeatureEntry(Icons.storefront_outlined, '樱花币商店', '兑换头像框和皮肤', onShop),
      _FeatureEntry(Icons.photo_library_outlined, '我的空间', '查看和编辑个人空间', onSpace),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: entries.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.25,
      ),
      itemBuilder: (context, index) {
        final item = entries[index];
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: item.onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  _ColoredIcon(icon: item.icon, color: AppTheme.primaryColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
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

class _MoreServicesCard extends StatefulWidget {
  const _MoreServicesCard({
    required this.onHistoryRecords,
    required this.onBookshelf,
    required this.onShop,
    required this.onSuibian,
    required this.onDressUp,
    required this.onSpace,
    required this.onFavorites,
    required this.onDownloads,
    required this.onHorseRaceGame,
    required this.onChatRoom,
    required this.onGrowthCenter,
    required this.onCreatorCenter,
    this.onAdminCenter,
  });

  final VoidCallback onHistoryRecords;
  final VoidCallback onBookshelf;
  final VoidCallback onShop;
  final VoidCallback onSuibian;
  final VoidCallback onDressUp;
  final VoidCallback onSpace;
  final VoidCallback onFavorites;
  final VoidCallback onDownloads;
  final VoidCallback onHorseRaceGame;
  final VoidCallback onChatRoom;
  final VoidCallback onGrowthCenter;
  final VoidCallback onCreatorCenter;
  final VoidCallback? onAdminCenter;

  @override
  State<_MoreServicesCard> createState() => _MoreServicesCardState();
}

class _MoreServicesCardState extends State<_MoreServicesCard> {
  static const int _itemsPerPage = 8;
  final PageController _pageController = PageController();
  int _pageIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = [
      _ProfileShortcutEntry(
        Icons.storefront_outlined,
        '商城',
        widget.onShop,
        color: const Color(0xFFE78A98),
      ),
      _ProfileShortcutEntry(
        Icons.play_circle_outline_rounded,
        '随便看',
        widget.onSuibian,
        color: const Color(0xFFFF5B51),
      ),
      _ProfileShortcutEntry(
        Icons.menu_book_outlined,
        '书架',
        widget.onBookshelf,
        color: const Color(0xFF4978D0),
      ),
      _ProfileShortcutEntry(
        Icons.history_rounded,
        '历史记录',
        widget.onHistoryRecords,
        color: const Color(0xFF52647A),
      ),
      _ProfileShortcutEntry(
        Icons.star_border_rounded,
        '收藏',
        widget.onFavorites,
        color: const Color(0xFFD39A28),
      ),
      _ProfileShortcutEntry(
        Icons.forum_outlined,
        '聊天室',
        widget.onChatRoom,
        color: const Color(0xFF1E9CCF),
      ),
      _ProfileShortcutEntry(
        Icons.auto_awesome_motion_outlined,
        '我的装扮',
        widget.onDressUp,
        color: const Color(0xFFB25DFF),
      ),
      _ProfileShortcutEntry(
        Icons.sports_esports_outlined,
        '小游戏',
        widget.onHorseRaceGame,
        color: const Color(0xFFE65D42),
      ),
      _ProfileShortcutEntry(
        Icons.explore_outlined,
        '发现中心',
        widget.onGrowthCenter,
        color: const Color(0xFF3C8D7B),
      ),
      _ProfileShortcutEntry(
        Icons.drive_file_rename_outline_rounded,
        '创作中心',
        widget.onCreatorCenter,
        color: const Color(0xFF22324A),
      ),
      _ProfileShortcutEntry(
        Icons.file_download_outlined,
        '下载',
        widget.onDownloads,
        color: const Color(0xFF496579),
      ),
      _ProfileShortcutEntry(
        Icons.photo_library_outlined,
        '空间',
        widget.onSpace,
        color: const Color(0xFF6B72D6),
      ),
      if (widget.onAdminCenter != null)
        _ProfileShortcutEntry(
          Icons.admin_panel_settings_outlined,
          '运营管理',
          widget.onAdminCenter!,
          color: const Color(0xFF8458B3),
        ),
    ];
    final pages = <List<_ProfileShortcutEntry>>[
      for (var start = 0; start < entries.length; start += _itemsPerPage)
        entries.sublist(start, math.min(start + _itemsPerPage, entries.length)),
    ];
    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('更多服务', style: _profileSectionTitleStyle),
          ),
          const SizedBox(height: 10),
          const _ProfileSectionDivider(),
          const SizedBox(height: 12),
          SizedBox(
            height: 132,
            child: PageView.builder(
              controller: _pageController,
              itemCount: pages.length,
              onPageChanged: (value) => setState(() => _pageIndex = value),
              itemBuilder: (context, pageIndex) {
                final pageEntries = pages[pageIndex];
                return Stack(
                  children: [
                    GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      itemCount: pageEntries.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 4,
                            mainAxisExtent: 62,
                          ),
                      itemBuilder: (context, index) => _ProfileShortcutAction(
                        entry: pageEntries[index],
                        iconSize: 22,
                        labelSize: 11,
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _ProfileServiceSeparators(
                          itemCount: pageEntries.length,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (pages.length > 1) ...[
            const SizedBox(height: 8),
            Center(
              child: _ProfileServicePageDots(
                count: pages.length,
                index: _pageIndex,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfileServicePageDots extends StatelessWidget {
  const _ProfileServicePageDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (itemIndex) {
        final active = itemIndex == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 14 : 5,
          height: 5,
          decoration: BoxDecoration(
            color: active
                ? _profileAccentBlue
                : const Color(0xFFB8C4D4).withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _ProfileSectionDivider extends StatelessWidget {
  const _ProfileSectionDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF526D8D).withValues(alpha: 0.26),
            const Color(0xFF526D8D).withValues(alpha: 0.16),
            const Color(0xFF526D8D).withValues(alpha: 0.02),
          ],
          stops: const [0, 0.72, 1],
        ),
      ),
    );
  }
}

class _ProfileShortDivider extends StatelessWidget {
  const _ProfileShortDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF526D8D).withValues(alpha: 0.02),
            const Color(0xFF526D8D).withValues(alpha: 0.32),
            const Color(0xFF526D8D).withValues(alpha: 0.02),
          ],
        ),
      ),
    );
  }
}

class _ProfileServiceSeparators extends StatelessWidget {
  const _ProfileServiceSeparators({required this.itemCount});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    if (itemCount <= 1) return const SizedBox.shrink();
    return CustomPaint(
      painter: _ProfileServiceSeparatorPainter(itemCount: itemCount),
    );
  }
}

class _ProfileServiceSeparatorPainter extends CustomPainter {
  const _ProfileServiceSeparatorPainter({required this.itemCount});

  final int itemCount;

  @override
  void paint(Canvas canvas, Size size) {
    const columns = 4;
    final rows = (itemCount / columns).ceil().clamp(1, 2);
    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    final paint = Paint()
      ..color = const Color(0xFF526D8D).withValues(alpha: 0.3)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    for (var row = 0; row < rows; row++) {
      final rowItemCount = math.min(columns, itemCount - row * columns);
      if (rowItemCount <= 1) continue;
      final y = row * cellHeight + cellHeight / 2;
      for (var col = 1; col < rowItemCount; col++) {
        final x = col * cellWidth;
        canvas.drawLine(Offset(x, y - 20), Offset(x, y + 20), paint);
      }
    }

    if (rows <= 1) return;
    final visibleColumns = math.min(columns, itemCount);
    final y = cellHeight;
    for (var col = 0; col < visibleColumns; col++) {
      final x = col * cellWidth + cellWidth / 2;
      canvas.drawLine(Offset(x - 17, y), Offset(x + 17, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ProfileServiceSeparatorPainter oldDelegate) {
    return oldDelegate.itemCount != itemCount;
  }
}

class _SpacePreviewCard extends StatelessWidget {
  const _SpacePreviewCard({
    required this.user,
    required this.profile,
    required this.onOpen,
    required this.onEdit,
  });

  final InteractionUser? user;
  final UserProfile? profile;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final photos = profile?.photos ?? const <ProfilePhoto>[];
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '我的空间',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              TextButton(onPressed: onOpen, child: const Text('查看全部')),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                _BannerImage(url: user?.profileBannerUrl ?? '', height: 120),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.38),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Row(
                    children: [
                      _LevelAvatar(user: user, size: 54),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.spaceTitle.isNotEmpty == true
                                  ? user!.spaceTitle
                                  : '${user?.nickname ?? '初樱'}的个人空间',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              user?.bio.isNotEmpty == true
                                  ? user!.bio
                                  : '这个人很懒，什么也没留下～',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.84),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: List.generate(3, (index) {
              final photo = index < photos.length ? photos[index] : null;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: index == 2 ? 0 : 8),
                  child: _PhotoSlot(
                    imageUrl: photo?.imageUrl ?? '',
                    onTap: onEdit,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
