export interface ProxyServiceState {
  active: boolean;
  enabled: boolean;
}

export interface ProxyTimerState {
  active: boolean;
  nextRun: string;
}

export interface ProxySubscription {
  id: string;
  name: string;
  nodeCount: number;
}

export interface ProxyRuntimeState {
  mixedPort: number;
  mode: string;
  logLevel: string;
  ipv6: boolean;
}

export interface ProxyGroup {
  name: string;
  type: string;
  current: string;
  options: string[];
}

export interface ProxyNode {
  name: string;
  type: string;
  alive: boolean;
  delay: number;
}

export interface ProxyStatus {
  service: ProxyServiceState;
  subscription: { configured: boolean; timer: ProxyTimerState };
  subscriptions: ProxySubscription[];
  config: { path: string; exists: boolean };
  version: string;
  runtime: ProxyRuntimeState;
  groups: ProxyGroup[];
  nodes: ProxyNode[];
  nodeTotal: number;
  manualModeEnabled: boolean;
}

export interface ProxyCheck {
  name: string;
  ok: boolean;
  status: number;
  value: string;
}

export interface ProxyConnectivityTest {
  ok: boolean;
  checks: ProxyCheck[];
}

export interface ProxyNodeTestItem {
  name: string;
  ok: boolean;
  delay: number;
}

export interface ProxyNodeTestResult {
  tested: number;
  available: number;
  failed: number;
  nodes: ProxyNodeTestItem[];
}
