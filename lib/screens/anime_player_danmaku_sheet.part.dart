part of 'anime_player_screen.dart';

class _DanmakuSheet extends StatefulWidget {
  const _DanmakuSheet({
    required this.service,
    required this.videoId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.currentTimeMs,
    required this.settings,
    required this.onSettingsChanged,
    required this.onDanmakuSent,
  });

  final InteractionService service;
  final String videoId;
  final String animeId;
  final String animeTitle;
  final String episodeId;
  final String episodeTitle;
  final int Function() currentTimeMs;
  final _DanmakuDisplaySettings settings;
  final ValueChanged<_DanmakuDisplaySettings> onSettingsChanged;
  final ValueChanged<InteractionDanmaku> onDanmakuSent;

  @override
  State<_DanmakuSheet> createState() => _DanmakuSheetState();
}

class _DanmakuSheetState extends State<_DanmakuSheet> {
  final TextEditingController _controller = TextEditingController();

  List<InteractionDanmaku> _items = const [];
  bool _isLoading = true;
  bool _isSending = false;
  late _DanmakuDisplaySettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final items = await widget.service.fetchDanmaku(
        videoId: widget.videoId,
        animeId: widget.animeId,
        animeTitle: widget.animeTitle,
        episodeId: widget.episodeId,
        episodeTitle: widget.episodeTitle,
      );
      if (!mounted) return;
      setState(() => _items = items);
    } catch (_) {
      if (mounted) _showMessage('弹幕加载失败');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
        color: _danmakuColorHex(_settings.color),
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, item]
          ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
        _controller.clear();
      });
      widget.onDanmakuSent(item);
    } catch (_) {
      if (mounted) _showMessage('弹幕发送失败');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final isLandscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: SizedBox(
          height:
              MediaQuery.sizeOf(context).height * (isLandscape ? 0.86 : 0.68),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '弹幕',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _isLoading ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              _buildSettingsPanel(),
              const SizedBox(height: 8),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _items.isEmpty
                    ? const InteractionEmptyState(
                        icon: Icons.subtitles_outlined,
                        title: '还没有弹幕',
                        subtitle: '发出一条，会按当前播放进度出现在画面上',
                      )
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 16),
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.content),
                            subtitle: Text(
                              '${_formatDanmakuTime(item.timeMs)} · ${item.user.nickname}',
                            ),
                          );
                        },
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: auth.isLoggedIn ? '发一条弹幕' : '登录后发弹幕',
                        filled: true,
                        fillColor: Colors.white,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppTheme.dividerColor,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppTheme.dividerColor,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 42,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _isSending ? null : _send,
                      icon: Icon(
                        auth.isLoggedIn ? Icons.send : Icons.login,
                        size: 17,
                      ),
                      label: Text(auth.isLoggedIn ? '发送' : '登录'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.tune_outlined,
                  color: AppTheme.primaryColor,
                  size: 17,
                ),
              ),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  '弹幕设置',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              Switch.adaptive(
                value: _settings.enabled,
                onChanged: (value) =>
                    _updateSettings(_settings.copyWith(enabled: value)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Opacity(
            opacity: _settings.enabled ? 1 : 0.42,
            child: IgnorePointer(
              ignoring: !_settings.enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAreaSelector(),
                  const SizedBox(height: 12),
                  _buildColorSelector(),
                  const SizedBox(height: 8),
                  _SettingSlider(
                    label: '透明度',
                    value: _settings.opacity,
                    min: 0.2,
                    max: 1,
                    display: '${(_settings.opacity * 100).round()}%',
                    onChanged: (value) =>
                        _updateSettings(_settings.copyWith(opacity: value)),
                  ),
                  const SizedBox(height: 4),
                  _SettingSlider(
                    label: '字号',
                    value: _settings.fontSize,
                    min: 12,
                    max: 22,
                    display: _settings.fontSize.round().toString(),
                    onChanged: (value) =>
                        _updateSettings(_settings.copyWith(fontSize: value)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAreaSelector() {
    const options = [(0.25, '1/4'), (0.5, '半屏'), (0.75, '3/4'), (1.0, '全屏')];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '显示区域',
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((entry) {
            final selected = (_settings.area - entry.$1).abs() < 0.01;
            return ChoiceChip(
              label: SizedBox(
                width: 50,
                child: Text(entry.$2, textAlign: TextAlign.center),
              ),
              selected: selected,
              showCheckmark: false,
              selectedColor: AppTheme.primaryColor.withValues(alpha: 0.12),
              side: BorderSide(
                color: selected ? AppTheme.primaryColor : AppTheme.dividerColor,
              ),
              labelStyle: TextStyle(
                color: selected ? AppTheme.primaryColor : AppTheme.textPrimary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
              onSelected: (_) =>
                  _updateSettings(_settings.copyWith(area: entry.$1)),
              visualDensity: VisualDensity.compact,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildColorSelector() {
    const colors = [
      Colors.white,
      Color(0xFFFFF176),
      Color(0xFF64B5F6),
      Color(0xFFFF8A80),
      Color(0xFF81C784),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '弹幕颜色',
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: colors.map((color) {
            final selected = color.toARGB32() == _settings.color.toARGB32();
            final checkColor = color == Colors.white
                ? AppTheme.primaryColor
                : Colors.white;
            return InkWell(
              onTap: () => _updateSettings(_settings.copyWith(color: color)),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? AppTheme.primaryColor
                        : AppTheme.dividerColor,
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                child: selected
                    ? Icon(Icons.check, size: 16, color: checkColor)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  void _updateSettings(_DanmakuDisplaySettings settings) {
    setState(() => _settings = settings);
    widget.onSettingsChanged(settings);
  }

  String _formatDanmakuTime(int ms) {
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
