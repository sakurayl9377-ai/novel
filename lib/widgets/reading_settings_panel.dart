import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/reading_settings.dart';

class ReadingSettingsPanel extends StatefulWidget {
  final ReadingSettings settings;
  final Function(double) onFontSizeChanged;
  final Function(String) onFontFamilyChanged;
  final Function(String) onBackgroundChanged;
  final Function(String) onPageTurnModeChanged;

  const ReadingSettingsPanel({
    super.key,
    required this.settings,
    required this.onFontSizeChanged,
    required this.onFontFamilyChanged,
    required this.onBackgroundChanged,
    required this.onPageTurnModeChanged,
  });

  @override
  State<ReadingSettingsPanel> createState() => _ReadingSettingsPanelState();
}

class _ReadingSettingsPanelState extends State<ReadingSettingsPanel> {
  late double _fontSize;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.settings.fontSize;
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final isNight = widget.settings.nightMode;

    return Container(
      decoration: BoxDecoration(
        color: isNight ? AppTheme.nightCard : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 拖动条
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textHint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 字号调节
            Text(
              '字号',
              style: TextStyle(
                fontSize: 13,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.text_fields,
                  size: 18,
                  color: AppTheme.textHint,
                ),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 14,
                    max: 32,
                    divisions: 18,
                    activeColor: AppTheme.primaryColor,
                    inactiveColor: AppTheme.textHint.withValues(alpha: 0.3),
                    label: '${_fontSize.toInt()}',
                    onChanged: (v) {
                      setState(() => _fontSize = v);
                      widget.onFontSizeChanged(v);
                    },
                  ),
                ),
                Container(
                  constraints: const BoxConstraints(minWidth: 36),
                  child: Text(
                    '${_fontSize.toInt()}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 背景色
            Text(
              '背景',
              style: TextStyle(
                fontSize: 13,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ReadingSettings.backgroundColors.map((color) {
                final isSelected = widget.settings.backgroundColor == color;
                return GestureDetector(
                  onTap: () => widget.onBackgroundChanged(color),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _parseColor(color),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.primaryColor
                            : AppTheme.dividerColor,
                        width: isSelected ? 3 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: AppTheme.primaryColor.withValues(
                                  alpha: 0.3,
                                ),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            // 翻页模式
            Text(
              '翻页',
              style: TextStyle(
                fontSize: 13,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ReadingSettings.pageTurnModes.map((mode) {
                  final isSelected = widget.settings.pageTurnMode == mode;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        mode,
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected
                              ? Colors.white
                              : (isNight
                                    ? AppTheme.nightText
                                    : AppTheme.textPrimary),
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: AppTheme.primaryColor,
                      backgroundColor: isNight
                          ? AppTheme.nightBackground
                          : Colors.grey.shade100,
                      onSelected: (_) => widget.onPageTurnModeChanged(mode),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),

            // 字体选择
            Text(
              '字体',
              style: TextStyle(
                fontSize: 13,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ReadingSettings.fontFamilies.map((family) {
                  final isSelected = widget.settings.fontFamily == family;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        family,
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected
                              ? Colors.white
                              : (isNight
                                    ? AppTheme.nightText
                                    : AppTheme.textPrimary),
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: AppTheme.primaryColor,
                      backgroundColor: isNight
                          ? AppTheme.nightBackground
                          : Colors.grey.shade100,
                      onSelected: (_) => widget.onFontFamilyChanged(family),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
