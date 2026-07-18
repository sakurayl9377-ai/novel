export type CommentStatus = 'visible' | 'deleted';
export type ReportStatus = 'open' | 'resolved' | 'ignored';
export type ReportTargetType = 'comment' | 'danmaku' | 'chat' | 'user';

export interface UserBrief {
  id: number;
  nickname: string;
  avatarUrl?: string;
}

export interface CommentItem {
  id: number;
  parentId: number | null;
  targetType: string;
  targetId: string;
  chapterId: string;
  episodeId: string;
  rating: number | null;
  content: string;
  likeCount: number;
  replyCount: number;
  status: CommentStatus;
  createdAt: string;
  user: UserBrief;
}

export interface CountItem {
  key: string;
  count: number;
}

export interface CommentListResponse {
  page: number;
  pageSize: number;
  total: number;
  statusCounts: Partial<Record<CommentStatus, number>>;
  targetCounts: CountItem[];
  items: CommentItem[];
}

export interface ModerationTargetContext {
  type: string;
  id: string;
  title: string;
  chapterId: string;
  chapterTitle: string;
  episodeId: string;
  episodeTitle: string;
}

export interface CommentPreview {
  type: 'comment';
  status: string;
  content: string;
  targetType: string;
  targetId: string;
  chapterId: string;
  episodeId: string;
  user: UserBrief;
  createdAt: string;
}

export interface DanmakuPreview {
  type: 'danmaku';
  status: string;
  content: string;
  videoId: string;
  animeId: string;
  episodeId: string;
  timeMs: number;
  user: UserBrief;
  createdAt: string;
}

export interface ChatPreview {
  type: 'chat';
  status: string;
  content: string;
  roomId: string;
  user: UserBrief;
  createdAt: string;
}

export interface UserPreview {
  type: 'user';
  id: number;
  email: string;
  nickname: string;
  role: string;
  status: string;
  createdAt: string;
  lastLoginAt: string | null;
}

export type ReportPreview = CommentPreview | DanmakuPreview | ChatPreview | UserPreview;

export interface ReportItem {
  id: number;
  targetType: ReportTargetType;
  targetId: string;
  reason: string;
  status: ReportStatus;
  createdAt: string;
  handledAt: string | null;
  reporter: Pick<UserBrief, 'id' | 'nickname'> | null;
  handler: Pick<UserBrief, 'id' | 'nickname'> | null;
  preview: ReportPreview | null;
}

export interface ReportListResponse {
  page: number;
  pageSize: number;
  total: number;
  statusCounts: Partial<Record<ReportStatus, number>>;
  targetCounts: CountItem[];
  items: ReportItem[];
}

export interface CommentContextResponse {
  item: CommentItem;
  parent: CommentItem | null;
  replies: CommentItem[];
  reports: ReportItem[];
  target: ModerationTargetContext;
}
