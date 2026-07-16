import 'package:flutter/material.dart';

import 'reader_accessibility.dart';
import 'reader_tokens.dart';

/// A compact progress/status badge intended for the reader overlay layer.
class ReaderProgressHud extends StatelessWidget {
  const ReaderProgressHud({
    super.key,
    required this.label,
    this.visible = true,
    this.semanticLabel,
    this.leading,
    this.announceChanges = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  final String label;
  final bool visible;
  final String? semanticLabel;
  final Widget? leading;
  final bool announceChanges;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final duration = ReaderAccessibility.effectiveDuration(
      context,
      ReaderTokens.hudTransitionDuration,
    );
    final foreground = foregroundColor ?? tokens.onChrome;
    final visual = DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? tokens.chromeSurface,
        borderRadius: BorderRadius.circular(ReaderTokens.hudRadius),
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              IconTheme(
                data: IconThemeData(color: foreground, size: 14),
                child: leading!,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );

    return IgnorePointer(
      child: ExcludeSemantics(
        excluding: !visible,
        child: Semantics(
          container: true,
          liveRegion: announceChanges,
          label: semanticLabel ?? label,
          excludeSemantics: true,
          child: AnimatedOpacity(
            key: const Key('reader-progress-hud-opacity'),
            opacity: visible ? 1 : 0,
            duration: duration,
            child: visual,
          ),
        ),
      ),
    );
  }
}
