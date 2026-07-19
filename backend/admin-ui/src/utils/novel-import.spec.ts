import {
  chapterTitleFromFileName,
  decodeNovelFile,
  NovelImportError,
  parseNovelFiles,
  parseNovelText,
  type NovelImportFile,
} from './novel-import';

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

  it('sorts multiple chapter files naturally and imports one chapter per file', async () => {
    const parsed = await parseNovelFiles([
      namedFile('010_第十章_终点.txt', '第十章 终点\n第十章正文'),
      namedFile('002_第二章_购物清单.txt', '第二章 购物清单\n第二章正文'),
      namedFile('001_第一章_饿死的人、_醒了.txt', '第一章 饿死的人、醒了\n第一章正文'),
    ]);

    expect(parsed.orderedFileNames).toEqual([
      '001_第一章_饿死的人、_醒了.txt',
      '002_第二章_购物清单.txt',
      '010_第十章_终点.txt',
    ]);
    expect(parsed.chapters.map((chapter) => chapter.title)).toEqual([
      '第一章 饿死的人、醒了',
      '第二章 购物清单',
      '第十章 终点',
    ]);
    expect(parsed.chapters.map((chapter) => chapter.content)).toEqual([
      '第一章正文',
      '第二章正文',
      '第十章正文',
    ]);
  });

  it('builds readable chapter titles from numbered file names', () => {
    expect(chapterTitleFromFileName('001_第一章_饿死的人、_醒了.txt')).toBe(
      '第一章 饿死的人、醒了',
    );
    expect(chapterTitleFromFileName('023-第二十三章-陈浩的价码.md')).toBe(
      '第二十三章-陈浩的价码',
    );
  });

  it('keeps full-book auto splitting when only one file is selected', async () => {
    const parsed = await parseNovelFiles([
      namedFile('整本小说.txt', '第一章 开始\n正文一\n\n第二章 继续\n正文二'),
    ]);

    expect(parsed.fileCount).toBe(1);
    expect(parsed.chapters.map((chapter) => chapter.title)).toEqual([
      '第一章 开始',
      '第二章 继续',
    ]);
  });

  it('rejects the whole batch when a chapter file has no body', async () => {
    await expect(parseNovelFiles([
      namedFile('001_第一章.txt', '第一章 开始\n正文'),
      namedFile('002_第二章.txt', '第二章 空章'),
    ])).rejects.toThrow('“002_第二章.txt”缺少章节正文');
  });
});

function namedFile(name: string, content: BlobPart): NovelImportFile {
  const file = new Blob([content]) as NovelImportFile;
  Object.defineProperty(file, 'name', { value: name });
  return file;
}
