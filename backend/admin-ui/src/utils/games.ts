import type {
  AdminGameControl,
  GameServiceAction,
  GameServiceState,
  GameServiceUnitState,
} from '@/types/games';

export type GameStatusTone = 'success' | 'warning' | 'danger' | 'info';

export function gameServiceStatusLabel(service: GameServiceState): string {
  const labels: Record<string, string> = {
    running: '运行中',
    active: '运行中',
    starting: '启动中',
    activating: '启动中',
    stopping: '停止中',
    deactivating: '停止中',
    stopped: '已停止',
    inactive: '已停止',
    partial: '部分运行',
    failed: '启动失败',
    unmanaged: '应用内置',
    unknown: '状态未知',
  };
  return labels[service.status] || service.status || (service.active ? '运行中' : '状态未知');
}

export function gameServiceStatusTone(service: GameServiceState): GameStatusTone {
  if (['running', 'active'].includes(service.status)) return 'success';
  if (['failed'].includes(service.status)) return 'danger';
  if (service.status === 'unmanaged') return 'info';
  if (['starting', 'activating', 'stopping', 'deactivating', 'partial'].includes(service.status)) {
    return 'warning';
  }
  return service.active ? 'success' : 'info';
}

export function gameServiceActionLabel(action: GameServiceAction): string {
  return ({ start: '启动', stop: '停止', restart: '重启' } as const)[action];
}

export function gameServiceUnitStatusLabel(unit: GameServiceUnitState): string {
  return gameServiceStatusLabel({
    unit: unit.unit,
    status: unit.status,
    active: unit.active,
    enabled: unit.enabled,
    checkedAt: '',
    units: [],
  });
}

export function gameServiceUnitStatusTone(unit: GameServiceUnitState): GameStatusTone {
  return gameServiceStatusTone({
    unit: unit.unit,
    status: unit.status,
    active: unit.active,
    enabled: unit.enabled,
    checkedAt: '',
    units: [],
  });
}

export function gameServiceActionDisabled(
  game: AdminGameControl,
  action: GameServiceAction,
): boolean {
  if (!game.controllable) return true;

  const status = game.service.status;
  if (action === 'start') {
    return ['running', 'activating', 'unmanaged'].includes(status);
  }
  if (action === 'stop') {
    return ['stopped', 'deactivating', 'unmanaged'].includes(status);
  }
  return ['stopped', 'unknown', 'unmanaged'].includes(status);
}
