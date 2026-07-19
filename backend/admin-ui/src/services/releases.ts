import { apiRequest } from '@/services/api';
import type { ReleaseWorkbenchResponse } from '@/types/releases';

export function getReleaseWorkbench(): Promise<ReleaseWorkbenchResponse> {
  return apiRequest('/admin/releases/workbench');
}
