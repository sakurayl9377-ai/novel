export type RaceRoundStatus = 'betting' | 'locked' | 'racing' | 'settling';
export type RaceBetStatus = 'pending' | 'won' | 'lost';
export type RaceIntegrityStatus = 'healthy' | 'warning' | 'error';
export type RaceSeasonStatus = 'draft' | 'active' | 'paused' | 'ended';
export type RaceSeasonMetric = 'rounds' | 'wins' | 'bet' | 'profit';
export type RaceItemStatus = 'active' | 'disabled';

export interface RaceOperationOptions {
  roundStatuses: RaceRoundStatus[];
  betStatuses: RaceBetStatus[];
  integrityStatuses: RaceIntegrityStatus[];
  seasonStatuses: RaceSeasonStatus[];
  seasonMetrics: RaceSeasonMetric[];
  taskStatuses: RaceItemStatus[];
  rewardStatuses: RaceItemStatus[];
  tiers: RaceTier[];
}

export interface RaceTier {
  key: string;
  points: number;
}

export interface RaceIntegrityIssue {
  code: string;
  severity: 'warning' | 'error';
  message: string;
}

export interface RaceIntegrity {
  status: RaceIntegrityStatus;
  errorCount: number;
  warningCount: number;
  checks: number;
  issues: RaceIntegrityIssue[];
}

export interface RaceRoundSummary {
  id: number;
  roundCode: string;
  status: RaceRoundStatus;
  rulesVersion: number;
  phaseStartedAt: number;
  phaseEndsAt: number;
  winnerIndex: number;
  betCount: number;
  participants: number;
  totalStaked: number;
  totalPayout: number;
  houseNet: number;
  pendingBets: number;
  createdAt: string;
  lockedAt: string;
  settledAt: string;
  integrity: RaceIntegrity;
}

export interface RaceRuleSummary {
  version: number;
  legacy: boolean;
  schedule: { timezone: string; opensAt: string; closesAt: string };
  phases: {
    bettingSeconds: number;
    lockedSeconds: number;
    racingSeconds: number;
    resultSeconds: number;
  };
  limits: { minBet: number; perHorse: number; perRound: number; perDay: number };
  payoutRate: number;
  virtualLiquidity?: number;
  operatorControlsResult: false;
}

export interface ResponsibleGamingOverview {
  configuredUsers: number;
  activeCooldowns: number;
  activeSelfExclusions: number;
  customBetLimits: number;
  customLossLimits: number;
  today: {
    participants: number;
    totalBet: number;
    totalPayout: number;
    aggregateLoss: number;
    usersAtReminderThreshold: number;
  };
  notices: Array<{
    noticeDate: string;
    noticeType: string;
    count: number;
    amount: number;
  }>;
  policy: {
    mode: 'aggregate_read_only';
    userControlsMutableByAdmin: false;
  };
}

export interface RaceWorkbenchResponse {
  generatedAt: string;
  currentRound: RaceRoundSummary | null;
  service: {
    leaseKey: string;
    active: boolean;
    ownerId: string;
    leaseUntil: number;
    updatedAt: string;
  };
  finance24h: {
    betCount: number;
    participants: number;
    totalStaked: number;
    totalPayout: number;
    houseNet: number;
  };
  rounds: {
    total: number;
    betting: number;
    locked: number;
    racing: number;
    settled: number;
    recentWarnings: number;
    recentErrors: number;
  };
  season: RaceSeasonSummary | null;
  responsibleGaming: ResponsibleGamingOverview;
  rules: RaceRuleSummary;
  options: RaceOperationOptions;
}

export interface RaceRoundListResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  items: RaceRoundSummary[];
  options: RaceOperationOptions;
}

export interface RaceBet {
  id: number;
  user: { id: number; email: string; nickname: string; avatarUrl: string };
  horseIndex: number;
  amount: number;
  odds: number;
  payout: number;
  status: RaceBetStatus;
  createdAt: string;
}

export interface RaceRoundDetailResponse {
  generatedAt: string;
  item: RaceRoundSummary & {
    horses: Array<Record<string, unknown> & { name?: string; color?: string }>;
    odds: number[];
    race: Record<string, unknown>;
    result: Record<string, unknown>;
    fairness: {
      algorithm: string;
      seedCommit: string;
      seedReveal: string;
      revealVerified: boolean | null;
    };
    horseTotals: Array<{
      index: number;
      name: string;
      color: string;
      betCount: number;
      participants: number;
      totalStaked: number;
      totalPayout: number;
    }>;
  };
  bets: {
    page: number;
    pageSize: number;
    total: number;
    items: RaceBet[];
  };
  rules: RaceRuleSummary;
  options: RaceOperationOptions;
}

