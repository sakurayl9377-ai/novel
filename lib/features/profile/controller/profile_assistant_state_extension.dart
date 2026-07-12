part of '../profile_screen.dart';

extension _ProfileAssistantStateActions on _ProfileScreenState {
  Future<void> _loadChatBotProfile() async {
    final generation = ++_assistantProfileGeneration;
    try {
      final auth = context.read<InteractionAuthProvider>();
      final results = await Future.wait<Object>(<Future<Object>>[
        _assistantService.fetchPublicProfile(token: auth.token),
        _assistantService.loadPreferences(),
      ]);
      final profile = results[0] as ChatBotPublicProfile;
      final preferences = results[1] as ProfileAssistantPreferences;
      final localSkinId = preferences.skinId;
      if (!mounted || generation != _assistantProfileGeneration) return;
      _mutate(() {
        _chatBotProfile = profile;
        _assistantSkinIndex = _assistantSkinIndexById(
          localSkinId.isEmpty ? profile.skinId : localSkinId,
        );
      });
    } catch (_) {
      // Keep the built-in Sakura skin if the public bot profile is unavailable.
    }
  }

  Future<void> _loadAssistantPreferences() async {
    final generation = ++_assistantPreferencesGeneration;
    try {
      final preferences = await _assistantService.loadPreferences();
      if (!mounted || generation != _assistantPreferencesGeneration) return;
      _mutate(() {
        if (preferences.skinId.isNotEmpty) {
          _assistantSkinIndex = _assistantSkinIndexById(preferences.skinId);
        }
        if (preferences.dockOffset != null) {
          _assistantDockOffset = preferences.dockOffset;
        }
      });
    } catch (_) {
      // Preferences are optional; defaults keep the assistant usable.
    }
  }

  void _openMiniAssistant(InteractionUser? user) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final size = MediaQuery.sizeOf(sheetContext);
        final isTablet = size.width >= 720;
        return Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: isTablet ? math.min(size.width - 48, 640) : double.infinity,
            height: size.height * (isTablet ? 0.72 : 0.82),
            child: _MiniAssistantPanel(
              user: user,
              botName: _chatBotProfile.botName,
              canChangeSkin: true,
              initialSkinIndex: _assistantSkinIndex,
              onLoadMessages: _loadMiniAssistantMessages,
              onSendMessage: _sendMiniAssistantMessage,
              onSkinChanged: _saveAssistantSkin,
              onOpenChatRoom: () {
                Navigator.pop(sheetContext);
                _openChatRoom();
              },
              onOpenDressUp: () {
                Navigator.pop(sheetContext);
                unawaited(_openMyDressUp());
              },
            ),
          ),
        );
      },
    );
  }

  Future<List<ChatBotDirectMessage>> _loadMiniAssistantMessages() async {
    if (!mounted) return const [];
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn || auth.token.isEmpty) return const [];
    try {
      return await _assistantService.fetchMessages(
        token: auth.token,
        limit: 50,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<ChatBotDirectReply> _sendMiniAssistantMessage(String content) async {
    if (!await _ensureLogin()) {
      return const ChatBotDirectReply(reply: '登录后我就能陪你一对一聊天啦。');
    }
    if (!mounted) return const ChatBotDirectReply(reply: '');
    try {
      return await _assistantService.sendMessage(
        token: context.read<InteractionAuthProvider>().token,
        content: content,
      );
    } catch (_) {
      return const ChatBotDirectReply(reply: '我这边刚刚没连上后台，等一下再问我一次好不好？');
    }
  }

  Offset _defaultAssistantDockOffset(Size size, EdgeInsets padding) {
    return Offset(
      size.width -
          _miniAssistantDockWidth -
          padding.right -
          _miniAssistantDockEdgeMargin,
      size.height -
          _miniAssistantDockHeight -
          padding.bottom -
          _miniAssistantDockEdgeMargin,
    );
  }

  Offset _clampAssistantDockOffset(
    Offset offset,
    Size size,
    EdgeInsets padding,
  ) {
    final minX = padding.left + _miniAssistantDockEdgeMargin;
    final minY = padding.top + _miniAssistantDockEdgeMargin;
    final maxX = math.max(
      minX,
      size.width -
          _miniAssistantDockWidth -
          padding.right -
          _miniAssistantDockEdgeMargin,
    );
    final maxY = math.max(
      minY,
      size.height -
          _miniAssistantDockHeight -
          padding.bottom -
          _miniAssistantDockEdgeMargin,
    );
    return Offset(
      offset.dx.clamp(minX, maxX).toDouble(),
      offset.dy.clamp(minY, maxY).toDouble(),
    );
  }

  Offset _currentAssistantDockOffset(Size size, EdgeInsets padding) {
    return _clampAssistantDockOffset(
      _assistantDockOffset ?? _defaultAssistantDockOffset(size, padding),
      size,
      padding,
    );
  }

  void _startAssistantDrag(Size size, EdgeInsets padding) {
    _mutate(() {
      _isAssistantDragging = true;
      _assistantDockOffset = _currentAssistantDockOffset(size, padding);
    });
  }

  void _updateAssistantDrag(
    DragUpdateDetails details,
    Size size,
    EdgeInsets padding,
  ) {
    final next = _clampAssistantDockOffset(
      _currentAssistantDockOffset(size, padding) + details.delta,
      size,
      padding,
    );
    if (next == _assistantDockOffset) return;
    _mutate(() => _assistantDockOffset = next);
  }

  void _endAssistantDrag(DragEndDetails details) {
    if (!_isAssistantDragging) return;
    final offset = _assistantDockOffset;
    _mutate(() => _isAssistantDragging = false);
    if (offset != null) unawaited(_saveAssistantDockOffset(offset));
  }

  void _cancelAssistantDrag() {
    if (!_isAssistantDragging) return;
    _mutate(() => _isAssistantDragging = false);
  }

  Future<void> _saveAssistantDockOffset(Offset offset) async {
    try {
      await _assistantService.saveDockOffset(offset);
    } catch (_) {
      // Drag placement is a convenience preference; ignore storage failures.
    }
  }

  Future<bool> _saveAssistantSkin(int index) async {
    final previousIndex = _assistantSkinIndex;
    final selected =
        _assistantSkins[index.clamp(0, _assistantSkins.length - 1).toInt()];
    _mutate(() => _assistantSkinIndex = index);
    try {
      await _assistantService.saveSkinId(selected.id);
      if (!mounted) return true;
      _showMessage('小樱皮肤已更新');
      return true;
    } catch (_) {
      if (mounted) {
        _mutate(() => _assistantSkinIndex = previousIndex);
        _showMessage('小樱皮肤保存失败');
      }
      return false;
    }
  }
}
