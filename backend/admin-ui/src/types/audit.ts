export type AuditPeriod = '24h' | '7d' | '30d' | 'all';
export type AuditStatus = '' | 'success' | 'error';
export type AuditMethod = '' | 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface AuditAdmin {
  id: number;
  email: string;
  nickname: string;
}

export interface AuditItem {
  id: number;
  method: string;
  path: string;
  statusCode: number;
  ip: string;
  userAgent: string;
  requestId: string;
  createdAt: string;
  admin: AuditAdmin | null;
}

export interface AuditWorkbenchResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  filters: {
    period: AuditPeriod;
    q: string;
    method: AuditMethod;
    status: AuditStatus;
  };
  summary: {
    total: number;
    errors: number;
    sensitiveActions: number;
    uniqueAdmins: number;
    lastAt: string;
    errorRate: number;
  };
  statusCounts: {
    success: number;
    error: number;
  };
  methodCounts: Array<{ key: string; count: number }>;
  items: AuditItem[];
}
