import type { EditableChapter } from '@/types/ai-novel';

export const maxNovelImportBytes = 8 * 1024 * 1024;
export const maxNovelBatchImportBytes = 64 * 1024 * 1024;
export const maxNovelChapterCount = 1000;

const chapterHeadingLinePattern = /^(?:#{1,6}\s*)?(第[^\n]{1,30}[章节回卷部篇][^\n]{0,80}|(?:chapter|chap\.)\s+\d+[^\n]*)\s*$/i;
const fileNameCollator = new Intl.Collator('zh-CN', {
  numeric: true,
  sensitivity: 'base',
});

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

export interface NovelImportFile extends Blob {
  readonly name: string;
}

export interface ParsedNovelFiles extends ParsedNovelText {
  fileCount: number;
  encodings: DecodedNovelFile['encoding'][];
  orderedFileNames: string[];
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

  const headingPattern = new RegExp(chapterHeadingLinePattern.source, 'gim');
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

export async function parseNovelFiles(
  files: readonly NovelImportFile[],
): Promise<ParsedNovelFiles> {
  if (!files.length) {
    throw new NovelImportError('请选择要导入的 TXT 或 Markdown 文件', 'files_required');
  }
  if (files.length > maxNovelChapterCount) {
    throw new NovelImportError(
      `一次最多导入 ${maxNovelChapterCount} 个章节文件`,
      'file_count_exceeded',
    );
  }

  const totalBytes = files.reduce((total, file) => total + file.size, 0);
  if (totalBytes > maxNovelBatchImportBytes) {
    throw new NovelImportError('所选文件总大小不能超过 64MB', 'batch_too_large');
  }

  const orderedFiles = files
    .map((file, originalIndex) => ({ file, originalIndex }))
    .sort((left, right) => (
      fileNameCollator.compare(left.file.name, right.file.name)
      || left.originalIndex - right.originalIndex
    ))
    .map(({ file }) => file);

  for (const file of orderedFiles) validateNovelFileExtension(file.name);

  if (orderedFiles.length === 1) {
    const file = orderedFiles[0];
    if (!file) throw new NovelImportError('请选择要导入的文件', 'files_required');
    const decoded = await decodeImportFile(file);
    const parsed = parseNovelText(decoded.text);
    return {
      ...parsed,
      fileCount: 1,
      encodings: [decoded.encoding],
      orderedFileNames: [file.name],
    };
  }

  const chapters: EditableChapter[] = [];
  const encodings: DecodedNovelFile['encoding'][] = [];
  for (const file of orderedFiles) {
    const decoded = await decodeImportFile(file);
    encodings.push(decoded.encoding);
    chapters.push(chapterFromFile(file.name, decoded.text, chapters.length));
  }

  return {
    chapters,
    characterCount: chapters.reduce(
      (total, chapter) => total + chapter.title.length + chapter.content.length,
      0,
    ),
    fileCount: orderedFiles.length,
    encodings,
    orderedFileNames: orderedFiles.map((file) => file.name),
  };
}

export function chapterTitleFromFileName(fileName: string, index = 0): string {
  let title = fileName.replace(/\.(?:txt|md)$/i, '').trim();
  title = title
    .replace(/^\s*\d{1,6}(?:\s*[_\-\u2013\u2014.\uFF0E\u3001]\s*|\s+)/, '')
    .replace(/^\s*\d{1,6}\s*(?=第[^\n]{1,30}[章节回卷部篇])/, '')
    .replace(/[＿_]+/g, ' ')
    .replace(/\s+([，。！？；：、,.!?;:])/g, '$1')
    .replace(/([，。！？；：、,.!?;:])\s+/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  return title || `第 ${index + 1} 章`;
}

function chapterFromFile(fileName: string, rawText: string, index: number): EditableChapter {
  const text = String(rawText || '').replace(/\r\n?/g, '\n').trim();
  if (!text) {
    throw new NovelImportError(`“${fileName}”中没有可导入的正文`, 'content_empty');
  }

  const lines = text.split('\n');
  const heading = lines[0]?.trim().match(chapterHeadingLinePattern);
  const title = heading
    ? (heading[1]?.trim() || lines[0]?.replace(/^#{1,6}\s*/, '').trim())
    : chapterTitleFromFileName(fileName, index);
  const content = (heading ? lines.slice(1).join('\n') : text).trim();
  if (!content) {
    throw new NovelImportError(`“${fileName}”缺少章节正文`, 'chapter_content_empty');
  }
  return editableChapter(title || chapterTitleFromFileName(fileName, index), content, index);
}

async function decodeImportFile(file: NovelImportFile): Promise<DecodedNovelFile> {
  try {
    return await decodeNovelFile(file);
  } catch (error) {
    if (error instanceof NovelImportError) {
      throw new NovelImportError(`“${file.name}”：${error.message}`, error.code);
    }
    throw error;
  }
}

function validateNovelFileExtension(fileName: string): void {
  const extension = fileName.split('.').pop()?.toLowerCase();
  if (!['txt', 'md'].includes(extension || '')) {
    throw new NovelImportError(`“${fileName}”不是 TXT 或 Markdown 文件`, 'file_type_invalid');
  }
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
