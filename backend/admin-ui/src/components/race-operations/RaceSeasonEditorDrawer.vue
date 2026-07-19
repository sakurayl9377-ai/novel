<script setup lang="ts">
import { Calendar, DataAnalysis, InfoFilled, Tickets } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { createRaceSeason, updateRaceSeason } from '@/services/race-operations';
import type {
  RaceOperationOptions,
  RaceSeasonDetailResponse,
  RaceSeasonSummary,
  RaceTier,
} from '@/types/race-operations';
import { parseServerTime } from '@/utils/format';
import { raceSeasonStatusLabel, raceTierLabel } from '@/utils/race-operations';

const props = defineProps<{
  modelValue: boolean;
  item: RaceSeasonSummary | null;
  options: RaceOperationOptions;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: RaceSeasonDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const openSections = ref(['basics', 'scoring', 'tiers']);
const form = reactive({
  seasonKey: '',
  title: '',
  description: '',
  dateRange: null as [Date, Date] | null,
  participationPoints: 10,
  winPoints: 20,
  maxProfitBonus: 30,
  tiers: [] as RaceTier[],
  changeNote: '',
});

const editing = computed(() => Boolean(props.item));
const termsLocked = computed(() => Boolean(props.item?.participants));

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
    : new Date(Date.now() + 30 * 86400_000);
  const sourceTiers = props.item?.config.tiers?.length
    ? props.item.config.tiers
    : props.options.tiers;
  Object.assign(form, {
    seasonKey: props.item?.seasonKey || '',
    title: props.item?.title || '',
    description: props.item?.description || '',
    dateRange: start && end ? [start, end] : null,
    participationPoints: props.item?.config.participationPoints ?? 10,
    winPoints: props.item?.config.winPoints ?? 20,
    maxProfitBonus: props.item?.config.maxProfitBonus ?? 30,
    tiers: sourceTiers.map((item) => ({ ...item })),
    changeNote: '',
  });
  openSections.value = ['basics', 'scoring', 'tiers'];
}

function addTier(): void {
  if (form.tiers.length >= 10) return;
  const previous = form.tiers.at(-1);
  form.tiers.push({
    key: `tier-${form.tiers.length + 1}`,
    points: (previous?.points || 0) + 1000,
  });
}

