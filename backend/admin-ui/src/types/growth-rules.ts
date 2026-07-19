export type GrowthRuleSetState = 'draft' | 'published' | 'superseded' | 'discarded';

export interface GrowthLevelRule {
  level: number;
  points: number;
  name: string;
  effect: string;
  dailyPointCap: number;
  targetDays: number;
  permissions: string[];
}

export interface GrowthRuleSetRecord {
  id: number;
  revision: number;
  state: GrowthRuleSetState;
  baseRevision: number;
  editVersion: number;
  rules: GrowthLevelRule[];
  note: string;
  admin: { id: number; nickname: string; email: string } | null;
  createdAt: string;
  updatedAt: string;
  publishedAt: string;
}

export interface GrowthRuleDistribution {
  level: number;
  users: number;
}

export interface GrowthRuleImpact {
  totalUsers: number;
  affectedLevelUsers: number;
  levelUpUsers: number;
  levelDownUsers: number;
  dailyCapChangedUsers: number;
  dailyCapReducedUsers: number;
  changedLevels: Array<{ level: number; fields: string[] }>;
  beforeDistribution: GrowthRuleDistribution[];
  afterDistribution: GrowthRuleDistribution[];
}

export interface GrowthPrivilegeDefinition {
  key: string;
  label: string;
  unlockLevel: number;
}

export interface GrowthRulesWorkbenchResponse {
  generatedAt: string;
  active: GrowthRuleSetRecord;
  draft: GrowthRuleSetRecord | null;
  impact: GrowthRuleImpact | null;
  publishedImpact?: GrowthRuleImpact;
  stats: {
    users: number;
    minPoints: number;
    maxPoints: number;
    averagePoints: number;
    distribution: GrowthRuleDistribution[];
  };
  capabilities: GrowthPrivilegeDefinition[];
  history: GrowthRuleSetRecord[];
}
