import { apiRequest, queryString } from '@/services/api';
import type { AuditMethod, AuditPeriod, AuditStatus, AuditWorkbenchResponse } from '@/types/audit';

export function getAuditWorkbench(query: {
  q?: string;
  period?: AuditPeriod;
  method?: AuditMethod;
  status?: AuditStatus;
  page?: number;
  pageSize?: number;
}): Promise<AuditWorkbenchResponse> {
  return apiRequest(`/admin/audit/workbench${queryString(query)}`);
}
