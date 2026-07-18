const fallbackConfig: NovelAdminRuntimeConfig = {
  apiPrefix: '/api',
  adminPath: '/admin',
};

export const runtimeConfig: NovelAdminRuntimeConfig = { ...fallbackConfig };

export async function loadRuntimeConfig(): Promise<void> {
  try {
    const response = await fetch('./config.json', { cache: 'no-store' });
    if (!response.ok) return;
    const config = await response.json() as Partial<NovelAdminRuntimeConfig>;
    Object.assign(runtimeConfig, config);
  } catch {
    // Vite development and local static previews can safely use defaults.
  }
}

export function legacyAdminUrl(): string {
  return `${runtimeConfig.adminPath.replace(/\/$/, '')}/`;
}
