<script setup lang="ts">
import { Coin, Medal, SwitchButton, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { finalizeRaceSeason, transitionRaceSeason } from '@/services/race-operations';
import type { RaceSeasonDetailResponse, RaceSeasonStatus } from '@/types/race-operations';
import { parseServerTime } from '@/utils/format';
import { raceSeasonTransitionLabel } from '@/utils/race-operations';

type SeasonAction = RaceSeasonStatus | 'finalize';

const props = defineProps<{
  modelValue: boolean;
  detail: RaceSeasonDetailResponse | null;
  target: SeasonAction | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: RaceSeasonDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const note = ref('');
const acknowledged = ref(false);

const activating = computed(() => props.target === 'active');
const finalizing = computed(() => props.target === 'finalize');
const cancelling = computed(() => props.target === 'ended');
const earlyFinalize = computed(() => {
  const end = props.detail?.item.endsAt ? parseServerTime(props.detail.item.endsAt) : null;
  return Boolean(end && end.getTime() > Date.now());
});
const actionLabel = computed(() => {
  if (finalizing.value) return '结算赛季';
  if (!props.target) return '赛季状态';
  return raceSeasonTransitionLabel(props.target as RaceSeasonStatus);
});

watch(
  () => props.modelValue,
  (open) => {
    if (open) {
      note.value = '';
      acknowledged.value = false;
    }
  },
);

async function save(): Promise<void> {
  if (!props.detail || !props.target) return;
  if (note.value.trim().length < 4) {
    ElMessage.warning('请填写具体的状态变更原因');
    return;
  }
  if ((activating.value || finalizing.value || cancelling.value) && !acknowledged.value) {
    ElMessage.warning(activating.value ? '请确认奖励预算' : '请确认该操作的不可逆影响');
    return;
  }
  saving.value = true;
  try {
    const result = finalizing.value
      ? await finalizeRaceSeason(props.detail.item.id, {
        expectedRevision: props.detail.item.revision,
        note: note.value.trim(),
        ...(earlyFinalize.value ? { acknowledgeEarlyFinalize: true } : {}),
      })
      : await transitionRaceSeason(props.detail.item.id, {
        status: props.target as RaceSeasonStatus,
        expectedRevision: props.detail.item.revision,
        note: note.value.trim(),
        ...(activating.value ? { acknowledgeBudget: true } : {}),
      });
    ElMessage.success(`${actionLabel.value}成功`);
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛季状态变更失败'));
    if (error instanceof ApiError && error.code === 'race_season_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    width="min(620px, 94vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="dialog-heading">
        <span>SEASON LIFECYCLE</span>
        <h2>{{ actionLabel }}</h2>
        <p>{{ detail?.item.title }} · 当前版本 {{ detail?.item.revision }}</p>
      </div>
    </template>

    <template v-if="detail && target">
      <section v-if="activating" class="budget-review">
        <header><ElIcon><Coin /></ElIcon><div><strong>启用前奖励预算复核</strong><small>{{ detail.budget.eligibleUsers.toLocaleString() }} 位有效用户 · {{ detail.item.activeTaskCount }} 个任务 · {{ detail.item.activeRewardCount }} 项排名奖励</small></div></header>
        <dl>
          <div><dt>成长值上限</dt><dd>{{ detail.budget.maximumPoints.toLocaleString() }}</dd></div>
          <div><dt>樱花币上限</dt><dd>{{ detail.budget.maximumCoins.toLocaleString() }}</dd></div>
          <div><dt>任务成长值</dt><dd>{{ detail.budget.maximumTaskPoints.toLocaleString() }}</dd></div>
          <div><dt>排名樱花币</dt><dd>{{ detail.budget.maximumRankingCoins.toLocaleString() }}</dd></div>
        </dl>
        <ElAlert
          v-if="!detail.item.activeRewardCount"
          title="赛季尚未满足启用条件"
          description="至少需要一项有效排名奖励。"
          type="warning"
          :closable="false"
          show-icon
        />
      </section>

      <section v-else-if="finalizing" class="finalize-review" :class="{ danger: earlyFinalize }">
        <ElIcon><WarningFilled v-if="earlyFinalize" /><Medal v-else /></ElIcon>
        <div>
          <strong>{{ earlyFinalize ? '赛季尚未到计划结束时间' : '最终榜单与奖励即将锁定' }}</strong>
          <p>{{ detail.item.participants }} 位参与者，预计生成 {{ detail.item.activeRewardCount }} 类排名奖励。结算成功后赛季不可重新启用，重复请求不会重复发奖。</p>
        </div>
      </section>

      <section v-else class="status-impact" :class="{ danger: cancelling }">
        <ElIcon><WarningFilled v-if="cancelling" /><SwitchButton v-else /></ElIcon>
        <div>
          <strong>{{ cancelling ? '取消后赛季不能恢复' : '暂停后不再累计赛季积分和任务进度' }}</strong>
          <p>{{ cancelling ? '仅无参与数据的草稿或暂停赛季可取消，配置与审计记录仍会保留。' : '暂停期间可以复核配置；已有参与数据对应的规则与奖励条款仍会保持锁定。' }}</p>
        </div>
      </section>

      <ElFormItem label="操作原因" required class="note-field">
        <ElInput v-model="note" type="textarea" :rows="3" maxlength="500" show-word-limit :placeholder="activating ? '说明预算、时间与奖励已由谁复核' : '说明本次状态操作的原因'" />
      </ElFormItem>

      <ElCheckbox v-if="activating || finalizing || cancelling" v-model="acknowledged" class="acknowledgement">
        <span v-if="activating"><ElIcon><Coin /></ElIcon>我已核对赛季时间、任务、排名奖励和最大成长值 / 樱花币预算</span>
        <span v-else-if="finalizing">我确认最终榜单与奖励发放后不可撤销{{ earlyFinalize ? '，并已评估提前结算影响' : '' }}</span>
        <span v-else>我确认该赛季没有参与数据，取消后不能恢复</span>
      </ElCheckbox>
    </template>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton :type="finalizing || cancelling ? 'danger' : 'primary'" :loading="saving" @click="save">{{ actionLabel }}</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.dialog-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.dialog-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 11px; }
.budget-review { display: grid; gap: 13px; padding: 15px; border: 1px solid #cfe1ee; border-radius: 8px; background: #f5fafd; }
.budget-review header { display: flex; align-items: flex-start; gap: 9px; }
.budget-review header > .el-icon { margin-top: 2px; color: #39769b; }
.budget-review header div { display: grid; gap: 3px; }
.budget-review header strong { color: #285978; font-size: 13px; }
.budget-review header small { color: #5e7e91; font-size: 10px; line-height: 1.45; }
.budget-review dl { margin: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border-top: 1px solid #d8e7f0; }
.budget-review dl div { min-width: 0; display: grid; gap: 4px; padding: 11px 8px 2px; border-right: 1px solid #d8e7f0; }
.budget-review dl div:last-child { border-right: 0; }
.budget-review dt { color: #5e7e91; font-size: 9px; }
.budget-review dd { margin: 0; color: #285978; font-size: 16px; font-weight: 800; letter-spacing: 0; overflow-wrap: anywhere; }
.status-impact, .finalize-review { display: flex; align-items: flex-start; gap: 11px; padding: 14px; border: 1px solid #eadcad; border-radius: 8px; color: #7b622b; background: #fffaf0; }
.status-impact.danger, .finalize-review.danger { border-color: #efcbd3; color: #984257; background: #fff5f7; }
.status-impact > .el-icon, .finalize-review > .el-icon { margin-top: 2px; font-size: 18px; }
.status-impact strong, .finalize-review strong { font-size: 13px; }
.status-impact p, .finalize-review p { margin: 5px 0 0; font-size: 11px; line-height: 1.55; }
.note-field { display: grid; margin: 17px 0 12px; }
.note-field :deep(.el-form-item__label) { justify-content: flex-start; }
.acknowledgement { height: auto; align-items: flex-start; white-space: normal; }
.acknowledgement span { display: inline-flex; align-items: center; gap: 5px; line-height: 1.5; white-space: normal; }
@media (max-width: 560px) {
  .budget-review dl { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .budget-review dl div { border-bottom: 1px solid #d8e7f0; }
}
</style>
