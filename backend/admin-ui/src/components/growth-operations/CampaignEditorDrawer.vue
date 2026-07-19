<script setup lang="ts">
import {
  Calendar,
  InfoFilled,
  Picture,
  Promotion,
  UploadFilled,
  User,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import type { UploadRequestOptions } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  createGrowthCampaign,
  updateGrowthCampaign,
  uploadCampaignBanner,
} from '@/services/growth-operations';
import type {
  CampaignAudiencePreset,
  CampaignDetailResponse,
  CampaignSummary,
  GrowthOperationOptions,
} from '@/types/growth-operations';
import { parseServerTime } from '@/utils/format';
import {
  campaignAudienceLabel,
  campaignStatusLabel,
} from '@/utils/growth-operations';

type UploadAjaxError = Parameters<UploadRequestOptions['onError']>[0];

const props = defineProps<{
  modelValue: boolean;
  item: CampaignSummary | null;
  options: GrowthOperationOptions;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: CampaignDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const uploading = ref(false);
const openSections = ref(['basics', 'audience', 'schedule']);
const form = reactive({
  campaignKey: '',
  title: '',
  description: '',
  bannerUrl: '',
  audiencePreset: 'all_registered' as CampaignAudiencePreset,
  dateRange: null as [Date, Date] | null,
  minVersionCode: 0,
  maxVersionCode: 0,
  changeNote: '',
});

const editing = computed(() => Boolean(props.item));
const legacyAudience = computed(() => form.audiencePreset === 'legacy_custom');

watch(
  () => props.modelValue,
  (open) => {
    if (open) resetForm();
  },
);

function resetForm(): void {
  const start = props.item?.startsAt ? parseServerTime(props.item.startsAt) : new Date();
  const end = props.item?.endsAt
    ? parseServerTime(props.item.endsAt)
    : new Date(Date.now() + 7 * 86400_000);
  Object.assign(form, {
    campaignKey: props.item?.campaignKey || '',
    title: props.item?.title || '',
    description: props.item?.description || '',
    bannerUrl: props.item?.bannerUrl || '',
    audiencePreset: props.item?.audiencePreset || 'all_registered',
    dateRange: start && end ? [start, end] : null,
    minVersionCode: props.item?.minVersionCode || 0,
    maxVersionCode: props.item?.maxVersionCode || 0,
    changeNote: '',
  });
  openSections.value = ['basics', 'audience', 'schedule'];
}

async function handleBannerUpload(options: UploadRequestOptions): Promise<void> {
  const file = options.file;
  if (file.size > 5 * 1024 * 1024) {
    const error = new Error('活动横幅不能超过 5MB');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
    const error = new Error('活动横幅仅支持 JPG、PNG 或 WebP');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  uploading.value = true;
  try {
    const result = await uploadCampaignBanner(file);
    form.bannerUrl = result.url;
    options.onSuccess(result);
    ElMessage.success('横幅已上传，保存草稿后正式生效');
  } catch (error) {
    options.onError(asUploadError(error));
    ElMessage.error(errorMessage(error, '活动横幅上传失败'));
  } finally {
    uploading.value = false;
  }
}

async function save(): Promise<void> {
  const validation = validateForm();
  if (validation) {
    ElMessage.warning(validation);
    return;
  }
  saving.value = true;
  try {
    const payload = {
      campaignKey: form.campaignKey.trim(),
      title: form.title.trim(),
      description: form.description.trim(),
      bannerUrl: form.bannerUrl,
      startsAt: form.dateRange?.[0].toISOString() || '',
      endsAt: form.dateRange?.[1].toISOString() || '',
      audiencePreset: form.audiencePreset as Exclude<CampaignAudiencePreset, 'legacy_custom'>,
      minVersionCode: form.minVersionCode,
      maxVersionCode: form.maxVersionCode,
      changeNote: form.changeNote.trim(),
    };
    const result = props.item
      ? await updateGrowthCampaign(props.item.id, {
        ...payload,
        expectedRevision: props.item.revision,
      })
      : await createGrowthCampaign(payload);
    ElMessage.success(props.item ? '活动草稿已更新并生成新版本' : '活动草稿已创建');
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动草稿保存失败'));
    if (error instanceof ApiError && error.code === 'growth_campaign_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function validateForm(): string {
  if (!form.campaignKey.trim()) return '请填写活动标识';
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(form.campaignKey.trim())) return '活动标识仅支持小写字母、数字、点、冒号、下划线和短横线';
  if (!form.title.trim()) return '请填写用户可见的活动名称';
  if (!form.description.trim()) return '请填写活动说明';
  if (!form.bannerUrl) return '请上传活动横幅';
  if (legacyAudience.value) return '旧版自定义人群不可继续使用，请改选受支持的人群';
  if (!form.dateRange) return '请选择完整的开始与结束时间';
  if (form.dateRange[0].getTime() >= form.dateRange[1].getTime()) return '结束时间必须晚于开始时间';
  if (form.maxVersionCode && form.minVersionCode > form.maxVersionCode) return '最高版本号不能低于最低版本号';
  if (form.changeNote.trim().length < 4) return '请填写具体的创建或修改原因';
  return '';
}

function asUploadError(error: unknown): UploadAjaxError {
  return error as UploadAjaxError;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(760px, 97vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="editor-heading">
        <span>{{ editing ? 'CAMPAIGN REVISION' : 'NEW CAMPAIGN DRAFT' }}</span>
        <h2>{{ editing ? item?.title : '创建活动草稿' }}</h2>
        <p v-if="item">{{ campaignStatusLabel(item.status) }} · 版本 {{ item.revision }} · {{ item.activeTaskCount }} 个有效任务</p>
        <p v-else>活动始终先保存为草稿，任务与预算复核完成后再启用。</p>
      </div>
    </template>

    <div class="editor-body">
      <ElCollapse v-model="openSections" class="editor-collapse">
        <ElCollapseItem name="basics">
          <template #title>
            <span class="collapse-heading"><ElIcon><InfoFilled /></ElIcon>活动内容与横幅</span>
          </template>
          <div class="section-grid">
            <ElFormItem label="活动标识" required>
              <ElInput v-model="form.campaignKey" :disabled="editing" maxlength="120" placeholder="summer-reading-2026" />
            </ElFormItem>
            <ElFormItem label="活动名称" required>
              <ElInput v-model="form.title" maxlength="80" show-word-limit placeholder="用户在活动页看到的名称" />
            </ElFormItem>
            <ElFormItem class="wide" label="活动说明" required>
              <ElInput v-model="form.description" type="textarea" :rows="3" maxlength="1000" show-word-limit placeholder="说明参与方式、时间与奖励规则" />
            </ElFormItem>
            <div class="banner-field wide">
              <div class="banner-preview" :class="{ empty: !form.bannerUrl }">
                <img v-if="form.bannerUrl" :src="form.bannerUrl" alt="活动横幅" />
                <span v-else><ElIcon><Picture /></ElIcon><b>尚未上传横幅</b></span>
              </div>
              <div class="banner-actions">
                <strong>活动横幅</strong>
                <p>建议 16:9，JPG、PNG 或 WebP，最大 5MB。仅支持站内上传，不接受 URL。</p>
                <ElUpload
                  accept="image/jpeg,image/png,image/webp"
                  :show-file-list="false"
                  :http-request="handleBannerUpload"
                  :disabled="uploading"
                >
                  <ElButton :icon="UploadFilled" :loading="uploading">
                    {{ form.bannerUrl ? '替换横幅' : '上传横幅' }}
                  </ElButton>
                </ElUpload>
              </div>
            </div>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="audience">
          <template #title>
            <span class="collapse-heading"><ElIcon><User /></ElIcon>目标人群</span>
          </template>
          <ElAlert
            v-if="legacyAudience"
            title="该活动使用旧版自定义人群"
            description="旧配置无法可靠评估覆盖人数与奖励预算，请改选一个受支持的人群后保存。"
            type="warning"
            :closable="false"
            show-icon
          />
          <div class="audience-options">
            <label
              v-for="preset in options.audiencePresets"
              :key="preset"
              :class="{ selected: form.audiencePreset === preset }"
            >
              <ElRadio v-model="form.audiencePreset" :value="preset">
                <strong>{{ campaignAudienceLabel(preset) }}</strong>
                <small>{{ {
                  all_registered: '所有正常注册账号',
                  new_users: '注册时间不超过 7 天',
                  active_users: '近 30 天有内容行为',
                  readers: '有小说或漫画阅读行为',
                  anime_viewers: '有动漫观看行为',
                }[preset] }}</small>
              </ElRadio>
            </label>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="schedule">
          <template #title>
            <span class="collapse-heading"><ElIcon><Calendar /></ElIcon>时间与客户端范围</span>
          </template>
          <div class="section-grid schedule-grid">
            <ElFormItem class="wide" label="活动时间" required>
              <ElDatePicker
                v-model="form.dateRange"
                type="datetimerange"
                start-placeholder="开始时间"
                end-placeholder="结束时间"
                range-separator="至"
                unlink-panels
              />
            </ElFormItem>
            <ElFormItem label="最低版本号">
              <ElInputNumber v-model="form.minVersionCode" :min="0" :max="100000000" controls-position="right" />
              <span class="field-help">0 表示不限制最低版本。</span>
            </ElFormItem>
            <ElFormItem label="最高版本号">
              <ElInputNumber v-model="form.maxVersionCode" :min="0" :max="100000000" controls-position="right" />
              <span class="field-help">0 表示不限制最高版本。</span>
            </ElFormItem>
          </div>
        </ElCollapseItem>
      </ElCollapse>

      <section class="change-note">
        <div><ElIcon><Promotion /></ElIcon><span><strong>版本说明</strong><small>每次保存都会生成可恢复的活动版本。</small></span></div>
        <ElInput v-model="form.changeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明本次创建或修改的依据" />
      </section>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
        <ElButton type="primary" :loading="saving" @click="save">{{ editing ? '保存新版本' : '创建草稿' }}</ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.editor-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.editor-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.editor-body { display: grid; gap: 16px; }
.collapse-heading { display: flex; align-items: center; gap: 8px; color: var(--ink-800); font-size: 13px; font-weight: 700; }
.collapse-heading .el-icon { color: var(--sakura-600); }
.section-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 16px; padding: 8px 3px 2px; }
.section-grid .wide { grid-column: 1 / -1; }
.section-grid :deep(.el-form-item) { display: grid; align-content: start; }
.section-grid :deep(.el-form-item__label) { justify-content: flex-start; }
.section-grid :deep(.el-input-number), .section-grid :deep(.el-date-editor) { width: 100%; }
.banner-field { display: grid; grid-template-columns: minmax(230px, 1.3fr) minmax(210px, 1fr); gap: 16px; margin: 3px 0 16px; }
.banner-preview { width: 100%; aspect-ratio: 16 / 9; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.banner-preview img { width: 100%; height: 100%; display: block; object-fit: cover; }
.banner-preview span { width: 100%; height: 100%; display: grid; place-items: center; align-content: center; gap: 7px; color: var(--ink-500); font-size: 12px; }
.banner-preview .el-icon { font-size: 26px; }
.banner-actions { display: grid; align-content: center; justify-items: start; gap: 8px; }
.banner-actions strong { color: var(--ink-900); font-size: 13px; }
.banner-actions p { margin: 0; color: var(--ink-500); font-size: 11px; line-height: 1.55; }
.audience-options { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 9px; padding: 10px 3px 4px; }
.audience-options label { min-width: 0; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: white; cursor: pointer; }
.audience-options label.selected { border-color: var(--sakura-300); background: var(--sakura-50); }
.audience-options :deep(.el-radio) { width: 100%; height: auto; align-items: flex-start; }
.audience-options :deep(.el-radio__label) { min-width: 0; display: grid; gap: 3px; white-space: normal; }
.audience-options strong { color: var(--ink-900); font-size: 12px; }
.audience-options small, .field-help { color: var(--ink-500); font-size: 10px; line-height: 1.45; }
.field-help { display: block; margin-top: 5px; }
.change-note { display: grid; grid-template-columns: minmax(180px, .7fr) minmax(260px, 1.3fr); gap: 16px; padding: 15px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.change-note > div { display: flex; align-items: flex-start; gap: 9px; }
.change-note > div > .el-icon { margin-top: 2px; color: var(--sakura-600); }
.change-note span { display: grid; gap: 4px; }
.change-note strong { color: var(--ink-900); font-size: 12px; }
.change-note small { color: var(--ink-500); font-size: 10px; line-height: 1.5; }
.drawer-footer { display: flex; justify-content: flex-end; gap: 8px; }
@media (max-width: 620px) {
  .section-grid, .audience-options, .banner-field, .change-note { grid-template-columns: 1fr; }
  .section-grid > * { grid-column: 1 !important; }
}
</style>
