/// <reference types="vite/client" />

declare global {
  interface NovelAdminRuntimeConfig {
    apiPrefix: string;
    adminPath: string;
    wsChatPath?: string;
    wsGamePath?: string;
    wsDanmakuPath?: string;
  }

  interface Window {
    NOVEL_ADMIN_CONFIG?: NovelAdminRuntimeConfig;
  }
}

declare module 'vue-router' {
  interface RouteMeta {
    title?: string;
    hint?: string;
    requiresAuth?: boolean;
    requiresAdmin?: boolean;
    legacy?: boolean;
  }
}

export {};
