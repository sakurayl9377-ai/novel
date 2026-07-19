import { apiRequest, queryString } from '@/services/api';
import type {
  AnalyticsDays,
  AnalyticsErrorsResponse,
  AnalyticsOverviewResponse,
} from '@/types/analytics';

export function getAnalyticsOverview(days: AnalyticsDays): Promise<AnalyticsOverviewResponse> {
  return apiRequest(`/admin/analytics/overview${queryString({ days })}`);
}
export function getAnalyticsErrors(query: {
  days: AnalyticsDays;
  q?: string;
  versionCode?: number;
  fatal?: boolean;
  page?: number;
  pageSize?: number;
}): Promise<AnalyticsErrorsResponse> {
  return apiRequest(`/admin/analytics/errors${queryString({
    days: query.days,
    q: query.q,
    versionCode: query.versionCode,
    fatal: query.fatal ? 1 : '',
    page: query.page,
    pageSize: query.pageSize,
  })}`);
}
