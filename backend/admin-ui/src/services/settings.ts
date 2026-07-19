import { apiFormRequest, apiRequest } from '@/services/api';
import type { SettingsWorkbenchResponse } from '@/types/settings';

export function getSettingsWorkbench(): Promise<SettingsWorkbenchResponse> {
  return apiRequest('/admin/settings/workbench');
}

export function saveAppAnnouncement(payload: Record<string, unknown>): Promise<SettingsWorkbenchResponse> {
  return apiRequest('/admin/settings/app-announcement', { method: 'PATCH', body: payload });
}

export function saveChatBotSettings(payload: Record<string, unknown>): Promise<SettingsWorkbenchResponse> {
  return apiRequest('/admin/settings/chat-bot', { method: 'PATCH', body: payload });
}

export function saveIflytekAsrSettings(payload: Record<string, unknown>): Promise<SettingsWorkbenchResponse> {
  return apiRequest('/admin/settings/iflytek-asr', { method: 'PATCH', body: payload });
}

export function saveIflytekTtsSettings(payload: Record<string, unknown>): Promise<SettingsWorkbenchResponse> {
  return apiRequest('/admin/settings/iflytek-tts', { method: 'PATCH', body: payload });
}

export function clearSettingsSecret(group: string, field: string): Promise<SettingsWorkbenchResponse> {
  return apiRequest(`/admin/settings/secrets/${encodeURIComponent(group)}/${encodeURIComponent(field)}`, { method: 'DELETE' });
}

export function uploadChatBotAvatar(file: File): Promise<{ url: string; mimeType: string; size: number }> {
  const form = new FormData();
  form.append('file', file);
  return apiFormRequest('/admin/settings/chat-bot/avatar', form);
}

export function testChatBotSettings(payload: Record<string, unknown>): Promise<{ ok: boolean; reply: string; provider: string; model: string }> {
  return apiRequest('/admin/settings/chat-bot/test', { method: 'POST', body: payload });
}
