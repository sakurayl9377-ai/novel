<script setup lang="ts">
import {
  CircleCheck,
  Delete,
  Key,
  MagicStick,
  Refresh,
  Setting,
  UploadFilled,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import type { UploadFile } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import {
  clearSettingsSecret,
  getSettingsWorkbench,
  saveAppAnnouncement,
  saveChatBotSettings,
  saveIflytekAsrSettings,
  saveIflytekTtsSettings,
  testChatBotSettings,
  uploadChatBotAvatar,
} from '@/services/settings';
import type { SettingsGroupHealth, SettingsWorkbenchResponse } from '@/types/settings';
import { formatDateTime } from '@/utils/format';

type GroupKey = 'appAnnouncement' | 'chatBot' | 'iflytekAsr' | 'iflytekTts';

const loading = ref(false);
const initialized = ref(false);
const savingGroup = ref<GroupKey | ''>('');
const uploadingAvatar = ref(false);
const testingBot = ref(false);
const openedSections = ref<string[]>(['announcement', 'chatBot']);
const data = ref<SettingsWorkbenchResponse>(emptySettings());
const baselines = reactive<Record<GroupKey, string>>({
  appAnnouncement: '',
  chatBot: '',
  iflytekAsr: '',
  iflytekTts: '',
});
const announcement = reactive({ enabled: false, title: '公告', content: '' });
const chatBot = reactive({
  enabled: false,
  provider: 'nvidia',
  baseUrl: '',
  apiKey: '',
  model: '',
  botName: '小樱',
  avatarUrl: '',
  skinId: 'sakura',
  triggerMode: 'mention',
  systemPrompt: '',
});
const asr = reactive({
  enabled: false,
  productType: 'rtasr',
  appId: '',
  apiKey: '',
  secretKey: '',
  apiSecret: '',
  hostUrl: '',
});
const tts = reactive({
  enabled: false,
  appId: '',
  apiKey: '',
  apiSecret: '',
  hostUrl: '',
});
const testMessage = ref('你好，请回复一句简短的话。');
const testReply = ref('');
const testMeta = ref('');

const health = computed(() => data.value.health);
const attentionCount = computed(() => health.value.attentionCount);
const providerOptions = computed(() => data.value.chatBotProviderPresets);
const skinOptions = computed(() => data.value.chatBotSkins);
const asrProductOptions = computed(() => Object.entries(data.value.speechDefaults.asrHostUrls));
const chatAvatarPreview = computed(() => chatBot.avatarUrl);
const dirty = computed<Record<GroupKey, boolean>>(() => ({
  appAnnouncement: serializeAnnouncement() !== baselines.appAnnouncement,
  chatBot: serializeChatBot() !== baselines.chatBot,
  iflytekAsr: serializeAsr() !== baselines.iflytekAsr,
  iflytekTts: serializeTts() !== baselines.iflytekTts,
}));

onMounted(() => void loadSettings());

async function loadSettings(): Promise<void> {
  loading.value = true;
  try {
    applySettings(await getSettingsWorkbench());
  } catch (error) {
    ElMessage.error(errorMessage(error, '系统配置加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function applySettings(next: SettingsWorkbenchResponse): void {
  data.value = next;
  Object.assign(announcement, {
    enabled: next.appAnnouncement.enabled === 'true',
    title: next.appAnnouncement.title,
    content: next.appAnnouncement.content,
  });
  Object.assign(chatBot, {
    enabled: next.chatBot.enabled === 'true',
    provider: next.chatBot.provider,
    baseUrl: next.chatBot.baseUrl,
    apiKey: '',
    model: next.chatBot.model,
    botName: next.chatBot.botName,
    avatarUrl: next.chatBot.avatarUrl,
    skinId: next.chatBot.skinId,
    triggerMode: next.chatBot.triggerMode,
    systemPrompt: next.chatBot.systemPrompt,
  });
  Object.assign(asr, {
    enabled: next.iflytekAsr.enabled === 'true',
    productType: next.iflytekAsr.productType,
    appId: next.iflytekAsr.appId,
    apiKey: '',
    secretKey: '',
    apiSecret: '',
    hostUrl: next.iflytekAsr.hostUrl,
  });
  Object.assign(tts, {
    enabled: next.iflytekTts.enabled === 'true',
    appId: next.iflytekTts.appId,
    apiKey: '',
    apiSecret: '',
    hostUrl: next.iflytekTts.hostUrl,
  });
  baselines.appAnnouncement = serializeAnnouncement();
  baselines.chatBot = serializeChatBot();
  baselines.iflytekAsr = serializeAsr();
  baselines.iflytekTts = serializeTts();
}

async function saveGroup(group: GroupKey): Promise<void> {
  savingGroup.value = group;
  try {
    const next = group === 'appAnnouncement'
      ? await saveAppAnnouncement({ enabled: announcement.enabled, title: announcement.title, content: announcement.content })
      : group === 'chatBot'
        ? await saveChatBotSettings(chatBotPayload())
        : group === 'iflytekAsr'
          ? await saveIflytekAsrSettings(asrPayload())
          : await saveIflytekTtsSettings(ttsPayload());
    applySettings(next);
    ElMessage.success('配置已保存');
  } catch (error) {
    ElMessage.error(errorMessage(error, '配置保存失败'));
  } finally {
    savingGroup.value = '';
  }
}

async function clearSecret(group: 'chat-bot' | 'iflytek-asr' | 'iflytek-tts', field: string, label: string): Promise<void> {
  try {
    await ElMessageBox.confirm(`清除${label}后，依赖它的功能会自动停用。`, `清除${label}`, {
      type: 'warning',
      confirmButtonText: '清除并停用',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    applySettings(await clearSettingsSecret(group, field));
    ElMessage.success(`${label}已清除`);
  } catch (error) {
    ElMessage.error(errorMessage(error, '密钥清除失败'));
  }
}

async function handleAvatarChange(file: UploadFile): Promise<void> {
  const raw = file.raw;
  if (!raw) return;
  uploadingAvatar.value = true;
  try {
    const result = await uploadChatBotAvatar(raw);
    chatBot.avatarUrl = result.url;
    ElMessage.success('头像已上传，保存机器人配置后生效');
  } catch (error) {
    ElMessage.error(errorMessage(error, '头像上传失败'));
  } finally {
    uploadingAvatar.value = false;
  }
}

function clearAvatar(): void {
  chatBot.avatarUrl = '';
}

function onProviderChange(provider: string): void {
  const preset = providerOptions.value.find((item) => item.id === provider);
  if (!preset) return;
  chatBot.baseUrl = preset.baseUrl;
  chatBot.model = preset.model;
}

async function runBotTest(): Promise<void> {
  testingBot.value = true;
  testReply.value = '';
  testMeta.value = '';
  try {
    const result = await testChatBotSettings({ message: testMessage.value, chatBot: chatBotPayload() });
    testReply.value = result.reply;
    testMeta.value = `${result.provider} · ${result.model}`;
  } catch (error) {
    ElMessage.error(errorMessage(error, '机器人测试失败'));
  } finally {
    testingBot.value = false;
  }
}

function healthFor(group: GroupKey): SettingsGroupHealth {
  return health.value.groups[group];
}

function healthLabel(group: GroupKey): string {
  const state = healthFor(group);
  if (!state.enabled) return '未启用';
  return state.ready ? '可用' : '待补全';
}

function healthTone(group: GroupKey): 'success' | 'warning' | 'info' {
  const state = healthFor(group);
  if (!state.enabled) return 'info';
  return state.ready ? 'success' : 'warning';
}

function missingLabel(value: string): string {
  return ({
    content: '公告内容',
    appId: 'App ID',
    apiKey: 'API Key',
    secretKey: 'Secret Key',
    apiSecret: 'API Secret',
    baseUrl: '接口地址',
    model: '模型',
  } as Record<string, string>)[value] || value;
}

function secretHint(configured: boolean): string {
  return configured ? '已配置，留空保持原值' : '尚未配置';
}

function announcementUpdatedAt(): string {
  return healthFor('appAnnouncement').updatedAt;
}

function chatBotPayload(): Record<string, unknown> {
  return { ...chatBot };
}

function asrPayload(): Record<string, unknown> {
  return { ...asr };
}

function ttsPayload(): Record<string, unknown> {
  return { ...tts };
}

function serializeAnnouncement(): string {
  return JSON.stringify({ enabled: announcement.enabled, title: announcement.title, content: announcement.content });
}

function serializeChatBot(): string {
  return JSON.stringify({ ...chatBot });
}

function serializeAsr(): string {
  return JSON.stringify({ ...asr });
}

function serializeTts(): string {
  return JSON.stringify({ ...tts });
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptySettings(): SettingsWorkbenchResponse {
  return {
    generatedAt: '',
    appAnnouncement: { enabled: 'false', title: '公告', content: '', version: '' },
    iflytekAsr: {
      productType: 'rtasr', appId: '', apiKey: { configured: false, updatedAt: '' }, secretKey: { configured: false, updatedAt: '' }, apiSecret: { configured: false, updatedAt: '' }, hostUrl: '', enabled: 'false',
    },
    iflytekTts: {
      appId: '', apiKey: { configured: false, updatedAt: '' }, apiSecret: { configured: false, updatedAt: '' }, hostUrl: '', enabled: 'false',
    },
    chatBot: {
      enabled: 'false', provider: 'nvidia', baseUrl: '', apiKey: { configured: false, updatedAt: '' }, model: '', botName: '小樱', avatarUrl: '', skinId: 'sakura', triggerMode: 'mention', systemPrompt: '',
    },
    speechDefaults: { asrProductType: 'rtasr', asrHostUrls: {}, ttsHostUrl: '' },
    chatBotProviderPresets: [],
    chatBotSkins: [],
    health: {
      enabledCount: 0,
      readyCount: 0,
      attentionCount: 0,
      groups: {
        appAnnouncement: { enabled: false, ready: false, missing: ['content'], updatedAt: '' },
        chatBot: { enabled: false, ready: false, missing: ['apiKey', 'baseUrl', 'model'], updatedAt: '' },
        iflytekAsr: { enabled: false, ready: false, missing: ['appId', 'apiKey'], updatedAt: '' },
        iflytekTts: { enabled: false, ready: false, missing: ['appId', 'apiKey', 'apiSecret'], updatedAt: '' },
      },
    },
  };
}
</script>

<template>
  <div class="page-stack settings-page">
    <section class="page-action-row settings-heading">
      <div>
        <span class="eyebrow">SYSTEM SETTINGS</span>
        <h2>系统配置</h2>
        <p>每个服务独立保存，凭据只显示配置状态；启用前先完成可用性检查。</p>
      </div>
      <ElButton :icon="Refresh" :loading="loading" @click="loadSettings">刷新配置</ElButton>
    </section>

    <ElAlert v-if="initialized && attentionCount" :title="`${attentionCount} 项已启用配置需要补全`" type="warning" :closable="false" show-icon>
      <template #default>请先补齐必需字段，再让客户端使用对应服务。</template>
    </ElAlert>
    <ElAlert v-else-if="initialized" title="系统配置状态正常" type="success" :closable="false" show-icon>
      <template #default>密钥使用服务器加密存储，后台不会回显明文。</template>
    </ElAlert>

    <section class="metric-grid settings-metrics">
      <MetricCard label="已启用服务" :value="health.enabledCount" hint="公告 / 机器人 / 语音" :icon="Setting" />
      <MetricCard label="可用服务" :value="health.readyCount" hint="已启用且凭据完整" :icon="CircleCheck" tone="success" />
      <MetricCard label="待补全" :value="health.attentionCount" hint="不会静默失败" :icon="WarningFilled" :tone="health.attentionCount ? 'warning' : 'default'" />
      <MetricCard label="最近更新" :value="formatDateTime(data.generatedAt)" hint="配置工作台快照" :icon="Refresh" />
    </section>

    <ElCollapse v-model="openedSections" class="settings-collapse">
      <ElCollapseItem name="announcement">
        <template #title><div class="collapse-title"><div><strong>App 公告</strong><small>客户端启动时显示的维护与运营公告</small></div><div class="title-status"><ElTag :type="healthTone('appAnnouncement')" effect="plain">{{ healthLabel('appAnnouncement') }}</ElTag><ElTag v-if="dirty.appAnnouncement" type="warning" effect="plain">未保存</ElTag></div></div></template>
        <ElForm label-position="top" class="settings-form">
          <div class="form-grid two-columns"><ElFormItem label="公告标题"><ElInput v-model="announcement.title" maxlength="80" show-word-limit /></ElFormItem><ElFormItem label="显示开关"><div class="switch-field"><ElSwitch v-model="announcement.enabled" /><span>{{ announcement.enabled ? '客户端显示' : '暂不显示' }}</span></div></ElFormItem></div>
          <ElFormItem label="公告内容" required><ElInput v-model="announcement.content" type="textarea" :rows="5" maxlength="4000" show-word-limit placeholder="填写用户需要看到的公告内容" /></ElFormItem>
          <div class="form-footer"><span>上次更新：{{ formatDateTime(announcementUpdatedAt()) }}</span><ElButton type="primary" :disabled="!dirty.appAnnouncement" :loading="savingGroup === 'appAnnouncement'" @click="saveGroup('appAnnouncement')">保存公告</ElButton></div>
        </ElForm>
      </ElCollapseItem>

      <ElCollapseItem name="chatBot">
        <template #title><div class="collapse-title"><div><strong>AI 聊天机器人</strong><small>聊天房间内的 AI 回复、皮肤和触发规则</small></div><div class="title-status"><ElTag :type="healthTone('chatBot')" effect="plain">{{ healthLabel('chatBot') }}</ElTag><ElTag v-if="dirty.chatBot" type="warning" effect="plain">未保存</ElTag></div></div></template>
        <ElForm label-position="top" class="settings-form">
          <div class="form-grid three-columns"><ElFormItem label="启用机器人"><div class="switch-field"><ElSwitch v-model="chatBot.enabled" /><span>{{ chatBot.enabled ? '已启用' : '已停用' }}</span></div></ElFormItem><ElFormItem label="服务商"><ElSelect v-model="chatBot.provider" @change="onProviderChange"><ElOption v-for="item in providerOptions" :key="item.id" :label="item.label" :value="item.id" /></ElSelect></ElFormItem><ElFormItem label="机器人名称"><ElInput v-model="chatBot.botName" maxlength="40" /></ElFormItem></div>
          <div class="form-grid two-columns"><ElFormItem label="API Key"><ElInput v-model="chatBot.apiKey" type="password" show-password :placeholder="secretHint(data.chatBot.apiKey.configured)" /><div class="secret-row"><span><ElIcon><Key /></ElIcon>{{ data.chatBot.apiKey.configured ? '服务器已有加密凭据' : '尚未配置凭据' }}</span><ElButton v-if="data.chatBot.apiKey.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('chat-bot', 'apiKey', '机器人 API Key')">清除</ElButton></div></ElFormItem><ElFormItem label="触发方式"><ElSelect v-model="chatBot.triggerMode"><ElOption label="仅被 @ 时回复" value="mention" /><ElOption label="问题消息自动回复" value="smart" /></ElSelect></ElFormItem></div>
          <div class="avatar-editor"><div class="avatar-preview" :class="{ empty: !chatAvatarPreview }"><img v-if="chatAvatarPreview" :src="chatAvatarPreview" alt="机器人头像预览"><ElIcon v-else :size="28"><MagicStick /></ElIcon></div><div class="avatar-copy"><strong>机器人头像</strong><span>{{ chatAvatarPreview ? '已上传托管头像' : `使用 ${skinOptions.find((item) => item.id === chatBot.skinId)?.label || '默认皮肤'} 的内置头像` }}</span><div class="avatar-actions"><ElUpload accept="image/jpeg,image/png,image/webp" :show-file-list="false" :auto-upload="false" :disabled="uploadingAvatar" :on-change="handleAvatarChange"><ElButton size="small" :icon="UploadFilled" :loading="uploadingAvatar">{{ chatAvatarPreview ? '替换头像' : '上传头像' }}</ElButton></ElUpload><ElButton v-if="chatAvatarPreview" text size="small" @click="clearAvatar">恢复内置头像</ElButton></div></div><ElFormItem label="聊天皮肤" class="skin-field"><ElSelect v-model="chatBot.skinId"><ElOption v-for="item in skinOptions" :key="item.id" :label="item.label" :value="item.id" /></ElSelect></ElFormItem></div>
          <ElCollapse class="advanced-collapse"><ElCollapseItem name="chat-advanced" title="高级连接参数"><div class="form-grid two-columns"><ElFormItem label="接口地址"><ElInput v-model="chatBot.baseUrl" :disabled="chatBot.provider === 'nvidia'" placeholder="HTTPS 地址" /></ElFormItem><ElFormItem label="模型"><ElInput v-model="chatBot.model" :disabled="chatBot.provider === 'nvidia'" /></ElFormItem></div><ElFormItem label="系统提示词"><ElInput v-model="chatBot.systemPrompt" type="textarea" :rows="4" maxlength="4000" show-word-limit /></ElFormItem></ElCollapseItem></ElCollapse>
          <div class="test-panel"><div class="test-header"><div><strong>连接测试</strong><small>使用当前表单值，未保存的 API Key 也会参与测试</small></div><ElButton type="primary" :loading="testingBot" @click="runBotTest">发送测试消息</ElButton></div><ElInput v-model="testMessage" maxlength="500" placeholder="输入一条测试消息" /><div v-if="testReply" class="test-result"><span>{{ testMeta }}</span><p>{{ testReply }}</p></div></div>
          <div class="form-footer"><span>上次更新：{{ formatDateTime(healthFor('chatBot').updatedAt) }}</span><ElButton type="primary" :disabled="!dirty.chatBot" :loading="savingGroup === 'chatBot'" @click="saveGroup('chatBot')">保存机器人</ElButton></div>
        </ElForm>
      </ElCollapseItem>

      <ElCollapseItem name="asr">
        <template #title><div class="collapse-title"><div><strong>讯飞语音识别</strong><small>聊天语音转文字服务</small></div><div class="title-status"><ElTag :type="healthTone('iflytekAsr')" effect="plain">{{ healthLabel('iflytekAsr') }}</ElTag><ElTag v-if="dirty.iflytekAsr" type="warning" effect="plain">未保存</ElTag></div></div></template>
        <ElForm label-position="top" class="settings-form"><div class="form-grid three-columns"><ElFormItem label="启用识别"><div class="switch-field"><ElSwitch v-model="asr.enabled" /><span>{{ asr.enabled ? '已启用' : '已停用' }}</span></div></ElFormItem><ElFormItem label="产品类型"><ElSelect v-model="asr.productType"><ElOption v-for="[value, label] in asrProductOptions" :key="value" :label="value === 'rtasr' ? '实时语音识别（RTASR）' : value.toUpperCase()" :value="value" /></ElSelect></ElFormItem><ElFormItem label="App ID"><ElInput v-model="asr.appId" maxlength="120" /></ElFormItem></div><div class="form-grid two-columns"><ElFormItem label="API Key"><ElInput v-model="asr.apiKey" type="password" show-password :placeholder="secretHint(data.iflytekAsr.apiKey.configured)" /><div class="secret-row"><span>{{ data.iflytekAsr.apiKey.configured ? '已配置' : '尚未配置' }}</span><ElButton v-if="data.iflytekAsr.apiKey.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('iflytek-asr', 'apiKey', '讯飞 ASR API Key')">清除</ElButton></div></ElFormItem><ElFormItem label="Secret Key"><ElInput v-model="asr.secretKey" type="password" show-password :placeholder="secretHint(data.iflytekAsr.secretKey.configured)" /><div class="secret-row"><span>{{ data.iflytekAsr.secretKey.configured ? '已配置' : '可选兼容字段' }}</span><ElButton v-if="data.iflytekAsr.secretKey.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('iflytek-asr', 'secretKey', '讯飞 ASR Secret Key')">清除</ElButton></div></ElFormItem></div><ElCollapse class="advanced-collapse"><ElCollapseItem name="asr-advanced" title="高级连接参数"><ElFormItem label="API Secret（兼容旧配置）"><ElInput v-model="asr.apiSecret" type="password" show-password :placeholder="secretHint(data.iflytekAsr.apiSecret.configured)" /><div class="secret-row"><span>{{ data.iflytekAsr.apiSecret.configured ? '已配置' : '未配置' }}</span><ElButton v-if="data.iflytekAsr.apiSecret.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('iflytek-asr', 'apiSecret', '讯飞 ASR API Secret')">清除</ElButton></div></ElFormItem><ElFormItem label="WebSocket 地址"><ElInput v-model="asr.hostUrl" /></ElFormItem></ElCollapseItem></ElCollapse><div class="form-footer"><span>上次更新：{{ formatDateTime(healthFor('iflytekAsr').updatedAt) }}</span><ElButton type="primary" :disabled="!dirty.iflytekAsr" :loading="savingGroup === 'iflytekAsr'" @click="saveGroup('iflytekAsr')">保存语音识别</ElButton></div></ElForm>
      </ElCollapseItem>

      <ElCollapseItem name="tts">
        <template #title><div class="collapse-title"><div><strong>讯飞语音合成</strong><small>机器人语音播报服务</small></div><div class="title-status"><ElTag :type="healthTone('iflytekTts')" effect="plain">{{ healthLabel('iflytekTts') }}</ElTag><ElTag v-if="dirty.iflytekTts" type="warning" effect="plain">未保存</ElTag></div></div></template>
        <ElForm label-position="top" class="settings-form"><div class="form-grid three-columns"><ElFormItem label="启用合成"><div class="switch-field"><ElSwitch v-model="tts.enabled" /><span>{{ tts.enabled ? '已启用' : '已停用' }}</span></div></ElFormItem><ElFormItem label="App ID"><ElInput v-model="tts.appId" maxlength="120" /></ElFormItem><ElFormItem label="API Key"><ElInput v-model="tts.apiKey" type="password" show-password :placeholder="secretHint(data.iflytekTts.apiKey.configured)" /><div class="secret-row"><span>{{ data.iflytekTts.apiKey.configured ? '已配置' : '尚未配置' }}</span><ElButton v-if="data.iflytekTts.apiKey.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('iflytek-tts', 'apiKey', '讯飞 TTS API Key')">清除</ElButton></div></ElFormItem></div><div class="form-grid two-columns"><ElFormItem label="API Secret"><ElInput v-model="tts.apiSecret" type="password" show-password :placeholder="secretHint(data.iflytekTts.apiSecret.configured)" /><div class="secret-row"><span>{{ data.iflytekTts.apiSecret.configured ? '已配置' : '尚未配置' }}</span><ElButton v-if="data.iflytekTts.apiSecret.configured" text type="danger" size="small" :icon="Delete" @click="clearSecret('iflytek-tts', 'apiSecret', '讯飞 TTS API Secret')">清除</ElButton></div></ElFormItem><ElFormItem label="WebSocket 地址"><ElInput v-model="tts.hostUrl" /></ElFormItem></div><div class="form-footer"><span>上次更新：{{ formatDateTime(healthFor('iflytekTts').updatedAt) }}</span><ElButton type="primary" :disabled="!dirty.iflytekTts" :loading="savingGroup === 'iflytekTts'" @click="saveGroup('iflytekTts')">保存语音合成</ElButton></div></ElForm>
      </ElCollapseItem>
    </ElCollapse>

    <ElAlert class="settings-boundary" type="info" :closable="false" show-icon>
      <template #title><span><ElIcon><Key /></ElIcon>凭据安全边界</span></template>
      <template #default>页面只接收“已配置 / 更新时间”状态；保存时留空会保留服务器已有密钥，清除操作会立即停用对应服务。</template>
    </ElAlert>
  </div>
</template>

<style scoped>
.settings-page { gap: 16px; }.settings-heading { padding-bottom: 2px; }.settings-heading h2 { margin: 6px 0 4px; font-size: 25px; }.settings-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }.settings-metrics { grid-template-columns: repeat(4, minmax(155px, 1fr)); gap: 10px; }.settings-metrics :deep(.metric-card) { min-height: 112px; padding: 14px; }.settings-collapse { overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }.settings-collapse :deep(.el-collapse-item__header) { min-height: 68px; padding: 0 18px; }.settings-collapse :deep(.el-collapse-item__wrap) { border-top: 1px solid var(--line); }.settings-collapse :deep(.el-collapse-item__content) { padding: 18px; }.collapse-title { min-width: 0; display: flex; align-items: center; justify-content: space-between; gap: 18px; padding-right: 8px; }.collapse-title > div:first-child { min-width: 0; display: grid; gap: 4px; }.collapse-title strong { color: var(--ink-900); font-size: 14px; }.collapse-title small { overflow: hidden; color: var(--ink-500); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.title-status { display: flex; flex: 0 0 auto; align-items: center; gap: 6px; }.settings-form { max-width: 1100px; }.form-grid { display: grid; gap: 14px; }.two-columns { grid-template-columns: repeat(2, minmax(0, 1fr)); }.three-columns { grid-template-columns: repeat(3, minmax(0, 1fr)); }.switch-field { min-height: 32px; display: flex; align-items: center; gap: 10px; color: var(--ink-700); font-size: 12px; }.secret-row { min-height: 19px; display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-top: 4px; color: var(--ink-500); font-size: 10px; }.secret-row span { display: inline-flex; align-items: center; gap: 4px; }.form-footer { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; padding-top: 14px; border-top: 1px solid var(--line); color: var(--ink-500); font-size: 10px; }.advanced-collapse { margin: 4px 0 14px; border: 1px solid var(--line); border-radius: 7px; }.advanced-collapse :deep(.el-collapse-item__header) { min-height: 42px; padding: 0 12px; color: var(--ink-700); font-size: 12px; }.advanced-collapse :deep(.el-collapse-item__content) { padding: 14px 12px 4px; }.avatar-editor { display: grid; grid-template-columns: auto minmax(0, 1fr) minmax(190px, .5fr); align-items: center; gap: 15px; margin: 2px 0 15px; padding: 13px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }.avatar-preview { width: 66px; height: 66px; overflow: hidden; display: grid; place-items: center; border-radius: 50%; color: var(--sakura-600); background: var(--sakura-100); }.avatar-preview img { width: 100%; height: 100%; object-fit: cover; }.avatar-preview.empty { border: 1px dashed var(--sakura-300); }.avatar-copy { min-width: 0; display: grid; gap: 5px; }.avatar-copy strong { color: var(--ink-900); font-size: 13px; }.avatar-copy > span { color: var(--ink-500); font-size: 10px; }.avatar-actions { display: flex; align-items: center; gap: 8px; margin-top: 3px; }.skin-field { margin: 0; }.test-panel { display: grid; gap: 10px; margin: 2px 0 15px; padding: 14px; border: 1px solid #e8dce5; border-radius: 7px; background: #fffafd; }.test-header { display: flex; align-items: center; justify-content: space-between; gap: 12px; }.test-header > div { display: grid; gap: 4px; }.test-header strong { color: var(--ink-900); font-size: 12px; }.test-header small { color: var(--ink-500); font-size: 10px; }.test-result { padding: 10px; border-left: 3px solid var(--sakura-400); background: white; }.test-result span { color: var(--ink-500); font-size: 10px; }.test-result p { margin: 6px 0 0; color: var(--ink-900); font-size: 12px; line-height: 1.55; white-space: pre-wrap; }.settings-boundary :deep(.el-alert__title span) { display: inline-flex; align-items: center; gap: 5px; }
@media (max-width: 1100px) { .settings-metrics { grid-template-columns: repeat(2, minmax(155px, 1fr)); }.avatar-editor { grid-template-columns: auto minmax(0, 1fr); }.skin-field { grid-column: 1 / -1; } }
@media (max-width: 720px) { .settings-heading { align-items: flex-start; flex-direction: column; }.two-columns, .three-columns { grid-template-columns: 1fr; }.settings-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }.avatar-editor { grid-template-columns: auto minmax(0, 1fr); }.avatar-copy { min-width: 0; }.test-header, .form-footer { align-items: flex-start; flex-direction: column; }.form-footer .el-button { width: 100%; }.settings-collapse :deep(.el-collapse-item__header) { padding-inline: 12px; }.settings-collapse :deep(.el-collapse-item__content) { padding-inline: 12px; } }
</style>
