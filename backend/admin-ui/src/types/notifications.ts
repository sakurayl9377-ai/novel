export type NotificationStatus = 'draft' | 'sent' | 'canceled' | 'failed';
export type NotificationCategory = 'system' | 'update' | 'operation' | 'security' | 'growth' | 'race' | 'ai_novel';
export type NotificationAudienceScope = 'all_active' | 'recent_active';

export interface NotificationAudience {
  scope: NotificationAudienceScope;
  recentDays: number;
  platforms: string[];
  minVersionCode: number;
  maxVersionCode: number;
  includeAdmins: boolean;
  legacy?: boolean;
}

export interface NotificationOperator {
  id: number;
  nickname: string;
  email: string;
}

export interface NotificationItem {
  id: number;
  title: string;
  content: string;
  category: NotificationCategory;
  status: NotificationStatus;
  audience: NotificationAudience;
  recipientCount: number;
  deliveredCount: number;
  failedCount: number;
  previewCount: number;
  unreadCount: number;
  revision: number;
  failureReason: string;
  sentAt: string;
  createdAt: string;
  updatedAt: string;
  operator: NotificationOperator | null;
}

export interface NotificationStats {
  total: number;
  drafts: number;
  sent: number;
  canceled: number;
  failed: number;
  sent24h: number;
  delivered: number;
  unread: number;
  sentRecords: number;
}

export interface NotificationOptions {
  statuses: NotificationStatus[];
  categories: NotificationCategory[];
  scopes: NotificationAudienceScope[];
  recentDays: number[];
  platforms: string[];
  maxRecipients: number;
}

export interface NotificationPreviewSample {
  id: number;
  nickname: string;
  createdAt: string;
  lastActiveAt: string;
  platform: string;
  versionCode: number;
}

export interface NotificationPreview {
  live: boolean;
  eligibleCount: number;
  sample: NotificationPreviewSample[];
  truncated: boolean;
  maxRecipients: number;
  capturedAt?: string;
  audience?: NotificationAudience;
}

export interface NotificationEvent {
  id: number;
  action: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  note: string;
  createdAt: string;
  operator: NotificationOperator | null;
}

export interface NotificationDelivery {
  attemptedCount: number;
  deliveredCount: number;
  failedCount: number;
  unreadCount: number;
  firstCreatedAt: string;
  lastCreatedAt: string;
  atomic: boolean;
}

export interface NotificationWorkbenchResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  items: NotificationItem[];
  stats: NotificationStats;
  options: NotificationOptions;
}

export interface NotificationDetailResponse {
  generatedAt: string;
  item: NotificationItem;
  preview: NotificationPreview & { audience: NotificationAudience };
  delivery: NotificationDelivery;
  events: NotificationEvent[];
  options: NotificationOptions;
}

export interface NotificationMutationPayload {
  title: string;
  content: string;
  category: NotificationCategory;
  audience: NotificationAudience;
  expectedRevision?: number;
  changeNote: string;
}

export interface NotificationSendResponse {
  ok: boolean;
  idempotent: boolean;
  item: NotificationItem;
  delivery: NotificationDelivery;
}

export interface AppAnnouncementCurrent {
  enabled: boolean;
  id: string;
  version: string;
  title: string;
  content: string;
  updatedAt: string;
  activeRevisionId: number;
  latestRevisionId: number;
}

export interface AppAnnouncementRevision {
  id: number;
  version: string;
  title: string;
  content: string;
  enabled: boolean;
  sourceRevisionId: number | null;
  note: string;
  createdAt: string;
  operator: NotificationOperator | null;
}

export interface AppAnnouncementWorkbenchResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  current: AppAnnouncementCurrent;
  items: AppAnnouncementRevision[];
  stats: {
    total: number;
    published: number;
    disabled: number;
  };
}

export interface AppAnnouncementMutationResponse {
  ok: boolean;
  changed: boolean;
  current: Omit<AppAnnouncementCurrent, 'activeRevisionId' | 'latestRevisionId'>;
  revision?: AppAnnouncementRevision;
}
