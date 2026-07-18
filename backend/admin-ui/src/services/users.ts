import { apiRequest, queryString } from '@/services/api';
import type {
  AdminUser,
  UserBanPayload,
  UserDetailResponse,
  UserEconomyPayload,
  UserListResponse,
  UserProfilePayload,
  UserRiskFilter,
  UserRole,
  UserSort,
  UserStatus,
} from '@/types/user';

export function listUsers(query: {
  q?: string;
  status?: '' | UserStatus;
  role?: '' | UserRole;
  risk?: UserRiskFilter;
  appVersionCode?: '' | number;
  sort?: UserSort;
  page?: number;
  pageSize?: number;
}): Promise<UserListResponse> {
  return apiRequest(`/admin/users${queryString(query)}`);
}

export function getUserDetail(id: number): Promise<UserDetailResponse> {
  return apiRequest(`/admin/users/${id}/activity`);
}

export function updateUserProfile(
  id: number,
  payload: UserProfilePayload,
): Promise<{ item: AdminUser }> {
  return apiRequest(`/admin/users/${id}/profile`, {
    method: 'PATCH',
    body: payload,
  });
}

export function banUser(
  id: number,
  payload: UserBanPayload,
): Promise<{ item: AdminUser; revokedSessions: number; disconnected: number }> {
  return apiRequest(`/admin/users/${id}/ban`, {
    method: 'POST',
    body: payload,
  });
}

export function unbanUser(
  id: number,
  removeKnownIps: boolean,
): Promise<{ item: AdminUser; removedIps: number }> {
  return apiRequest(`/admin/users/${id}/unban`, {
    method: 'POST',
    body: { removeKnownIps },
  });
}

export function changeUserRole(
  id: number,
  role: UserRole,
): Promise<{ item: AdminUser; revokedSessions: number }> {
  return apiRequest(`/admin/users/${id}/role`, {
    method: 'POST',
    body: { role },
  });
}

export function adjustUserEconomy(
  id: number,
  payload: UserEconomyPayload,
): Promise<{
  item: AdminUser;
  currency: string;
  delta: number;
  previousBalance: number;
  nextBalance: number;
}> {
  return apiRequest(`/admin/users/${id}/economy-adjustment`, {
    method: 'POST',
    body: payload,
  });
}

export function revokeUserSessions(
  id: number,
): Promise<{ revokedSessions: number; disconnected: number }> {
  return apiRequest(`/admin/users/${id}/revoke-sessions`, {
    method: 'POST',
    body: {},
  });
}
