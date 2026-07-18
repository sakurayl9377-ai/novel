import { computed, ref } from 'vue';
import { defineStore } from 'pinia';

import { apiRequest, adminTokenStorageKey } from '@/services/api';
import type { AuthResponse, SessionUser } from '@/types/auth';

export const useSessionStore = defineStore('session', () => {
  const user = ref<SessionUser | null>(null);
  const ready = ref(false);
  const authenticating = ref(false);
  const error = ref('');

  const isAdmin = computed(() => user.value?.role === 'admin');
  const defaultRouteName = computed(() => isAdmin.value ? 'dashboard' : 'ai-novels');

  async function restore(): Promise<void> {
    const token = localStorage.getItem(adminTokenStorageKey);
    if (!token) {
      ready.value = true;
      return;
    }
    try {
      const data = await apiRequest<{ user: SessionUser }>('/auth/me');
      user.value = data.user;
    } catch {
      clearSession();
    } finally {
      ready.value = true;
    }
  }

  async function login(email: string, password: string): Promise<void> {
    authenticating.value = true;
    error.value = '';
    try {
      const data = await apiRequest<AuthResponse>('/auth/login', {
        method: 'POST',
        auth: false,
        body: { email, password },
      });
      localStorage.setItem(adminTokenStorageKey, data.token);
      user.value = data.user;
      ready.value = true;
    } catch (loginError) {
      error.value = loginError instanceof Error ? loginError.message : '登录失败';
      throw loginError;
    } finally {
      authenticating.value = false;
    }
  }

  async function logout(): Promise<void> {
    try {
      await apiRequest('/auth/logout', { method: 'POST' });
    } catch {
      // Local session removal must still succeed when the server is unavailable.
    }
    clearSession();
  }

  function clearSession(): void {
    localStorage.removeItem(adminTokenStorageKey);
    user.value = null;
    ready.value = true;
    error.value = '';
  }

  return {
    user,
    ready,
    authenticating,
    error,
    isAdmin,
    defaultRouteName,
    restore,
    login,
    logout,
    clearSession,
  };
});
