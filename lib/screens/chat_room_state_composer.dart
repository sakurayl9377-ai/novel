part of 'chat_room_screen.dart';

abstract class _ChatRoomComposerState extends _ChatRoomConnectionState {
  bool _hasCompleteChatProfile(InteractionUser? user) {
    if (user == null) return false;
    final nickname = user.nickname.trim();
    final defaultNickname = user.email.split('@').first.trim();
    return nickname.isNotEmpty &&
        nickname != '用户' &&
        nickname != defaultNickname;
  }

  Future<bool> _ensureCanChat() async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
      );
      if (!mounted || !context.read<InteractionAuthProvider>().isLoggedIn) {
        return false;
      }
    }
    final latestAuth = context.read<InteractionAuthProvider>();
    if (_hasCompleteChatProfile(latestAuth.user)) return true;
    final updated = await _openProfileSetup();
    return updated && mounted && _hasCompleteChatProfile(latestAuth.user);
  }

  Future<bool> _openProfileSetup() async {
    final auth = context.read<InteractionAuthProvider>();
    final user = auth.user;
    if (user == null) return false;
    final nicknameController = TextEditingController(
      text: user.nickname == user.email.split('@').first ? '' : user.nickname,
    );
    final avatarController = TextEditingController(text: user.avatarUrl);
    var isSaving = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.viewInsetsOf(context).bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '设置昵称后发言',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '新用户会使用默认头像，发言前只需要设置一个非默认昵称。',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nicknameController,
                    textInputAction: TextInputAction.next,
                    decoration: interactionInputDecoration(
                      hintText: '设置昵称',
                      icon: Icons.badge_outlined,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: avatarController,
                    keyboardType: TextInputType.url,
                    decoration: interactionInputDecoration(
                      hintText: '头像图片 URL（可选）',
                      icon: Icons.image_outlined,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton.icon(
                      onPressed: isSaving
                          ? null
                          : () async {
                              final nickname = nicknameController.text.trim();
                              final avatarUrl = avatarController.text.trim();
                              final defaultNickname = user.email
                                  .split('@')
                                  .first
                                  .trim();
                              if (nickname.isEmpty ||
                                  nickname == defaultNickname) {
                                _showMessage('请设置非默认昵称后再发言');
                                return;
                              }
                              setSheetState(() => isSaving = true);
                              try {
                                final profile = await _service.updateMyProfile(
                                  token: auth.token,
                                  nickname: nickname,
                                  avatarUrl: avatarUrl,
                                  gender: user.gender,
                                  bio: user.bio,
                                  signature: user.signature,
                                  spaceTitle: user.spaceTitle,
                                  profileBannerUrl: user.profileBannerUrl,
                                  dynamicAvatarUrl: user.dynamicAvatarUrl,
                                  profileTheme: user.profileTheme,
                                  privacyMode: user.privacyMode,
                                );
                                await auth.updateCachedUser(profile.user);
                                if (context.mounted) {
                                  Navigator.pop(context, true);
                                }
                              } catch (_) {
                                if (mounted) _showMessage('资料保存失败');
                              } finally {
                                if (context.mounted) {
                                  setSheetState(() => isSaving = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('保存并发言'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    nicknameController.dispose();
    avatarController.dispose();
    return saved == true;
  }

  Future<bool> _send({
    String type = 'text',
    String content = '',
    String mediaUrl = '',
    Map<String, dynamic>? metadata,
  }) async {
    if (!await _ensureCanChat()) return false;
    final attachment = _pendingAttachment;
    final outgoingMetadata = <String, dynamic>{
      ...?metadata,
      ...?attachment?.toMetadata(),
    };
    final text = content.isEmpty ? _controller.text.trim() : content.trim();
    final fallbackText = attachment?.fallbackText ?? '';
    final messageText = text.isEmpty ? fallbackText : text;
    final url = mediaUrl.trim();
    if (messageText.isEmpty && outgoingMetadata.isEmpty) return false;
    if ((type == 'image' || type == 'audio') && url.isEmpty) return false;
    _channel?.sink.add(
      jsonEncode({
        'type': type,
        'content': messageText,
        if (url.isNotEmpty) 'mediaUrl': url,
        if (outgoingMetadata.isNotEmpty) 'metadata': outgoingMetadata,
      }),
    );
    if (attachment != null && mounted) {
      setState(() => _pendingAttachment = null);
    }
    return true;
  }

  Future<void> _sendText() async {
    final content = _controller.text.trim();
    if (content.isEmpty && _pendingAttachment == null) return;
    final type = _pendingAttachment?.share == null ? 'text' : 'share';
    final sent = await _send(type: type, content: content);
    if (sent) _controller.clear();
  }

  Future<void> _openImageSender() async {
    if (!await _ensureCanChat()) return;
    if (!mounted) return;
    final user = context.read<InteractionAuthProvider>().user;
    if (user?.growth.privileges.chatImages != true) {
      _showMessage('Lv3 解锁聊天室图片消息');
      return;
    }
    final uploaded = await _pickAndUploadChatMedia(
      kind: 'chatImage',
      label: '图片',
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
      mimeResolver: _imageMimeType,
    );
    if (uploaded == null) return;
    await _send(type: 'image', content: '分享了一张图片', mediaUrl: uploaded.url);
  }

  Future<void> _openMorePanel() async {
    if (!await _ensureCanChat()) return;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 4,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.9,
            children: [
              _ChatPanelAction(
                icon: Icons.image_outlined,
                label: '图片',
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openImageSender());
                },
              ),
              _ChatPanelAction(
                icon: Icons.attach_file_rounded,
                label: '文件',
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openFileSender());
                },
              ),
              _ChatPanelAction(
                icon: Icons.ios_share_rounded,
                label: '分享',
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openFavoriteSharePicker());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFileSender() async {
    final uploaded = await _pickAndUploadChatMedia(
      kind: 'chatFile',
      label: '文件',
      allowedExtensions: const ['pdf', 'txt', 'zip'],
      mimeResolver: _fileMimeType,
    );
    if (uploaded == null) return;
    await _send(
      type: 'file',
      content: uploaded.name,
      mediaUrl: uploaded.url,
      metadata: {
        'file': {
          'name': uploaded.name,
          'url': uploaded.url,
          'size': uploaded.size,
        },
      },
    );
  }

  Future<void> _openFavoriteSharePicker() async {
    final items = await _storageService.getFavoriteItems();
    if (!mounted) return;
    if (items.isEmpty) {
      _showMessage('收藏列表还是空的');
      return;
    }
    final selected = await showModalBottomSheet<FavoriteItem>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          itemCount: items.length + 1,
          separatorBuilder: (_, index) =>
              index == 0 ? const SizedBox(height: 8) : const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Text(
                '选择要分享的收藏',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              );
            }
            final item = items[index - 1];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _ShareCover(url: item.coverUrl, size: 46),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                item.subtitle.isEmpty
                    ? _libraryTypeLabel(item.type)
                    : item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, item),
            );
          },
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _pendingAttachment = _PendingChatAttachment.share(selected));
  }

  // ignore: unused_element
  Future<void> _openVoiceFileSender() async {
    final uploaded = await _pickAndUploadChatMedia(
      kind: 'chatAudio',
      label: '语音',
      allowedExtensions: const ['aac', 'm4a', 'mp3', 'ogg', 'wav', 'webm'],
      mimeResolver: _audioMimeType,
    );
    if (uploaded == null) return;
    await _send(type: 'audio', content: '语音消息', mediaUrl: uploaded.url);
  }

  void _toggleVoiceInputMode() {
    if (_isSendingVoice || _isRecordingVoice) return;
    setState(() => _voiceInputMode = !_voiceInputMode);
    if (_voiceInputMode) {
      _inputFocusNode.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }

  void _setVoiceReleaseAction(_VoiceReleaseAction action) {
    if (!_isRecordingVoice || action == _voiceReleaseAction) return;
    setState(() => _voiceReleaseAction = action);
  }

  Future<void> _startVoiceRecording() async {
    if (_isRecordingVoice || _isSendingVoice) return;
    if (!await _ensureCanChat()) return;
    if (!mounted) return;
    try {
      final hasPermission = await _voiceRecorder.hasPermission();
      if (!hasPermission) {
        _showMessage('请允许麦克风权限后再发送语音');
        return;
      }
      final supported = await _voiceRecorder.isEncoderSupported(
        AudioEncoder.wav,
      );
      if (!supported) {
        _showMessage('当前设备不支持语音录制');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}chat_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _voiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          bitRate: 256000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _isRecordingVoice = true;
        _isSendingVoice = false;
        _voiceReleaseAction = _VoiceReleaseAction.send;
        _voiceRecordSeconds = 0;
        _voiceRecordStartedAt = DateTime.now();
      });
      _voiceTimer?.cancel();
      _voiceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _voiceRecordStartedAt;
        if (!mounted || startedAt == null) return;
        final seconds = DateTime.now().difference(startedAt).inSeconds;
        setState(() => _voiceRecordSeconds = seconds);
        if (seconds >= 60) unawaited(_finishVoiceRecording());
      });
    } catch (_) {
      if (mounted) _showMessage('语音录制启动失败');
    }
  }

  Future<void> _finishVoiceRecording([
    _VoiceReleaseAction action = _VoiceReleaseAction.send,
  ]) async {
    if (!_isRecordingVoice) return;
    final finalAction = _voiceReleaseAction == _VoiceReleaseAction.send
        ? action
        : _voiceReleaseAction;
    _voiceTimer?.cancel();
    final startedAt = _voiceRecordStartedAt;
    final elapsed = startedAt == null
        ? _voiceRecordSeconds
        : DateTime.now().difference(startedAt).inSeconds;
    final shouldUpload = finalAction != _VoiceReleaseAction.cancel;
    final token = shouldUpload
        ? context.read<InteractionAuthProvider>().token
        : '';
    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
        _isSendingVoice = shouldUpload;
        _voiceReleaseAction = _VoiceReleaseAction.send;
        _voiceRecordStartedAt = null;
      });
    }
    try {
      final path = await _voiceRecorder.stop();
      if (path == null || path.trim().isEmpty) {
        if (mounted) _showMessage('语音录制失败');
        return;
      }
      final file = File(path);
      if (!await file.exists()) {
        if (mounted) _showMessage('语音文件读取失败');
        return;
      }
      if (!shouldUpload) {
        unawaited(file.delete().catchError((_) => file));
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        if (mounted) _showMessage('语音文件为空');
        return;
      }
      if (elapsed < 1) {
        unawaited(file.delete().catchError((_) => file));
        if (mounted) _showMessage('录音时间太短');
        return;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        if (mounted) _showMessage('语音不能超过 5MB');
        return;
      }
      final url = await _service.uploadProfileImage(
        token: token,
        kind: 'chatAudio',
        bytes: bytes,
        mimeType: 'audio/wav',
      );
      unawaited(file.delete().catchError((_) => file));
      final seconds = elapsed < 1 ? 1 : elapsed;
      if (finalAction == _VoiceReleaseAction.transcribe) {
        final text = await _service.transcribeChatAudio(
          token: token,
          mediaUrl: url,
        );
        if (text.isEmpty) {
          if (mounted) _showMessage('没有识别到语音内容');
          await _send(type: 'audio', content: '$seconds" 语音', mediaUrl: url);
          return;
        }
        await _send(
          type: 'audio',
          content: '$seconds" 语音\n$text',
          mediaUrl: url,
        );
        return;
      }
      await _send(type: 'audio', content: '$seconds" 语音', mediaUrl: url);
    } catch (_) {
      if (mounted) _showMessage('语音发送失败');
    } finally {
      if (mounted) {
        setState(() {
          _isSendingVoice = false;
          _voiceReleaseAction = _VoiceReleaseAction.send;
          _voiceRecordSeconds = 0;
        });
      }
    }
  }

  Future<_UploadedChatMedia?> _pickAndUploadChatMedia({
    required String kind,
    required String label,
    required List<String> allowedExtensions,
    required String? Function(String) mimeResolver,
  }) async {
    if (!await _ensureCanChat()) return null;
    if (!mounted) return null;
    final token = context.read<InteractionAuthProvider>().token;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      final file = result.files.single;
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null || bytes.isEmpty) {
        _showMessage('$label文件读取失败');
        return null;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        _showMessage('$label不能超过 5MB');
        return null;
      }
      final mimeType = mimeResolver(file.extension ?? file.name);
      if (mimeType == null) {
        _showMessage('请选择支持的$label文件');
        return null;
      }
      final url = await _service.uploadProfileImage(
        token: token,
        kind: kind,
        bytes: bytes,
        mimeType: mimeType,
      );
      return _UploadedChatMedia(url: url, name: file.name, size: bytes.length);
    } catch (_) {
      if (mounted) _showMessage('$label上传失败');
      return null;
    }
  }

  String? _imageMimeType(String value) {
    final ext = value.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
  }

  String? _audioMimeType(String value) {
    final ext = value.split('.').last.toLowerCase();
    return switch (ext) {
      'aac' => 'audio/aac',
      'm4a' => 'audio/mp4',
      'mp3' => 'audio/mpeg',
      'ogg' => 'audio/ogg',
      'wav' => 'audio/wav',
      'webm' => 'audio/webm',
      _ => null,
    };
  }

  String? _fileMimeType(String value) {
    final ext = value.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'zip' => 'application/zip',
      _ => null,
    };
  }

  Future<void> _openStickerPicker() async {
    if (!await _ensureCanChat()) return;
    if (!mounted) return;
    final user = context.read<InteractionAuthProvider>().user;
    final result = await showModalBottomSheet<_ChatExpressionResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ChatExpressionPanel(
        canSendStickers: user?.growth.privileges.chatStickers == true,
      ),
    );
    if (result == null) return;
    final sticker = result.sticker;
    if (sticker != null) {
      await _send(type: 'sticker', content: sticker.id);
      return;
    }
    _insertEmoji(result.emoji);
  }

  void _insertEmoji(String emoji) {
    if (emoji.isEmpty) return;
    if (_voiceInputMode) setState(() => _voiceInputMode = false);
    final value = _controller.value;
    final text = value.text;
    final selection = value.selection;
    final rawStart = selection.isValid ? selection.start : text.length;
    final rawEnd = selection.isValid ? selection.end : text.length;
    final start = rawStart < rawEnd ? rawStart : rawEnd;
    final end = rawStart > rawEnd ? rawStart : rawEnd;
    final nextText = text.replaceRange(start, end, emoji);
    final nextOffset = start + emoji.length;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    _inputFocusNode.requestFocus();
  }
}
