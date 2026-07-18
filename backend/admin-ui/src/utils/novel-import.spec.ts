import { decodeNovelFile, NovelImportError, parseNovelText } from './novel-import';

describe('novel import', () => {
  it('detects UTF-8 and splits Chinese and Markdown chapter headings', async () => {
    const source = '# 第一章 起航\n星舰离港。\n\n## 第二章 深空\n舰队进入深空。';
    const decoded = await decodeNovelFile(new Blob([source]));
    const parsed = parseNovelText(decoded.text);

    expect(decoded.encoding).toBe('UTF-8');
    expect(parsed.chapters.map((chapter) => chapter.title)).toEqual([
      '第一章 起航',
      '第二章 深空',
    ]);
    expect(parsed.chapters[1]?.content).toContain('进入深空');
  });

  it('decodes UTF-16LE files with a byte order mark', async () => {
    const source = '第一章 测试\n正文内容';
    const bytes = new Uint8Array(2 + source.length * 2);
    bytes.set([0xff, 0xfe]);
    [...source].forEach((character, index) => {
      const code = character.charCodeAt(0);
      bytes[2 + index * 2] = code & 0xff;
      bytes[3 + index * 2] = code >> 8;
    });

    const decoded = await decodeNovelFile(new Blob([bytes]));
    expect(decoded.encoding).toBe('UTF-16LE');
    expect(decoded.text).toContain('正文内容');
  });

  it('fails explicitly instead of silently truncating more than 1000 chapters', () => {
    const source = Array.from(
      { length: 1001 },
      (_, index) => `第${index + 1}章 测试\n正文 ${index + 1}`,
    ).join('\n\n');

    expect(() => parseNovelText(source)).toThrowError(NovelImportError);
  });
});
