import { describe, expect, it } from 'vitest';

import type { AdminGameControl, GameServiceState } from '@/types/games';
import {
  gameServiceActionDisabled,
  gameServiceActionLabel,
  gameServiceStatusLabel,
  gameServiceStatusTone,
  gameServiceUnitStatusLabel,
  gameServiceUnitStatusTone,
} from './games';

const runningService: GameServiceState = {
  unit: 'modao',
  status: 'running',
  active: true,
  enabled: true,
  checkedAt: '2026-07-23T05:00:00.000Z',
  units: [],
};

describe('game operations presentation', () => {
  it('labels aggregate service states consistently', () => {
    expect(gameServiceStatusLabel(runningService)).toBe('运行中');
    expect(gameServiceStatusTone(runningService)).toBe('success');
    expect(gameServiceStatusLabel({ ...runningService, status: 'partial' })).toBe('部分运行');
    expect(gameServiceStatusTone({ ...runningService, status: 'failed', active: false })).toBe('danger');
    expect(gameServiceUnitStatusLabel({
      unit: 'modao-game.service',
      status: 'activating',
      active: false,
      enabled: true,
      unitFileState: 'enabled',
    })).toBe('启动中');
    expect(gameServiceUnitStatusTone({
      unit: 'modao-game.service',
      status: 'activating',
      active: false,
      enabled: true,
      unitFileState: 'enabled',
    })).toBe('warning');
  });

  it('only exposes service actions that match the current state', () => {
    const game = {
      id: 'modao',
      route: 'modao',
      name: '魔道修仙',
      description: '',
      visible: true,
      sortOrder: 10,
      entryType: 'apk',
      requiresLogin: true,
      controllable: true,
      updatedAt: '2026-07-23T05:00:00.000Z',
      service: runningService,
    } satisfies AdminGameControl;

    expect(gameServiceActionDisabled(game, 'start')).toBe(true);
    expect(gameServiceActionDisabled(game, 'stop')).toBe(false);
    expect(gameServiceActionDisabled(game, 'restart')).toBe(false);

    const withStatus = (status: GameServiceState['status'], active = false) => ({
      ...game,
      service: { ...runningService, status, active },
    });

    expect(gameServiceActionDisabled(withStatus('stopped'), 'start')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('stopped'), 'stop')).toBe(true);
    expect(gameServiceActionDisabled(withStatus('stopped'), 'restart')).toBe(true);
    expect(gameServiceActionDisabled(withStatus('partial', true), 'start')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('partial', true), 'restart')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('failed'), 'stop')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('failed'), 'restart')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('activating'), 'start')).toBe(true);
    expect(gameServiceActionDisabled(withStatus('activating'), 'restart')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('deactivating'), 'stop')).toBe(true);
    expect(gameServiceActionDisabled(withStatus('deactivating'), 'restart')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('unknown'), 'stop')).toBe(false);
    expect(gameServiceActionDisabled(withStatus('unknown'), 'restart')).toBe(true);
    expect(gameServiceActionDisabled({ ...game, controllable: false }, 'stop')).toBe(true);
    expect(gameServiceActionLabel('restart')).toBe('重启');
  });
});
