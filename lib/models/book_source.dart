
class BookSource {
  final String id;
  final String name;
  final String baseUrl;
  final String searchUrl;
  final String bookListUrl;
  final String chapterListUrl;
  final String contentUrl;
  final bool enabled;
  final int weight;
  final String? searchRule;
  final String? bookListRule;
  final String? chapterRule;
  final String? contentRule;
  final DateTime addedAt;

  BookSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.searchUrl = '',
    this.bookListUrl = '',
    this.chapterListUrl = '',
    this.contentUrl = '',
    this.enabled = true,
    this.weight = 0,
    this.searchRule,
    this.bookListRule,
    this.chapterRule,
    this.contentRule,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  BookSource copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? searchUrl,
    String? bookListUrl,
    String? chapterListUrl,
    String? contentUrl,
    bool? enabled,
    int? weight,
    String? searchRule,
    String? bookListRule,
    String? chapterRule,
    String? contentRule,
    DateTime? addedAt,
  }) {
    return BookSource(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      searchUrl: searchUrl ?? this.searchUrl,
      bookListUrl: bookListUrl ?? this.bookListUrl,
      chapterListUrl: chapterListUrl ?? this.chapterListUrl,
      contentUrl: contentUrl ?? this.contentUrl,
      enabled: enabled ?? this.enabled,
      weight: weight ?? this.weight,
      searchRule: searchRule ?? this.searchRule,
      bookListRule: bookListRule ?? this.bookListRule,
      chapterRule: chapterRule ?? this.chapterRule,
      contentRule: contentRule ?? this.contentRule,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'searchUrl': searchUrl,
    'bookListUrl': bookListUrl,
    'chapterListUrl': chapterListUrl,
    'contentUrl': contentUrl,
    'enabled': enabled,
    'weight': weight,
    'searchRule': searchRule,
    'bookListRule': bookListRule,
    'chapterRule': chapterRule,
    'contentRule': contentRule,
    'addedAt': addedAt.toIso8601String(),
  };

  factory BookSource.fromJson(Map<String, dynamic> json) => BookSource(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    searchUrl: json['searchUrl'] as String? ?? '',
    bookListUrl: json['bookListUrl'] as String? ?? '',
    chapterListUrl: json['chapterListUrl'] as String? ?? '',
    contentUrl: json['contentUrl'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    weight: json['weight'] as int? ?? 0,
    searchRule: json['searchRule'] as String?,
    bookListRule: json['bookListRule'] as String?,
    chapterRule: json['chapterRule'] as String?,
    contentRule: json['contentRule'] as String?,
    addedAt: json['addedAt'] != null ? DateTime.parse(json['addedAt'] as String) : DateTime.now(),
  );
}