function removeTier(index: number): void {
  if (index === 0) return;
  form.tiers.splice(index, 1);
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
      seasonKey: form.seasonKey.trim(),
      title: form.title.trim(),
      description: form.description.trim(),
      startsAt: form.dateRange?.[0].toISOString() || '',
      endsAt: form.dateRange?.[1].toISOString() || '',
      config: {
        participationPoints: form.participationPoints,
        winPoints: form.winPoints,
        maxProfitBonus: form.maxProfitBonus,
        tiers: form.tiers.map((item) => ({ key: item.key.trim(), points: item.points })),
      },
      changeNote: form.changeNote.trim(),
    };
    const result = props.item
      ? await updateRaceSeason(props.item.id, {
        ...payload,
        expectedRevision: props.item.revision,
      })
      : await createRaceSeason(payload);
    ElMessage.success(props.item ? '赛季配置已保存为新版本' : '赛季草稿已创建');
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛季保存失败'));
    if (error instanceof ApiError && error.code === 'race_season_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function validateForm(): string {
  if (!form.seasonKey.trim()) return '请填写赛季标识';
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(form.seasonKey.trim())) {
    return '赛季标识仅支持小写字母、数字、点、冒号、下划线和短横线';
  }
  if (!form.title.trim()) return '请填写赛季名称';
  if (!form.description.trim()) return '请填写赛季说明';
  if (!form.dateRange) return '请选择完整的赛季时间';
  if (form.dateRange[0].getTime() >= form.dateRange[1].getTime()) return '结束时间必须晚于开始时间';
  if (!form.tiers.length || form.tiers[0].key !== 'bronze' || form.tiers[0].points !== 0) {
    return '首个段位必须是 0 成长值起步的 bronze';
  }
  if (new Set(form.tiers.map((item) => item.key.trim())).size !== form.tiers.length) return '段位标识不能重复';
  for (let index = 1; index < form.tiers.length; index += 1) {
    if (form.tiers[index].points <= form.tiers[index - 1].points) return '段位门槛必须严格递增';
  }
  if (form.changeNote.trim().length < 4) return '请填写具体的创建或修改原因';
  return '';
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
        <span>{{ editing ? 'SEASON REVISION' : 'NEW SEASON DRAFT' }}</span>
        <h2>{{ editing ? item?.title : '创建赛季草稿' }}</h2>
        <p v-if="item">{{ raceSeasonStatusLabel(item.status) }} · 版本 {{ item.revision }} · {{ item.participants }} 位参与者</p>
        <p v-else>先保存草稿，再配置任务、排名奖励并完成预算复核。</p>
      </div>
    </template>

    <div class="editor-body">
      <ElAlert
        v-if="termsLocked"
        title="该赛季已有参与数据"
        description="赛季时间、计分参数和段位门槛已锁定；仍可修正名称与说明。"
        type="warning"
        :closable="false"
        show-icon
      />

      <ElCollapse v-model="openSections" class="editor-collapse">
        <ElCollapseItem name="basics">
          <template #title><span class="collapse-heading"><ElIcon><InfoFilled /></ElIcon>赛季信息</span></template>
          <div class="section-grid">
            <ElFormItem label="赛季标识" required>
              <ElInput v-model="form.seasonKey" :disabled="editing" maxlength="120" placeholder="summer-race-2026" />
            </ElFormItem>
            <ElFormItem label="赛季名称" required>
              <ElInput v-model="form.title" maxlength="100" show-word-limit placeholder="用户看到的赛季名称" />
            </ElFormItem>
            <ElFormItem class="wide" label="赛季说明" required>
              <ElInput v-model="form.description" type="textarea" :rows="3" maxlength="1000" show-word-limit placeholder="说明参与周期、积分方式和排名奖励" />
            </ElFormItem>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="schedule">
          <template #title><span class="collapse-heading"><ElIcon><Calendar /></ElIcon>赛季时间</span></template>
          <ElFormItem label="开始与结束时间" required class="date-field">
            <ElDatePicker
              v-model="form.dateRange"
              type="datetimerange"
              :disabled="termsLocked"
              range-separator="至"
              start-placeholder="开始时间"
              end-placeholder="结束时间"
              :default-time="[new Date(2000, 1, 1, 0, 0, 0), new Date(2000, 1, 1, 23, 59, 59)]"
            />
          </ElFormItem>
        </ElCollapseItem>

        <ElCollapseItem name="scoring">
          <template #title><span class="collapse-heading"><ElIcon><DataAnalysis /></ElIcon>积分规则</span></template>
          <div class="scoring-grid">
            <ElFormItem label="每轮参与积分">
              <ElInputNumber v-model="form.participationPoints" :disabled="termsLocked" :min="1" :max="10000" controls-position="right" />
            </ElFormItem>
            <ElFormItem label="获胜额外积分">
              <ElInputNumber v-model="form.winPoints" :disabled="termsLocked" :min="0" :max="10000" controls-position="right" />
            </ElFormItem>
            <ElFormItem label="单轮收益加分上限">
              <ElInputNumber v-model="form.maxProfitBonus" :disabled="termsLocked" :min="0" :max="10000" controls-position="right" />
            </ElFormItem>
          </div>
          <p class="formula-note">正收益每满 100 樱花币增加 1 积分，并受单轮收益加分上限约束。</p>
        </ElCollapseItem>

        <ElCollapseItem name="tiers">
          <template #title><span class="collapse-heading"><ElIcon><DataAnalysis /></ElIcon>段位门槛</span></template>
          <div class="tier-editor">
            <div v-for="(tier, index) in form.tiers" :key="index" class="tier-row">
              <span>{{ index + 1 }}</span>
              <ElInput v-model="tier.key" :disabled="termsLocked || index === 0" maxlength="40" placeholder="段位标识" />
              <ElInputNumber v-model="tier.points" :disabled="termsLocked || index === 0" :min="0" :max="100000000" controls-position="right" />
              <small>{{ raceTierLabel(tier.key) }}</small>
              <ElButton v-if="index > 0 && !termsLocked" text type="danger" @click="removeTier(index)">移除</ElButton>
            </div>
            <ElButton v-if="!termsLocked && form.tiers.length < 10" plain @click="addTier">添加段位</ElButton>
          </div>
        </ElCollapseItem>
      </ElCollapse>

      <section class="change-note">
        <header><ElIcon><Tickets /></ElIcon><div><strong>变更说明</strong><small>记录赛季配置的业务依据与复核人。</small></div></header>
        <ElInput v-model="form.changeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明为什么创建或修改该赛季" />
      </section>
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="save">{{ editing ? '保存新版本' : '创建赛季草稿' }}</ElButton>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.editor-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.editor-heading p { margin: 0; color: var(--ink-500); font-size: 11px; }
.editor-body { display: grid; gap: 14px; }
.editor-collapse { border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.editor-collapse :deep(.el-collapse-item__header) { min-height: 54px; height: auto; padding: 8px 15px; }
.editor-collapse :deep(.el-collapse-item__content) { padding: 3px 15px 16px; }
.collapse-heading { display: inline-flex; align-items: center; gap: 8px; color: var(--ink-900); font-size: 12px; font-weight: 800; }
.collapse-heading .el-icon { color: var(--sakura-600); }
.section-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
.section-grid .wide { grid-column: 1 / -1; }
.section-grid :deep(.el-form-item__label), .date-field :deep(.el-form-item__label), .scoring-grid :deep(.el-form-item__label) { justify-content: flex-start; }
.date-field { display: grid; }
.date-field :deep(.el-date-editor) { width: 100%; }
.scoring-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.scoring-grid :deep(.el-input-number) { width: 100%; }
.formula-note { margin: 0; padding: 9px 11px; border-radius: 6px; color: #5f7181; background: #f1f5f7; font-size: 10px; line-height: 1.5; }
.tier-editor { display: grid; gap: 8px; }
.tier-row { display: grid; grid-template-columns: 28px minmax(110px, .8fr) minmax(130px, 1fr) 70px auto; align-items: center; gap: 8px; }
.tier-row > span { width: 26px; height: 26px; display: grid; place-items: center; border-radius: 6px; color: var(--sakura-700); background: var(--sakura-50); font-size: 10px; font-weight: 800; }
.tier-row > small { color: var(--ink-500); font-size: 10px; }
.tier-row :deep(.el-input-number) { width: 100%; }
.change-note { display: grid; grid-template-columns: minmax(160px, .55fr) minmax(260px, 1.45fr); gap: 13px; padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.change-note header { display: flex; align-items: flex-start; gap: 8px; }
.change-note header > .el-icon { margin-top: 2px; color: var(--sakura-600); }
.change-note header div { display: grid; gap: 3px; }
.change-note strong { color: var(--ink-900); font-size: 12px; }
.change-note small { color: var(--ink-500); font-size: 9px; line-height: 1.45; }
@media (max-width: 620px) {
  .section-grid, .scoring-grid, .change-note { grid-template-columns: 1fr; }
  .section-grid > * { grid-column: 1 !important; }
  .tier-row { grid-template-columns: 28px minmax(0, 1fr) minmax(110px, 1fr); }
  .tier-row > small { grid-column: 2; }
  .tier-row > .el-button { grid-column: 3; grid-row: 2; justify-self: end; }
}
</style>
