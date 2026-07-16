import 'dart:convert';

import '../reader_core/reader_modes.dart';

class MangaReaderPreferences {
  const MangaReaderPreferences({
    this.readingMode = MangaReadingMode.longStrip,
    this.pageDirection = MangaPageDirection.ltr,
    this.spreadMode = MangaSpreadMode.single,
    this.imageQuality = MangaImageQuality.auto,
    this.autoRotateSpread = false,
    this.nightMode = false,
  });

  static const storageKey = 'manga_reader_settings:v1';

  final MangaReadingMode readingMode;
  final MangaPageDirection pageDirection;
  final MangaSpreadMode spreadMode;
  final MangaImageQuality imageQuality;
  final bool autoRotateSpread;
  final bool nightMode;

  MangaReaderPreferences copyWith({
    MangaReadingMode? readingMode,
    MangaPageDirection? pageDirection,
    MangaSpreadMode? spreadMode,
    MangaImageQuality? imageQuality,
    bool? autoRotateSpread,
    bool? nightMode,
  }) {
    return MangaReaderPreferences(
      readingMode: readingMode ?? this.readingMode,
      pageDirection: pageDirection ?? this.pageDirection,
      spreadMode: spreadMode ?? this.spreadMode,
      imageQuality: imageQuality ?? this.imageQuality,
      autoRotateSpread: autoRotateSpread ?? this.autoRotateSpread,
      nightMode: nightMode ?? this.nightMode,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'readingMode': readingMode.code,
      'pageDirection': pageDirection.code,
      'spreadMode': spreadMode.code,
      'imageQuality': imageQuality.code,
      'autoRotateSpread': autoRotateSpread,
      'nightMode': nightMode,
    };
  }

  String encode() => jsonEncode(toJson());

  factory MangaReaderPreferences.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const MangaReaderPreferences();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const MangaReaderPreferences();
      return MangaReaderPreferences.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return const MangaReaderPreferences();
    }
  }

  factory MangaReaderPreferences.fromJson(Map<String, dynamic> json) {
    return MangaReaderPreferences(
      readingMode: MangaReadingMode.fromStorage(
        json['readingMode'] ?? json['mode'] ?? json['readMode'],
      ),
      pageDirection: MangaPageDirection.fromStorage(
        json['pageDirection'] ?? json['direction'],
      ),
      spreadMode: MangaSpreadMode.single,
      imageQuality: MangaImageQuality.fromStorage(
        json['imageQuality'] ?? json['quality'],
      ),
      autoRotateSpread: false,
      nightMode: json['nightMode'] == true || json['night'] == true,
    );
  }
}
