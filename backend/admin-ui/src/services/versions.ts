import { apiRequest, queryString } from '@/services/api';
import type { VersionActivity, VersionWorkbenchResponse } from '@/types/versions';

export function getVersionWorkbench(query: {
  q?: string;
  versionCode?: number;
  platform?: string;
  activity?: VersionActivity;
  page?: number;
  pageSize?: number;
}): Promise<VersionWorkbenchResponse> {
  return apiRequest(`/admin/app-versions/workbench${queryString(query)}`);
}
