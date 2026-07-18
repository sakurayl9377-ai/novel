import { runtimeConfig } from '@/config/runtime';

export const adminTokenStorageKey = 'novelAdminToken';

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly code: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface ApiRequestOptions extends Omit<RequestInit, 'body'> {
  body?: unknown;
  auth?: boolean;
}

export async function apiRequest<T>(
  path: string,
  options: ApiRequestOptions = {},
): Promise<T> {
  const serializedBody = options.body === undefined
    ? undefined
    : JSON.stringify(options.body);
  const headers = new Headers(options.headers);
  const token = localStorage.getItem(adminTokenStorageKey) || '';
  if (options.auth !== false && token) headers.set('Authorization', `Bearer ${token}`);
  if (serializedBody !== undefined) headers.set('Content-Type', 'application/json');

  let response: Response;
  try {
    response = await fetch(`${runtimeConfig.apiPrefix}${path}`, {
      ...options,
      headers,
      body: serializedBody,
    });
  } catch (error) {
    throw new ApiError(
      error instanceof Error ? error.message : '网络连接失败，请稍后重试',
      0,
      'network_error',
    );
  }

  const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    const code = String(data.error || `http_${response.status}`);
    if (response.status === 401) {
      window.dispatchEvent(new Event('novel-admin:unauthorized'));
    }
    throw new ApiError(friendlyApiError(code), response.status, code, data);
  }
  return data as T;
}

export function queryString(values: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    if (value === '' || value === null || value === undefined) continue;
    params.set(key, String(value));
  }
  const query = params.toString();
  return query ? `?${query}` : '';
}

function friendlyApiError(code: string): string {
  const messages: Record<string, string> = {
    unauthorized: '登录已失效，请重新登录',
    admin_required: '当前账号没有管理权限',
    account_banned: '当前账号已被封禁',
    internal_error: '服务暂时不可用，请稍后重试',
  };
  return messages[code] || code.replaceAll('_', ' ');
}
