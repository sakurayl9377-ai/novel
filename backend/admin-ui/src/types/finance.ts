export type FinancePeriod = 'today' | '7d' | '30d' | '90d' | '365d' | 'all';
export type FinanceCurrency = '' | 'points' | 'coins' | 'mixed';
export type FinanceDirection = '' | 'credit' | 'debit';

export interface FinanceEventUser {
  id: number;
  email: string;
  nickname: string;
  avatarUrl: string;
  currentPoints: number;
  currentCoins: number;
}

export interface FinanceEventOperator {
  id: number;
  nickname: string;
  email: string;
}

export interface FinanceEvent {
  id: number;
  action: string;
  pointsDelta: number;
  coinsDelta: number;
  description: string;
  relatedType: string;
  relatedId: string;
  createdAt: string;
  user: FinanceEventUser;
  operator: FinanceEventOperator | null;
}

export interface FinanceSummary {
  affectedUsers: number;
  pointsDelta: number;
  pointsIssued: number;
  pointsSpent: number;
  coinsDelta: number;
  coinsIssued: number;
  coinsSpent: number;
}

export interface FinanceBalances {
  users: number;
  totalPoints: number;
  totalCoins: number;
  coinHolders: number;
  negativeBalances: number;
}

export interface FinanceActionCount {
  action: string;
  count: number;
  pointsDelta: number;
  coinsDelta: number;
}

export interface FinanceDailyFlow {
  day: string;
  events: number;
  pointsCredit: number;
  pointsDebit: number;
  coinsCredit: number;
  coinsDebit: number;
}

export interface FinanceWorkbenchResponse {
  page: number;
  pageSize: number;
  total: number;
  filters: {
    period: FinancePeriod;
    currency: FinanceCurrency;
    direction: FinanceDirection;
    action: string;
  };
  summary: FinanceSummary;
  balances: FinanceBalances;
  actions: FinanceActionCount[];
  daily: FinanceDailyFlow[];
  items: FinanceEvent[];
}
