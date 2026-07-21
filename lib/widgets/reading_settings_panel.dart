import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../features/reader_core/reader_modes.dart';
import '../models/reading_settings.dart';

class ReadingSettingsPanel extends StatefulWidget {
  const ReadingSettingsPanel({
    super.key,
    required this.settings,
    required this.onPreviewChanged,
    required this.onChangeEnd,
  });

  final ReadingSettings settings;
  final ValueChanged<ReadingSettings> onPreviewChanged;
  final VoidCallback onChangeEnd;

  @override
  State<ReadingSettingsPanel> createState() => _ReadingSettingsPanelState();
}

class _ReadingSettingsPanelState extends State<ReadingSettingsPanel> {
  late ReadingSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings.copyWith();
  }

  void _update(ReadingSettings next) {
    setState(() => _settings = next);
    widget.onPreviewChanged(next);
  }

  Color _parseColor(String hex) {
    final normalized = hex.replaceAll('#', '');
    return Color(
      int.parse(
        normalized.length == 6 ? 'FF$normalized' : normalized,
        radix: 16,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNight = _settings.nightMode;
    final surface = isNight ? AppTheme.nightCard : Colors.white;
    final primaryText = isNight ? AppTheme.nightText : AppTheme.textPrimary;
    final secondaryText = isNight ? Colors.white70 : AppTheme.textSecondary;

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Material(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const SizedBox(height: 9),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: secondaryText.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '阅读设置',
                        style: TextStyle(
                          color: primaryText,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '完成',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, color: secondaryText),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: secondaryText.withValues(alpha: 0.14)),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                  children: [
                    _SectionTitle('亮度', color: secondaryText),
                    Row(
                      children: [
                        Icon(Icons.brightness_5_outlined, color: secondaryText),
                        Expanded(
                          child: Slider(
                            value: _settings.brightness,
                            min: 0.05,
                            max: 1,
                            divisions: 19,
                            label: '${(_settings.brightness * 100).round()}%',
                            onChanged: _settings.useSystemBrightness
                                ? null
                                : (value) => _update(
                                    _settings.copyWith(brightness: value),
                                  ),
                            onChangeEnd: _settings.useSystemBrightness
                                ? null
                                : (_) => widget.onChangeEnd(),
                          ),
                        ),
                        Text(
                          _settings.useSystemBrightness
                              ? '系统'
                              : '${(_settings.brightness * 100).round()}%',
                          style: TextStyle(color: primaryText, fontSize: 13),
                        ),
                      ],
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '跟随系统亮度',
                        style: TextStyle(color: primaryText),
                      ),
                      value: _settings.useSystemBrightness,
                      onChanged: (value) => _update(
                        _settings.copyWith(useSystemBrightness: value),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionTitle('翻页方式', color: secondaryText),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: NovelPageMode.values
                          .map((mode) {
                            return ChoiceChip(
                              label: Text(mode.label),
                              selected: _settings.pageMode == mode,
                              onSelected: (_) =>
                                  _update(_settings.copyWith(pageMode: mode)),
                            );
                          })
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 22),
                    _SectionTitle('字号', color: secondaryText),
                    _ValueSlider(
                      value: _settings.fontSize,
                      min: 14,
                      max: 34,
                      divisions: 20,
                      leading: const Icon(Icons.text_decrease),
                      trailing: const Icon(Icons.text_increase),
                      label: '${_settings.fontSize.round()}',
                      onChanged: (value) =>
                          _update(_settings.copyWith(fontSize: value)),
                      onChangeEnd: widget.onChangeEnd,
                    ),
                    const SizedBox(height: 14),
                    _SectionTitle('字体', color: secondaryText),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ReadingSettings.fontFamilies
                          .map((font) {
                            return ChoiceChip(
                              label: Text(
                                ReadingSettings.fontLabel(font),
                                style: TextStyle(
                                  fontFamily: font == ReadingSettings.systemFont
                                      ? null
                                      : font,
                                ),
                              ),
                              selected: _settings.fontFamily == font,
                              onSelected: (_) =>
                                  _update(_settings.copyWith(fontFamily: font)),
                            );
                          })
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 22),
                    _SectionTitle('排版', color: secondaryText),
                    _ValueSlider(
                      value: _settings.lineHeight,
                      min: 1.2,
                      max: 2.2,
                      divisions: 10,
                      label: '行距 ${_settings.lineHeight.toStringAsFixed(1)}',
                      onChanged: (value) =>
                          _update(_settings.copyWith(lineHeight: value)),
                      onChangeEnd: widget.onChangeEnd,
                    ),
                    _ValueSlider(
                      value: _settings.paragraphSpacing,
                      min: 0,
                      max: 1.6,
                      divisions: 16,
                      label:
                          '段距 ${_settings.paragraphSpacing.toStringAsFixed(1)}',
                      onChanged: (value) =>
                          _update(_settings.copyWith(paragraphSpacing: value)),
                      onChangeEnd: widget.onChangeEnd,
                    ),
                    _ValueSlider(
                      value: _settings.horizontalPadding,
                      min: 12,
                      max: 40,
                      divisions: 14,
                      label: '页边距 ${_settings.horizontalPadding.round()}',
                      onChanged: (value) =>
                          _update(_settings.copyWith(horizontalPadding: value)),
                      onChangeEnd: widget.onChangeEnd,
                    ),
                    const SizedBox(height: 18),
                    _SectionTitle('阅读背景', color: secondaryText),
                    Wrap(
                      spacing: 14,
                      runSpacing: 12,
                      children: ReadingSettings.backgroundColors
                          .map((color) {
                            final selected = _settings.backgroundColor == color;
                            return Semantics(
                              button: true,
                              selected: selected,
                              label: '阅读背景 $color',
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => _update(
                                  _settings.copyWith(
                                    backgroundColor: color,
                                    nightMode:
                                        color == '#1A1A1A' ||
                                        color == '#2B2B2B',
                                  ),
                                ),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _parseColor(color),
                                    border: Border.all(
                                      color: selected
                                          ? AppTheme.primaryColor
                                          : secondaryText.withValues(
                                              alpha: 0.24,
                                            ),
                                      width: selected ? 3 : 1,
                                    ),
                                  ),
                                  child: selected
                                      ? Icon(
                                          Icons.check,
                                          size: 20,
                                          color:
                                              _parseColor(
                                                    color,
                                                  ).computeLuminance() >
                                                  0.5
                                              ? AppTheme.primaryColor
                                              : Colors.white,
                                        )
                                      : null,
                                ),
                              ),
                            );
                          })
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 20),
                    _SectionTitle('操作', color: secondaryText),
                    _ReaderSwitch(
                      title: '单手点击区',
                      subtitle: '扩大右侧下一页区域',
                      value: _settings.singleHandMode,
                      onChanged: (value) =>
                          _update(_settings.copyWith(singleHandMode: value)),
                    ),
                    _ReaderSwitch(
                      title: '音量键翻页',
                      subtitle: '阅读时拦截音量键，上键上一页、下键下一页',
                      value: _settings.volumeKeyTurnPage,
                      onChanged: (value) =>
                          _update(_settings.copyWith(volumeKeyTurnPage: value)),
                    ),
                    _ReaderSwitch(
                      title: '屏幕常亮',
                      subtitle: '仅在阅读界面保持屏幕唤醒',
                      value: _settings.keepScreenOn,
                      onChanged: (value) =>
                          _update(_settings.copyWith(keepScreenOn: value)),
                    ),
                    const SizedBox(height: 12),
                    _SectionTitle('自动阅读速度', color: secondaryText),
                    _ValueSlider(
                      value: _settings.autoReadSpeed,
                      min: 0.5,
                      max: 3,
                      divisions: 10,
                      label: '${_settings.autoReadSpeed.toStringAsFixed(1)}×',
                      onChanged: (value) =>
                          _update(_settings.copyWith(autoReadSpeed: value)),
                      onChangeEnd: widget.onChangeEnd,
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    required this.onChangeEnd,
    this.leading,
    this.trailing,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
            onChangeEnd: (_) => onChangeEnd(),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        if (leading == null && trailing == null)
          SizedBox(
            width: 82,
            child: Text(
              label,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _ReaderSwitch extends StatelessWidget {
  const _ReaderSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
