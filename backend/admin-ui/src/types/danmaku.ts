import type { ReportItem, UserBrief } from '@/types/moderation';

export type DanmakuStatus = 'visible' | 'deleted';

export interface DanmakuItem {
  id: number;
  videoId: string;
  animeId: string;
  episodeId: string;
  timeMs: number;
  content: string;
  color: string;
  mode: string;
  status: DanmakuStatus;
  createdAt: string;
  user: UserBrief;
  isImported: boolean;
}

export interface DanmakuStats {
  animeCount: number;
  videoCount: number;
  userCount: number;
  importedCount: number;
}

export interface DanmakuListResponse {
  page: number;
  pageSize: number;
  total: number;
  statusCounts: Partial<Record<DanmakuStatus, number>>;
  stats: DanmakuStats;
  items: DanmakuItem[];
}

export interface DanmakuAnimeCandidate {
  animeId: string;
  animeTitle: string;
  titleMissing?: boolean;
  episodeCount: number;
  danmakuCount: number;
  userCount?: number;
  aliasCount: number;
  lastCreatedAt?: string;
  source?: string;
  sourceLabel?: string;
}

export interface DanmakuEpisodeCandidate {
  videoId: string;
  animeId: string;
  animeTitle: string;
  titleMissing?: boolean;
  episodeId: string;
  episodeTitle: string;
  danmakuCount: number;
  userCount: number;
  aliasCount: number;
  minTimeMs?: number | null;
  maxTimeMs?: number | null;
  lastCreatedAt?: string;
  latestContent?: string;
}

export interface DanmakuAlias {
  aliasVideoId: string;
  canonicalVideoId: string;
  animeId: string;
  episodeId: string;
  sourceName: string;
  createdAt: string;
}

export interface DanmakuGroup {
  videoId: string;
  animeId: string;
  animeTitle: string;
  episodeId: string;
  episodeTitle: string;
  aliasCount: number;
  bilibiliImportedCount: number;
  danmakuCount?: number;
  userCount?: number;
  minTimeMs?: number | null;
  maxTimeMs?: number | null;
  lastCreatedAt?: string;
}

export interface DanmakuContextResponse {
  item: DanmakuItem;
  group: DanmakuGroup;
  aliases: DanmakuAlias[];
  nearby: DanmakuItem[];
  reports: ReportItem[];
}
