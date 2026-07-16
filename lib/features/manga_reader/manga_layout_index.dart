/// Maintains manga page extents with logarithmic updates and lookups.
///
/// A Fenwick tree is used instead of repeatedly scanning every preceding page
/// while the reader scrolls or while decoded image dimensions arrive.
class MangaLayoutIndex {
  MangaLayoutIndex({required int pageCount, required double defaultExtent}) {
    reset(pageCount: pageCount, defaultExtent: defaultExtent);
  }

  late List<double> _extents;
  late List<double> _tree;

  int get pageCount => _extents.length;

  double get totalExtent => _prefixExtent(pageCount);

  void reset({required int pageCount, required double defaultExtent}) {
    assert(pageCount >= 0);
    assert(defaultExtent > 0 && defaultExtent.isFinite);
    _extents = List<double>.filled(pageCount, defaultExtent);
    _tree = List<double>.filled(pageCount + 1, 0);
    for (var index = 0; index < pageCount; index++) {
      _add(index, defaultExtent);
    }
  }

  double extentAt(int index) {
    if (index < 0 || index >= pageCount) return 0;
    return _extents[index];
  }

  void updateExtent(int index, double extent) {
    if (index < 0 || index >= pageCount) return;
    if (extent <= 0 || !extent.isFinite) return;
    final delta = extent - _extents[index];
    if (delta.abs() < 0.01) return;
    _extents[index] = extent;
    _add(index, delta);
  }

  /// Returns the leading scroll offset for [index].
  double offsetOf(int index) {
    return _prefixExtent(index.clamp(0, pageCount));
  }

  /// Finds the page containing [offset] in O(log n).
  int indexAtOffset(double offset) {
    if (pageCount == 0) return 0;
    if (offset <= 0 || !offset.isFinite) return 0;
    if (offset >= totalExtent) return pageCount - 1;

    var treeIndex = 0;
    var accumulated = 0.0;
    var bit = 1;
    while (bit << 1 <= pageCount) {
      bit <<= 1;
    }
    while (bit != 0) {
      final next = treeIndex + bit;
      if (next <= pageCount && accumulated + _tree[next] <= offset) {
        treeIndex = next;
        accumulated += _tree[next];
      }
      bit >>= 1;
    }
    return treeIndex.clamp(0, pageCount - 1);
  }

  MangaPageLocation locationAt(double offset) {
    if (pageCount == 0) return const MangaPageLocation(pageIndex: 0);
    final pageIndex = indexAtOffset(offset);
    final extent = extentAt(pageIndex);
    final pageOffset = offset - offsetOf(pageIndex);
    return MangaPageLocation(
      pageIndex: pageIndex,
      pageOffsetRatio: extent <= 0 ? 0 : (pageOffset / extent).clamp(0.0, 1.0),
    );
  }

  void _add(int index, double delta) {
    for (
      var cursor = index + 1;
      cursor < _tree.length;
      cursor += cursor & -cursor
    ) {
      _tree[cursor] += delta;
    }
  }

  double _prefixExtent(int endExclusive) {
    var result = 0.0;
    for (var cursor = endExclusive; cursor > 0; cursor -= cursor & -cursor) {
      result += _tree[cursor];
    }
    return result;
  }
}

class MangaPageLocation {
  const MangaPageLocation({this.pageIndex = 0, this.pageOffsetRatio = 0});

  final int pageIndex;
  final double pageOffsetRatio;
}
