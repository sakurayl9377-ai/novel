import type { ChatMessage, ChatViolation } from '@/types/chat';
import type { DanmakuItem } from '@/types/danmaku';
import type { CommentItem, ReportItem } from '@/types/moderation';

export type UserStatus = 'active' | 'banned';
export type UserRole = 'user' | 'admin';
export type UserGender = 'private' | 'male' | 'female';
export type UserRiskFilter = '' | 'chat_violations' | 'reported' | 'no_version';
export type UserSort = 'newest' | 'recent' | 'risk' | 'points' | 'coins';
export type EconomyCurrency = 'points' | 'coins';
export type EconomyDirection = 'credit' | 'debit';

export interface UserGrowth {
  level: number;
  maxLevel: number;
  levelName: string;
  levelEffect: string;
  dailyPointCap: number;
  points: number;
  sakuraCoins: number;
  currentLevelPoints: number;
  nextLevelPoints: number;
  progress: number;
  effects: Array<{
    level: number;
    name: string;
    points: number;
    effect: string;
    permissions: string[];
    unlocked: boolean;
  }>;
}

export interface UserAppInstallBrief {
  versionName: string;
  versionCode: number;
  platform: string;
  deviceModel: string;
  osVersion: string;
  lastSeenAt: string;
}

export interface AdminUser {
  id: number;
  email: string;
  nickname: string;
  avatarUrl: string;
  gender: UserGender;
  bio: string;
  signature: string;
  spaceTitle: string;
  profileBannerUrl: string;
  dynamicAvatarUrl: string;
  profileTheme: string;
  growth: UserGrowth;
  role: UserRole;
  status: UserStatus;
  registerIp: string;
  lastLoginIp: string;
  bannedUntil: string;
  banReason: string;
  chatViolationTotal: number;
  chatTempBanCount: number;
  activeSessionCount: number;
  deviceCount: number;
  createdAt: string;
  lastLoginAt: string;
  appInstall: UserAppInstallBrief | null;
  stats: {
    comments: number;
    danmaku: number;
    chat: number;
    reports: number;
    reported: number;
  };
}

export interface UserWorkbenchStats {
  total: number;
  active: number;
  banned: number;
  admins: number;
  newToday: number;
  activeToday: number;
  riskUsers: number;
  chatViolationUsers: number;
  reportedUsers: number;
  noVersionUsers: number;
  activeSessions: number;
}

export interface UserVersionOption {
  versionCode: number;
  versionName: string;
  platform: string;
  userCount: number;
  lastSeenAt: string;
}

export interface UserListResponse {
  page: number;
  pageSize: number;
  total: number;
  statusCounts: Partial<Record<UserStatus, number>>;
  roleCounts: Partial<Record<UserRole, number>>;
  stats: UserWorkbenchStats;
  versionOptions: UserVersionOption[];
  items: AdminUser[];
}

export interface UserDevice {
  id: number;
  installId: string;
  versionName: string;
  versionCode: number;
  platform: string;
  deviceModel: string;
  osVersion: string;
  firstSeenAt: string;
  lastSeenAt: string;
  lastIp: string;
}

export interface UserSession {
  id: number;
  expiresAt: string;
  createdAt: string;
  revokedAt: string;
  active: boolean;
}

export interface UserRewardEvent {
  id: number;
  action: string;
  pointsDelta: number;
  coinsDelta: number;
  description: string;
  relatedType: string;
  relatedId: string;
  createdAt: string;
}

export interface BlockedUserIp {
  ip: string;
  reason: string;
  createdAt: string;
}

export interface UserDetailResponse {
  user: AdminUser;
  comments: CommentItem[];
  danmaku: DanmakuItem[];
  chat: ChatMessage[];
  reports: ReportItem[];
  reportsAgainst: ReportItem[];
  devices: UserDevice[];
  sessions: { activeCount: number; items: UserSession[] };
  rewardEvents: UserRewardEvent[];
  violations: ChatViolation[];
  blockedIps: BlockedUserIp[];
}

export interface UserProfilePayload {
  nickname: string;
  gender: UserGender;
  signature: string;
  bio: string;
}

export interface UserBanPayload {
  mode: 'temporary' | 'permanent';
  durationHours?: 1 | 24 | 72 | 168 | 720;
  reasonCode: string;
  note: string;
  blockKnownIps: boolean;
}

export interface UserEconomyPayload {
  currency: EconomyCurrency;
  direction: EconomyDirection;
  amount: number;
  reasonCode: string;
  note: string;
}
