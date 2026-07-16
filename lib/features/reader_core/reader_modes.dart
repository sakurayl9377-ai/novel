/// Stable novel reader page modes persisted by their English [code].
enum NovelPageMode {
  verticalScroll,
  horizontalSlide,
  cover,
  simulation;

  String get code => name;

  String get label => switch (this) {
    NovelPageMode.verticalScroll => '上下滚动',
    NovelPageMode.horizontalSlide => '左右平移',
    NovelPageMode.cover => '覆盖翻页',
    NovelPageMode.simulation => '纸张仿真',
  };

  /// Reads both the new stable code and values used by older Chinese builds.
  /// Unknown values deliberately fall back to [verticalScroll].
  static NovelPageMode fromStorage(Object? value) {
    if (value is NovelPageMode) return value;
    return switch (_normalized(value)) {
      'horizontalslide' ||
      '左右平移' ||
      '平移' ||
      '滑动' => NovelPageMode.horizontalSlide,
      'cover' || '覆盖' || '覆盖翻页' => NovelPageMode.cover,
      'simulation' || '仿真' || '仿真翻页' || '纸张仿真' => NovelPageMode.simulation,
      _ => NovelPageMode.verticalScroll,
    };
  }
}

/// Stable manga layout modes persisted by their English [code].
enum MangaReadingMode {
  longStrip,
  paged;

  String get code => name;

  String get label => switch (this) {
    MangaReadingMode.longStrip => '条漫',
    MangaReadingMode.paged => '页漫',
  };

  static MangaReadingMode fromStorage(Object? value) {
    if (value is MangaReadingMode) return value;
    return switch (_normalized(value)) {
      'paged' || 'page' || '页漫' || '横向分页' => MangaReadingMode.paged,
      _ => MangaReadingMode.longStrip,
    };
  }
}

/// Reading direction for paged manga.
enum MangaPageDirection {
  ltr,
  rtl;

  String get code => name;

  String get label => switch (this) {
    MangaPageDirection.ltr => '从左到右',
    MangaPageDirection.rtl => '从右到左',
  };

  static MangaPageDirection fromStorage(Object? value) {
    if (value is MangaPageDirection) return value;
    return switch (_normalized(value)) {
      'rtl' || '从右到左' || '右到左' || '日漫' => MangaPageDirection.rtl,
      _ => MangaPageDirection.ltr,
    };
  }
}

/// Single/double-page preference for paged manga.
enum MangaSpreadMode {
  auto,
  single,
  double;

  String get code => name;

  String get label => switch (this) {
    MangaSpreadMode.auto => '自动',
    MangaSpreadMode.single => '单页',
    MangaSpreadMode.double => '双页',
  };

  static MangaSpreadMode fromStorage(Object? value) {
    if (value is MangaSpreadMode) return value;
    return switch (_normalized(value)) {
      'single' || '单页' => MangaSpreadMode.single,
      'double' || '双页' => MangaSpreadMode.double,
      _ => MangaSpreadMode.auto,
    };
  }
}

/// Image quality preference for manga pages.
enum MangaImageQuality {
  auto,
  high,
  original;

  String get code => name;

  String get label => switch (this) {
    MangaImageQuality.auto => '自动',
    MangaImageQuality.high => '高清',
    MangaImageQuality.original => '原图',
  };

  static MangaImageQuality fromStorage(Object? value) {
    if (value is MangaImageQuality) return value;
    return switch (_normalized(value)) {
      'high' || 'hd' || '高清' => MangaImageQuality.high,
      'original' || 'source' || '原图' => MangaImageQuality.original,
      _ => MangaImageQuality.auto,
    };
  }
}

String _normalized(Object? value) {
  return value?.toString().trim().toLowerCase().replaceAll(
        RegExp(r'[\s_-]'),
        '',
      ) ??
      '';
}
