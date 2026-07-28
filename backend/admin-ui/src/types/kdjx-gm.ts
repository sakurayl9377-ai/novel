export type KdjxUserStatus = 'active' | 'banned';
export type KdjxPaymentStatus =
  | 'paid'
  | 'fulfilling'
  | 'delivery_failed'
  | 'fulfilled';
export type KdjxSessionStatus = 'active' | 'revoked' | 'expired';
export type KdjxGmAction =
  | 'revoke_sessions'
  | 'retry_payment'
  | 'deliver_item';
export type KdjxGmActionResult = 'pending' | 'success' | 'failed';
export type KdjxGmDeliveryStatus =
  | 'pending'
  | 'succeeded'
  | 'failed'
  | 'unknown';
export type KdjxGmDeliveryType = 'direct' | 'mail';

export interface KdjxGmSummary {
  linkedPlayers: number;
  activeGameSessions: number;
  paymentOrders: number;
  deliveryFailed: number;
  fulfilled: number;
  totalCoinSpend: number;
}

export interface KdjxGmPlayer {
  userId: number;
  email: string;
  nickname: string;
  userStatus: KdjxUserStatus;
  userRole: 'user' | 'admin';
  sakuraCoins: number;
  userCreatedAt: string;
  lastLoginAt: string;
  gameOpenId: string;
  gameAccountId: string;
  lastRoleId: string;
  lastServerKey: string;
  linkedAt: string;
  linkedUpdatedAt: string;
  canDeliverItems: boolean;
  deliveryBlockCode: '' | 'kdjx_player_identity_incomplete';
  activeGameSessions: number;
  paymentCount: number;
  lastPaymentStatus: '' | KdjxPaymentStatus;
  lastPaymentAt: string;
}

export interface KdjxGmSession {
  id: string;
  status: KdjxSessionStatus;
  expiresAt: string;
  lastUsedAt: string;
  revokedAt: string;
  createdAt: string;
}

export interface KdjxGmPayment {
  id: string;
  userId: number;
  email: string;
  nickname: string;
  userStatus: '' | KdjxUserStatus;
  gameOrderId: string;
  channelOrderId: string;
  gameOpenId: string;
  accountId: string;
  roleId: string;
  serverKey: string;
  productId: string;
  productName: string;
  rechargeId: number;
  moneyCents: number;
  coinCost: number;
  status: KdjxPaymentStatus;
  attempts: number;
  fulfillmentReference: string;
  lastError: string;
  canRetry: boolean;
  fulfilledAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface KdjxGmActionLog {
  id: number;
  adminUserId: number | null;
  adminEmail: string;
  adminNickname: string;
  action: KdjxGmAction;
  targetType: 'player' | 'payment' | 'delivery';
  targetId: string;
  reason: string;
  result: KdjxGmActionResult;
  errorCode: string;
  createdAt: string;
}

export interface KdjxGmCatalogItem {
  id: string;
  name: string;
  description: string;
  type: string;
  quality: string;
  maxQuantity: number;
  deliveryTypes: readonly KdjxGmDeliveryType[];
}

export interface KdjxGmCatalogResponse {
  generatedAt: string;
  items: KdjxGmCatalogItem[];
}

export interface KdjxGmDelivery {
  id: number;
  requestId: string;
  userId: number;
  email: string;
  nickname: string;
  adminUserId: number | null;
  adminEmail: string;
  adminNickname: string;
  deliveryType: KdjxGmDeliveryType;
  roleId: string;
  serverKey: string;
  itemId: string;
  itemName: string;
  itemType: string;
  itemQuality: string;
  quantity: number;
  reason: string;
  status: KdjxGmDeliveryStatus;
  remoteReference: string;
  errorCode: string;
  createdAt: string;
  updatedAt: string;
  completedAt: string;
}

export interface KdjxGmDeliveriesResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  deliveries: KdjxGmDelivery[];
}

export interface KdjxGmCreateDeliveryPayload {
  requestId: string;
  deliveryType: KdjxGmDeliveryType;
  itemId: string;
  quantity: number;
  expectedRoleId: string;
  expectedServerKey: string;
  expectedLinkUpdatedAt: string;
  reason: string;
}

export interface KdjxGmCreateDeliveryResponse {
  ok: boolean;
  idempotent: boolean;
  delivery: KdjxGmDelivery;
}

export interface KdjxGmWorkbenchResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  summary: KdjxGmSummary;
  players: KdjxGmPlayer[];
  recentActions: KdjxGmActionLog[];
}

export interface KdjxGmPlayerDetailResponse {
  player: KdjxGmPlayer;
  sessions: KdjxGmSession[];
  payments: KdjxGmPayment[];
  deliveries: KdjxGmDelivery[];
}

export interface KdjxGmPaymentsResponse {
  generatedAt: string;
  page: number;
  pageSize: number;
  total: number;
  payments: KdjxGmPayment[];
}

export interface KdjxGmRevokeResponse {
  ok: true;
  userId: number;
  revokedSessions: number;
  activeGameSessions: number;
}

export interface KdjxGmRetryResponse {
  ok: boolean;
  payment: KdjxGmPayment;
}
