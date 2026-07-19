import { apiRequest, queryString } from '@/services/api';
import type {
  RaceIntegrityStatus,
  RaceRewardMutationPayload,
  RaceRoundDetailResponse,
  RaceRoundListResponse,
  RaceRoundStatus,
  RaceSeasonDetailResponse,
  RaceSeasonListResponse,
  RaceSeasonMutationPayload,
  RaceSeasonStatus,
  RaceTaskMutationPayload,
  ResponsibleGamingOverview,
  RaceWorkbenchResponse,
} from '@/types/race-operations';

export function getRaceWorkbench(): Promise<RaceWorkbenchResponse> {
  return apiRequest('/admin/horse-race/workbench');
}

export function getRaceRounds(query: {
  q?: string;
  status?: '' | RaceRoundStatus;
  integrity?: '' | RaceIntegrityStatus;
  page?: number;
  pageSize?: number;
}): Promise<RaceRoundListResponse> {
  return apiRequest(`/admin/horse-race/rounds${queryString(query)}`);
}

export function getRaceRound(
  id: number,
  query: {
    betQ?: string;
    betStatus?: string;
    horseIndex?: number | '';
    page?: number;
    pageSize?: number;
  } = {},
): Promise<RaceRoundDetailResponse> {
  return apiRequest(`/admin/horse-race/rounds/${id}${queryString(query)}`);
}

export function getResponsibleGamingOverview(): Promise<ResponsibleGamingOverview> {
  return apiRequest('/admin/horse-race/responsible-gaming');
}

export function getRaceSeasons(query: {
  q?: string;
  status?: '' | RaceSeasonStatus;
  page?: number;
  pageSize?: number;
}): Promise<RaceSeasonListResponse> {
  return apiRequest(`/admin/horse-race/seasons${queryString(query)}`);
}

export function getRaceSeason(
  id: number,
  query: { leaderboardPage?: number; leaderboardPageSize?: number } = {},
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${id}${queryString(query)}`);
}

export function createRaceSeason(
  payload: RaceSeasonMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest('/admin/horse-race/seasons', { method: 'POST', body: payload });
}

export function updateRaceSeason(
  id: number,
  payload: RaceSeasonMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${id}`, { method: 'PATCH', body: payload });
}

export function transitionRaceSeason(
  id: number,
  payload: {
    status: RaceSeasonStatus;
    expectedRevision: number;
    note: string;
    acknowledgeBudget?: boolean;
  },
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${id}/status`, {
    method: 'POST',
    body: payload,
  });
}

export function finalizeRaceSeason(
  id: number,
  payload: {
    expectedRevision: number;
    note: string;
    acknowledgeEarlyFinalize?: boolean;
  },
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${id}/finalize`, {
    method: 'POST',
    body: payload,
  });
}

export function createRaceSeasonTask(
  seasonId: number,
  payload: RaceTaskMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/tasks`, {
    method: 'POST',
    body: payload,
  });
}

export function updateRaceSeasonTask(
  seasonId: number,
  taskId: number,
  payload: RaceTaskMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/tasks/${taskId}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function removeRaceSeasonTask(
  seasonId: number,
  taskId: number,
  payload: { expectedRevision: number; note: string },
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/tasks/${taskId}`, {
    method: 'DELETE',
    body: payload,
  });
}

export function createRaceSeasonReward(
  seasonId: number,
  payload: RaceRewardMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/rewards`, {
    method: 'POST',
    body: payload,
  });
}

export function updateRaceSeasonReward(
  seasonId: number,
  rewardId: number,
  payload: RaceRewardMutationPayload,
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/rewards/${rewardId}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function removeRaceSeasonReward(
  seasonId: number,
  rewardId: number,
  payload: { expectedRevision: number; note: string },
): Promise<RaceSeasonDetailResponse> {
  return apiRequest(`/admin/horse-race/seasons/${seasonId}/rewards/${rewardId}`, {
    method: 'DELETE',
    body: payload,
  });
}
