<script setup lang="ts">
import { Coin, Document, Lock, User } from '@element-plus/icons-vue';
import { computed } from 'vue';

import type { FinanceEvent } from '@/types/finance';
import { formatDateTime } from '@/utils/format';
import {
  financeActionLabel,
  financeEventDirection,
  financeEventDirectionLabel,
  financeRelatedTypeLabel,
  signedAsset,
} from '@/utils/finance';

const props = defineProps<{
  modelValue: boolean;
  event: FinanceEvent | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'view-user': [userId: number];
}>();

const direction = computed(() => props.event ? financeEventDirection(props.event) : 'zero');
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(620px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <span class="heading-icon"><ElIcon><Document /></ElIcon></span>
        <div><span>LEDGER EVENT</span><h2>账变 #{{ event?.id }}</h2><p>{{ event ? formatDateTime(event.createdAt) : '' }}</p></div>
        <ElTag v-if="event" :type="direction === 'debit' ? 'danger' : direction === 'credit' ? 'success' : 'warning'">
          {{ financeEventDirectionLabel(event) }}
        </ElTag>
      </div>
    </template>

    <template v-if="event">
      <section class="event-amounts" :class="direction">
        <div><span>成长值变化</span><strong>{{ signedAsset(event.pointsDelta) }}</strong></div>
        <div><span>樱花币变化</span><strong>{{ signedAsset(event.coinsDelta) }}</strong></div>
      </section>

      <section class="detail-section">
        <div class="section-heading"><ElIcon><User /></ElIcon><div><h3>关联用户</h3><p>这里显示的是当前余额，不代表该事件发生后的历史余额。</p></div></div>
        <div class="user-line">
          <ElAvatar :src="event.user.avatarUrl" :size="44">{{ event.user.nickname?.slice(0, 1) }}</ElAvatar>
          <div><strong>{{ event.user.nickname || `用户 #${event.user.id}` }}</strong><span>{{ event.user.email }} · UID {{ event.user.id }}</span></div>
          <div class="current-balances"><span>成长值 <b>{{ event.user.currentPoints.toLocaleString() }}</b></span><span>樱花币 <b>{{ event.user.currentCoins.toLocaleString() }}</b></span></div>
        </div>
        <ElButton type="primary" plain class="user-button" @click="emit('view-user', event.user.id)">打开完整用户档案</ElButton>
      </section>

      <section class="detail-section">
        <div class="section-heading"><ElIcon><Coin /></ElIcon><div><h3>业务来源</h3><p>用于定位产生账变的规则、商品、活动或管理员。</p></div></div>
        <dl class="source-grid">
          <div><dt>事件类型</dt><dd>{{ financeActionLabel(event.action) }}</dd></div>
          <div><dt>来源类别</dt><dd>{{ financeRelatedTypeLabel(event.relatedType) }}</dd></div>
          <div><dt>关联标识</dt><dd>{{ event.relatedId || '未记录' }}</dd></div>
          <div><dt>操作管理员</dt><dd>{{ event.operator ? `${event.operator.nickname} · UID ${event.operator.id}` : '系统或用户行为' }}</dd></div>
          <div class="wide"><dt>账变说明</dt><dd>{{ event.description || '未填写说明' }}</dd></div>
        </dl>
      </section>

      <div class="immutable-note">
        <ElIcon><Lock /></ElIcon>
        <span>账变记录不可编辑或删除。需要纠正时，请对该用户新增一笔反向人工账变，系统会保留完整审计链。</span>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading { display: flex; width: 100%; align-items: center; gap: 11px; }.heading-icon { display: grid; flex: 0 0 44px; width: 44px; height: 44px; place-items: center; border-radius: 13px; color: #b04b6d; background: #ffeaf0; }.drawer-heading > div { min-width: 0; flex: 1; }.drawer-heading > div > span { color: #c45d82; font-size: 9px; font-weight: 800; letter-spacing: .14em; }.drawer-heading h2 { margin: 2px 0; color: #42343a; font-size: 20px; }.drawer-heading p { margin: 0; color: #96828a; font-size: 10px; }
.event-amounts { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; padding: 15px; border: 1px solid #e8e1e4; border-radius: 15px; background: #faf8f9; }.event-amounts div { display: flex; flex-direction: column; align-items: center; gap: 4px; }.event-amounts span { color: #97848b; font-size: 10px; }.event-amounts strong { color: #4a3b41; font-size: 24px; }.event-amounts.credit strong { color: #32865a; }.event-amounts.debit strong { color: #c94e6d; }.event-amounts.mixed strong { color: #a16f31; }
.detail-section { padding: 19px 0; border-bottom: 1px solid #eee7ea; }.section-heading { display: flex; align-items: flex-start; gap: 8px; margin-bottom: 11px; color: #b75677; }.section-heading h3, .section-heading p { margin: 0; }.section-heading h3 { color: #483a40; font-size: 14px; }.section-heading p { margin-top: 3px; color: #96838a; font-size: 10px; }.user-line { display: flex; align-items: center; gap: 10px; padding: 12px; border-radius: 13px; background: #faf8f9; }.user-line > div:nth-child(2) { display: flex; min-width: 0; flex: 1; flex-direction: column; gap: 3px; }.user-line strong { overflow: hidden; color: #483a40; text-overflow: ellipsis; white-space: nowrap; }.user-line span { color: #948087; font-size: 10px; }.current-balances { display: flex; flex-direction: column; align-items: flex-end; gap: 3px; }.current-balances b { color: #5a454d; }.user-button { width: 100%; margin-top: 9px; }
.source-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 0; }.source-grid div { padding: 10px; border-radius: 11px; background: #faf8f9; }.source-grid .wide { grid-column: span 2; }.source-grid dt { color: #9b878e; font-size: 9px; }.source-grid dd { margin: 4px 0 0; overflow-wrap: anywhere; color: #4f4046; font-size: 12px; }.immutable-note { display: flex; align-items: flex-start; gap: 8px; padding: 12px; margin-top: 18px; border-radius: 12px; color: #836a48; background: #fff6e8; font-size: 10px; line-height: 1.6; }.immutable-note :deep(.el-icon) { flex: 0 0 auto; margin-top: 2px; }
@media (max-width: 500px) { .event-amounts, .source-grid { grid-template-columns: 1fr; }.source-grid .wide { grid-column: span 1; }.user-line { flex-wrap: wrap; }.current-balances { width: 100%; flex-direction: row; justify-content: space-between; align-items: center; } }
</style>
