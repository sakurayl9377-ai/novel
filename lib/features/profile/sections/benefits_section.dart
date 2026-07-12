part of '../profile_screen.dart';

class _LevelBenefitsPanel extends StatefulWidget {
  const _LevelBenefitsPanel({
    required this.rows,
    required this.currentLevel,
    required this.growth,
  });

  final List<UserLevelEffect> rows;
  final int currentLevel;
  final UserGrowth growth;

  @override
  State<_LevelBenefitsPanel> createState() => _LevelBenefitsPanelState();
}

class _LevelBenefitsPanelState extends State<_LevelBenefitsPanel> {
  late int _selectedLevel = widget.currentLevel;

  List<UserLevelEffect> _effectiveRows() {
    final source = widget.rows.isNotEmpty
        ? widget.rows
        : _levelPlanFor(widget.currentLevel);
    return source.take(7).toList(growable: false)
      ..sort((a, b) => a.level.compareTo(b.level));
  }

  @override
  Widget build(BuildContext context) {
    final rows = _effectiveRows();
    final selected = rows.firstWhere(
      (row) => row.level == _selectedLevel,
      orElse: () => rows.first,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < rows.length; i += 1) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _LevelTabChip(
                  row: rows[i],
                  selected: rows[i].level == selected.level,
                  unlocked: widget.currentLevel >= rows[i].level,
                  onTap: () => setState(() => _selectedLevel = rows[i].level),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.topCenter,
              children: [...previousChildren, ?currentChild],
            ),
            child: _LevelBenefitDetailCard(
              key: ValueKey<int>(selected.level),
              row: selected,
              currentLevel: widget.currentLevel,
              growth: widget.growth,
            ),
          ),
        ),
      ],
    );
  }
}

class _LevelTabChip extends StatelessWidget {
  const _LevelTabChip({
    required this.row,
    required this.selected,
    required this.unlocked,
    required this.onTap,
  });

  final UserLevelEffect row;
  final bool selected;
  final bool unlocked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = _LevelVisualStyle.forLevel(row.level);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: selected
                        ? [
                            Color.lerp(style.buttonColor, Colors.white, 0.35)!,
                            style.buttonColor,
                          ]
                        : const [Colors.transparent, Colors.transparent],
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: style.glowColor.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? Colors.white : Colors.transparent,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: selected
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.lerp(
                                  style.buttonColor,
                                  Colors.white,
                                  0.2,
                                )!,
                                style.buttonColor,
                              ],
                            )
                          : unlocked
                          ? LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                style.buttonColor.withValues(alpha: 0.2),
                                style.buttonColor.withValues(alpha: 0.08),
                              ],
                            )
                          : null,
                      color: selected || unlocked
                          ? null
                          : const Color(0xFFF1F4F8),
                      border: selected
                          ? null
                          : Border.all(
                              color: unlocked
                                  ? style.buttonColor.withValues(alpha: 0.28)
                                  : const Color(0xFFE2E8F0),
                            ),
                    ),
                    child: Text(
                      'LV${row.level}',
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : unlocked
                            ? style.buttonColor
                            : AppTheme.textHint,
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            row.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? style.buttonColor
                  : unlocked
                  ? AppTheme.textSecondary
                  : AppTheme.textHint,
              fontSize: 10.5,
              height: 1,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              fontFamilyFallback: _profileFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}
