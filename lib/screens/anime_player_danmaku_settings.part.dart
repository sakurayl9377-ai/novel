part of 'anime_player_screen.dart';

class _DanmakuSettingsBottomSheet extends StatelessWidget {
  const _DanmakuSettingsBottomSheet({
    required this.settings,
    required this.onSettingsChanged,
  });

  final _DanmakuDisplaySettings settings;
  final ValueChanged<_DanmakuDisplaySettings> onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
      ),
      child: SafeArea(
        child: _DanmakuSettingsSurface(
          dark: false,
          settings: settings,
          onSettingsChanged: onSettingsChanged,
        ),
      ),
    );
  }
}

class _DanmakuSettingsSurface extends StatelessWidget {
  const _DanmakuSettingsSurface({
    required this.dark,
    required this.settings,
    required this.onSettingsChanged,
  });

  final bool dark;
  final _DanmakuDisplaySettings settings;
  final ValueChanged<_DanmakuDisplaySettings> onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * (dark ? 0.9 : 0.78);
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xEE1D1E27) : Colors.white,
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
          child: _DanmakuSettingsEditor(
            dark: dark,
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
        ),
      ),
    );
  }
}

class _DanmakuSettingsEditor extends StatefulWidget {
  const _DanmakuSettingsEditor({
    required this.dark,
    required this.settings,
    required this.onSettingsChanged,
  });

  final bool dark;
  final _DanmakuDisplaySettings settings;
  final ValueChanged<_DanmakuDisplaySettings> onSettingsChanged;

  @override
  State<_DanmakuSettingsEditor> createState() => _DanmakuSettingsEditorState();
}

class _DanmakuSettingsEditorState extends State<_DanmakuSettingsEditor> {
  late _DanmakuDisplaySettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
  }

  @override
  void didUpdateWidget(covariant _DanmakuSettingsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      _settings = widget.settings;
    }
  }

  void _update(_DanmakuDisplaySettings settings) {
    setState(() => _settings = settings);
    widget.onSettingsChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.dark ? Colors.white : AppTheme.textPrimary;
    final mutedColor = widget.dark ? Colors.white70 : AppTheme.textSecondary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 15, 14, 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.tune_rounded,
                  color: AppTheme.primaryColor,
                  size: 19,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  '弹幕设置',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Switch.adaptive(
                value: _settings.enabled,
                onChanged: (value) =>
                    _update(_settings.copyWith(enabled: value)),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: Opacity(
              opacity: _settings.enabled ? 1 : 0.42,
              child: IgnorePointer(
                ignoring: !_settings.enabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAreaSlider(),
                    const SizedBox(height: 14),
                    _buildColorSelector(mutedColor),
                    const SizedBox(height: 14),
                    _SettingSlider(
                      label: '不透明度',
                      value: _settings.opacity,
                      min: 0.2,
                      max: 1,
                      display: '${(_settings.opacity * 100).round()}%',
                      dark: widget.dark,
                      onChanged: (value) =>
                          _update(_settings.copyWith(opacity: value)),
                    ),
                    const SizedBox(height: 4),
                    _SettingSlider(
                      label: '字号',
                      value: _settings.fontSize,
                      min: 12,
                      max: 22,
                      display: _settings.fontSize.round().toString(),
                      dark: widget.dark,
                      onChanged: (value) =>
                          _update(_settings.copyWith(fontSize: value)),
                    ),
                    const SizedBox(height: 4),
                    _SettingSlider(
                      label: '滚动时长',
                      value: _settings.duration,
                      min: 5,
                      max: 14,
                      display: '${_settings.duration.round()}秒',
                      dark: widget.dark,
                      onChanged: (value) =>
                          _update(_settings.copyWith(duration: value)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '画面防挡',
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _DanmakuFilterTile(
                          dark: widget.dark,
                          label: '固定',
                          icon: Icons.vertical_align_top_rounded,
                          active: _settings.hideFixed,
                          onTap: () => _update(
                            _settings.copyWith(hideFixed: !_settings.hideFixed),
                          ),
                        ),
                        _DanmakuFilterTile(
                          dark: widget.dark,
                          label: '滚动',
                          icon: Icons.subtitles_rounded,
                          active: _settings.hideScroll,
                          onTap: () => _update(
                            _settings.copyWith(
                              hideScroll: !_settings.hideScroll,
                            ),
                          ),
                        ),
                        _DanmakuFilterTile(
                          dark: widget.dark,
                          label: '高级',
                          icon: Icons.auto_awesome_rounded,
                          active: _settings.hideSpecial,
                          onTap: () => _update(
                            _settings.copyWith(
                              hideSpecial: !_settings.hideSpecial,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAreaSlider() {
    const values = [0.25, 0.5, 0.75, 1.0];
    return _SettingSlider(
      label: '显示区域',
      value: _areaIndex(values).toDouble(),
      min: 0,
      max: 3,
      divisions: 3,
      display: '${(_settings.area * 100).round()}%',
      dark: widget.dark,
      onChanged: (value) {
        final nextIndex = value.round().clamp(0, values.length - 1).toInt();
        _update(_settings.copyWith(area: values[nextIndex]));
      },
    );
  }

  int _areaIndex(List<double> values) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < values.length; i++) {
      final distance = (_settings.area - values[i]).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  Widget _buildColorSelector(Color mutedColor) {
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
        Text(
          '弹幕颜色',
          style: TextStyle(
            fontSize: 13,
            color: mutedColor,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 13,
          runSpacing: 10,
          children: colors.map((color) {
            final selected = color.toARGB32() == _settings.color.toARGB32();
            final checkColor = color == Colors.white
                ? AppTheme.primaryColor
                : Colors.white;
            return InkWell(
              onTap: () => _update(_settings.copyWith(color: color)),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? AppTheme.primaryColor
                        : widget.dark
                        ? Colors.white24
                        : AppTheme.dividerColor,
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                child: selected
                    ? Icon(Icons.check, size: 18, color: checkColor)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _DanmakuFilterTile extends StatelessWidget {
  const _DanmakuFilterTile({
    required this.dark,
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final bool dark;
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final background = active
        ? AppTheme.primaryColor.withValues(alpha: dark ? 0.3 : 0.12)
        : dark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFF5F6FA);
    final borderColor = active
        ? AppTheme.primaryColor
        : dark
        ? Colors.white12
        : AppTheme.dividerColor;
    final textColor = active
        ? AppTheme.primaryColor
        : dark
        ? Colors.white
        : AppTheme.textPrimary;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 82,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: textColor, size: 24),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
