import 'package:flutter/widgets.dart';

/// Shared accessibility decisions for reader surfaces.
abstract final class ReaderAccessibility {
  /// Honors both the platform animation switch and accessible navigation.
  static bool reduceMotion(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    return mediaQuery?.disableAnimations == true ||
        mediaQuery?.accessibleNavigation == true;
  }

  static Duration effectiveDuration(BuildContext context, Duration preferred) {
    return reduceMotion(context) ? Duration.zero : preferred;
  }
}
