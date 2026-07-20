export type AiNovelStatus = 'draft' | 'pending' | 'published' | 'rejected';
export type AiNovelMetadataRevisionStatus = 'draft' | 'pending' | 'approved' | 'rejected';
export type AiNovelSerializationStatus = 'ongoing' | 'completed';
export type AiChapterChangeType = 'published' | 'add' | 'update';
export type AiReviewDecision = 'approve' | 'reject' | 'direct_publish';
export type AiReviewTargetKind = 'novel' | 'metadata' | 'chapter';

export interface AiNovelSummary {
  id: string;
  numericId: number;
  title: string;
  author: string;
  coverUrl: string;
  description: string;
  category: string;
  status: AiNovelStatus;
  serializationStatus: AiNovelSerializationStatus;
  reviewNote: string;
  revision: number;
  chapterCount: number;
  publishedChapterCount: number;
  pendingChapterCount: number;
  ownerId: number;
  ownerNickname: string;
  ownerEmail: string;
  submittedAt: string;
  reviewedAt: string;
  publishedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface AiNovelChapter {
  id: number;
  novelId: number;
  novelTitle: string;
  title: string;
  content?: string;
  index: number;
  status: AiNovelStatus;
  replacesChapterId: number | null;
  publishedChapterId: number | null;
  changeType: AiChapterChangeType;
  originalTitle?: string;
  originalContent?: string;
  reviewNote: string;
  revision: number;
  ownerId: number;
  ownerNickname: string;
  ownerEmail: string;
  submittedAt: string;
  reviewedAt: string;
  publishedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface AiNovelReviewEvent {
  id: number;
  novelId: number;
  chapterId: number | null;
  submissionRevision: number;
  decision: AiReviewDecision;
  note: string;
  reviewerId: number;
  reviewerNickname: string;
  reviewerEmail: string;
  createdAt: string;
}

export interface AiNovelMetadataRevision {
  id: number;
  novelId: number;
  novelTitle: string;
  title: string;
  penName: string;
  category: string;
  coverUrl: string;
  description: string;
  serializationStatus: AiNovelSerializationStatus;
  status: AiNovelMetadataRevisionStatus;
  reviewNote: string;
  revision: number;
  ownerId: number;
  ownerNickname: string;
  ownerEmail: string;
  submittedAt: string;
  reviewedAt: string;
  publishedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface AiNovelMetadataReviewEvent {
  id: number;
  novelId: number;
  metadataRevisionId: number;
  submissionRevision: number;
  decision: AiReviewDecision;
  note: string;
  reviewerId: number;
  reviewerNickname: string;
  reviewerEmail: string;
  createdAt: string;
}

export interface AiNovelDetail {
  item: AiNovelSummary;
  chapters: AiNovelChapter[];
  reviews: AiNovelReviewEvent[];
  metadataRevision: AiNovelMetadataRevision | null;
  metadataReviews: AiNovelMetadataReviewEvent[];
}

export interface AiChapterReviewDetail {
  item: AiNovelChapter;
  reviews: AiNovelReviewEvent[];
}

export interface AiMetadataReviewDetail {
  item: AiNovelMetadataRevision;
  novel: AiNovelSummary;
  reviews: AiNovelMetadataReviewEvent[];
}

export interface AiNovelReviewBook extends AiNovelSummary {
  chapters: AiNovelChapter[];
  metadataRevision: AiNovelMetadataRevision | null;
}

export interface AiNovelReviewAuthor {
  ownerId: number;
  ownerNickname: string;
  ownerEmail: string;
  novelCount: number;
  pendingNovelCount: number;
  pendingMetadataCount: number;
  pendingChapterCount: number;
  novels: AiNovelReviewBook[];
}

export interface AiNovelReviewQueue {
  items: AiNovelReviewAuthor[];
  page: number;
  pageSize: number;
  total: number;
  summary: {
    pendingNovelCount: number;
    pendingMetadataCount: number;
    pendingChapterCount: number;
  };
}

export interface AiNovelReviewTarget {
  kind: AiReviewTargetKind;
  id: number;
  expectedRevision: number;
}

export interface PageResponse<T> {
  items: T[];
  page: number;
  pageSize: number;
  total: number;
}

export interface EditableChapter {
  clientId: string;
  title: string;
  content: string;
  id?: number;
  publishedChapterId?: number | null;
  workflowStatus?: AiNovelStatus;
  changeType?: AiChapterChangeType;
  reviewNote?: string;
  originalTitle?: string;
  originalContent?: string;
  locked?: boolean;
}

export interface CoverUploadResponse {
  url: string;
  mimeType: string;
  size: number;
}
