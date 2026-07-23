export type GameServiceAction = 'start' | 'stop' | 'restart';
export type GameEntryType = 'native' | 'web' | 'apk';
export type GameServiceUnitStatus =
  | 'running'
  | 'stopped'
  | 'failed'
  | 'activating'
  | 'deactivating'
  | 'unknown';
export type GameServiceStatus = GameServiceUnitStatus | 'partial' | 'unmanaged';

export interface GameServiceUnitState {
  unit: string;
  status: GameServiceUnitStatus;
  active: boolean;
  enabled: boolean;
  unitFileState: string;
}

export interface GameServiceState {
  unit: string;
  status: GameServiceStatus;
  active: boolean;
  enabled: boolean;
  checkedAt: string;
  error?: string;
  units: GameServiceUnitState[];
}

export interface AdminGameControl {
  id: string;
  route: string;
  name: string;
  description: string;
  visible: boolean;
  sortOrder: number;
  entryType: GameEntryType;
  requiresLogin: boolean;
  controllable: boolean;
  updatedAt: string;
  service: GameServiceState;
}

export interface GameControlWorkbenchResponse {
  generatedAt: string;
  games: AdminGameControl[];
}

export interface GameControlMutationResponse {
  game: AdminGameControl;
  message?: string;
}
