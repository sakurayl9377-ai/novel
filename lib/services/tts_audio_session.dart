import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';

enum TtsAudioInterruptionKind { focusPause, focusDuck, unknown, becomingNoisy }

class TtsAudioInterruptionEvent {
  const TtsAudioInterruptionEvent({required this.begin, required this.kind});

  const TtsAudioInterruptionEvent.becomingNoisy()
    : begin = true,
      kind = TtsAudioInterruptionKind.becomingNoisy;

  final bool begin;
  final TtsAudioInterruptionKind kind;
}

abstract interface class TtsAudioSessionPort {
  Stream<TtsAudioInterruptionEvent> get events;

  Future<void> configureForSpeech();

  Future<bool> activate();

  Future<void> deactivate();

  Future<void> dispose();
}

class SystemTtsAudioSession implements TtsAudioSessionPort {
  final StreamController<TtsAudioInterruptionEvent> _events =
      StreamController<TtsAudioInterruptionEvent>.broadcast(sync: true);
  AudioSession? _session;
  Future<void>? _initialization;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  bool _available = true;
  bool _disposed = false;

  @override
  Stream<TtsAudioInterruptionEvent> get events => _events.stream;

  Future<void> _ensureInitialized() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final session = await AudioSession.instance;
      if (_disposed) return;
      _session = session;
      _interruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        if (_disposed) return;
        _events.add(
          TtsAudioInterruptionEvent(
            begin: event.begin,
            kind: switch (event.type) {
              AudioInterruptionType.pause =>
                TtsAudioInterruptionKind.focusPause,
              AudioInterruptionType.duck => TtsAudioInterruptionKind.focusDuck,
              AudioInterruptionType.unknown => TtsAudioInterruptionKind.unknown,
            },
          ),
        );
      }, onError: (_) {});
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        if (!_disposed) {
          _events.add(const TtsAudioInterruptionEvent.becomingNoisy());
        }
      }, onError: (_) {});
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
  }

  @override
  Future<void> configureForSpeech() async {
    await _ensureInitialized();
    if (!_available || _disposed) return;
    try {
      await _session?.configure(const AudioSessionConfiguration.speech());
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
  }

  @override
  Future<bool> activate() async {
    await _ensureInitialized();
    if (!_available || _disposed) return true;
    try {
      return await _session?.setActive(true) ?? true;
    } on MissingPluginException {
      _available = false;
      return true;
    } on PlatformException {
      _available = false;
      return true;
    }
  }

  @override
  Future<void> deactivate() async {
    await _ensureInitialized();
    if (!_available || _disposed) return;
    try {
      await _session?.setActive(false);
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait<void>([
      if (_interruptionSubscription case final subscription?)
        subscription.cancel(),
      if (_becomingNoisySubscription case final subscription?)
        subscription.cancel(),
    ]);
    await _events.close();
  }
}
