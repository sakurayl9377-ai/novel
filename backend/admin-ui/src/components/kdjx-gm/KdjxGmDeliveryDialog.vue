<script setup lang="ts">
import { Message } from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { createKdjxGmDelivery } from '@/services/kdjx-gm';
import type {
  KdjxGmCatalogItem,
  KdjxGmCreateDeliveryResponse,
  KdjxGmPlayer,
} from '@/types/kdjx-gm';
import {
  kdjxGmCatalogOptions,
  kdjxGmItemLabel,
  kdjxGmItemMeta,
} from '@/utils/kdjx-gm';

const props = defineProps<{
  modelValue: boolean;
  player: KdjxGmPlayer | null;
  catalog: KdjxGmCatalogItem[];
  catalogLoading: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  sent: [response: KdjxGmCreateDeliveryResponse];
}>();

const itemId = ref<string>();
const quantity = ref(1);
const reason = ref('');
const sending = ref(false);
const requestId = ref('');

const selectableItems = computed(() => props.catalog.filter(
  (item) => item.deliveryTypes.includes('mail'),
));
const catalogOptions = computed(() => kdjxGmCatalogOptions(selectableItems.value));
const selectedItem = computed(() => props.catalog.find(
  (item) => item.id === itemId.value,
) || null);
const maxQuantity = computed(() => Math.max(
  1,
  Math.min(2_147_483_647, Number(selectedItem.value?.maxQuantity || 9999)),
));
const playerReady = computed(() => props.player?.canDeliverItems === true);

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    itemId.value = undefined;
    quantity.value = 1;
    reason.value = '';
    sending.value = false;
    requestId.value = createRequestId();
  },
  { immediate: true },
);

watch(maxQuantity, (maximum) => {
  if (quantity.value > maximum) quantity.value = maximum;
});

async function confirmDelivery(): Promise<void> {
  const player = props.player;
  const item = selectedItem.value;
  const normalizedReason = reason.value
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!player || !playerReady.value) {
    ElMessage.warning('玩家的游戏身份关联不完整，请先让玩家重新登录一次游戏');
    return;
  }
  if (!item || !item.deliveryTypes.includes('mail')) {
    ElMessage.warning('请从物品目录中选择要发放的物品');
    return;
  }
  if (!Number.isInteger(quantity.value) || quantity.value < 1 || quantity.value > maxQuantity.value) {
    ElMessage.warning(`数量必须是 1 至 ${maxQuantity.value} 的整数`);
    return;
  }
  if (normalizedReason.length < 4 || normalizedReason.length > 160) {
    ElMessage.warning('请填写 4 至 160 个字的具体发放原因');
    return;
  }

  try {
    await ElMessageBox.confirm(
      `玩家：${player.nickname || player.email}\n角色：${player.lastRoleId}（${player.lastServerKey}）\n方式：邮件附件\n物品：${kdjxGmItemLabel(item)} × ${quantity.value}\n原因：${normalizedReason}`,
      '最后确认发放',
      {
        type: 'warning',
        confirmButtonText: '确认发放',
        cancelButtonText: '返回检查',
        customClass: 'kdjx-delivery-confirm',
      },
    );
  } catch (error) {
    if (!isDialogCancel(error)) {
      ElMessage.error(errorMessage(error, '发放确认失败'));
    }
    return;
  }

  sending.value = true;
  try {
    const response = await createKdjxGmDelivery(player.userId, {
      requestId: requestId.value,
      deliveryType: 'mail',
      itemId: item.id,
      quantity: quantity.value,
      expectedRoleId: player.lastRoleId,
      expectedServerKey: player.lastServerKey,
      expectedLinkUpdatedAt: player.linkedUpdatedAt,
      reason: normalizedReason,
    });
    if (!response.ok) {
      if (response.delivery.status === 'failed') {
        ElMessage.error('游戏服已拒绝本次邮件发放；修正问题后请关闭窗口并重新发起');
      } else {
        ElMessage.warning('游戏服尚未确认发放结果，请勿新建请求，先核对发放历史');
      }
      emit('sent', response);
      return;
    }
    ElMessage.success(
      response.idempotent
        ? '已确认同一请求的上次发放结果，没有重复发送'
        : `${item.name} × ${quantity.value} 已发送`,
    );
    emit('sent', response);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '物品发放失败，请核对历史记录后再重试'));
  } finally {
    sending.value = false;
  }
}

function createRequestId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0'));
  return [
    hex.slice(0, 4).join(''),
    hex.slice(4, 6).join(''),
    hex.slice(6, 8).join(''),
    hex.slice(8, 10).join(''),
    hex.slice(10).join(''),
  ].join('-');
}

