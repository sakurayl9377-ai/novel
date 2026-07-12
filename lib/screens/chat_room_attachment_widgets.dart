part of 'chat_room_screen.dart';

class _ShareMessageCard extends StatelessWidget {
  const _ShareMessageCard({
    required this.share,
    required this.note,
    required this.isSentByMe,
    required this.chatBubble,
  });

  final Map<String, dynamic> share;
  final String note;
  final bool isSentByMe;
  final String chatBubble;

  @override
  Widget build(BuildContext context) {
    final title = _stringOf(share['title']);
    final subtitle = _stringOf(share['subtitle']);
    final coverUrl = _stringOf(share['coverUrl']);
    final cleanNote = note.trim() == title ? '' : note.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isSentByMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (cleanNote.isNotEmpty) ...[
          _ShareNoteBubble(
            text: cleanNote,
            isSentByMe: isSentByMe,
            chatBubble: chatBubble,
          ),
          const SizedBox(height: 7),
        ],
        InkWell(
          onTap: () => _openSharedItem(context, share),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 250),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.dividerColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                _ShareCover(url: coverUrl, size: 56),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        subtitle.isEmpty ? '点击查看详情' : subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ShareNoteBubble extends StatelessWidget {
  const _ShareNoteBubble({
    required this.text,
    required this.isSentByMe,
    required this.chatBubble,
  });

  final String text;
  final bool isSentByMe;
  final String chatBubble;

  @override
  Widget build(BuildContext context) {
    final bubbleColors = chatBubble.isEmpty
        ? null
        : _chatBubbleColors(chatBubble);
    final hasCustomBubble = bubbleColors != null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: hasCustomBubble
            ? null
            : isSentByMe
            ? AppTheme.primaryColor
            : Colors.white,
        gradient: hasCustomBubble
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bubbleColors,
              )
            : null,
        borderRadius: BorderRadius.circular(8),
        border: isSentByMe || hasCustomBubble
            ? null
            : Border.all(color: AppTheme.dividerColor),
        boxShadow: hasCustomBubble
            ? [
                BoxShadow(
                  color: bubbleColors.last.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isSentByMe || hasCustomBubble
              ? Colors.white
              : AppTheme.textPrimary,
          fontSize: 16,
          height: 1.32,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FileMessageCard extends StatelessWidget {
  const _FileMessageCard({required this.file, required this.isSentByMe});

  final Map<String, dynamic> file;
  final bool isSentByMe;

  @override
  Widget build(BuildContext context) {
    final name = _stringOf(file['name']).isEmpty
        ? '文件'
        : _stringOf(file['name']);
    final size = _intOf(file['size']);
    return Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSentByMe ? AppTheme.primaryColor : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: isSentByMe ? null : Border.all(color: AppTheme.dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            color: isSentByMe ? Colors.white : AppTheme.primaryColor,
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSentByMe ? Colors.white : AppTheme.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (size > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    _formatFileSize(size),
                    style: TextStyle(
                      color: isSentByMe
                          ? Colors.white.withValues(alpha: 0.78)
                          : AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyQuoteBlock extends StatelessWidget {
  const _ReplyQuoteBlock({required this.reply, required this.light});

  final Map<String, dynamic> reply;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: light
            ? Colors.white.withValues(alpha: 0.18)
            : const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${_stringOf(reply['nickname'])}: ${_stringOf(reply['content'])}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: light
              ? Colors.white.withValues(alpha: 0.86)
              : AppTheme.textHint,
          fontSize: 12,
          height: 1.25,
        ),
      ),
    );
  }
}

class _ShareCover extends StatelessWidget {
  const _ShareCover({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFEAF1FA),
        child: url.isEmpty
            ? const Icon(Icons.menu_book_outlined, color: AppTheme.primaryColor)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.menu_book_outlined,
                  color: AppTheme.primaryColor,
                ),
              ),
      ),
    );
  }
}

class _ChatImageMessage extends StatelessWidget {
  const _ChatImageMessage({required this.message, required this.isSentByMe});

  final chat_core.ImageMessage message;
  final bool isSentByMe;

  @override
  Widget build(BuildContext context) {
    final caption = message.text?.trim() ?? '';
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isSentByMe ? AppTheme.primaryColor : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: isSentByMe ? null : Border.all(color: AppTheme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              message.source,
              width: 204,
              height: 128,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 204,
                height: 128,
                color: const Color(0xFFE9EDF3),
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              caption,
              style: TextStyle(
                color: isSentByMe ? Colors.white : AppTheme.textPrimary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
