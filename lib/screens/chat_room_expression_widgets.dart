part of 'chat_room_screen.dart';

class _ChatExpressionResult {
  const _ChatExpressionResult.emoji(this.emoji) : sticker = null;

  const _ChatExpressionResult.sticker(_ChatSticker value)
    : emoji = '',
      sticker = value;

  final String emoji;
  final _ChatSticker? sticker;
}

class _ChatExpressionPanel extends StatelessWidget {
  const _ChatExpressionPanel({required this.canSendStickers});

  final bool canSendStickers;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height < 720 ? 314.0 : 360.0;
    return DefaultTabController(
      length: 1 + _chatStickerPacks.length,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: AppTheme.primaryColor,
                unselectedLabelColor: AppTheme.textSecondary,
                indicatorColor: AppTheme.primaryColor,
                dividerColor: AppTheme.dividerColor,
                labelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
                tabs: [
                  const Tab(text: 'Emoji'),
                  for (final pack in _chatStickerPacks) Tab(text: pack.label),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    const _EmojiGrid(),
                    for (final pack in _chatStickerPacks)
                      _StickerPackGrid(
                        pack: pack,
                        canSendStickers: canSendStickers,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
      itemCount: _chatEmojiItems.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemBuilder: (context, index) {
        final emoji = _chatEmojiItems[index];
        return InkWell(
          onTap: () =>
              Navigator.pop(context, _ChatExpressionResult.emoji(emoji)),
          borderRadius: BorderRadius.circular(8),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 26, height: 1)),
          ),
        );
      },
    );
  }
}

class _StickerPackGrid extends StatelessWidget {
  const _StickerPackGrid({required this.pack, required this.canSendStickers});

  final _ChatStickerPack pack;
  final bool canSendStickers;

  @override
  Widget build(BuildContext context) {
    if (!canSendStickers) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              color: AppTheme.textHint,
              size: 34,
            ),
            SizedBox(height: 10),
            Text(
              'Lv4 解锁表情包快捷发送',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      itemCount: pack.stickers.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.84,
      ),
      itemBuilder: (context, index) {
        final sticker = pack.stickers[index];
        return InkWell(
          onTap: () =>
              Navigator.pop(context, _ChatExpressionResult.sticker(sticker)),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9FC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ChatStickerPreview(sticker: sticker, size: 58),
                const SizedBox(height: 7),
                Text(
                  sticker.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChatStickerPreview extends StatelessWidget {
  const _ChatStickerPreview({required this.sticker, required this.size});

  final _ChatSticker sticker;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (sticker.assetPath.isNotEmpty) {
      return SvgPicture.asset(
        sticker.assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          sticker.emoji,
          style: TextStyle(fontSize: size * 0.58, height: 1),
        ),
      ),
    );
  }
}
