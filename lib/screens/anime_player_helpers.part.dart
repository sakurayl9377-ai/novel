part of 'anime_player_screen.dart';

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
    this.dark = false,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max).toDouble();
    final textColor = dark ? Colors.white : AppTheme.textSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: textColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: textColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: clamped,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

double _doubleInRange(
  dynamic value,
  double min,
  double max, {
  required double fallback,
}) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  if (parsed == null || parsed.isNaN) return fallback;
  return parsed.clamp(min, max).toDouble();
}

int _intValue(dynamic value, {required int fallback}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

Color _danmakuColorFromHex(String value) {
  final raw = value.trim();
  final hex = raw.startsWith('#') ? raw.substring(1) : raw;
  if (hex.length == 6) {
    final rgb = int.tryParse(hex, radix: 16);
    if (rgb != null) return Color(0xFF000000 | rgb);
  }
  if (hex.length == 8) {
    final argb = int.tryParse(hex, radix: 16);
    if (argb != null) return Color(argb);
  }
  return Colors.white;
}

String _danmakuColorHex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

DanmakuItemType _danmakuItemTypeFromMode(String mode) {
  return switch (mode.trim().toLowerCase()) {
    'top' => DanmakuItemType.top,
    'bottom' => DanmakuItemType.bottom,
    _ => DanmakuItemType.scroll,
  };
}
