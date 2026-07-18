import type { EditableChapter } from '@/types/ai-novel';

export const maxNovelImportBytes = 8 * 1024 * 1024;
export const maxNovelChapterCount = 1000;

export class NovelImportError extends Error {
  constructor(
    message: string,
    public readonly code: string,
  ) {
    super(message);
    this.name = 'NovelImportError';
  }
}

export interface DecodedNovelFile {
  text: string;
  encoding: 'UTF-8' | 'UTF-16LE' | 'UTF-16BE' | 'GB18030';
}

export interface ParsedNovelText {
  chapters: EditableChapter[];
  characterCount: number;
}

export async function decodeNovelFile(file: Blob): Promise<DecodedNovelFile> {
  if (file.size > maxNovelImportBytes) {
    throw new NovelImportError('文件不能超过 8MB', 'file_too_large');
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return { text: decode(bytes.subarray(3), 'utf-8'), encoding: 'UTF-8' };
  }
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return { text: decode(bytes.subarray(2), 'utf-16le'), encoding: 'UTF-16LE' };
  }
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return { text: decode(bytes.subarray(2), 'utf-16be'), encoding: 'UTF-16BE' };
  }
  try {
    return {
      text: new TextDecoder('utf-8', { fatal: true }).decode(bytes),
      encoding: 'UTF-8',
    };
  } catch {
    try {
      return { text: decode(bytes, 'gb18030'), encoding: 'GB18030' };
    } catch {
      throw new NovelImportError('无法识别文件编码，请转换为 UTF-8 后重试', 'encoding_invalid');
    }
  }
}

export function parseNovelText(rawText: string): ParsedNovelText {
  const text = String(rawText || '').replace(/\r\n?/g, '\n').trim();
  if (!text) throw new NovelImportError('文件中没有可导入的正文', 'content_empty');

  const headingPattern = /^(?:#{1,6}\s*)?(第[^\n]{1,30}[章节回卷部篇][^\n]{0,80}|(?:chapter|chap\.)\s+\d+[^\n]*)\s*$/gim;
  const matches = [...text.matchAll(headingPattern)];
  const chapters: EditableChapter[] = [];
  if (!matches.length) {
    chapters.push(editableChapter('正文', text, 0));
  } else {
    const preface = text.slice(0, matches[0]?.index || 0).trim();
    if (preface) chapters.push(editableChapter('序章', preface, chapters.length));
    for (let index = 0; index < matches.length; index += 1) {
      const match = matches[index];
      const start = Number(match.index) + match[0].length;
      const end = index + 1 < matches.length ? Number(matches[index + 1]?.index) : text.length;
      const content = text.slice(start, end).trim();
      if (!content) continue;
      const title = match[1]?.trim() || match[0].replace(/^#{1,6}\s*/, '').trim();
      chapters.push(editableChapter(title, content, chapters.length));
      if (chapters.length > maxNovelChapterCount) {
        throw new NovelImportError(
          `识别到的章节超过 ${maxNovelChapterCount} 章，请拆分文件后再导入`,
          'chapter_count_exceeded',
        );
      }
    }
  }
  if (!chapters.length) {
    throw new NovelImportError('没有识别到包含正文的章节', 'chapter_content_empty');
  }
  return {
    chapters,
    characterCount: chapters.reduce(
      (total, chapter) => total + chapter.title.length + chapter.content.length,
      0,
    ),
  };
}

function editableChapter(title: string, content: string, index: number): EditableChapter {
  return {
    clientId: `import-${index}-${Math.random().toString(36).slice(2, 9)}`,
    title,
    content,
  };
}

function decode(bytes: Uint8Array, encoding: string): string {
  return new TextDecoder(encoding, { fatal: true }).decode(bytes).replace(/^\uFEFF/, '');
}
