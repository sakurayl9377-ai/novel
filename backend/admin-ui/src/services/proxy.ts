import { apiRequest } from '@/services/api';
import type {
  ProxyConnectivityTest,
  ProxyNodeTestResult,
  ProxyStatus,
} from '@/types/proxy';

export function getProxyStatus(): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy');
}

export function testProxy(): Promise<ProxyConnectivityTest> {
  return apiRequest('/admin/proxy/test', { method: 'POST' });
}

export function testProxyNodes(): Promise<ProxyNodeTestResult> {
  return apiRequest('/admin/proxy/nodes/test-all', { method: 'POST' });
}

export function addProxySubscription(payload: { name: string; url: string }): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/subscriptions', { method: 'POST', body: payload });
}

export function updateProxySubscription(id: string): Promise<ProxyStatus> {
  return apiRequest(`/admin/proxy/subscriptions/${encodeURIComponent(id)}/update`, { method: 'POST' });
}

export function deleteProxySubscription(id: string): Promise<ProxyStatus> {
  return apiRequest(`/admin/proxy/subscriptions/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export function updateAllProxySubscriptions(): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/subscriptions/update-all', { method: 'POST' });
}

export function setProxyService(enabled: boolean): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/service', { method: 'PATCH', body: { enabled } });
}

export function enableProxyManualMode(): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/enable-manual-mode', { method: 'POST' });
}

export function setProxyGroup(group: string, choice: string): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/group', { method: 'PATCH', body: { group, choice } });
}

export function setProxyNode(choice: string): Promise<ProxyStatus> {
  return apiRequest('/admin/proxy/node', { method: 'PATCH', body: { choice } });
}
