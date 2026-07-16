import 'package:flutter/material.dart';

import 'reader_accessibility.dart';
import 'reader_tokens.dart';

/// Standard modal surface for reader catalogs, settings, and secondary tools.
class ReaderModalSheet extends StatelessWidget {
  const ReaderModalSheet({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.semanticLabel,
    this.showDragHandle = true,
    this.showCloseButton = true,
    this.maxHeightFactor = 0.9,
  }) : assert(maxHeightFactor > 0 && maxHeightFactor <= 1);

  final Widget child;
  final Widget? title;
  final Widget? trailing;
  final String? semanticLabel;
  final bool showDragHandle;
  final bool showCloseButton;
  final double maxHeightFactor;

  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    Widget? title,
    Widget? trailing,
    String? semanticLabel,
    bool showDragHandle = true,
    bool showCloseButton = true,
    double maxHeightFactor = 0.9,
    bool isDismissible = true,
    bool enableDrag = true,
    bool useRootNavigator = false,
  }) {
    final tokens = ReaderTokens.of(context);
    final reduceMotion = ReaderAccessibility.reduceMotion(context);
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      barrierColor: tokens.scrim,
      sheetAnimationStyle: reduceMotion
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: ReaderTokens.sheetTransitionDuration,
              reverseDuration: ReaderTokens.sheetTransitionDuration,
            ),
      builder: (sheetContext) => ReaderModalSheet(
        title: title,
        trailing: trailing,
        semanticLabel: semanticLabel,
        showDragHandle: showDragHandle,
        showCloseButton: showCloseButton,
        maxHeightFactor: maxHeightFactor,
        child: builder(sheetContext),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final duration = ReaderAccessibility.effectiveDuration(
      context,
      ReaderTokens.sheetTransitionDuration,
    );
    final hasHeader = title != null || trailing != null || showCloseButton;

    return AnimatedPadding(
      duration: duration,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        scopesRoute: true,
        namesRoute: semanticLabel != null,
        label: semanticLabel,
        child: Material(
          color: tokens.chromeSurface,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(ReaderTokens.sheetRadius),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showDragHandle)
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: tokens.chromeMuted.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  if (hasHeader)
                    _ReaderSheetHeader(
                      title: title,
                      trailing: trailing,
                      showCloseButton: showCloseButton,
                    ),
                  Flexible(fit: FlexFit.loose, child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderSheetHeader extends StatelessWidget {
  const _ReaderSheetHeader({
    required this.title,
    required this.trailing,
    required this.showCloseButton,
  });

  final Widget? title;
  final Widget? trailing;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.only(left: 18, right: 6),
          child: Row(
            children: [
              Expanded(
                child: DefaultTextStyle.merge(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.onChrome,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                  child: title ?? const SizedBox.shrink(),
                ),
              ),
              ?trailing,
              if (showCloseButton)
                IconButton(
                  key: const Key('reader-modal-sheet-close'),
                  tooltip: '关闭',
                  onPressed: () => Navigator.maybePop(context),
                  color: tokens.onChrome,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
