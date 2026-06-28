class Chapter {
  final String id;
  final String novelId;
  final String title;
  String content;
  final int index;
  final String url;
  final bool isLoaded;
  final DateTime addedAt;

  Chapter({
    required this.id,
    required this.novelId,
    required this.title,
    this.content = '',
    required this.index,
    this.url = '',
    this.isLoaded = false,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  Chapter copyWith({
    String? id,
    String? novelId,
    String? title,
    String? content,
    int? index,
    String? url,
    bool? isLoaded,
    DateTime? addedAt,
  }) {
    return Chapter(
      id: id ?? this.id,
      novelId: novelId ?? this.novelId,
      title: title ?? this.title,
      content: content ?? this.content,
      index: index ?? this.index,
      url: url ?? this.url,
      isLoaded: isLoaded ?? this.isLoaded,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'novelId': novelId,
    'title': title,
    'content': content,
    'index': index,
    'url': url,
    'isLoaded': isLoaded,
    'addedAt': addedAt.toIso8601String(),
  };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
    id: json['id'] as String,
    novelId: json['novelId'] as String,
    title: json['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
    index: json['index'] as int? ?? 0,
    url: json['url'] as String? ?? '',
    isLoaded: json['isLoaded'] as bool? ?? false,
    addedAt: json['addedAt'] != null ? DateTime.parse(json['addedAt'] as String) : DateTime.now(),
  );
}
