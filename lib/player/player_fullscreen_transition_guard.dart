class PlayerFullscreenTransitionGuard {
  bool _transitionActive = false;
  bool _resumeIntent = false;
  int _resumeAllowedUntilMs = 0;

  bool get transitionActive => _transitionActive;
  bool get resumeIntent => _resumeIntent;
  int get resumeAllowedUntilMs => _resumeAllowedUntilMs;

  bool begin({
    required bool wasPlaying,
    required int nowMs,
    int gracePeriodMs = 3200,
  }) {
    if (_transitionActive) return false;
    _transitionActive = true;
    _resumeIntent = wasPlaying;
    _resumeAllowedUntilMs = nowMs + gracePeriodMs;
    return true;
  }

  void retainResumeIntent(bool shouldResume) {
    _resumeIntent = _resumeIntent || shouldResume;
  }

  void recordPlaybackIntent(bool playing) {
    if (playing) {
      _resumeIntent = true;
      return;
    }
    _resumeIntent = false;
    _resumeAllowedUntilMs = 0;
  }

  bool suppressesLifecyclePause(int nowMs) {
    return _transitionActive || nowMs < _resumeAllowedUntilMs;
  }

  bool shouldResume(int nowMs) {
    return _resumeIntent && suppressesLifecyclePause(nowMs);
  }

  void finishTransition() {
    _transitionActive = false;
  }

  void expire(int nowMs) {
    if (_transitionActive || nowMs < _resumeAllowedUntilMs) return;
    _resumeIntent = false;
    _resumeAllowedUntilMs = 0;
  }
}
