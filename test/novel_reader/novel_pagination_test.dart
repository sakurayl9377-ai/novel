import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/novel_pagination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 18, height: 1.6);

  test('pagination covers content exactly with no overlap or gap', () {
    final content = List.generate(
      24,
      (index) => '　　这是第$index段用于验证真实文字行分页边界的正文内容。',
    ).join('\n\n');
    final result = NovelPaginationEngine.paginate(
      content: content,
      width: 260,
      height: 360,
      style: style,
      paragraphSpacing: 0.72,
    );

    expect(result.pages.length, greaterThan(1));
    expect(result.pages.first.startOffset, 0);
    expect(result.pages.last.endOffset, content.length);
    for (var index = 1; index < result.pages.length; index++) {
      expect(
        result.pages[index - 1].endOffset,
        result.pages[index].startOffset,
      );
    }
    expect(result.pages.map((page) => page.textOf(content)).join(), content);
  });

  test('page lookup keeps the canonical character anchor', () {
    final content = List.filled(80, '　　文字排版分页测试段落。').join('\n\n');
    final result = NovelPaginationEngine.paginate(
      content: content,
      width: 240,
      height: 320,
      style: style,
      paragraphSpacing: 0.72,
    );

    for (var offset = 0; offset <= content.length; offset += 37) {
      final pageIndex = result.pageForOffset(offset);
      final page = result.pages[pageIndex];
      expect(page.startOffset, lessThanOrEqualTo(offset));
      if (pageIndex < result.pages.length - 1) {
        expect(offset, lessThan(page.endOffset));
      }
    }
  });

  test('larger typography creates no fewer pages', () {
    final content = List.filled(40, '　　字体变化后仍按实际行边界重新分页。').join('\n\n');
    final small = NovelPaginationEngine.paginate(
      content: content,
      width: 280,
      height: 420,
      style: style,
      paragraphSpacing: 0.5,
    );
    final large = NovelPaginationEngine.paginate(
      content: content,
      width: 280,
      height: 420,
      style: const TextStyle(fontSize: 26, height: 1.9),
      paragraphSpacing: 1.2,
    );

    expect(large.pages.length, greaterThanOrEqualTo(small.pages.length));
  });

  test('first page title reservation only affects page partition', () {
    final content = List.filled(30, '　　章节标题预留空间测试。').join('\n\n');
    final normal = NovelPaginationEngine.paginate(
      content: content,
      width: 250,
      height: 360,
      style: style,
      paragraphSpacing: 0.72,
    );
    final reserved = NovelPaginationEngine.paginate(
      content: content,
      width: 250,
      height: 360,
      style: style,
      paragraphSpacing: 0.72,
      firstPageReservedHeight: 90,
    );

    expect(reserved.pages.first.startOffset, 0);
    expect(reserved.pages.last.endOffset, content.length);
    expect(reserved.pages.length, greaterThanOrEqualTo(normal.pages.length));
    expect(reserved.pages.map((page) => page.textOf(content)).join(), content);
  });

  test('identical typography reuses a bounded pagination result', () {
    final content = List.filled(36, '　　分页缓存避免返回章节时重复整章排版。').join('\n\n');
    final first = NovelPaginationEngine.paginate(
      content: content,
      width: 260,
      height: 360,
      style: style,
      paragraphSpacing: 0.85,
    );
    final second = NovelPaginationEngine.paginate(
      content: content,
      width: 260,
      height: 360,
      style: style,
      paragraphSpacing: 0.85,
    );

    expect(second, same(first));

    for (var index = 0; index < 9; index++) {
      NovelPaginationEngine.paginate(
        content: '$content\n\n第 $index 个缓存键',
        width: 260,
        height: 360,
        style: style,
        paragraphSpacing: 0.85,
      );
    }
    expect(NovelPaginationEngine.cachedLayoutCount, lessThanOrEqualTo(5));
  });
}
