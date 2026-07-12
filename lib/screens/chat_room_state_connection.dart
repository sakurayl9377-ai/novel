part of 'chat_room_screen.dart';

abstract class _ChatRoomConnectionState extends State<ChatRoomScreen> {
  final InteractionService _service = InteractionService();
  final StorageService _storageService = StorageService();
  final chat_core.InMemoryChatController _chatController =
      chat_core.InMemoryChatController();
  final ScrollController _messageScrollController = ScrollController();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final Map<String, chat_core.User> _chatUsers = {};
  final Map<String, ChatMessage> _messageById = {};
  final AudioRecorder _voiceRecorder = AudioRecorder();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _voiceTimer;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _isConnecting = false;
  bool _hasDraft = false;
  bool _isRecordingVoice = false;
  bool _isSendingVoice = false;
  bool _isJoiningRoom = false;
  bool _isJoinedRoom = false;
  bool _voiceInputMode = false;
  _VoiceReleaseAction _voiceReleaseAction = _VoiceReleaseAction.send;
  int _voiceRecordSeconds = 0;
  int _connectionSerial = 0;
  String _mentionQuery = '';
  bool _showMentionSuggestions = false;
  DateTime? _voiceRecordStartedAt;
  String? _errorMessage;
  _PendingChatAttachment? _pendingAttachment;
  _ChatEntranceNotice? _entranceNotice;
  final List<_ChatEntranceNotice> _entranceQueue = [];
  Timer? _entranceTimer;
  int _entranceSerial = 0;
  ChatRoomInfo? _roomSnapshot;
  bool _isLoadingRoomSnapshot = false;
  bool _isLoadingOlderMessages = false;
  bool _hasMoreHistoryMessages = true;
  int _oldestMessageId = 0;

  Future<void> _loadRoomSnapshot({required bool showError});

  ChatRoomInfo _roomInfoForDisplay();

  void _showMessage(String message);

