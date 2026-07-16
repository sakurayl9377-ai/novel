import 'package:flutter/material.dart';

import 'reader_tokens.dart';

enum ReaderChromePlacement { top, bottom }

/// A reader control surface that paints through the relevant system inset.
class ReaderChrome extends StatelessWidget {
  const ReaderChrome({
    super.key,
    required this.placement,
    required this.child,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.backgroundColor,
    this.foregroundColor,
    this.semanticLabel,
    this.showDivider = true,
  });

  const ReaderChrome.top({
    super.key,
    required this.child,
    this.height = ReaderTokens.topChromeHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.backgroundColor,
    this.foregroundColor,
    this.semanticLabel = '阅读器顶部控制栏',
    this.showDivider = true,
  }) : placement = ReaderChromePlacement.top;

  const ReaderChrome.bottom({
    super.key,
    required this.child,
    this.height = ReaderTokens.bottomChromeHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.backgroundColor,
    this.foregroundColor,
    this.semanticLabel = '阅读器底部控制栏',
    this.showDivider = true,
  }) : placement = ReaderChromePlacement.bottom;

  final ReaderChromePlacement placement;
  final Widget child;
  final double? height;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final String? semanticLabel;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final foreground = foregroundColor ?? tokens.onChrome;
    final dividerSide = BorderSide(
      color: showDivider ? tokens.divider : Colors.transparent,
    );

    return Semantics(
      container: true,
      // Keep every icon action independently focusable for screen readers.
      explicitChildNodes: true,
      label: semanticLabel,
      child: Material(
        color: backgroundColor ?? tokens.chromeSurface,
        child: SafeArea(
          top: placement == ReaderChromePlacement.top,
          bottom: placement == ReaderChromePlacement.bottom,
          left: false,
          right: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: placement == ReaderChromePlacement.bottom
                    ? dividerSide
                    : BorderSide.none,
                bottom: placement == ReaderChromePlacement.top
                    ? dividerSide
                    : BorderSide.none,
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height ?? 0),
              child: Padding(
                padding: padding,
                child: IconTheme(
                  data: IconThemeData(color: foreground, size: 24),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: foreground),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Consistent, accessible action used inside reader chrome.
class ReaderChromeAction extends StatelessWidget {
  const ReaderChromeAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool? selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final effectiveColor =
        color ??
        (selected == true ? tokens.accent : IconTheme.of(context).color);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        constraints: const BoxConstraints(
          minWidth: ReaderTokens.minimumTapTarget,
          minHeight: ReaderTokens.minimumTapTarget,
        ),
        color: effectiveColor,
        disabledColor: tokens.chromeMuted.withValues(alpha: 0.45),
        icon: Icon(icon),
      ),
    );
  }
}
