import { apiRequest } from '@/services/api';
import type {
  GrowthLevelRule,
  GrowthRulesWorkbenchResponse,
} from '@/types/growth-rules';

export function getGrowthRulesWorkbench(): Promise<GrowthRulesWorkbenchResponse> {
  return apiRequest('/admin/growth/rules/workbench');
}

export function saveGrowthRulesDraft(payload: {
  rules: GrowthLevelRule[];
  expectedEditVersion: number;
  note: string;
}): Promise<GrowthRulesWorkbenchResponse> {
  return apiRequest('/admin/growth/rules/draft', {
    method: 'PUT',
    body: payload,
  });
}

export function publishGrowthRulesDraft(payload: {
  expectedEditVersion: number;
  note: string;
  acknowledgeImpact: boolean;
}): Promise<GrowthRulesWorkbenchResponse> {
  return apiRequest('/admin/growth/rules/draft/publish', {
    method: 'POST',
    body: payload,
  });
}

export function discardGrowthRulesDraft(payload: {
  expectedEditVersion: number;
  note: string;
}): Promise<GrowthRulesWorkbenchResponse> {
  return apiRequest('/admin/growth/rules/draft/discard', {
    method: 'POST',
    body: payload,
  });
}

export function restoreGrowthRulesRevision(
  revision: number,
  payload: {
    note: string;
    replaceDraft: boolean;
    expectedDraftEditVersion?: number;
  },
): Promise<GrowthRulesWorkbenchResponse> {
  return apiRequest(`/admin/growth/rules/revisions/${revision}/restore-draft`, {
    method: 'POST',
    body: payload,
  });
}
