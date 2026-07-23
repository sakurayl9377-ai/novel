import { apiRequest } from '@/services/api';
import type {
  GameControlMutationResponse,
  GameControlWorkbenchResponse,
  GameServiceAction,
} from '@/types/games';

export function getGameControls(): Promise<GameControlWorkbenchResponse> {
  return apiRequest('/admin/games/control');
}

export function setGameVisibility(
  id: string,
  visible: boolean,
): Promise<GameControlMutationResponse> {
  return apiRequest(`/admin/games/control/${encodeURIComponent(id)}/visibility`, {
    method: 'PATCH',
    body: { visible },
  });
}

export function controlGameService(
  id: string,
  action: GameServiceAction,
): Promise<GameControlMutationResponse> {
  return apiRequest(`/admin/games/control/${encodeURIComponent(id)}/action`, {
    method: 'POST',
    body: { action },
  });
}
