<script setup lang="ts">
import { Coin, TrendCharts, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, watch } from 'vue';

import type { AdminUser, UserEconomyPayload } from '@/types/user';
import { signedNumber } from '@/utils/users';

const props = defineProps<{
  modelValue: boolean;
  user: AdminUser | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [payload: UserEconomyPayload];
}>();

const form = reactive<UserEconomyPayload>({
  currency: 'coins',
  direction: 'credit',
  amount: 0,
  reasonCode: 'customer_support',
  note: '',
});

const currentBalance = computed(() => form.currency === 'coins'
  ? Number(props.user?.growth.sakuraCoins || 0)
  : Number(props.user?.growth.points || 0));
const delta = computed(() => form.direction === 'credit' ? Number(form.amount || 0) : -Number(form.amount || 0));
const nextBalance = computed(() => currentBalance.value + delta.value);

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    Object.assign(form, {
      currency: 'coins',
      direction: 'credit',
      amount: 0,
      reasonCode: 'customer_support',
      note: '',
    });
  },
);

function submit(): void {
  const amount = Number(form.amount || 0);
  if (!Number.isInteger(amount) || amount <= 0) {
    ElMessage.warning('请输入大于 0 的整数金额');
    return;
  }
  if (nextBalance.value < 0) {
    ElMessage.warning('扣除数量不能超过当前余额');
    return;
  }
  emit('submit', {
    currency: form.currency,
    direction: form.direction,
    amount,
    reasonCode: form.reasonCode,
    note: form.note.trim(),
  });
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="人工账变"
    width="min(560px, 94vw)"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div class="economy-target">
      <span class="target-icon"><ElIcon><Coin /></ElIcon></span>
      <div><strong>{{ user?.nickname }}</strong><span>所有调整都会写入用户账变流水，不能直接覆盖余额。</span></div>
    </div>

    <ElForm label-position="top">
      <div class="two-columns">
        <ElFormItem label="资产类型" required>
          <ElSelect v-model="form.currency" class="full-width">
            <ElOption label="樱花币" value="coins" /><ElOption label="成长值" value="points" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem label="调整方向" required>
          <ElRadioGroup v-model="form.direction">
            <ElRadioButton value="credit">增加</ElRadioButton>
            <ElRadioButton value="debit">扣除</ElRadioButton>
          </ElRadioGroup>
        </ElFormItem>
      </div>
      <ElFormItem label="数量" required>
        <ElInputNumber v-model="form.amount" :min="0" :max="100000000" :step="10" controls-position="right" class="full-width" />
      </ElFormItem>
      <ElFormItem label="调整原因" required>
        <ElSelect v-model="form.reasonCode" class="full-width">
          <ElOption label="客服补偿" value="customer_support" />
          <ElOption label="活动奖励" value="campaign_reward" />
          <ElOption label="退款返还" value="refund" />
          <ElOption label="异常账变纠正" value="fraud_correction" />
          <ElOption label="数据修正" value="data_correction" />
          <ElOption label="其他人工调整" value="other" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="凭据说明">
        <ElInput v-model="form.note" maxlength="120" show-word-limit placeholder="建议填写工单号、活动批次或复核说明" />
      </ElFormItem>
    </ElForm>

    <div class="balance-preview" :class="{ invalid: nextBalance < 0 }">
      <span><small>当前余额</small><b>{{ currentBalance.toLocaleString() }}</b></span>
      <span class="delta"><ElIcon><TrendCharts /></ElIcon>{{ signedNumber(delta) }}</span>
      <span><small>调整后</small><b>{{ nextBalance.toLocaleString() }}</b></span>
    </div>
    <div v-if="form.direction === 'debit'" class="debit-note">
      <ElIcon><WarningFilled /></ElIcon><span>余额不足时服务端会拒绝整笔操作，不会静默扣到 0。</span>
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="submit">确认记账</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.economy-target { display: flex; align-items: center; gap: 11px; padding: 13px; margin-bottom: 18px; border: 1px solid #f0e3d3; border-radius: 14px; background: #fffaf3; }.target-icon { display: grid; width: 40px; height: 40px; place-items: center; border-radius: 12px; color: #b47a25; background: #ffedca; }.target-icon :deep(.el-icon) { font-size: 20px; }.economy-target > div { display: flex; flex-direction: column; gap: 3px; }.economy-target strong { color: #4b3d36; }.economy-target span { color: #937f74; font-size: 11px; }
.two-columns { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }.full-width { width: 100%; }.balance-preview { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; gap: 16px; padding: 16px; border: 1px solid #eadfe3; border-radius: 15px; background: #fcfafb; }.balance-preview.invalid { border-color: #efb8c3; background: #fff4f6; }.balance-preview > span:not(.delta) { display: flex; flex-direction: column; align-items: center; gap: 4px; }.balance-preview small { color: #99868d; }.balance-preview b { color: #44363c; font-size: 21px; }.delta { display: flex; align-items: center; gap: 5px; color: #c25579; font-weight: 700; }.debit-note { display: flex; gap: 7px; padding: 9px 11px; margin-top: 10px; border-radius: 10px; color: #a16645; background: #fff4e7; font-size: 11px; }
@media (max-width: 520px) { .two-columns { grid-template-columns: 1fr; gap: 0; } }
</style>
