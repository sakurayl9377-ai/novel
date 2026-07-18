import { apiRequest, queryString } from '@/services/api';
import type {
  CommentContextResponse,
  CommentItem,
  CommentListResponse,
  CommentStatus,
  ReportListResponse,
  ReportStatus,
} from '@/types/moderation';

export interface ModerationListQuery extends Record<string, unknown> {
  page?: number;
  pageSize?: number;
  status?: string;
  targetType?: string;
  q?: string;
}

export function listComments(query: ModerationListQuery): Promise<CommentListResponse> {
  return apiRequest(`/admin/comments${queryString(query)}`);
}

export function getCommentContext(id: number): Promise<CommentContextResponse> {
  return apiRequest(`/admin/comments/${id}/context`);
}

export function updateCommentStatus(
  id: number,
  status: CommentStatus,
): Promise<{ item: CommentItem }> {
  return apiRequest(`/admin/comments/${id}/status`, {
    method: 'PATCH',
    body: { status },
  });
}

export function listReports(query: ModerationListQuery): Promise<ReportListResponse> {
  return apiRequest(`/admin/reports${queryString(query)}`);
}

export function updateReportStatus(
  id: number,
  status: ReportStatus,
): Promise<{ ok: boolean }> {
  return apiRequest(`/admin/reports/${id}`, {
    method: 'PATCH',
    body: { status },
  });
}

export function resolveReportAndDeleteTarget(id: number): Promise<{ ok: boolean; deleted: number }> {
  return apiRequest(`/admin/reports/${id}/resolve-delete-target`, { method: 'POST' });
}
