import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_accessibility.dart';
import 'reader_tokens.dart';

/// Stable reader viewport with independently overlaid control chrome.
///
/// [content] always occupies the complete scaffold body. Showing or hiding
/// chrome never inserts/removes layout siblings around it, preventing page and
/// scroll anchors from moving when controls are toggled.
class ReaderShell extends StatelessWidget {
  const ReaderShell({
    super.key,
    required this.content,
    this.chromeVisible = true,
    this.topChrome,
    this.bottomChrome,
    this.progressHud,
    this.overlays = const <Widget>[],
    this.onContentTap,
    this.contentSemanticLabel,
    this.backgroundColor,
    this.systemUiOverlayStyle,
    this.resizeToAvoidBottomInset = false,
    this.progressHudAlignment = Alignment.bottomRight,
    this.progressHudPadding = const EdgeInsets.all(16),
  });

  final Widget content;
  final bool chromeVisible;
  final Widget? topChrome;
  final Widget? bottomChrome;
  final Widget? progressHud;
  final List<Widget> overlays;
  final VoidCallback? onContentTap;
  final String? contentSemanticLabel;
  final Color? backgroundColor;
  final SystemUiOverlayStyle? systemUiOverlayStyle;
  final bool resizeToAvoidBottomInset;
  final AlignmentGeometry progressHudAlignment;
  final EdgeInsets progressHudPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = ReaderTokens.of(context);
    final background = backgroundColor ?? tokens.canvas;
    final overlayStyle =
        systemUiOverlayStyle ??
        _overlayStyleFor(background, tokens.chromeSurface);
    final duration = ReaderAccessibility.effectiveDuration(
      context,
      ReaderTokens.chromeTransitionDuration,
    );

    Widget contentLayer = RepaintBoundary(
      key: const Key('reader-shell-content-layer'),
      child: content,
    );
    if (contentSemanticLabel != null) {
      contentLayer = Semantics(
        container: true,
        label: contentSemanticLabel,
        child: contentLayer,
      );
    }
    if (onContentTap != null) {
      contentLayer = GestureDetector(
        key: const Key('reader-shell-content-tap-target'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onContentTap,
        child: contentLayer,
      );
    }

    return Scaffold(
      backgroundColor: background,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Stack(
          key: const Key('reader-shell-stack'),
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: contentLayer),
            ...overlays,
            if (progressHud != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: SafeArea(
                    minimum: progressHudPadding,
                    child: Align(
                      alignment: progressHudAlignment,
                      child: progressHud,
                    ),
                  ),
                ),
              ),
            if (topChrome != null)
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                child: _ReaderChromeVisibility(
                  key: const Key('reader-shell-top-chrome'),
                  visible: chromeVisible,
                  hiddenOffset: const Offset(0, -1),
                  duration: duration,
                  child: topChrome!,
                ),
              ),
            if (bottomChrome != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _ReaderChromeVisibility(
                  key: const Key('reader-shell-bottom-chrome'),
                  visible: chromeVisible,
                  hiddenOffset: const Offset(0, 1),
                  duration: duration,
                  child: bottomChrome!,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static SystemUiOverlayStyle _overlayStyleFor(
    Color background,
    Color navigationBar,
  ) {
    final brightBackground = background.computeLuminance() > 0.5;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: brightBackground
          ? Brightness.dark
          : Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: navigationBar,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    );
  }
}

class _ReaderChromeVisibility extends StatelessWidget {
  const _ReaderChromeVisibility({
    super.key,
    required this.visible,
    required this.hiddenOffset,
    required this.duration,
    required this.child,
  });

  final bool visible;
  final Offset hiddenOffset;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedSlide(
          key: const Key('reader-chrome-slide'),
          offset: visible ? Offset.zero : hiddenOffset,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            key: const Key('reader-chrome-opacity'),
            opacity: visible ? 1 : 0,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ),
      ),
    );
  }
}
