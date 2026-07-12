class CatalogTitleParts {
  const CatalogTitleParts({required this.indexLabel, required this.title});

  final String indexLabel;
  final String title;

  static CatalogTitleParts from(
    String rawTitle, {
    required int fallbackIndex,
    required String unit,
  }) {
    final normalized = rawTitle.trim().replaceAll(RegExp(r'\s+'), ' ');
    final fallbackLabel = '第${fallbackIndex.toString().padLeft(2, '0')}$unit';
    if (normalized.isEmpty) {
      return CatalogTitleParts(indexLabel: fallbackLabel, title: '');
    }

    final patterns = <RegExp>[
      RegExp(r'^(第\s*\d+\s*[话集章节回卷期])\s*[:：\-_.、 ]*\s*(.*)$'),
      RegExp(r'^(\d+\s*[话集章节回卷期])\s*[:：\-_.、 ]*\s*(.*)$'),
      RegExp(r'^(\d{1,4})\s*[:：\-_.、 ]+\s*(.*)$'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(normalized);
      if (match == null) continue;
      final label = _compactLabel(match.group(1) ?? fallbackLabel, unit);
      final title = (match.group(2) ?? '').trim();
      return CatalogTitleParts(indexLabel: label, title: title);
    }

    return CatalogTitleParts(indexLabel: fallbackLabel, title: normalized);
  }

  static String _compactLabel(String value, String unit) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(r'^\d+$').hasMatch(compact)) return '$compact$unit';
    return compact;
  }
}
