part of 'chat_room_screen.dart';

class _ChatSticker {
  const _ChatSticker(
    this.id,
    this.label,
    this.emoji,
    this.icon, {
    this.assetPath = '',
  });

  final String id;
  final String label;
  final String emoji;
  final IconData icon;
  final String assetPath;
}

class _ChatStickerPack {
  const _ChatStickerPack({
    required this.id,
    required this.label,
    required this.stickers,
  });

  final String id;
  final String label;
  final List<_ChatSticker> stickers;
}

class _UploadedChatMedia {
  const _UploadedChatMedia({
    required this.url,
    required this.name,
    required this.size,
  });

  final String url;
  final String name;
  final int size;
}

class _PendingChatAttachment {
  const _PendingChatAttachment._({this.share, this.reply});

  factory _PendingChatAttachment.share(FavoriteItem item) {
    return _PendingChatAttachment._(share: item);
  }

  factory _PendingChatAttachment.reply(ChatMessage message) {
    return _PendingChatAttachment._(
      reply: _PendingReply(
        messageId: message.id,
        userId: message.user.id,
        nickname: message.user.nickname,
        content: message.type == 'sticker'
            ? _stickerById(message.content).emoji
            : message.content,
      ),
    );
  }

  final FavoriteItem? share;
  final _PendingReply? reply;

  String get fallbackText {
    final shareItem = share;
    if (shareItem != null) return shareItem.title;
    final replyItem = reply;
    if (replyItem != null) return replyItem.content;
    return '';
  }

  Map<String, dynamic> toMetadata() {
    final shareItem = share;
    final replyItem = reply;
    return {
      if (shareItem != null)
        'share': {
          'type': shareItem.type.value,
          'itemId': shareItem.itemId,
          'title': shareItem.title,
          'subtitle': shareItem.subtitle,
          'coverUrl': shareItem.coverUrl,
        },
      if (replyItem != null)
        'reply': {
          'messageId': replyItem.messageId,
          'userId': replyItem.userId,
          'nickname': replyItem.nickname,
          'content': replyItem.content,
        },
    };
  }
}

class _PendingReply {
  const _PendingReply({
    required this.messageId,
    required this.userId,
    required this.nickname,
    required this.content,
  });

  final int messageId;
  final int userId;
  final String nickname;
  final String content;
}

String _libraryTypeLabel(LibraryItemType type) {
  return switch (type) {
    LibraryItemType.novel => '小说',
    LibraryItemType.anime => '动漫',
    LibraryItemType.manga => '漫画',
  };
}

String _stringOf(dynamic value) => value?.toString().trim() ?? '';

int _intOf(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _messageSearchPreview(ChatMessage message) {
  final content = message.content.trim();
  return switch (message.type) {
    'image' => content.isEmpty ? '[图片]' : '[图片] $content',
    'audio' => content.isEmpty ? '[语音]' : '[语音] $content',
    'sticker' => '[表情] ${_stickerById(content).emoji}',
    _ => content.isEmpty ? '[消息]' : content,
  };
}

Duration _chatAudioDuration(String? text) {
  final match = RegExp(r'(\d{1,3})').firstMatch(text ?? '');
  final seconds = int.tryParse(match?.group(1) ?? '') ?? 1;
  return Duration(seconds: seconds.clamp(1, 60));
}

String _chatAudioTranscript(String? text) {
  final raw = (text ?? '').trim();
  if (raw.isEmpty) return '';
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length <= 1) return '';
  final first = lines.first;
  if (RegExp(r'\d{1,3}"?\s*语音|语音消息').hasMatch(first)) {
    return lines.skip(1).join('\n').trim();
  }
  return '';
}

bool _chatMemberIsOnline(ChatRoomMember member, int currentUserId) {
  return member.isBot ||
      member.online ||
      (currentUserId > 0 && member.id == currentUserId);
}

String _formatFileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

DateTime? _parseChatServerTime(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return null;
  final normalized = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
  final hasTimezone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(normalized);
  final parsed = DateTime.tryParse(hasTimezone ? normalized : '${normalized}Z');
  return parsed?.toLocal();
}

void _openSharedItem(BuildContext context, Map<String, dynamic> share) {
  final type = _stringOf(share['type']);
  final itemId = _stringOf(share['itemId']);
  final title = _stringOf(share['title']);
  if (type == LibraryItemType.novel.value) {
    final query = _stringOf(share['query']).isNotEmpty
        ? _stringOf(share['query'])
        : title.isNotEmpty
        ? title
        : itemId;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          autofocus: false,
          initialKeyword: query,
          autoOpenFirst: share['autoOpenFirst'] == true,
        ),
      ),
    );
    return;
  }
  if (type == LibraryItemType.anime.value) {
    final id = int.tryParse(itemId) ?? 0;
    if (id > 0) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnimeDetailScreen(animeId: id, title: title),
        ),
      );
      return;
    }
  }
  if (type == LibraryItemType.manga.value && itemId.isNotEmpty) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaDetailScreen(mangaId: itemId, title: title),
      ),
    );
  }
}

_ChatSticker _stickerById(String id) {
  return _allChatStickers.firstWhere(
    (item) => item.id == id,
    orElse: () => const _ChatSticker(
      'sakura_smile',
      '樱花笑',
      '🌸',
      Icons.local_florist_outlined,
    ),
  );
}

Iterable<_ChatSticker> get _allChatStickers sync* {
  yield* _legacyChatStickers;
  for (final pack in _chatStickerPacks) {
    yield* pack.stickers;
  }
}

_VoiceReleaseAction _voiceActionForPosition(
  BuildContext context,
  Offset globalPosition,
) {
  final size = MediaQuery.sizeOf(context);
  final zoneTop = size.height - 245;
  final zoneBottom = size.height - 82;
  final inDropZone =
      globalPosition.dy >= zoneTop && globalPosition.dy <= zoneBottom;
  if (!inDropZone) return _VoiceReleaseAction.send;
  if (globalPosition.dx < size.width / 2) return _VoiceReleaseAction.cancel;
  return _VoiceReleaseAction.transcribe;
}

String _formatChatMessageTime(DateTime? value) {
  final time = value?.toLocal() ?? DateTime.now();
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

List<Color> _chatBubbleColors(String value) {
  return switch (value) {
    'night_sakura' => const [Color(0xFF3B2B67), Color(0xFFFF7AAD)],
    'sakura_pink' => const [Color(0xFFFF8AB6), Color(0xFFFFB7D1)],
    'moon_blue' => const [Color(0xFF4F7DFF), Color(0xFF8A6DFF)],
    'mint_leaf' => const [Color(0xFF00BFA5), Color(0xFF7BE7C7)],
    'gold_aurora' => const [Color(0xFFFFB84D), Color(0xFFFF6F91)],
    _ => const [AppTheme.primaryColor, Color(0xFF65A9FF)],
  };
}
