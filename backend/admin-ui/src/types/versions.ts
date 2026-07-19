export type VersionActivity = 'all' | '7d' | '30d' | 'stale';

export interface VersionInstall {
  id: number;
  installId: string;
  user: {
    id: number;
    email: string;
    nickname: string;
    status: string;
  };
  versionName: string;
  versionCode: number;
  platform: string;
  osVersion: string;
  deviceModel: string;
  firstSeenAt: string;
  lastSeenAt: string;
  lastIp: string;
}

export interface VersionPoint {
  versionName: string;
  versionCode: number;
  platform: string;
  userCount: number;
  lastSeenAt: string;
}

export interface PlatformPoint {
  platform: string;
  userCount: number;
  latestVersionCode: number;
  lastSeenAt: string;
}

export interface VersionWorkbenchResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  filters: {
    q: string;
    versionCode: number;
    platform: string;
    activity: VersionActivity;
  };
  summary: {
    registeredUsers: number;
    reportingUsers: number;
    unreportedUsers: number;
    installs: number;
    active7dInstalls: number;
    staleInstalls: number;
    latestVersionCode: number;
    latestVersionName: string;
    currentUsers: number;
    outdatedUsers: number;
    reportingCoverage: number;
    upgradeCoverage: number;
    lastSeenAt: string;
  };
  versions: VersionPoint[];
  platforms: PlatformPoint[];
  versionOptions: Array<{ versionName: string; versionCode: number }>;
  items: VersionInstall[];
}
