part of 'profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  final InteractionService _service = InteractionService();
  late final ProfileAssistantService _assistantService;
  late final AnimationController _sakuraController;
  late final ProfileController _controller;

  int _assistantSkinIndex = 0;
  ChatBotPublicProfile _chatBotProfile = const ChatBotPublicProfile();
  Offset? _assistantDockOffset;
  bool _isAssistantDragging = false;
  String _sessionFingerprint = '';
  int _assistantProfileGeneration = 0;
  int _assistantPreferencesGeneration = 0;

  List<ShopItem> get _shopItems => _controller.state.shopItems;
  bool get _isLoading => _controller.state.isLoading;
  int get _messageUnreadCount => _controller.state.unreadCount;

  @override
  void initState() {
    super.initState();
    _controller = ProfileController(
      repository: InteractionProfileRepository(_service),
    )..addListener(_handleControllerChanged);
    _assistantService = ProfileAssistantService(_service);
    _sakuraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
      unawaited(_loadAssistantPreferences());
      unawaited(_loadChatBotProfile());
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleControllerChanged)
      ..dispose();
    _sakuraController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _mutate(VoidCallback update) {
    if (mounted) setState(update);
  }

  void _scheduleSessionSync(InteractionAuthProvider auth) {
    final fingerprint = '${auth.user?.id ?? 0}:${auth.token}';
    if (_sessionFingerprint == fingerprint) return;
    _sessionFingerprint = fingerprint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _controller.switchSession(
          user: auth.user,
          token: auth.token,
          updateCachedUser: auth.updateCachedUser,
        ),
      );
    });
  }

  Future<void> _load() async {
    final auth = context.read<InteractionAuthProvider>();
    await _controller.switchSession(
      user: auth.user,
      token: auth.token,
      updateCachedUser: auth.updateCachedUser,
      forceRefresh: true,
    );
  }

  Future<void> _loadMessageUnreadSummary() async {
    await _controller.refreshUnread();
  }

  UserProfile? _profileForAuth(InteractionAuthProvider auth) {
    return _controller.profileFor(auth.user);
  }

  Future<bool> _ensureLogin() async {
    final auth = context.read<InteractionAuthProvider>();
    if (auth.isLoggedIn) return true;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
    );
    if (!mounted) return false;
    await _load();
    if (!mounted) return false;
    return context.read<InteractionAuthProvider>().isLoggedIn;
  }

  Future<UserProfile?> _signIn() async {
    final loggedIn = await _ensureLogin();
    if (!mounted || !loggedIn) return null;
    final auth = context.read<InteractionAuthProvider>();
    try {
      final profile = await _controller.signIn();
      if (!mounted) return profile;
      await auth.updateCachedUser(profile.user);
      if (!mounted) return profile;
      _showMessage('签到成功，经验和樱花币已到账');
      return profile;
    } catch (_) {
      if (mounted) _showMessage('今天已经签过到了');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    _scheduleSessionSync(auth);
    final authUser = auth.user;
    final profile = _profileForAuth(auth);
    final user = profile?.user ?? authUser;
    final topContentInset = MediaQuery.paddingOf(context).top + 56;
    final contentSideInset =
        ((MediaQuery.sizeOf(context).width - 860).clamp(0, double.infinity) /
            2) +
        _profileHorizontalPadding;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        toolbarHeight: 50,
        centerTitle: false,
        titleSpacing: _profileHorizontalPadding,
        title: const Text(
          '我的',
          style: TextStyle(
            fontSize: 19,
            height: 1,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          _HeaderIconButton(
            tooltip: '消息',
            onPressed: () => unawaited(_openMessages()),
            icon: Icons.mark_chat_unread_outlined,
            badgeCount: _messageUnreadCount,
          ),
          _HeaderIconButton(
            tooltip: '设置',
            onPressed: _openProfileSettings,
            icon: Icons.settings_outlined,
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final mediaSize = MediaQuery.sizeOf(context);
          final stackSize = Size(
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : mediaSize.width,
            constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : mediaSize.height,
          );
          final viewPadding = MediaQuery.paddingOf(context);
          final assistantOffset = _currentAssistantDockOffset(
            stackSize,
            viewPadding,
          );
          return Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  _defaultProfileSakuraBackgroundAsset,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.02),
                        _profileTopBackground.withValues(alpha: 0.06),
                        _profileBottomBackground.withValues(alpha: 0.1),
                      ],
                      stops: const [0, 0.36, 1],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: _SakuraPetalField(animation: _sakuraController),
                  ),
                ),
              ),
              RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(900),
                  padding: EdgeInsets.fromLTRB(
                    contentSideInset,
                    0,
                    contentSideInset,
                    28,
                  ).copyWith(top: topContentInset),
                  children: [
                    if (_isLoading) ...[
                      const LinearProgressIndicator(minHeight: 2),
                      const SizedBox(height: 10),
                    ],
                    if (_controller.state.hasError) ...[
                      ProfileLoadErrorBanner(
                        message: _controller.state.errorMessage!,
                        onRetry: () => unawaited(_load()),
                      ),
                      const SizedBox(height: 10),
                    ],
                    _ProfileHeader(
                      user: user,
                      stats: profile?.stats ?? const UserProfileStats(),
                      isLoggedIn: auth.isLoggedIn,
                      onLogin: _ensureLogin,
                      onEdit: _openEditProfile,
                      onFollowers: () =>
                          _openFollowList(kind: _FollowListKind.followers),
                      onFollowing: () =>
                          _openFollowList(kind: _FollowListKind.following),
                    ),
                    const SizedBox(height: 4),
                    _MemberHeroCard(user: user),
                    const SizedBox(height: _profileModuleGap),
                    _StatsPanel(
                      user: user,
                      isLoggedIn: auth.isLoggedIn,
                      stats: profile?.stats ?? const UserProfileStats(),
                      onLogin: _ensureLogin,
                      onEdit: _openEditProfile,
                      onMemberCenter: _openMemberCenter,
                      onComments: () => _openMyInteractions(initialTab: 0),
                      onDanmaku: () => _openMyInteractions(initialTab: 1),
                    ),
                    const SizedBox(height: _profileModuleGap),
                    _DailySignInCard(
                      user: user,
                      rewards: profile?.dailyRewards ?? const [],
                      onOpen: _openDailyRewards,
                      onSignIn: _signIn,
                    ),
                    const SizedBox(height: _profileModuleGap),
                    _MoreServicesCard(
                      onHistoryRecords: _openHistoryRecords,
                      onBookshelf: _openBookshelf,
                      onShop: _openShop,
                      onDressUp: _openMyDressUp,
                      onSpace: _openMySpace,
                      onFavorites: _openFavorites,
                      onDownloads: _openDownloads,
                      onHorseRaceGame: () => unawaited(_openHorseRaceGame()),
                      onChatRoom: _openChatRoom,
                      onGrowthCenter: _openGrowthCenter,
                      onAdminCenter:
                          ProfilePermissionPolicy.canOpenAdminEntry(user)
                          ? _openAdminCenter
                          : null,
                      onCreatorCenter: () => _showReservedService('创作中心'),
                    ),
                  ],
                ),
              ),
              AnimatedPositioned(
                duration: _isAssistantDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                left: assistantOffset.dx,
                top: assistantOffset.dy,
                child: _MiniAssistantDock(
                  skin: _assistantSkins[_assistantSkinIndex],
                  botName: _chatBotProfile.botName,
                  animation: _sakuraController,
                  isDragging: _isAssistantDragging,
                  onTap: () => _openMiniAssistant(user),
                  onPanStart: (_) =>
                      _startAssistantDrag(stackSize, viewPadding),
                  onPanUpdate: (details) =>
                      _updateAssistantDrag(details, stackSize, viewPadding),
                  onPanEnd: _endAssistantDrag,
                  onPanCancel: _cancelAssistantDrag,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ignore: unused_element
  Future<void> _openMessages() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MessageCenterScreen()),
    );
    if (mounted) unawaited(_loadMessageUnreadSummary());
  }

  Future<void> _openProfileSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProfileSettingsPage(
          profile: _profileForAuth(context.read<InteractionAuthProvider>()),
          onReload: _load,
          onEditProfile: _openEditProfile,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openHistoryRecords() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const _HistoryRecordsPage()),
    );
    _controller.markLibrarySectionRefreshed(ProfileLibrarySection.history);
  }

  void _openBookshelf() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BookshelfScreen()),
    );
  }

  Future<void> _openFavorites() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const FavoritesScreen()),
    );
    _controller.markLibrarySectionRefreshed(ProfileLibrarySection.favorites);
  }

  Future<void> _openDownloads() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const DownloadsScreen()),
    );
    _controller.markLibrarySectionRefreshed(ProfileLibrarySection.downloads);
  }

  Future<void> _openHorseRaceGame() async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HorseRaceGameScreen()),
    );
  }

  void _openChatRoom() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatRoomListScreen()),
    );
  }

  void _openGrowthCenter() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GrowthCenterScreen()),
    );
  }

  void _openAdminCenter() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatRoomListScreen()),
    );
  }

  void _showReservedService(String label) {
    _showMessage('$label入口已保留，后续接入完整列表');
  }

  Future<void> _openDailyRewards() async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    var profile = _profileForAuth(auth);
    if (profile == null) {
      await _load();
      if (!mounted) return;
      profile = _profileForAuth(context.read<InteractionAuthProvider>());
      if (profile == null) return;
    }
    await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(
        builder: (_) => _DailyRewardsPage(
          initialProfile: profile!,
          onSignIn: _signIn,
          onRefresh: _refreshProfileSnapshot,
          onEditProfile: _openEditProfile,
          onOpenCommentTask: _openRewardCommentTask,
          onOpenDanmakuTask: _openRewardDanmakuTask,
          onOpenChatTask: _openRewardChatTask,
        ),
      ),
    );
  }

  Future<UserProfile?> _refreshProfileSnapshot() async {
    await _load();
    if (!mounted) return null;
    return _profileForAuth(context.read<InteractionAuthProvider>());
  }

  Future<UserProfile?> _openEditProfile() async {
    if (!await _ensureLogin()) return null;
    if (!mounted) return null;
    final auth = context.read<InteractionAuthProvider>();
    final currentProfile = _profileForAuth(auth);
    final user = currentProfile?.user ?? auth.user;
    if (user == null) return null;
    final profile = currentProfile ?? UserProfile(user: user);
    final next = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(
        builder: (_) => _EditProfilePage(
          profile: profile,
          token: auth.token,
          service: _service,
        ),
      ),
    );
    if (next == null || !mounted) return null;
    _controller.replaceProfile(next);
    await auth.updateCachedUser(next.user);
    _showMessage('资料已更新');
    return next;
  }

  Future<void> _openRewardCommentTask() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const SearchScreen(autofocus: false)),
    );
  }

  Future<void> _openRewardDanmakuTask() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const AnimeScreen()),
    );
  }

  Future<void> _openRewardChatTask() async {
    _openChatRoom();
  }

  Future<void> _openMemberCenter() async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    final user = _profileForAuth(auth)?.user ?? auth.user;
    if (user == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => _MemberCenterPage(user: user)),
    );
  }

  Future<void> _openMyInteractions({required int initialTab}) async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _MyInteractionsPage(
          token: auth.token,
          service: _service,
          initialTab: initialTab,
        ),
      ),
    );
  }

  Future<void> _openFollowList({required _FollowListKind kind}) async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    final user = _profileForAuth(auth)?.user ?? auth.user;
    if (user == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _FollowListPage(
          kind: kind,
          userId: user.id,
          selfUserId: auth.user?.id ?? user.id,
          token: auth.token,
          service: _service,
        ),
      ),
    );
    if (mounted) await _load();
  }

  // ignore: unused_element
  Future<void> _openShop() async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    if (_shopItems.isEmpty) {
      await _controller.refresh(showLoading: false);
      if (_shopItems.isEmpty && mounted) _showMessage('商店加载失败');
    }
    if (!mounted) return;
    final profile = _profileForAuth(auth);
    final user = profile?.user ?? auth.user;
    if (user == null) return;
    final next = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(
        builder: (_) => _CoinShopPage(
          token: auth.token,
          user: user,
          items: _shopItems,
          ownedItemIds: profile?.inventory.map((item) => item.id).toSet() ?? {},
          service: _service,
        ),
      ),
    );
    if (next == null || !mounted) return;
    _controller.replaceProfile(next);
    await auth.updateCachedUser(next.user);
  }

  Future<void> _openMyDressUp() async {
    if (!await _ensureLogin()) return;
    if (!mounted) return;
    var profile = _profileForAuth(context.read<InteractionAuthProvider>());
    if (profile == null) {
      await _load();
      if (!mounted) return;
      profile = _profileForAuth(context.read<InteractionAuthProvider>());
    }
    if (profile == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _MyDressUpPage(
          profile: profile!,
          token: context.read<InteractionAuthProvider>().token,
          service: _service,
          onProfileChanged: (next) async {
            if (!mounted) return;
            _controller.replaceProfile(next);
            await context.read<InteractionAuthProvider>().updateCachedUser(
              next.user,
            );
          },
        ),
      ),
    );
  }

  // ignore: unused_element
  Future<void> _openMySpace() async {
    final opened = await _ensureLogin();
    if (!mounted || !opened) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _ProfileSpacePage(
          profile: _profileForAuth(context.read<InteractionAuthProvider>()),
          onReload: _load,
          onEditProfile: _openEditProfile,
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
