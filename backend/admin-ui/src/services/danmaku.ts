import { apiRequest, queryString } from '@/services/api';
import type {
  DanmakuAnimeCandidate,
  DanmakuContextResponse,
  DanmakuEpisodeCandidate,
  DanmakuItem,
  DanmakuListResponse,
  DanmakuStatus,
} from '@/types/danmaku';

export interface DanmakuListQuery extends Record<string, unknown> {
  page?: number;
  pageSize?: number;
  q?: string;
  status?: string;
  animeId?: string;
  episodeId?: string;
  videoId?: string;
}

export function listDanmaku(query: DanmakuListQuery): Promise<DanmakuListResponse> {
  return apiRequest(`/admin/danmaku${queryString(query)}`);
}

export function getDanmakuContext(id: number): Promise<DanmakuContextResponse> {
  return apiRequest(`/admin/danmaku/${id}/context`);
}

export function updateDanmakuStatus(
  id: number,
  status: DanmakuStatus,
): Promise<{ item: DanmakuItem }> {
  return apiRequest(`/admin/danmaku/${id}/status`, {
    method: 'PATCH',
    body: { status },
  });
}

export function listDanmakuAnime(query: Record<string, unknown> = {}): Promise<{ items: DanmakuAnimeCandidate[] }> {
  return apiRequest(`/admin/danmaku/anime-search${queryString(query)}`);
}

export function listDanmakuEpisodes(
  animeId: string,
  query: Record<string, unknown> = {},
): Promise<{ items: DanmakuEpisodeCandidate[] }> {
  return apiRequest(`/admin/danmaku/anime/${encodeURIComponent(animeId)}/episodes${queryString(query)}`);
}