  String _chatError(String error);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleInputChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadRoomSnapshot(showError: false));
      unawaited(_connect(announceEntrance: true));
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _channel?.sink.close();
    _voiceTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _entranceTimer?.cancel();
    _entranceQueue.clear();
    if (_isRecordingVoice) {
      unawaited(_voiceRecorder.stop().catchError((_) => null));
    }
    unawaited(_voiceRecorder.dispose());
    _controller.removeListener(_handleInputChanged);
    _inputFocusNode.dispose();
    _controller.dispose();
    _messageScrollController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  Future<void> _connect({
    bool announceEntrance = false,
    bool silent = false,
  }) async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
      );
      if (!mounted) return;
      if (!context.read<InteractionAuthProvider>().isLoggedIn) {
        setState(() => _errorMessage = '登录后才能进入聊天室');
        return;
      }
    }

    final serial = ++_connectionSerial;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();

    if (!silent) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
      });
    }
    try {
      final channel = _service.connectChat(
        token: context.read<InteractionAuthProvider>().token,
        roomId: widget.roomId,
        announceEntrance: announceEntrance,
      );
      await _subscription?.cancel();
      _channel?.sink.close();
      if (!mounted || serial != _connectionSerial) {
        unawaited(channel.sink.close());
        return;
      }
      _channel = channel;
      _startHeartbeat(channel, serial);
      _subscription = channel.stream.listen(
        (event) {
          if (serial == _connectionSerial) _handleMessage(event);
        },
        onError: (_) {
          if (!mounted || serial != _connectionSerial) return;
          _scheduleReconnect(serial);
        },
        onDone: () {
          if (!mounted || serial != _connectionSerial) return;
          _scheduleReconnect(serial);
        },
      );
    } catch (_) {
      if (mounted && serial == _connectionSerial) {
        if (!silent) setState(() => _errorMessage = '聊天室连接失败');
        _scheduleReconnect(serial);
      }
    } finally {
      if (mounted && serial == _connectionSerial && !silent) {
        setState(() => _isConnecting = false);
      }
    }
  }

  void _startHeartbeat(WebSocketChannel channel, int serial) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted || serial != _connectionSerial) return;
      try {
        channel.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        if (mounted && serial == _connectionSerial) {
          _scheduleReconnect(serial);
        }
      }
    });
  }

  void _scheduleReconnect(int serial) {
    if (!mounted || serial != _connectionSerial) return;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || serial != _connectionSerial) return;
      unawaited(_connect(silent: true));
    });
  }

  void _handleMessage(dynamic raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw.toString());
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final type = decoded['type']?.toString();
    if (type == 'ready') {
      final userJson = decoded['user'];
      if (userJson is Map) {
        final user = InteractionUserBrief.fromJson(
          userJson.cast<String, dynamic>(),
        );
        _rememberChatUser(user);
        final isJoined = userJson['isJoined'];
        if (isJoined is bool && mounted) {
          setState(() => _isJoinedRoom = isJoined);
        }
      }
    }
    if (type == 'history') {
      final items = decoded['items'];
      if (items is List) {
        _messageById.clear();
        _chatUsers.clear();
        final history =
            items
                .whereType<Map>()
                .map(
                  (item) => ChatMessage.fromJson(item.cast<String, dynamic>()),
                )
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        _resetHistoryCursor(history);
        final messages = history.map(_toChatUiMessage).toList();
        unawaited(_setHistoryMessages(messages));
      }
    }
    if (type == 'message') {
      final item = decoded['item'];
      if (item is Map) {
        final message = ChatMessage.fromJson(item.cast<String, dynamic>());
        if (_messageById.containsKey(message.id.toString())) return;
        unawaited(_chatController.insertMessage(_toChatUiMessage(message)));
      }
    }
    if (type == 'entrance') {
      final userJson = decoded['user'];
      if (userJson is Map) {
        final user = InteractionUserBrief.fromJson(
          userJson.cast<String, dynamic>(),
        );
        _showEntrance(user, decoded['effect']?.toString() ?? '');
      }
    }
    if (type == 'error') {
      _showMessage(_chatError(decoded['error']?.toString() ?? ''));
    }
  }

  void _resetHistoryCursor(List<ChatMessage> messages) {
    _oldestMessageId = messages.isEmpty ? 0 : messages.first.id;
    _hasMoreHistoryMessages = messages.length >= _chatHistoryPageSize;
  }

  void _extendHistoryCursor(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    final oldest = messages.first.id;
    if (_oldestMessageId == 0 || oldest < _oldestMessageId) {
      _oldestMessageId = oldest;
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlderMessages ||
        !_hasMoreHistoryMessages ||
        _oldestMessageId <= 1) {
      return;
    }
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn || auth.token.isEmpty) return;

    _isLoadingOlderMessages = true;
    try {
      final olderMessages = await _service.fetchChatRoomMessages(
        roomId: widget.roomId,
        token: auth.token,
        beforeId: _oldestMessageId,
        pageSize: _chatHistoryPageSize,
      );
      if (!mounted) return;

      _hasMoreHistoryMessages = olderMessages.length >= _chatHistoryPageSize;
      final uniqueMessages =
          olderMessages
              .where(
                (message) => !_messageById.containsKey(message.id.toString()),
              )
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      if (uniqueMessages.isEmpty) return;

      _extendHistoryCursor(uniqueMessages);
      final chatMessages = uniqueMessages.map(_toChatUiMessage).toList();
      await _chatController.insertAllMessages(
        chatMessages,
        index: 0,
        animated: false,
      );
    } catch (_) {
      // Keep pagination quiet; the next pull can retry.
    } finally {
      _isLoadingOlderMessages = false;
    }
  }

  Future<void> _setHistoryMessages(List<chat_core.Message> messages) async {
    await _chatController.setMessages(messages, animated: false);
    if (messages.isNotEmpty) _jumpToLatestAfterHistory();
  }

  void _jumpToLatestAfterHistory({int attempts = 6}) {
    if (!mounted || attempts <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_messageScrollController.hasClients) {
        final position = _messageScrollController.position;
        final target = position.maxScrollExtent;
        if (target > position.minScrollExtent) {
          _messageScrollController.jumpTo(target);
        }
      }
      if (attempts > 1) {
        Future<void>.delayed(const Duration(milliseconds: 32), () {
          _jumpToLatestAfterHistory(attempts: attempts - 1);
        });
      }
    });
  }

  void _showEntrance(InteractionUserBrief user, String effect) {
    if (!mounted || effect != 'lv7') return;
    final notice = _ChatEntranceNotice(user: user, serial: ++_entranceSerial);
    if (_entranceNotice != null) {
      setState(() => _entranceQueue.add(notice));
      return;
    }
    setState(() => _entranceNotice = notice);
    _scheduleNextEntranceNotice();
  }

  void _scheduleNextEntranceNotice() {
    _entranceTimer?.cancel();
    _entranceTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      setState(() {
        _entranceNotice = _entranceQueue.isEmpty
            ? null
            : _entranceQueue.removeAt(0);
      });
      if (_entranceNotice != null) _scheduleNextEntranceNotice();
    });
  }

  chat_core.Message _toChatUiMessage(ChatMessage message) {
    final id = message.id.toString();
    final authorId = message.user.id.toString();
    _messageById[id] = message;
    _rememberChatUser(message.user);
    final createdAt = _parseChatServerTime(message.createdAt);
    if (message.type == 'image' && message.mediaUrl.isNotEmpty) {
      return chat_core.ImageMessage(
        id: id,
        authorId: authorId,
        createdAt: createdAt,
        sentAt: createdAt,
        source: message.mediaUrl,
        text: message.content,
      );
    }
    if (message.type == 'audio' && message.mediaUrl.isNotEmpty) {
      return chat_core.AudioMessage(
        id: id,
        authorId: authorId,
        createdAt: createdAt,
        sentAt: createdAt,
        source: message.mediaUrl,
        duration: _chatAudioDuration(message.content),
        text: message.content,
      );
    }

    final text = message.type == 'sticker'
        ? _stickerById(message.content).emoji
        : message.content;
    return chat_core.TextMessage(
      id: id,
      authorId: authorId,
      createdAt: createdAt,
      sentAt: createdAt,
      text: text,
    );
  }

  void _rememberChatUser(InteractionUserBrief user) {
    final authorId = user.id.toString();
    _chatUsers[authorId] = chat_core.User(
      id: authorId,
      name: user.nickname,
      imageSource: user.avatarUrl.isEmpty ? null : user.avatarUrl,
    );
  }

  void _handleInputChanged() {
    final next = _controller.text.trim().isNotEmpty;
    final mentionRange = _currentMentionRange();
    final nextMentionQuery = mentionRange == null
        ? ''
        : _controller.text.substring(mentionRange.start + 1, mentionRange.end);
    final nextShowMention =
        mentionRange != null && _isJoinedRoom && !_voiceInputMode;
    if (nextShowMention &&
        _roomInfoForDisplay().members.isEmpty &&
        !_isLoadingRoomSnapshot) {
      unawaited(_loadRoomSnapshot(showError: false));
    }
    if (next == _hasDraft &&
        nextMentionQuery == _mentionQuery &&
        nextShowMention == _showMentionSuggestions) {
      return;
    }
    setState(() {
      _hasDraft = next;
      _mentionQuery = nextMentionQuery;
      _showMentionSuggestions = nextShowMention;
    });
  }

  TextRange? _currentMentionRange() {
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final cursor = selection.baseOffset;
    if (cursor < 0 || cursor > _controller.text.length) return null;
    final prefix = _controller.text.substring(0, cursor);
    final at = prefix.lastIndexOf('@');
    if (at < 0) return null;
    final query = prefix.substring(at + 1);
    if (query.length > 24 || RegExp(r'[\s，,。.!！?？：:]').hasMatch(query)) {
      return null;
    }
    return TextRange(start: at, end: cursor);
  }

  List<ChatRoomMember> get _mentionSuggestions {
    if (!_showMentionSuggestions) return const [];
    final query = _mentionQuery.trim().toLowerCase();
    final members = _roomInfoForDisplay().members;
    if (members.isEmpty) return const [];
    final seen = <int>{};
    final filtered = <ChatRoomMember>[];
    for (final member in members) {
      if (member.id <= 0 || !seen.add(member.id)) continue;
      final nickname = member.nickname.trim();
      if (nickname.isEmpty) continue;
      if (query.isNotEmpty && !nickname.toLowerCase().contains(query)) {
        continue;
      }
      filtered.add(member);
    }
    filtered.sort((a, b) {
      if (a.isBot != b.isBot) return a.isBot ? -1 : 1;
      if (a.online != b.online) return a.online ? -1 : 1;
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.nickname.compareTo(b.nickname);
    });
    return filtered.take(8).toList();
  }

  void _insertMention(String nickname) {
    final clean = nickname.trim().isEmpty ? '用户' : nickname.trim();
    final mention = '@$clean ';
    final range = _currentMentionRange();
    final selection = _controller.selection;
    final text = _controller.text;
    final start =
        range?.start ?? (selection.isValid ? selection.start : text.length);
    final end = range?.end ?? (selection.isValid ? selection.end : text.length);
    final safeStart = start.clamp(0, text.length).toInt();
    final safeEnd = end.clamp(safeStart, text.length).toInt();
    final needsLeadingSpace =
        safeStart > 0 && !RegExp(r'\s').hasMatch(text[safeStart - 1]);
    final insertText = needsLeadingSpace ? ' $mention' : mention;
    final nextText = text.replaceRange(safeStart, safeEnd, insertText);
    final nextOffset = safeStart + insertText.length;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    if (_voiceInputMode) setState(() => _voiceInputMode = false);
    setState(() {
      _mentionQuery = '';
      _showMentionSuggestions = false;
      _hasDraft = nextText.trim().isNotEmpty;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }
}
