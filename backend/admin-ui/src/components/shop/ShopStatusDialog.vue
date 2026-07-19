<script setup lang="ts">
import { WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { changeShopItemStatus } from '@/services/shop';
import type { AdminShopItem, ShopStatus } from '@/types/shop';
import {
  shopStatusActionLabel,
  shopStatusLabel,
  shopStatusTransitions,
} from '@/utils/shop';

const props = defineProps<{
  modelValue: boolean;
  item: AdminShopItem | null;
  initialStatus?: ShopStatus | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [item: AdminShopItem];
  reload: [];
}>();

const saving = ref(false);
const targetStatus = ref<ShopStatus>('inactive');
const note = ref('');

const transitions = computed(() => props.item ? shopStatusTransitions(props.item.status) : []);
const impact = computed(() => {
  if (!props.item) return '';
  if (props.item.status === 'inactive' && targetStatus.value === 'active') {
    return '商品会立即出现在用户商店中。系统将再次检查预览图和运行时预设。';
  }
  if (props.item.status === 'active') {
    return `新用户将无法兑换；现有 ${props.item.holderCount} 位持有人仍可继续使用。`;
  }
  if (targetStatus.value === 'archived') {
    return `商品会离开日常编辑列表，但 ${props.item.holderCount} 份用户权益和装备状态都会保留。`;
  }
  return '商品会恢复为可编辑草稿，不会自动重新上架。';
});

watch(
  () => props.modelValue,
  (open) => {
    if (!open || !props.item) return;
    const allowed = shopStatusTransitions(props.item.status);
    targetStatus.value = props.initialStatus && allowed.includes(props.initialStatus)
      ? props.initialStatus
      : allowed[0] || 'inactive';
    note.value = '';
  },
);

async function save(): Promise<void> {
  if (!props.item) return;
  if (!note.value.trim()) {
    ElMessage.warning('请填写执行这个操作的原因');
    return;
  }
  saving.value = true;
  try {
    const result = await changeShopItemStatus(props.item.id, {
      status: targetStatus.value,
      expectedRevision: props.item.revision,
      note: note.value.trim(),
    });
    ElMessage.success(`${shopStatusActionLabel(props.item.status, targetStatus.value)}已完成`);
    emit('saved', result.item);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : '商品状态修改失败');
    if (error instanceof ApiError && error.code === 'shop_item_revision_conflict') {
      emit('reload');
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    width="min(520px, 94vw)"
    destroy-on-close
    :title="item ? `调整“${item.name}”状态` : '调整商品状态'"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div v-if="item" class="status-body">
      <div class="current-state"><span>当前状态</span><strong>{{ shopStatusLabel(item.status) }}</strong><small>配置版本 {{ item.revision }}</small></div>
      <ElFormItem label="执行操作" required>
        <ElSelect v-model="targetStatus" placeholder="选择状态操作">
          <ElOption
            v-for="status in transitions"
            :key="status"
            :label="shopStatusActionLabel(item.status, status)"
            :value="status"
          />
        </ElSelect>
      </ElFormItem>
      <div class="impact-note">
        <ElIcon><WarningFilled /></ElIcon>
        <p>{{ impact }}</p>
      </div>
      <ElFormItem label="操作原因" required>
        <ElInput v-model="note" type="textarea" :rows="3" maxlength="300" show-word-limit placeholder="填写判断依据或后续安排，内容会进入商品变更记录" />
      </ElFormItem>
    </div>
    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="save">确认执行</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.status-body { display: grid; gap: 14px; }
.current-state { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 10px; padding: 12px 13px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.current-state span, .current-state small { color: var(--ink-500); font-size: 11px; }
.current-state strong { color: var(--ink-900); font-size: 14px; }
.status-body :deep(.el-select) { width: 100%; }
.impact-note { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 9px; align-items: start; padding: 11px 12px; border: 1px solid #f0d8af; border-radius: 8px; color: #8b5d18; background: #fff9ee; }
.impact-note .el-icon { margin-top: 2px; }
.impact-note p { margin: 0; font-size: 12px; line-height: 1.55; }
</style>
