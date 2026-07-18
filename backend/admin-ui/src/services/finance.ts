import { apiRequest, queryString } from '@/services/api';
import type {
  FinanceCurrency,
  FinanceDirection,
  FinancePeriod,
  FinanceWorkbenchResponse,
} from '@/types/finance';

export function getFinanceWorkbench(query: {
  q?: string;
  period?: FinancePeriod;
  currency?: FinanceCurrency;
  direction?: FinanceDirection;
  action?: string;
  page?: number;
  pageSize?: number;
}): Promise<FinanceWorkbenchResponse> {
  return apiRequest(`/admin/finance/workbench${queryString(query)}`);
}
