import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlayerFullscreenCoordinator extends ChangeNotifier {
  bool _isFullscreen = false;
  bool _transitioning = false;
  bool _resumeAfterTransition = false;

  bool get isFullscreen => _isFullscreen;
  bool get transitioning => _transitioning;
  bool get resumeAfterTransition => _resumeAfterTransition;

  Future<void> enter({required bool wasPlaying}) async {
    if (_isFullscreen || _transitioning) return;
    _transitioning = true;
    _resumeAfterTransition = wasPlaying;
    notifyListeners();
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _isFullscreen = true;
    _transitioning = false;
    notifyListeners();
  }

  Future<void> exit({required bool wasPlaying}) async {
    if (!_isFullscreen || _transitioning) return;
    _transitioning = true;
    _resumeAfterTransition = _resumeAfterTransition || wasPlaying;
    notifyListeners();
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    _isFullscreen = false;
    _transitioning = false;
    notifyListeners();
  }

  bool consumeResumeIntent() {
    final result = _resumeAfterTransition;
    _resumeAfterTransition = false;
    return result;
  }
}