export interface RaceSeasonConfig {
  participationPoints: number;
  winPoints: number;
  maxProfitBonus: number;
  tiers: RaceTier[];
}

export interface RaceSeasonSummary {
  id: number;
  seasonKey: string;
  title: string;
  description: string;
  status: RaceSeasonStatus;
  startsAt: string;
  endsAt: string;
  config: RaceSeasonConfig;
  revision: number;
  participants: number;
  settlementRecords: number;
  taskCount: number;
  activeTaskCount: number;
  rewardCount: number;
  activeRewardCount: number;
  progressCount: number;
  taskClaimCount: number;
  rankingClaimCount: number;
  awardedPoints: number;
  awardedCoins: number;
  finalizedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface RaceSeasonTask {
  id: number;
  seasonId: number;
  taskKey: string;
  title: string;
  metric: RaceSeasonMetric;
  targetCount: number;
  rewardPoints: number;
  rewardCoins: number;
  status: RaceItemStatus;
  sortOrder: number;
  progressUsers: number;
  completedUsers: number;
  claimCount: number;
  identityLocked: boolean;
  rewardLocked: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface RaceSeasonReward {
  id: number;
  seasonId: number;
  rewardKey: string;
  title: string;
  tier: string;
  minRank: number;
  maxRank: number;
  rewardPoints: number;
  rewardCoins: number;
  status: RaceItemStatus;
  claimCount: number;
  awardedPoints: number;
  awardedCoins: number;
  termsLocked: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface RaceSeasonBudget {
  eligibleUsers: number;
  currentParticipants: number;
  taskPointsPerUser: number;
  taskCoinsPerUser: number;
  maximumTaskPoints: number;
  maximumTaskCoins: number;
  maximumRankingPoints: number;
  maximumRankingCoins: number;
  maximumPoints: number;
  maximumCoins: number;
  awardedPoints: number;
  awardedCoins: number;
  rankingExposure: Array<{
    rewardId: number;
    rewardKey: string;
    slots: number;
    points: number;
    coins: number;
  }>;
  conservativeUpperBound: true;
}

export interface RaceSeasonEvent {
  id: number;
  entityType: 'season' | 'task' | 'reward';
  entityId: number;
  action: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
  note: string;
  admin: { id: number; nickname: string; email: string };
  createdAt: string;
}

export interface RaceSeasonDetailResponse {
  item: RaceSeasonSummary;
  tasks: RaceSeasonTask[];
  rewards: RaceSeasonReward[];
  leaderboard: {
    page: number;
    pageSize: number;
    total: number;
    items: Array<{
      rank: number;
      user: { id: number; nickname: string; email: string; avatarUrl: string };
      points: number;
      rounds: number;
      wins: number;
      totalBet: number;
      totalPayout: number;
      profit: number;
      tier: string;
      updatedAt: string;
    }>;
  };
  budget: RaceSeasonBudget;
  events: RaceSeasonEvent[];
  transitions: RaceSeasonStatus[];
  warnings: Array<{ code: string; rewardIds: number[]; message: string }>;
  options: RaceOperationOptions;
  finalization?: { seasonId: number; awarded: number };
}

export interface RaceSeasonListResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  items: RaceSeasonSummary[];
  summary: {
    total: number;
    draft: number;
    active: number;
    paused: number;
    ended: number;
  };
  options: RaceOperationOptions;
}

export interface RaceSeasonMutationPayload {
  seasonKey?: string;
  title?: string;
  description?: string;
  startsAt?: string;
  endsAt?: string;
  config?: RaceSeasonConfig;
  expectedRevision?: number;
  changeNote: string;
}

export interface RaceTaskMutationPayload {
  expectedRevision: number;
  taskKey?: string;
  title?: string;
  metric?: RaceSeasonMetric;
  targetCount?: number;
  rewardPoints?: number;
  rewardCoins?: number;
  status?: RaceItemStatus;
  sortOrder?: number;
  changeNote: string;
}

export interface RaceRewardMutationPayload {
  expectedRevision: number;
  rewardKey?: string;
  title?: string;
  tier?: string;
  minRank?: number;
  maxRank?: number;
  rewardPoints?: number;
  rewardCoins?: number;
  status?: RaceItemStatus;
  changeNote: string;
}
