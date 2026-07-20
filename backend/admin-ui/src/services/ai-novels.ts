import { apiFormRequest, apiRequest, queryString } from '@/services/api';
import type {
  AiChapterBatchReviewDetail,
  AiChapterReviewDetail,
  AiMetadataReviewDetail,
  AiNovelChapter,
  AiNovelDetail,
  AiNovelMetadataRevision,
  AiNovelReviewQueue,
  AiNovelReviewTarget,
  AiNovelSummary,
  CoverUploadResponse,
  EditableChapter,
  AiNovelSerializationStatus,
  PageResponse,
} from '@/types/ai-novel';

export interface NovelListQuery extends Record<string, unknown> {
  page?: number;
  pageSize?: number;
  status?: string;
  q?: string;
}

export interface SaveNovelDraftPayload {
  expectedRevision: number;
  title: string;
  penName: string;
  category: string;
  coverUrl: string;
  description: string;
  serializationStatus: AiNovelSerializationStatus;
  chapters: Array<Pick<EditableChapter, 'title' | 'content'> & {
    id?: number;
    publishedChapterId?: number | null;
  }>;
}

export function listCreatorNovels(query: NovelListQuery): Promise<PageResponse<AiNovelSummary>> {
  return apiRequest(`/creator/ai-novels${queryString(query)}`);
}

export function listReviewNovels(query: NovelListQuery): Promise<PageResponse<AiNovelSummary>> {
  return apiRequest(`/admin/ai-novels${queryString(query)}`);
}

export function listReviewChapters(query: NovelListQuery): Promise<PageResponse<AiNovelChapter>> {
  return apiRequest(`/admin/ai-novel-chapters${queryString(query)}`);
}

export function getReviewQueue(query: NovelListQuery): Promise<AiNovelReviewQueue> {
  return apiRequest(`/admin/ai-novel-review-queue${queryString(query)}`);
}

export function createNovelDraft(): Promise<AiNovelDetail> {
  return apiRequest('/creator/ai-novels/drafts', { method: 'POST', body: {} });
}

export function getCreatorNovel(id: number): Promise<AiNovelDetail> {
  return apiRequest(`/creator/ai-novels/${id}`);
}

export function getReviewNovel(id: number): Promise<AiNovelDetail> {
  return apiRequest(`/admin/ai-novels/${id}`);
}

export function getReviewChapter(id: number): Promise<AiChapterReviewDetail> {
  return apiRequest(`/admin/ai-novel-chapters/${id}`);
}

export function getReviewChapterBatch(id: number): Promise<AiChapterBatchReviewDetail> {
  return apiRequest(`/admin/ai-novel-chapter-submission-batches/${id}`);
}

export function getReviewMetadata(id: number): Promise<AiMetadataReviewDetail> {
  return apiRequest(`/admin/ai-novel-metadata-revisions/${id}`);
}

export function saveNovelDraft(id: number, payload: SaveNovelDraftPayload): Promise<AiNovelDetail> {
  return apiRequest(`/creator/ai-novels/${id}/draft`, {
    method: 'PUT',
    body: payload,
  });
}

export function submitNovel(id: number, expectedRevision: number): Promise<AiNovelDetail> {
  return apiRequest(`/creator/ai-novels/${id}/submit`, {
    method: 'POST',
    body: { expectedRevision },
  });
}

export function deleteNovel(id: number): Promise<{ ok: boolean }> {
  return apiRequest(`/creator/ai-novels/${id}`, { method: 'DELETE' });
}

export function reviewNovel(
  id: number,
  decision: 'approve' | 'reject',
  expectedRevision: number,
  reviewNote = '',
): Promise<{ item: AiNovelSummary }> {
  return apiRequest(`/admin/ai-novels/${id}/review`, {
    method: 'POST',
    body: { decision, expectedRevision, reviewNote },
  });
}

export function reviewChapter(
  id: number,
  decision: 'approve' | 'reject',
  expectedRevision: number,
  reviewNote = '',
): Promise<{ item: AiNovelChapter }> {
  return apiRequest(`/admin/ai-novel-chapters/${id}/review`, {
    method: 'POST',
    body: { decision, expectedRevision, reviewNote },
  });
}

export function reviewMetadata(
  id: number,
  decision: 'approve' | 'reject',
  expectedRevision: number,
  reviewNote = '',
): Promise<{ item: AiNovelMetadataRevision }> {
  return apiRequest(`/admin/ai-novel-metadata-revisions/${id}/review`, {
    method: 'POST',
    body: { decision, expectedRevision, reviewNote },
  });
}

export function reviewChapterBatch(
  id: number,
  decision: 'approve' | 'reject',
  expectedRevision: number,
  reviewNote = '',
): Promise<AiChapterBatchReviewDetail> {
  return apiRequest(`/admin/ai-novel-chapter-submission-batches/${id}/review`, {
    method: 'POST',
    body: { decision, expectedRevision, reviewNote },
  });
}

export function batchReviewNovels(
  items: AiNovelReviewTarget[],
  decision: 'approve' | 'reject',
  reviewNote = '',
): Promise<{ reviewed: Array<Pick<AiNovelReviewTarget, 'kind' | 'id'>> }> {
  return apiRequest('/admin/ai-novel-reviews/batch', {
    method: 'POST',
    body: { items, decision, reviewNote },
  });
}

export function uploadNovelCover(file: File): Promise<CoverUploadResponse> {
  const body = new FormData();
  body.append('file', file, file.name);
  return apiFormRequest('/creator/ai-novel-covers', body);
}