function isDialogCancel(error: unknown): boolean {
  return error === 'cancel' || error === 'close';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="发放 KDJX 物品"
    width="min(620px, 94vw)"
    :close-on-click-modal="false"
    :close-on-press-escape="!sending"
    :show-close="!sending"
    append-to-body
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div v-if="player" class="delivery-dialog-body">
      <div class="delivery-target">
        <div>
          <span>玩家</span>
          <strong>{{ player.nickname || player.email }}</strong>
          <small>{{ player.email }} · Sakura ID {{ player.userId }}</small>
        </div>
        <div>
          <span>发放角色</span>
          <strong>{{ player.lastRoleId || '尚未同步角色' }}</strong>
          <small>{{ player.lastServerKey || '尚未同步服务器' }}</small>
        </div>
      </div>

      <ElAlert
        v-if="!playerReady"
        type="warning"
        :closable="false"
        show-icon
        title="玩家的游戏身份关联不完整，请先让玩家重新登录一次游戏"
      />

      <ElForm label-position="top" class="delivery-form">
        <div class="delivery-method">
          <ElIcon><Message /></ElIcon>
          <div>
            <span>发放方式</span>
            <strong>游戏邮件附件</strong>
            <small>物品发送到当前角色邮箱，玩家需在游戏内领取</small>
          </div>
        </div>

        <ElFormItem label="物品" required>
          <ElSelectV2
            v-model="itemId"
            :options="catalogOptions"
            :item-height="64"
            :loading="catalogLoading"
            :disabled="sending || !playerReady"
            filterable
            clearable
            placeholder="搜索物品名称、说明、类型、品质或 ID"
            no-data-text="当前方式没有可发放物品"
            class="item-select"
          >
            <template #default="{ item: option }">
              <div class="item-option">
                <strong>{{ option.item.name }}</strong>
                <span>{{ kdjxGmItemMeta(option.item) }}</span>
                <small v-if="option.item.description">{{ option.item.description }}</small>
              </div>
            </template>
          </ElSelectV2>
        </ElFormItem>

        <div class="delivery-fields">
          <ElFormItem label="数量" required>
            <ElInputNumber
              v-model="quantity"
              :min="1"
              :max="maxQuantity"
              :step="1"
              step-strictly
              controls-position="right"
              :disabled="sending || !selectedItem"
            />
            <span class="field-hint">
              {{ selectedItem ? `本物品单次最多 ${maxQuantity}` : '选择物品后显示单次上限' }}
            </span>
          </ElFormItem>
          <div v-if="selectedItem" class="selected-item">
            <span>本次内容</span>
            <strong>{{ selectedItem.name }} × {{ quantity }}</strong>
            <small>{{ kdjxGmItemMeta(selectedItem) }}</small>
            <small v-if="selectedItem.description">{{ selectedItem.description }}</small>
          </div>
        </div>

        <ElFormItem label="发放原因" required>
          <ElInput
            v-model="reason"
            type="textarea"
            :rows="3"
            maxlength="160"
            show-word-limit
            resize="none"
            :disabled="sending"
            placeholder="例如：玩家工单核实掉落异常，补发活动奖励"
          />
        </ElFormItem>
      </ElForm>

    </div>
    <ElEmpty v-else :image-size="56" description="没有可发放的玩家" />

    <template #footer>
      <ElButton :disabled="sending" @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton
        type="primary"
        :icon="Message"
        :loading="sending"
        :disabled="!player || !playerReady || catalogLoading"
        @click="confirmDelivery"
      >
        下一步确认
      </ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.delivery-dialog-body { display: grid; gap: 15px; }
.delivery-target { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.delivery-target > div { min-width: 0; display: grid; gap: 4px; padding: 13px 15px; }
.delivery-target > div + div { border-left: 1px solid var(--line); }
.delivery-target span, .selected-item span { color: var(--ink-500); font-size: 10px; }
.delivery-target strong, .selected-item strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.delivery-target small, .selected-item small { overflow: hidden; color: var(--ink-400); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.delivery-form :deep(.el-form-item) { margin-bottom: 16px; }
.delivery-form :deep(.el-form-item__label) { padding-bottom: 6px; color: var(--ink-700); font-size: 11px; font-weight: 700; }
.item-select { width: 100%; }
.item-option { min-width: 0; width: 100%; display: grid; align-content: center; gap: 2px; line-height: 1.25; }
.item-option strong { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.item-option span { overflow: hidden; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.item-option small { overflow: hidden; color: var(--ink-400); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.delivery-method { display: flex; align-items: center; gap: 10px; padding: 11px 13px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }
.delivery-method > .el-icon { flex: 0 0 auto; color: var(--sakura-600); font-size: 20px; }
.delivery-method > div { min-width: 0; display: grid; gap: 3px; }
.delivery-method span { color: var(--ink-500); font-size: 9px; }
.delivery-method strong { color: var(--ink-900); font-size: 12px; }
.delivery-method small { color: var(--ink-400); font-size: 9px; }
.field-hint { width: 100%; margin-top: 5px; color: var(--ink-400); font-size: 9px; line-height: 1.5; }
.delivery-fields { display: grid; grid-template-columns: minmax(160px, 0.65fr) minmax(220px, 1fr); gap: 12px; }
.delivery-fields :deep(.el-input-number) { width: 100%; }
.selected-item { min-width: 0; display: grid; align-content: center; gap: 4px; margin-bottom: 16px; padding: 10px 12px; border-left: 3px solid var(--sakura-500); background: #fff8fa; }
@media (max-width: 560px) {
  .delivery-target, .delivery-fields { grid-template-columns: 1fr; }
  .delivery-target > div + div { border-top: 1px solid var(--line); border-left: 0; }
}
</style>
