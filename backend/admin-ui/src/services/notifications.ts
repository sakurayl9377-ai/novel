import { apiRequest, queryString } from '@/services/api';
import type {
  AppAnnouncementMutationResponse,
  AppAnnouncementWorkbenchResponse,
  NotificationDetailResponse,
  NotificationItem,
  NotificationMutationPayload,
  NotificationPreview,
  NotificationSendResponse,
  NotificationWorkbenchResponse,
} from '@/types/notifications';

export function getAppAnnouncements(query: {
  page?: number;
  pageSize?: number;
} = {}): Promise<AppAnnouncementWorkbenchResponse> {
  return apiRequest(`/admin/app-announcements${queryString(query)}`);
}

export function publishAppAnnouncement(payload: {
  expectedVersion: string;
  title: string;
  content: string;
  changeNote: string;
}): Promise<AppAnnouncementMutationResponse> {
  return apiRequest('/admin/app-announcements/publish', { method: 'POST', body: payload });
}

export function disableAppAnnouncement(payload: {
  expectedVersion: string;
  changeNote: string;
}): Promise<AppAnnouncementMutationResponse> {
  return apiRequest('/admin/app-announcements/disable', { method: 'POST', body: payload });
}

export function republishAppAnnouncement(
  id: number,
  payload: { expectedVersion: string; changeNote: string },
): Promise<AppAnnouncementMutationResponse> {
  return apiRequest(`/admin/app-announcements/${id}/republish`, {
    method: 'POST',
    body: payload,
  });
}

export function getNotifications(query: {
  q?: string;
  status?: string;
  category?: string;
  page?: number;
  pageSize?: number;
} = {}): Promise<NotificationWorkbenchResponse> {
  return apiRequest(`/admin/notifications${queryString(query)}`);
}

export function getNotification(id: number): Promise<NotificationDetailResponse> {
  return apiRequest(`/admin/notifications/${id}`);
}

export function previewNotification(payload: {
  title: string;
  content: string;
  category: string;
  audience: NotificationMutationPayload['audience'];
}): Promise<NotificationPreview & { audience: NotificationMutationPayload['audience'] }> {
  return apiRequest('/admin/notifications/preview', { method: 'POST', body: payload });
}

export function createNotification(
  payload: NotificationMutationPayload,
): Promise<NotificationDetailResponse> {
  return apiRequest('/admin/notifications', { method: 'POST', body: payload });
}

export function updateNotification(
  id: number,
  payload: NotificationMutationPayload,
): Promise<NotificationDetailResponse> {
  return apiRequest(`/admin/notifications/${id}`, { method: 'PATCH', body: payload });
}

export function sendNotification(
  id: number,
  payload: { expectedRevision: number; idempotencyKey: string; changeNote: string },
): Promise<NotificationSendResponse> {
  return apiRequest(`/admin/notifications/${id}/send`, { method: 'POST', body: payload });
}

export function cancelNotification(
  id: number,
  payload: { expectedRevision: number; changeNote: string },
): Promise<NotificationDetailResponse> {
  return apiRequest(`/admin/notifications/${id}/cancel`, { method: 'POST', body: payload });
}

export function notificationRowLabel(item: NotificationItem): string {
  return item.title || `通知 #${item.id}`;
}
