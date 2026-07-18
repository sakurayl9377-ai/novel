import { apiRequest, queryString } from '@/services/api';
import type {
  BlockedIp,
  BlockedIpListResponse,
  ChatKeywordPayload,
  ChatKeywordRule,
  ChatKeywordStatus,
  ChatMessageContextResponse,
  ChatMessageStatus,
  ChatMessageType,
  ChatRoom,
  ChatRoomCategory,
  ChatRoomListResponse,
  ChatRoomMembersResponse,
  ChatRoomMessagesResponse,
  ChatRoomPayload,
  ChatRoomStatus,
  ChatViolationAction,
  ChatViolationListResponse,
} from '@/types/chat';

export function listChatRooms(query: {
  q?: string;
  status?: 'all' | ChatRoomStatus;
  category?: '' | ChatRoomCategory;
  page?: number;
  pageSize?: number;
}): Promise<ChatRoomListResponse> {
  return apiRequest(`/admin/chat/rooms${queryString(query)}`);
}

export function createChatRoom(payload: ChatRoomPayload): Promise<{ item: ChatRoom }> {
  return apiRequest('/admin/chat/rooms', { method: 'POST', body: payload });
}

export function updateChatRoom(
  roomId: string,
  payload: Partial<ChatRoomPayload>,
): Promise<{ item: ChatRoom }> {
  return apiRequest(`/admin/chat/rooms/${encodeURIComponent(roomId)}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function dissolveChatRoom(roomId: string): Promise<{ item: ChatRoom }> {
  return apiRequest(`/admin/chat/rooms/${encodeURIComponent(roomId)}`, {
    method: 'DELETE',
  });
}

export async function uploadChatRoomAvatar(file: File): Promise<string> {
  const dataBase64 = await fileToBase64(file);
  const data = await apiRequest<{ url: string }>('/users/me/avatar', {
    method: 'POST',
    body: { mimeType: file.type, dataBase64 },
  });
  return data.url;
}

export function listChatRoomMessages(query: {
  roomId: string;
  q?: string;
  status?: ChatMessageStatus;
  type?: '' | ChatMessageType;
  page?: number;
  pageSize?: number;
}): Promise<ChatRoomMessagesResponse> {
  return apiRequest(`/admin/chat/rooms/detail${queryString(query)}`);
}

export function getChatMessageContext(id: number): Promise<ChatMessageContextResponse> {
  return apiRequest(`/admin/chat/messages/${id}/context`);
}

export function updateChatMessageStatus(
  id: number,
  status: ChatMessageStatus,
): Promise<void> {
  return apiRequest(`/admin/chat/messages/${id}/status`, {
    method: 'PATCH',
    body: { status },
  });
}

export function updateChatMessagesStatus(
  ids: number[],
  status: ChatMessageStatus,
): Promise<{ updated: number }> {
  return apiRequest('/admin/chat/messages/batch/status', {
    method: 'PATCH',
    body: { ids, status },
  });
}

export function clearChatRoom(roomId: string): Promise<{ deleted: number }> {
  return apiRequest('/admin/chat/rooms/clear', {
    method: 'DELETE',
    body: { roomId, status: 'visible' },
  });
}

export function listChatRoomMembers(
  roomId: string,
  query: { q?: string; role?: string; page?: number; pageSize?: number } = {},
): Promise<ChatRoomMembersResponse> {
  return apiRequest(
    `/admin/chat/rooms/${encodeURIComponent(roomId)}/members${queryString(query)}`,
  );
}

export function updateChatRoomMemberRole(
  roomId: string,
  userId: number,
  role: 'member' | 'manager',
): Promise<void> {
  return apiRequest(
    `/admin/chat/rooms/${encodeURIComponent(roomId)}/members/${userId}`,
    { method: 'PATCH', body: { role } },
  );
}

export function removeChatRoomMember(roomId: string, userId: number): Promise<void> {
  return apiRequest(
    `/admin/chat/rooms/${encodeURIComponent(roomId)}/members/${userId}`,
    { method: 'DELETE' },
  );
}

export function listChatKeywords(query: {
  q?: string;
  status?: '' | ChatKeywordStatus;
  page?: number;
  pageSize?: number;
} = {}): Promise<{
  page: number;
  pageSize: number;
  total: number;
  items: ChatKeywordRule[];
  statusCounts: Partial<Record<ChatKeywordStatus, number>>;
}> {
  return apiRequest(`/admin/chat/keywords${queryString(query)}`);
}

export function createChatKeyword(payload: ChatKeywordPayload): Promise<{ id: number }> {
  return apiRequest('/admin/chat/keywords', {
    method: 'POST',
    body: { ...payload, severity: 'block' },
  });
}

export function updateChatKeyword(id: number, payload: Partial<ChatKeywordPayload>): Promise<void> {
  return apiRequest(`/admin/chat/keywords/${id}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function deleteChatKeyword(id: number): Promise<void> {
  return apiRequest(`/admin/chat/keywords/${id}`, { method: 'DELETE' });
}

export function testChatKeyword(content: string): Promise<{
  matched: boolean;
  item: ChatKeywordRule | null;
}> {
  return apiRequest('/admin/chat/keywords/test', {
    method: 'POST',
    body: { content },
  });
}

export function listChatViolations(query: {
  q?: string;
  roomId?: string;
  action?: '' | ChatViolationAction;
  page?: number;
  pageSize?: number;
}): Promise<ChatViolationListResponse> {
  return apiRequest(`/admin/chat/violations${queryString(query)}`);
}

export function listBlockedIps(query: {
  q?: string;
  page?: number;
  pageSize?: number;
}): Promise<BlockedIpListResponse> {
  return apiRequest(`/admin/blocked-ips${queryString(query)}`);
}

export function blockIp(payload: {
  ip: string;
  reason: string;
  userId?: number;
}): Promise<{ item: BlockedIp }> {
  return apiRequest('/admin/blocked-ips', { method: 'POST', body: payload });
}

export function unblockIp(ip: string): Promise<void> {
  return apiRequest(`/admin/blocked-ips/${encodeURIComponent(ip)}`, { method: 'DELETE' });
}

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error('图片读取失败'));
    reader.onload = () => {
      const result = String(reader.result || '');
      resolve(result.includes(',') ? result.slice(result.indexOf(',') + 1) : result);
    };
    reader.readAsDataURL(file);
  });
}
