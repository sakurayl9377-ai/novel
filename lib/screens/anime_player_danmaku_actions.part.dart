part of 'anime_player_screen.dart';

class _DanmakuControlSheet extends StatelessWidget {
  const _DanmakuControlSheet({
    required this.count,
    required this.enabled,
    required this.episodeTitle,
    required this.onEnabledChanged,
    required this.onCompose,
    required this.onSettings,
  });

  final int count;
  final bool enabled;
  final String episodeTitle;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onCompose;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final dark = isLandscape || Theme.of(context).brightness == Brightness.dark;
    final textColor = dark ? Colors.white : AppTheme.textPrimary;
    final mutedColor = dark ? Colors.white70 : AppTheme.textSecondary;
    final background = dark ? const Color(0xEE191A22) : Colors.white;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isLandscape ? 28 : 12,
          10,
          isLandscape ? 28 : 12,
          MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: Align(
          alignment: isLandscape
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isLandscape ? 430 : 560),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: dark ? Colors.white12 : AppTheme.dividerColor,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(
                              alpha: 0.14,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.subtitles_rounded,
                            color: AppTheme.primaryColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                episodeTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$count 条 · ${enabled ? '画面显示' : '已关闭'}',
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: enabled,
                          onChanged: onEnabledChanged,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              WidgetsBinding.instance.addPostFrameCallback(
                                (_) => onCompose(),
                              );
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('发弹幕'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => onSettings(),
                            );
                          },
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: const Text('设置'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DanmakuComposerSheet extends StatefulWidget {
  const _DanmakuComposerSheet({
    required this.service,
    required this.videoId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.currentTimeMs,
    required this.color,
    required this.onDanmakuSent,
  });

  final InteractionService service;
  final String videoId;
  final String animeId;
  final String animeTitle;
  final String episodeId;
  final String episodeTitle;
  final int Function() currentTimeMs;
  final String color;
  final ValueChanged<InteractionDanmaku> onDanmakuSent;

  @override
  State<_DanmakuComposerSheet> createState() => _DanmakuComposerSheetState();
}

class _DanmakuComposerSheetState extends State<_DanmakuComposerSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
      );
      return;
    }

    final content = _controller.text.trim();
    if (content.isEmpty) {
      _showMessage('请输入弹幕内容');
      return;
    }

    setState(() => _isSending = true);
    try {
      final item = await widget.service.postDanmaku(
        token: auth.token,
        videoId: widget.videoId,
        animeId: widget.animeId,
        animeTitle: widget.animeTitle,
        episodeId: widget.episodeId,
        episodeTitle: widget.episodeTitle,
        timeMs: widget.currentTimeMs(),
        content: content,
        color: widget.color,
      );
      if (!mounted) return;
      widget.onDanmakuSent(item);
      Navigator.pop(context);
    } catch (_) {
      if (mounted) _showMessage('弹幕发送失败');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildCompactComposer(context);
  }

  Widget _buildCompactComposer(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final media = MediaQuery.of(context);
    final isLandscape = media.size.width > media.size.height;
    final maxWidth = isLandscape ? 620.0 : 520.0;

    return Padding(
      padding: EdgeInsets.only(
        left: isLandscape ? 24 : 10,
        right: isLandscape ? 24 : 10,
        bottom: media.viewInsets.bottom + (isLandscape ? 18 : 10),
      ),
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xF0161820),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                  child: Row(
                    children: [
                      Tooltip(
                        message: '关闭',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.maybePop(context),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          autofocus: true,
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: auth.isLoggedIn ? '发一条友善的弹幕' : '登录后发弹幕',
                            hintStyle: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.10),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 11,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 40,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _isSending ? null : _send,
                          icon: Icon(
                            auth.isLoggedIn
                                ? Icons.send_rounded
                                : Icons.login_rounded,
                            size: 17,
                          ),
                          label: Text(auth.isLoggedIn ? '发送' : '登录'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
