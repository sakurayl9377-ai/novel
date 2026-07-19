export type GrowthContentType = '' | 'novel' | 'manga' | 'anime';
export type RankingPeriod = 'daily' | 'weekly';
export type RankingMetric = 'hot' | 'new' | 'following' | 'completion';
export type CampaignStatus = 'draft' | 'active' | 'paused' | 'ended';
export type CampaignAudiencePreset =
  | 'all_registered'
  | 'new_users'
  | 'active_users'
  | 'readers'
  | 'anime_viewers'
  | 'legacy_custom';

export interface GrowthOperationOptions {
  periods: RankingPeriod[];
  metrics: RankingMetric[];
  contentTypes: Array<Exclude<GrowthContentType, ''>>;
  rankingScopes: string[];
  campaignStatuses: CampaignStatus[];
  audiencePresets: Array<Exclude<CampaignAudiencePreset, 'legacy_custom'>>;
  taskEvents: string[];
}

export interface FunnelStep {
  event: string;
  events: number;
  actors: number;
  conversionFromPrevious: number | null;
}

export interface ContentConversion {
  contentKey: string;
  title: string;
  contentType: string;
  exposures: number;
  opens: number;
  starts: number;
  completes: number;
  openRate: number;
  completionRate: number;
}

export interface RetentionCohort {
  cohortDate: string;
  cohortSize: number;
  day1: number;
  day7: number;
  day1Rate: number;
  day7Rate: number;
}

export interface GrowthOperationsWorkbenchResponse {
  generatedAt: string;
  days: number;
  contentType: GrowthContentType;
  funnel: {
    days: number;
    steps: FunnelStep[];
    content: ContentConversion[];
    retention: RetentionCohort[];
  };
  totals: {
    behaviorEvents: number;
    activeUsers30d: number;
    activeCampaigns: number;
    rewardClaims: number;
    rewardPoints: number;
    rewardCoins: number;
  };
  options: GrowthOperationOptions;
}

export interface RankingBoardItem {
  rank: number;
  score: number;
  pinned: boolean;
  excluded: boolean;
  explanation: string;
  content: {
    stableKey: string;
    contentType: string;
    title: string;
    author: string;
    coverUrl: string;
  };
  signals: {
    exposures: number;
    clicks: number;
    opens: number;
    starts: number;
    completes: number;
    favorites: number;
    completionRate: number;
  };
}

export interface AdminIdentity {
  id: number;
  nickname: string;
  email: string;
}

export interface RankingControl {
  rankingKey: string;
  contentKey: string;
  title: string;
  contentType: string;
  coverUrl: string;
  pinned: boolean;
  excluded: boolean;
  manualWeight: number;
  note: string;
  revision: number;
  admin: AdminIdentity;
  createdAt: string;
  updatedAt: string;
}

export interface GrowthOperationEvent {
  id: number;
  entityType: string;
  entityKey: string;
  action: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  note: string;
  admin: AdminIdentity;
  createdAt: string;
}

export interface GrowthRankingsResponse {
  generatedAt: string;
  period: RankingPeriod;
  metric: RankingMetric;
  contentType: GrowthContentType;
  rankingKey: string;
  items: RankingBoardItem[];
  controls: RankingControl[];
  events: GrowthOperationEvent[];
  options: GrowthOperationOptions;
}

export interface CatalogSearchItem {
  stableKey: string;
  contentType: string;
  title: string;
  author: string;
  coverUrl: string;
  status: string;
}

export interface CampaignSummary {
  id: number;
  campaignKey: string;
  title: string;
  description: string;
  bannerUrl: string;
  status: CampaignStatus;
  startsAt: string;
  endsAt: string;
  audiencePreset: CampaignAudiencePreset;
  minVersionCode: number;
  maxVersionCode: number;
  revision: number;
  taskCount: number;
  activeTaskCount: number;
  progressCount: number;
  claimCount: number;
  claimedUsers: number;
  awardedPoints: number;
  awardedCoins: number;
  createdAt: string;
  updatedAt: string;
}

export interface CampaignTask {
  id: number;
  campaignId: number;
  taskKey: string;
  title: string;
  description: string;
  eventName: string;
  targetCount: number;
  rewardPoints: number;
  rewardCoins: number;
  contentType: GrowthContentType;
  contentKey: string;
  sortOrder: number;
  status: 'active' | 'disabled';
  progressUsers: number;
  completedUsers: number;
  claimCount: number;
  identityLocked: boolean;
  rewardLocked: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface CampaignBudget {
  audiencePreset: CampaignAudiencePreset;
  eligibleUsers: number;
  activeTasks: number;
  perUserPoints: number;
  perUserCoins: number;
  potentialPoints: number;
  potentialCoins: number;
  claimedUsers: number;
  claims: number;
  awardedPoints: number;
  awardedCoins: number;
}

export interface CampaignRevision {
  revision: number;
  note: string;
  admin: AdminIdentity;
  createdAt: string;
}

export interface CampaignDetailResponse {
  item: CampaignSummary;
  tasks: CampaignTask[];
  budget: CampaignBudget;
  revisions: CampaignRevision[];
  events: GrowthOperationEvent[];
  transitions: CampaignStatus[];
  options: GrowthOperationOptions;
  restoredFromRevision?: number;
}

export interface CampaignListResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  items: CampaignSummary[];
  summary: {
    total: number;
    draft: number;
    active: number;
    paused: number;
    ended: number;
    pendingClaims: number;
  };
  options: GrowthOperationOptions;
}

export interface CampaignMutationPayload {
  campaignKey?: string;
  title?: string;
  description?: string;
  bannerUrl?: string;
  startsAt?: string;
  endsAt?: string;
  audiencePreset?: Exclude<CampaignAudiencePreset, 'legacy_custom'>;
  minVersionCode?: number;
  maxVersionCode?: number;
  expectedRevision?: number;
  changeNote: string;
}

export interface CampaignTaskMutationPayload {
  expectedRevision: number;
  taskKey?: string;
  title?: string;
  description?: string;
  eventName?: string;
  targetCount?: number;
  rewardPoints?: number;
  rewardCoins?: number;
  contentType?: GrowthContentType;
  contentKey?: string;
  sortOrder?: number;
  status?: 'active' | 'disabled';
  changeNote: string;
}

export interface CampaignBannerUpload {
  url: string;
  mimeType: string;
  size: number;
}
