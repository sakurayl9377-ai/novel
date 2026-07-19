import type { ProxyGroup, ProxyNode } from '@/types/proxy';

export function proxyServiceLabel(active: boolean, enabled: boolean): string {
  if (active) return enabled ? '运行中' : '运行中但未设为开机启动';
  return enabled ? '已启用但未运行' : '已停止';
}

export function proxyServiceTone(active: boolean, enabled: boolean): 'success' | 'warning' | 'danger' {
  if (active && enabled) return 'success';
  if (active || enabled) return 'warning';
  return 'danger';
}

export function proxyGroupLabel(group: ProxyGroup): string {
  return group.name === 'PROXY-MODE' ? '流量出口模式' : group.name === 'NODE-MANUAL' ? '手动节点' : group.name;
}

export function proxyNodeTone(node: ProxyNode): 'success' | 'danger' | 'info' {
  if (!node.alive) return 'danger';
  if (node.delay > 0 && node.delay <= 800) return 'success';
  return 'info';
}

export function proxyNodeState(node: ProxyNode): string {
  if (!node.alive) return '不可用';
  if (!node.delay) return '未测速';
  return `${node.delay} ms`;
}
