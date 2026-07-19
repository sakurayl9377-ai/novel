export type AnalyticsDays = 1 | 7 | 14 | 30 | 90;

export interface AnalyticsDataQuality {
  eventCount: number;
  errorCount: number;
  reportingInstalls: number;
  lastEventAt: string;
  lastErrorAt: string;
}
export interface AnalyticsSummary {
  events: number;
  activeInstalls: number;
  sessions: number;
  errors: number;
  fatalErrors: number;
  errorGroups: number;
  crashFreeRate: number;
}

export interface AnalyticsFrameMetrics {
  samples: number;
  frames: number;
  slow16: number;
  slow32: number;
  frozen700: number;
  maxBuildMs: number;
  maxRasterMs: number;
  slow16Rate: number;
  slow32Rate: number;
}

export interface AnalyticsDailyPoint {
  day: string;
  events: number;
  activeInstalls: number;
  sessions: number;
  errors: number;
  fatalErrors: number;
}

export interface AnalyticsVersionPoint {
  versionName: string;
  versionCode: number;
  activeInstalls: number;
  events: number;
}

export interface AnalyticsScreenPoint {
  screen: string;
  views: number;
  uniqueInstalls: number;
  avgDurationMs: number;
  maxDurationMs: number;
}

export interface AnalyticsEventPoint {
  name: string;
  count: number;
  uniqueInstalls: number;
  avgDurationMs: number;
  failures: number;
}

export interface AnalyticsOverviewResponse {
  days: number;
  generatedAt: string;
  dataQuality: AnalyticsDataQuality;
  summary: AnalyticsSummary;
  frameMetrics: AnalyticsFrameMetrics;
  daily: AnalyticsDailyPoint[];
  topScreens: AnalyticsScreenPoint[];
  topEvents: AnalyticsEventPoint[];
  versions: AnalyticsVersionPoint[];
}

export interface AnalyticsErrorGroup {
  fingerprint: string;
  occurrences: number;
  affectedInstalls: number;
  fatalCount: number;
  firstSeenAt: string;
  lastSeenAt: string;
  latestVersionCode: number;
  type: string;
  message: string;
  stack: string;
  screen: string;
  fatal: boolean;
  metadata: Record<string, unknown>;
  versionName: string;
  versionCode: number;
  platform: string;
  osVersion: string;
  deviceModel: string;
  occurredAt: string;
}

export interface AnalyticsErrorsResponse {
  page: number;
  pageSize: number;
  total: number;
  days: number;
  items: AnalyticsErrorGroup[];
}
