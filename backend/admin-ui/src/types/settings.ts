export interface SecretSettingState {
  configured: boolean;
  updatedAt: string;
}

export interface SettingsGroupHealth {
  enabled: boolean;
  ready: boolean;
  missing: string[];
  updatedAt: string;
}

export interface SettingsWorkbenchHealth {
  enabledCount: number;
  readyCount: number;
  attentionCount: number;
  groups: {
    appAnnouncement: SettingsGroupHealth;
    chatBot: SettingsGroupHealth;
    iflytekAsr: SettingsGroupHealth;
    iflytekTts: SettingsGroupHealth;
  };
}

export interface ChatBotProviderPreset {
  id: string;
  label: string;
  baseUrl: string;
  model: string;
  requiresBaseUrl: boolean;
  requiresModel: boolean;
}

export interface ChatBotSkin {
  id: string;
  label: string;
  avatarAsset: string;
  imageAsset: string;
}

export interface SettingsWorkbenchResponse {
  generatedAt: string;
  appAnnouncement: {
    enabled: 'true' | 'false';
    title: string;
    content: string;
    version: string;
  };
  iflytekAsr: {
    productType: string;
    appId: string;
    apiKey: SecretSettingState;
    secretKey: SecretSettingState;
    apiSecret: SecretSettingState;
    hostUrl: string;
    enabled: 'true' | 'false';
  };
  iflytekTts: {
    appId: string;
    apiKey: SecretSettingState;
    apiSecret: SecretSettingState;
    hostUrl: string;
    enabled: 'true' | 'false';
  };
  chatBot: {
    enabled: 'true' | 'false';
    provider: string;
    baseUrl: string;
    apiKey: SecretSettingState;
    model: string;
    botName: string;
    avatarUrl: string;
    skinId: string;
    triggerMode: string;
    systemPrompt: string;
  };
  speechDefaults: {
    asrProductType: string;
    asrHostUrls: Record<string, string>;
    ttsHostUrl: string;
  };
  chatBotProviderPresets: ChatBotProviderPreset[];
  chatBotSkins: ChatBotSkin[];
  health: SettingsWorkbenchHealth;
}
