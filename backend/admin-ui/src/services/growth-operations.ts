import { apiFormRequest, apiRequest, queryString } from '@/services/api';
import type {
  CampaignBannerUpload,
  CampaignDetailResponse,
  CampaignListResponse,
  CampaignMutationPayload,
  CampaignStatus,
  CampaignTaskMutationPayload,
  CatalogSearchItem,
  GrowthContentType,
  GrowthOperationsWorkbenchResponse,
  GrowthRankingsResponse,
  RankingControl,
  RankingMetric,
  RankingPeriod,
} from '@/types/growth-operations';

export function getGrowthOperationsWorkbench(query: {
  days: number;
  contentType: GrowthContentType;
}): Promise<GrowthOperationsWorkbenchResponse> {
  return apiRequest(`/admin/growth/workbench${queryString(query)}`);
}

export function getGrowthRankings(query: {
  period: RankingPeriod;
  metric: RankingMetric;
  contentType: GrowthContentType;
  limit?: number;
}): Promise<GrowthRankingsResponse> {
  return apiRequest(`/admin/growth/rankings${queryString(query)}`);
}

export function saveGrowthRankingControl(
  rankingKey: string,
  contentKey: string,
  payload: {
    pinned: boolean;
    excluded: boolean;
    manualWeight: number;
    expectedRevision: number;
    note: string;
  },
): Promise<{ item: RankingControl }> {
  return apiRequest(
    `/admin/growth/rankings/${encodeURIComponent(rankingKey)}/${encodeURIComponent(contentKey)}`,
    { method: 'PUT', body: payload },
  );
}

export function removeGrowthRankingControl(
  rankingKey: string,
  contentKey: string,
  payload: { expectedRevision: number; note: string },
): Promise<{ deleted: true }> {
  return apiRequest(
    `/admin/growth/rankings/${encodeURIComponent(rankingKey)}/${encodeURIComponent(contentKey)}`,
    { method: 'DELETE', body: payload },
  );
}

export function searchGrowthCatalog(query: {
  q?: string;
  type?: GrowthContentType;
  status?: string;
  page?: number;
  pageSize?: number;
}): Promise<{ page: number; pageSize: number; total: number; items: CatalogSearchItem[] }> {
  return apiRequest(`/admin/content/catalog${queryString(query)}`);
}

export function getGrowthCampaigns(query: {
  q?: string;
  status?: '' | CampaignStatus;
  page?: number;
  pageSize?: number;
}): Promise<CampaignListResponse> {
  return apiRequest(`/admin/growth/campaigns${queryString(query)}`);
}

export function getGrowthCampaign(id: number): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${id}`);
}

export function uploadCampaignBanner(file: File): Promise<CampaignBannerUpload> {
  const form = new FormData();
  form.append('file', file);
  return apiFormRequest('/admin/growth/campaign-banners', form);
}

export function createGrowthCampaign(
  payload: CampaignMutationPayload,
): Promise<CampaignDetailResponse> {
  return apiRequest('/admin/growth/campaigns', { method: 'POST', body: payload });
}

export function updateGrowthCampaign(
  id: number,
  payload: CampaignMutationPayload,
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${id}`, { method: 'PATCH', body: payload });
}

export function transitionGrowthCampaign(
  id: number,
  payload: {
    status: CampaignStatus;
    expectedRevision: number;
    note: string;
    acknowledgeBudget?: boolean;
  },
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${id}/status`, { method: 'POST', body: payload });
}

export function restoreGrowthCampaign(
  id: number,
  payload: { revision: number; expectedRevision: number; note: string },
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${id}/rollback`, { method: 'POST', body: payload });
}

export function createGrowthCampaignTask(
  campaignId: number,
  payload: CampaignTaskMutationPayload,
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${campaignId}/tasks`, {
    method: 'POST',
    body: payload,
  });
}

export function updateGrowthCampaignTask(
  campaignId: number,
  taskId: number,
  payload: CampaignTaskMutationPayload,
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${campaignId}/tasks/${taskId}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function removeGrowthCampaignTask(
  campaignId: number,
  taskId: number,
  payload: { expectedRevision: number; note: string },
): Promise<CampaignDetailResponse> {
  return apiRequest(`/admin/growth/campaigns/${campaignId}/tasks/${taskId}`, {
    method: 'DELETE',
    body: payload,
  });
}
