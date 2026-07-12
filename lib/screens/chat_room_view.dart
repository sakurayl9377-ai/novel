part of 'chat_room_screen.dart';

class _ChatRoomScreenState extends _ChatRoomRoomState {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final currentUserId = auth.user?.id.toString() ?? 'guest';
    final canChat = _hasCompleteChatProfile(auth.user);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _openRoomInfoSheet,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: Theme.of(context).appBarTheme.foregroundColor,
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索历史消息',
            onPressed: _openMessageSearchSheet,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '重连',
            onPressed: _isConnecting ? null : _connect,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_isConnecting) const LinearProgressIndicator(minHeight: 2),
              if (_errorMessage != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  color: AppTheme.accentColor.withValues(alpha: 0.1),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 17,
                        color: AppTheme.accentColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: _entranceNotice == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(_entranceNotice!.serial),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        child: _ChatEntranceBanner(notice: _entranceNotice!),
                      ),
              ),
              Expanded(
                child: chat_ui.Chat(
                  chatController: _chatController,
                  currentUserId: currentUserId,
                  backgroundColor: const Color(0xFFF4F6FB),
                  resolveUser: (id) async {
                    return _chatUsers[id] ?? chat_core.User(id: id, name: '用户');
                  },
                  onMessageSend: (text) => unawaited(_send(content: text)),
                  onAttachmentTap: () => unawaited(_openImageSender()),
                  onMessageTap:
                      (context, message, {required index, required details}) {
                        final source = _messageById[message.id];
                        if (source != null) {
                          unawaited(_openMessageActions(source));
                        }
                      },
                  onMessageLongPress:
                      (context, message, {required index, required details}) {
                        final source = _messageById[message.id];
                        if (source != null) {
                          unawaited(_openMessageActions(source));
                        }
                      },
                  theme: chat_core.ChatTheme.light().copyWith(
                    colors: chat_core.ChatColors.light().copyWith(
                      primary: AppTheme.primaryColor,
                      surface: const Color(0xFFF4F6FB),
                      surfaceContainer: Colors.white,
                      surfaceContainerLow: Colors.white,
                      surfaceContainerHigh: const Color(0xFFE9F2FF),
                    ),
                    shape: const BorderRadius.all(Radius.circular(8)),
                  ),
                  builders: chat_core.Builders(
                    emptyChatListBuilder: (_) => const InteractionEmptyState(
                      icon: Icons.forum_outlined,
                      title: '聊天室还很安静',
                      subtitle: '发一条消息，和其他读者打个招呼',
                    ),
                    chatAnimatedListBuilder: (context, itemBuilder) =>
                        chat_ui.ChatAnimatedList(
                          itemBuilder: itemBuilder,
                          scrollController: _messageScrollController,
                          initialScrollToEndMode:
                              chat_ui.InitialScrollToEndMode.jump,
                          onEndReached: _loadOlderMessages,
                          bottomPadding: 92,
                        ),
                    chatMessageBuilder:
                        (
                          context,
                          message,
                          index,
                          animation,
                          child, {
                          isRemoved,
                          required isSentByMe,
                          groupStatus,
                        }) {
                          return _ChatMessageFrame(
                            message: message,
                            user: _chatUsers[message.authorId],
                            source: _messageById[message.id],
                            isSentByMe: isSentByMe,
                            animation: animation,
                            onMessageLongPress: () {
                              final source = _messageById[message.id];
                              if (source != null) {
                                unawaited(_openMessageActions(source));
                              }
                            },
                            onAvatarTap: () {
                              final source = _messageById[message.id];
                              if (source != null) {
                                unawaited(_openUserProfile(source));
                              }
                            },
                            onAvatarLongPress: () {
                              final source = _messageById[message.id];
                              if (source != null) {
                                _insertMention(source.user.nickname);
                              }
                            },
                            child: child,
                          );
                        },
                    textMessageBuilder:
                        (
                          context,
                          message,
                          index, {
                          required isSentByMe,
                          groupStatus,
                        }) {
                          return _ChatTextMessage(
                            message: message,
                            source: _messageById[message.id],
                            isSentByMe: isSentByMe,
                          );
                        },
                    imageMessageBuilder:
                        (
                          context,
                          message,
                          index, {
                          required isSentByMe,
                          groupStatus,
                        }) {
                          return _ChatImageMessage(
                            message: message,
                            isSentByMe: isSentByMe,
                          );
                        },
                    audioMessageBuilder:
                        (
                          context,
                          message,
                          index, {
                          required isSentByMe,
                          groupStatus,
                        }) {
                          return _ChatAudioMessage(
                            message: message,
                            source: _messageById[message.id],
                            isSentByMe: isSentByMe,
                            service: _service,
                            token: context
                                .read<InteractionAuthProvider>()
                                .token,
                            onQuote: (source) => _quoteMessage(source),
                          );
                        },
                    composerBuilder: (_) => _isJoinedRoom
                        ? _WechatChatComposer(
                            controller: _controller,
                            inputFocusNode: _inputFocusNode,
                            canChat: canChat,
                            hasDraft: _hasDraft || _pendingAttachment != null,
                            voiceInputMode: _voiceInputMode,
                            isRecordingVoice: _isRecordingVoice,
                            isSendingVoice: _isSendingVoice,
                            voiceRecordSeconds: _voiceRecordSeconds,
                            voiceReleaseAction: _voiceReleaseAction,
                            pendingAttachment: _pendingAttachment,
                            onClearPending: () =>
                                setState(() => _pendingAttachment = null),
                            onEnsureCanChat: () => unawaited(_ensureCanChat()),
                            onSend: () => unawaited(_sendText()),
                            onSticker: () => unawaited(_openStickerPicker()),
                            onMore: () => unawaited(_openMorePanel()),
                            onToggleVoiceMode: _toggleVoiceInputMode,
                            onVoiceRecordStart: _startVoiceRecording,
                            onVoiceRecordActionChanged: _setVoiceReleaseAction,
                            onVoiceRecordEnd: _finishVoiceRecording,
                            mentionSuggestions: _mentionSuggestions,
                            onMentionSelected: (member) =>
                                _insertMention(member.nickname),
                          )
                        : _JoinChatRoomBar(
                            isLoading: _isJoiningRoom,
                            canEnter: _roomInfoForDisplay().canEnter,
                            minLevel: _roomInfoForDisplay().minLevel,
                            onJoin: () => unawaited(_joinCurrentRoom()),
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (_isRecordingVoice)
            Positioned.fill(
              child: IgnorePointer(
                child: _VoiceRecordingOverlay(
                  seconds: _voiceRecordSeconds,
                  action: _voiceReleaseAction,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
