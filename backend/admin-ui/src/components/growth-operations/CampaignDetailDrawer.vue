<script setup lang="ts">
import {
  Coin,
  Delete,
  DocumentChecked,
  EditPen,
  Lock,
  Plus,
  Refresh,
  Tickets,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import CampaignTaskDialog from '@/components/growth-operations/CampaignTaskDialog.vue';
import { ApiError } from '@/services/api';
import {
  getGrowthCampaign,
  removeGrowthCampaignTask,
  restoreGrowthCampaign,
} from '@/services/growth-operations';
import type {
  CampaignDetailResponse,
  CampaignStatus,
  CampaignSummary,
  CampaignTask,
} from '@/types/growth-operations';
import { formatDateTime } from '@/utils/format';
import {
  campaignAudienceLabel,
  campaignEditable,
  campaignStatusLabel,
  campaignStatusTone,
  campaignTransitionLabel,
  growthContentTypeLabel,
  growthEventLabel,
  growthOperationActionLabel,
} from '@/utils/growth-operations';

const props = defineProps<{
  modelValue: boolean;
  campaignId: number;
  refreshKey: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  edit: [item: CampaignSummary];
  status: [target: CampaignStatus, detail: CampaignDetailResponse];
  changed: [detail: CampaignDetailResponse];
}>();

const loading = ref(false);
const detail = ref<CampaignDetailResponse | null>(null);
const activeTab = ref('overview');
const taskDialogOpen = ref(false);
const editingTask = ref<CampaignTask | null>(null);
const removeDialogOpen = ref(false);
const removingTask = ref<CampaignTask | null>(null);
const removeNote = ref('');
const removing = ref(false);
const restoreDialogOpen = ref(false);
const restoreRevision = ref<number | null>(null);
const restoreNote = ref('');
const restoring = ref(false);

const item = computed(() => detail.value?.item || null);
const editable = computed(() => Boolean(item.value && campaignEditable(item.value.status)));

watch(
  () => [props.modelValue, props.campaignId, props.refreshKey],
  ([open]) => {
    if (open && props.campaignId) void load();
  },
  { immediate: true },
);

async function load(): Promise<void> {
  loading.value = true;
  try {
    detail.value = await getGrowthCampaign(props.campaignId);
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动详情加载失败'));
  } finally {
    loading.value = false;
  }
}

function openTask(task: CampaignTask | null): void {
  editingTask.value = task;
  taskDialogOpen.value = true;
}

function afterMutation(value: CampaignDetailResponse): void {
  detail.value = value;
  emit('changed', value);
}

function openRemove(task: CampaignTask): void {
  removingTask.value = task;
  removeNote.value = '';
  removeDialogOpen.value = true;
}

async function removeTask(): Promise<void> {
  if (!detail.value || !removingTask.value || removeNote.value.trim().length < 4) {
    ElMessage.warning('请填写具体的任务停用或移除原因');
    return;
  }
  removing.value = true;
  try {
    const result = await removeGrowthCampaignTask(
      detail.value.item.id,
      removingTask.value.id,
      { expectedRevision: detail.value.item.revision, note: removeNote.value.trim() },
    );
    afterMutation(result);
    removeDialogOpen.value = false;
    ElMessage.success(removingTask.value.identityLocked ? '任务已停用，历史进度已保留' : '任务已移除');
  } catch (error) {
    ElMessage.error(errorMessage(error, '任务处理失败'));
    handleConflict(error);
  } finally {
    removing.value = false;
  }
}

function openRestore(revision: number): void {
  restoreRevision.value = revision;
  restoreNote.value = '';
  restoreDialogOpen.value = true;
}

async function restore(): Promise<void> {
  if (!detail.value || !restoreRevision.value || restoreNote.value.trim().length < 4) {
    ElMessage.warning('请填写恢复历史版本的具体原因');
    return;
  }
  restoring.value = true;
  try {
    const result = await restoreGrowthCampaign(detail.value.item.id, {
      revision: restoreRevision.value,
      expectedRevision: detail.value.item.revision,
      note: restoreNote.value.trim(),
    });
    afterMutation(result);
    restoreDialogOpen.value = false;
    ElMessage.success(`版本 ${restoreRevision.value} 已恢复为新的暂停版本`);
  } catch (error) {
    ElMessage.error(errorMessage(error, '历史版本恢复失败'));
    handleConflict(error);
  } finally {
    restoring.value = false;
  }
}

function handleConflict(error: unknown): void {
  if (error instanceof ApiError && error.code === 'growth_campaign_revision_conflict') {
    void load();
  }
}

function requestStatus(target: CampaignStatus): void {
  if (detail.value) emit('status', target, detail.value);
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(940px, 98vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="item" class="detail-heading">
        <img v-if="item.bannerUrl" :src="item.bannerUrl" alt="" />
        <span v-else class="heading-placeholder"><ElIcon><Tickets /></ElIcon></span>
        <div><span>CAMPAIGN · REVISION {{ item.revision }}</span><h2>{{ item.title }}</h2><p>{{ item.campaignKey }}</p></div>
        <ElTag :type="campaignStatusTone(item.status)" effect="plain">{{ campaignStatusLabel(item.status) }}</ElTag>
      </div>
    </template>

    <div v-loading="loading" class="detail-body">
      <template v-if="detail && item">
        <div class="detail-actions">
          <div>
            <ElButton v-if="editable" :icon="EditPen" @click="emit('edit', item)">编辑配置</ElButton>
            <ElButton :icon="Refresh" @click="load">刷新</ElButton>
          </div>
          <div>
            <ElButton
              v-for="transition in detail.transitions"
              :key="transition"
              :type="transition === 'ended' ? 'danger' : transition === 'active' ? 'primary' : 'warning'"
              :plain="transition !== 'active'"
              @click="requestStatus(transition)"
            >{{ campaignTransitionLabel(transition) }}</ElButton>
          </div>
        </div>

        <section class="detail-metrics">
          <div><span>预计覆盖</span><strong>{{ detail.budget.eligibleUsers.toLocaleString() }}</strong><small>{{ campaignAudienceLabel(detail.budget.audiencePreset) }}</small></div>
          <div><span>有效任务</span><strong>{{ detail.budget.activeTasks }}</strong><small>共 {{ item.taskCount }} 个任务</small></div>
          <div><span>已领奖用户</span><strong>{{ detail.budget.claimedUsers.toLocaleString() }}</strong><small>{{ detail.budget.claims }} 笔领取</small></div>
          <div><span>成长值上限</span><strong>{{ detail.budget.potentialPoints.toLocaleString() }}</strong><small>已发 {{ detail.budget.awardedPoints.toLocaleString() }}</small></div>
          <div><span>樱花币上限</span><strong>{{ detail.budget.potentialCoins.toLocaleString() }}</strong><small>已发 {{ detail.budget.awardedCoins.toLocaleString() }}</small></div>
        </section>

        <ElTabs v-model="activeTab" class="detail-tabs">
          <ElTabPane name="overview" label="活动配置">
            <section class="campaign-overview">
              <div class="large-banner">
                <img v-if="item.bannerUrl" :src="item.bannerUrl" alt="活动横幅" />
                <span v-else><ElIcon><WarningFilled /></ElIcon>尚未上传横幅</span>
              </div>
              <dl>
                <div><dt>目标人群</dt><dd>{{ campaignAudienceLabel(item.audiencePreset) }}</dd></div>
                <div><dt>客户端版本</dt><dd>{{ item.minVersionCode || '不限' }} 至 {{ item.maxVersionCode || '不限' }}</dd></div>
                <div><dt>开始时间</dt><dd>{{ formatDateTime(item.startsAt) }}</dd></div>
                <div><dt>结束时间</dt><dd>{{ formatDateTime(item.endsAt) }}</dd></div>
                <div><dt>最近修改</dt><dd>{{ formatDateTime(item.updatedAt) }}</dd></div>
                <div><dt>用户进度</dt><dd>{{ item.progressCount.toLocaleString() }} 条</dd></div>
                <div class="wide"><dt>活动说明</dt><dd>{{ item.description || '未填写' }}</dd></div>
              </dl>
            </section>
            <section class="budget-band">
              <div><ElIcon><Coin /></ElIcon><span><strong>单用户完整奖励</strong><small>完成所有有效任务时的理论值</small></span></div>
              <p><b>{{ detail.budget.perUserPoints.toLocaleString() }}</b> 成长值</p>
              <p><b>{{ detail.budget.perUserCoins.toLocaleString() }}</b> 樱花币</p>
            </section>
          </ElTabPane>

          <ElTabPane name="tasks" :label="`活动任务 ${detail.tasks.length}`">
            <div class="tab-toolbar">
              <div><strong>任务定义</strong><span>任务产生进度后将锁定完成条件。</span></div>
              <ElButton v-if="editable" type="primary" :icon="Plus" @click="openTask(null)">添加任务</ElButton>
            </div>
            <div class="task-list">
              <article v-for="task in detail.tasks" :key="task.id">
                <span class="task-state" :class="task.status"><ElIcon><DocumentChecked /></ElIcon></span>
                <div class="task-main">
                  <div><strong>{{ task.title }}</strong><ElTag size="small" effect="plain">{{ growthEventLabel(task.eventName) }} × {{ task.targetCount }}</ElTag><ElTag v-if="task.status === 'disabled'" size="small" type="info">已停用</ElTag></div>
                  <p>{{ task.description || '未填写任务说明' }}</p>
                  <span>{{ task.contentKey || growthContentTypeLabel(task.contentType) }} · 排序 {{ task.sortOrder }}</span>
                </div>
                <div class="task-reward"><span>奖励</span><strong>{{ task.rewardPoints }} / {{ task.rewardCoins }}</strong><small>成长值 / 樱花币</small></div>
                <div class="task-progress"><span>{{ task.progressUsers }} 人参与</span><strong>{{ task.completedUsers }} 人完成</strong><small>{{ task.claimCount }} 人已领</small></div>
                <div v-if="editable" class="task-actions">
                  <ElTooltip :content="task.identityLocked ? '完成条件已锁定，仍可编辑展示信息' : '编辑任务'">
                    <ElButton circle :icon="task.identityLocked ? Lock : EditPen" aria-label="编辑任务" @click="openTask(task)" />
                  </ElTooltip>
                  <ElTooltip :content="task.identityLocked ? '停用并保留历史进度' : '移除任务'">
                    <ElButton circle type="danger" plain :icon="Delete" aria-label="移除任务" @click="openRemove(task)" />
                  </ElTooltip>
                </div>
              </article>
              <ElEmpty v-if="!detail.tasks.length" :image-size="64" description="尚未添加活动任务" />
            </div>
          </ElTabPane>

          <ElTabPane name="versions" :label="`版本记录 ${detail.revisions.length}`">
            <div class="version-list">
              <article v-for="revision in detail.revisions" :key="revision.revision">
                <span :class="{ current: revision.revision === item.revision }">{{ revision.revision }}</span>
                <div><strong>版本 {{ revision.revision }}<ElTag v-if="revision.revision === item.revision" size="small" type="success">当前</ElTag></strong><p>{{ revision.note || '未填写版本说明' }}</p><small>{{ revision.admin.nickname || revision.admin.email }} · {{ formatDateTime(revision.createdAt) }}</small></div>
                <ElButton
                  v-if="editable && revision.revision < item.revision"
                  size="small"
                  :disabled="item.status === 'active'"
                  @click="openRestore(revision.revision)"
                >恢复为暂停版本</ElButton>
              </article>
            </div>
          </ElTabPane>

          <ElTabPane name="audit" :label="`操作审计 ${detail.events.length}`">
            <div class="event-list">
              <article v-for="event in detail.events" :key="event.id">
                <span class="event-icon" :class="event.action"><ElIcon><DocumentChecked /></ElIcon></span>
                <div><strong>{{ growthOperationActionLabel(event.action) }}</strong><p>{{ event.note || '未填写操作说明' }}</p><small>{{ event.admin.nickname || event.admin.email }} · {{ formatDateTime(event.createdAt) }}</small></div>
              </article>
            </div>
          </ElTabPane>
        </ElTabs>
      </template>
      <ElEmpty v-else-if="!loading" description="活动不存在或无法读取" />
    </div>

    <CampaignTaskDialog
      v-if="detail"
      v-model="taskDialogOpen"
      :detail="detail"
      :task="editingTask"
      @saved="afterMutation"
      @reload="load"
    />

    <ElDialog v-model="removeDialogOpen" width="min(520px, 92vw)" append-to-body :close-on-click-modal="false">
      <template #header><div class="modal-heading"><span>TASK RETIREMENT</span><h3>{{ removingTask?.identityLocked ? '停用活动任务' : '移除活动任务' }}</h3></div></template>
      <ElAlert
        :title="removingTask?.identityLocked ? '该任务已有用户进度，只会停用，不会删除' : '该任务尚无用户进度，可以安全移除'"
        :description="removingTask?.identityLocked ? '历史进度和奖励记录会完整保留。' : '操作仍会写入活动审计记录。'"
        type="warning"
        :closable="false"
        show-icon
      />
      <ElFormItem label="处理原因" required class="modal-field">
        <ElInput v-model="removeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明为什么停用或移除该任务" />
      </ElFormItem>
      <template #footer><ElButton @click="removeDialogOpen = false">取消</ElButton><ElButton type="danger" :loading="removing" @click="removeTask">确认处理</ElButton></template>
    </ElDialog>

    <ElDialog v-model="restoreDialogOpen" width="min(540px, 92vw)" append-to-body :close-on-click-modal="false">
      <template #header><div class="modal-heading"><span>REVISION RESTORE</span><h3>恢复版本 {{ restoreRevision }}</h3></div></template>
      <ElAlert title="恢复不会直接重新上线" description="历史配置会复制为一个新的暂停版本；已有进度或领奖任务的核心规则不能被回退。" type="info" :closable="false" show-icon />
      <ElFormItem label="恢复原因" required class="modal-field">
        <ElInput v-model="restoreNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明恢复版本的原因与复核结论" />
      </ElFormItem>
      <template #footer><ElButton @click="restoreDialogOpen = false">取消</ElButton><ElButton type="primary" :loading="restoring" @click="restore">恢复为暂停版本</ElButton></template>
    </ElDialog>
  </ElDrawer>
</template>

<style scoped>
.detail-heading { width: 100%; display: flex; align-items: center; gap: 12px; min-width: 0; }
.detail-heading > img, .heading-placeholder { width: 72px; height: 46px; flex: 0 0 72px; display: grid; place-items: center; border-radius: 7px; object-fit: cover; color: var(--sakura-600); background: var(--sakura-50); }
.detail-heading > div { min-width: 0; flex: 1; }
.detail-heading div > span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .08em; }
.detail-heading h2 { overflow: hidden; margin: 3px 0 2px; color: var(--ink-900); font-size: 18px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.detail-heading p { overflow: hidden; margin: 0; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.detail-body { min-height: 420px; display: grid; align-content: start; gap: 14px; }
.detail-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.detail-actions > div { display: flex; gap: 7px; flex-wrap: wrap; }
.detail-metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; }
.detail-metrics > div { min-width: 0; display: grid; gap: 4px; padding: 13px; border-right: 1px solid var(--line); }
.detail-metrics > div:last-child { border-right: 0; }
.detail-metrics span, .detail-metrics small { color: var(--ink-500); font-size: 10px; }
.detail-metrics strong { color: var(--ink-900); font-size: 19px; letter-spacing: 0; overflow-wrap: anywhere; }
.campaign-overview { display: grid; grid-template-columns: 300px minmax(0, 1fr); gap: 20px; padding: 10px 0; }
.large-banner { width: 100%; aspect-ratio: 16 / 9; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.large-banner img { width: 100%; height: 100%; display: block; object-fit: cover; }
.large-banner span { width: 100%; height: 100%; display: grid; place-items: center; align-content: center; gap: 7px; color: var(--ink-500); font-size: 11px; }
.campaign-overview dl { margin: 0; display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
.campaign-overview dl > div { min-width: 0; padding: 9px 11px; border-bottom: 1px solid var(--line); }
.campaign-overview dl .wide { grid-column: 1 / -1; }
.campaign-overview dt { color: var(--ink-500); font-size: 10px; }
.campaign-overview dd { margin: 4px 0 0; color: var(--ink-900); font-size: 12px; line-height: 1.5; overflow-wrap: anywhere; }
.budget-band { display: flex; align-items: center; gap: 24px; padding: 13px 14px; border: 1px solid #cfe1ee; border-radius: 8px; background: #f4f9fc; }
.budget-band > div { min-width: 0; display: flex; align-items: center; gap: 9px; margin-right: auto; color: #356e95; }
.budget-band span { display: grid; gap: 2px; }
.budget-band strong { color: #285978; font-size: 12px; }
.budget-band small { color: #587486; font-size: 10px; }
.budget-band p { margin: 0; color: #587486; font-size: 11px; white-space: nowrap; }
.budget-band b { color: #285978; font-size: 16px; }
.tab-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 9px 0 7px; }
.tab-toolbar > div { display: grid; gap: 3px; }
.tab-toolbar strong { color: var(--ink-900); font-size: 13px; }
.tab-toolbar span { color: var(--ink-500); font-size: 10px; }
.task-list, .version-list, .event-list { display: grid; }
.task-list article { display: grid; grid-template-columns: auto minmax(190px, 1.5fr) minmax(100px, .55fr) minmax(105px, .55fr) auto; align-items: center; gap: 11px; padding: 13px 2px; border-bottom: 1px solid var(--line); }
.task-state { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 7px; color: #287258; background: #e5f5ed; }
.task-state.disabled { color: #6c7785; background: #edf0f3; }
.task-main { min-width: 0; }
.task-main > div { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.task-main strong { color: var(--ink-900); font-size: 12px; }
.task-main p { overflow: hidden; margin: 4px 0; color: var(--ink-700); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.task-main > span, .task-reward span, .task-reward small, .task-progress span, .task-progress small { color: var(--ink-500); font-size: 9px; }
.task-reward, .task-progress { display: grid; gap: 3px; }
.task-reward strong, .task-progress strong { color: var(--ink-900); font-size: 12px; letter-spacing: 0; }
.task-actions { display: flex; gap: 5px; }
.version-list article { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px; padding: 13px 3px; border-bottom: 1px solid var(--line); }
.version-list article > span { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 50%; color: var(--ink-500); background: var(--surface-muted); font-size: 11px; font-weight: 800; }
.version-list article > span.current { color: white; background: var(--sakura-500); }
.version-list article > div { min-width: 0; }
.version-list strong { display: flex; align-items: center; gap: 6px; color: var(--ink-900); font-size: 12px; }
.version-list p { margin: 4px 0; color: var(--ink-700); font-size: 11px; }
.version-list small { color: var(--ink-500); font-size: 9px; }
.event-list article { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 11px; padding: 12px 2px; border-bottom: 1px solid var(--line); }
.event-icon { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 7px; color: #58697d; background: #edf1f5; }
.event-icon.activate { color: #287258; background: #e5f5ed; }
.event-icon.end { color: #a3465c; background: #fff0f3; }
.event-list strong { color: var(--ink-900); font-size: 12px; }
.event-list p { margin: 4px 0; color: var(--ink-700); font-size: 11px; }
.event-list small { color: var(--ink-500); font-size: 9px; }
.modal-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.modal-heading h3 { margin: 4px 0 0; color: var(--ink-900); font-size: 18px; letter-spacing: 0; }
.modal-field { display: grid; margin: 16px 0 0; }
.modal-field :deep(.el-form-item__label) { justify-content: flex-start; }
@media (max-width: 760px) {
  .detail-actions { align-items: flex-start; flex-direction: column; }
  .detail-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-metrics > div { border-bottom: 1px solid var(--line); }
  .campaign-overview { grid-template-columns: 1fr; }
  .task-list article { grid-template-columns: auto minmax(0, 1fr) auto; }
  .task-reward, .task-progress { grid-column: 2; }
  .task-actions { grid-column: 3; grid-row: 1 / span 3; }
}
@media (max-width: 520px) {
  .detail-metrics { grid-template-columns: 1fr; }
  .detail-metrics > div { border-right: 0; }
  .budget-band { align-items: flex-start; flex-direction: column; gap: 8px; }
  .version-list article { grid-template-columns: auto minmax(0, 1fr); }
  .version-list .el-button { grid-column: 2; justify-self: start; }
}
</style>
