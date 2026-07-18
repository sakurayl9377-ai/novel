import type { ReportItem } from '@/types/moderation';

export type ChatRoomCategory = 'novel' | 'anime' | 'manga';
export type ChatRoomStatus = 'active' | 'hidden' | 'deleted';
export type ChatMessageStatus = 'visible' | 'deleted';
export type ChatMessageType = 'text' | 'image' | 'audio' | 'file' | 'sticker' | 'share';
export type ChatKeywordStatus = 'active' | 'inactive';
export type ChatKeywordMatchType = 'contains' | 'exact';
export type ChatViolationAction = 'blocked' | 'temp_ban' | 'permanent_ban';
export type ChatMemberRole = 'member' | 'manager';

export interface ChatWorkbenchStats {
  activeRooms: number;
  hiddenRooms: number;
  visibleMessages: number;
  messages24h: number;
  violationsToday: number;
  activeKeywords: number;
  blockedIps: number;
}

export interface ChatRoomCategoryOption {
  key: ChatRoomCategory;
  label: string;
  count: number;
  hot: boolean;
}

export interface ChatRoom {
  roomId: string;
  id: string;
  name: string;
  avatarUrl: string;
  minLevel: number;
  category: ChatRoomCategory;
  categoryLabel: string;
  isOfficial: boolean;
  status: ChatRoomStatus;
  botEnabled: boolean;
  messageCount: number;
  deletedMessageCount: number;
  memberCount: number;
  recentMessageCount: number;
  userCount: number;
  activeUserCount?: number;
  lastCreatedAt?: string;
  lastMessageAt?: string;
  latestContent: string;
  createdAt: string;
  updatedAt: string;
}

export interface ChatRoomListResponse {
  page: number;
  pageSize: number;
  total: number;
  items: ChatRoom[];
  categories: ChatRoomCategoryOption[];
  statusCounts: Partial<Record<ChatRoomStatus, number>>;
  stats: ChatWorkbenchStats;
}

export interface ChatUserBrief {
  id: number;
  nickname: string;
  avatarUrl: string;
  badges?: unknown[];
  [key: string]: unknown;
}

export interface ChatMessage {
  id: number;
  roomId: string;
  type: ChatMessageType;
  content: string;
  mediaUrl: string;
  metadata: Record<string, unknown>;
  status: ChatMessageStatus;
  createdAt: string;
  user: ChatUserBrief;
}

export interface ChatRoomMessagesResponse {
  page: number;
  pageSize: number;
  total: number;
  room: ChatRoom;
  statusCounts: Partial<Record<ChatMessageStatus, number>>;
  items: ChatMessage[];
}

export interface ChatMessageContextResponse {
  item: ChatMessage;
  room: ChatRoom;
  nearby: ChatMessage[];
  reports: ReportItem[];
}

export interface ChatRoomPayload {
  roomId?: string;
  name: string;
  avatarUrl: string;
  minLevel: number;
  category: ChatRoomCategory;
  isOfficial: boolean;
  status?: Exclude<ChatRoomStatus, 'deleted'>;
  botEnabled: boolean;
}

export interface ChatRoomMember {
  userId: number;
  role: ChatMemberRole;
  joinedAt: string;
  lastSeenAt: string;
  lastReadAt: string;
  isSystem: boolean;
  user: {
    id: number;
    nickname: string;
    email: string;
    avatarUrl: string;
    status: string;
  };
}

export interface ChatRoomMembersResponse {
  page: number;
  pageSize: number;
  total: number;
  items: ChatRoomMember[];
}

export interface ChatKeywordRule {
  id: number;
  keyword: string;
  matchType: ChatKeywordMatchType;
  severity: 'block';
  status: ChatKeywordStatus;
  note: string;
  hitCount: number;
  lastHitAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface ChatKeywordPayload {
  keyword: string;
  matchType: ChatKeywordMatchType;
  severity?: 'block';
  status?: ChatKeywordStatus;
  note: string;
}

export interface ChatViolation {
  id: number;
  roomId: string;
  content: string;
  keywordId: number | null;
  keyword: string;
  action: ChatViolationAction;
  ip: string;
  createdAt: string;
  user: {
    id: number;
    nickname: string;
    email: string;
  };
}

export interface ChatViolationListResponse {
  page: number;
  pageSize: number;
  total: number;
  actionCounts: Partial<Record<ChatViolationAction, number>>;
  items: ChatViolation[];
}

export interface BlockedIp {
  ip: string;
  reason: string;
  createdAt: string;
  user: {
    id: number;
    nickname: string;
    email: string;
  } | null;
}

export interface BlockedIpListResponse {
  page: number;
  pageSize: number;
  total: number;
  items: BlockedIp[];
}
