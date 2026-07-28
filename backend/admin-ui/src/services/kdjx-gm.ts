import { apiRequest, queryString } from '@/services/api';
import type {
  KdjxGmCatalogResponse,
  KdjxGmCreateDeliveryPayload,
  KdjxGmCreateDeliveryResponse,
  KdjxGmDeliveriesResponse,
  KdjxGmDeliveryStatus,
  KdjxGmDeliveryType,
  KdjxGmPayment,
  KdjxGmPaymentsResponse,
  KdjxGmPlayerDetailResponse,
  KdjxGmRetryResponse,
  KdjxGmRevokeResponse,
  KdjxGmWorkbenchResponse,
  KdjxPaymentStatus,
  KdjxUserStatus,
} from '@/types/kdjx-gm';

export function getKdjxGmCatalog(): Promise<KdjxGmCatalogResponse> {
  return apiRequest('/admin/games/kdjx/gm/catalog');
}

export function getKdjxGmWorkbench(query: {
  q?: string;
  status?: '' | KdjxUserStatus;
  page?: number;
  pageSize?: number;
}): Promise<KdjxGmWorkbenchResponse> {
  return apiRequest(`/admin/games/kdjx/gm/workbench${queryString(query)}`);
}

export function getKdjxGmPlayer(
  userId: number,
): Promise<KdjxGmPlayerDetailResponse> {
  return apiRequest(`/admin/games/kdjx/gm/players/${userId}`);
}

export function getKdjxGmPayments(query: {
  q?: string;
  status?: '' | KdjxPaymentStatus;
  userId?: '' | number;
  page?: number;
  pageSize?: number;
}): Promise<KdjxGmPaymentsResponse> {
  return apiRequest(`/admin/games/kdjx/gm/payments${queryString(query)}`);
}

export function getKdjxGmDeliveries(query: {
  q?: string;
  status?: '' | KdjxGmDeliveryStatus;
  deliveryType?: '' | KdjxGmDeliveryType;
  userId?: '' | number;
  page?: number;
  pageSize?: number;
}): Promise<KdjxGmDeliveriesResponse> {
  return apiRequest(`/admin/games/kdjx/gm/deliveries${queryString(query)}`);
}

export function createKdjxGmDelivery(
  userId: number,
  payload: KdjxGmCreateDeliveryPayload,
): Promise<KdjxGmCreateDeliveryResponse> {
  return apiRequest(`/admin/games/kdjx/gm/players/${userId}/deliveries`, {
    method: 'POST',
    body: payload,
  });
}

export function revokeKdjxGmSessions(
  userId: number,
  payload: { reason: string; expectedActiveSessions: number },
): Promise<KdjxGmRevokeResponse> {
  return apiRequest(`/admin/games/kdjx/gm/players/${userId}/revoke-sessions`, {
    method: 'POST',
    body: payload,
  });
}

export function retryKdjxGmPayment(
  payment: Pick<KdjxGmPayment, 'gameOrderId' | 'status' | 'attempts'>,
  reason: string,
): Promise<KdjxGmRetryResponse> {
  return apiRequest(
    `/admin/games/kdjx/gm/payments/${encodeURIComponent(payment.gameOrderId)}/retry`,
    {
      method: 'POST',
      body: {
        reason,
        expectedStatus: payment.status,
        expectedAttempts: payment.attempts,
      },
    },
  );
}
