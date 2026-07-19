<script setup lang="ts">
import { Delete, Search, StarFilled, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  removeGrowthRankingControl,
  saveGrowthRankingControl,
  searchGrowthCatalog,
} from '@/services/growth-operations';
import type {
  CatalogSearchItem,
  GrowthOperationOptions,
  RankingControl,
} from '@/types/growth-operations';
import {
  growthContentTypeLabel,
  rankingScopeLabel,
} from '@/utils/growth-operations';

const props = defineProps<{
  modelValue: boolean;
  current: RankingControl | null;
  initialContent: CatalogSearchItem | null;
  controls: RankingControl[];
  defaultScope: string;
  options: GrowthOperationOptions;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  changed: [];
  reload: [];
}>();

const saving = ref(false);
const searching = ref(false);
const catalog = ref<CatalogSearchItem[]>([]);
const form = reactive({
  rankingKey: '',
  contentKey: '',
  mode: 'normal' as 'normal' | 'pinned' | 'excluded',
  manualWeight: 0,
  note: '',
});

const matchedControl = computed(() => props.controls.find(
  (item) => item.rankingKey === form.rankingKey && item.contentKey === form.contentKey,
) || null);
const editing = computed(() => Boolean(matchedControl.value));

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    const current = props.current;
    const selected = current ? {
      stableKey: current.contentKey,
      contentType: current.contentType,
      title: current.title,
      author: '',
      coverUrl: current.coverUrl,
      status: 'active',
    } : props.initialContent;
    Object.assign(form, {
      rankingKey: current?.rankingKey || props.defaultScope,
      contentKey: selected?.stableKey || '',
      mode: controlMode(current),
      manualWeight: current?.manualWeight || 0,
      note: '',
    });
    catalog.value = selected ? [selected] : [];
    if (!selected) void searchCatalog('');
  },
);

watch(
  () => [form.rankingKey, form.contentKey],
  () => {
    if (!props.modelValue || props.current) return;
    const current = matchedControl.value;
    form.mode = controlMode(current);
    form.manualWeight = current?.manualWeight || 0;
  },
);

async function searchCatalog(keyword: string): Promise<void> {
  searching.value = true;
  try {
    const response = await searchGrowthCatalog({
      q: keyword.trim(),
      status: 'active',
      page: 1,
      pageSize: 20,
    });
    const selected = catalog.value.find((item) => item.stableKey === form.contentKey);
    catalog.value = [
      ...(selected ? [selected] : []),
      ...response.items.filter((item) => item.stableKey !== selected?.stableKey),
    ];
  } catch (error) {
    ElMessage.error(errorMessage(error, '内容目录搜索失败'));
  } finally {
    searching.value = false;
  }
}

async function save(): Promise<void> {
  if (!form.contentKey) {
    ElMessage.warning('请先搜索并选择内容');
    return;
  }
  if (form.note.trim().length < 4) {
    ElMessage.warning('请填写具体的调整原因');
    return;
  }
  saving.value = true;
  try {
    await saveGrowthRankingControl(form.rankingKey, form.contentKey, {
      pinned: form.mode === 'pinned',
      excluded: form.mode === 'excluded',
      manualWeight: form.manualWeight,
      expectedRevision: matchedControl.value?.revision || 0,
      note: form.note.trim(),
    });
    ElMessage.success(editing.value ? '排行规则已更新并写入审计记录' : '排行规则已创建');
    emit('update:modelValue', false);
    emit('changed');
  } catch (error) {
    ElMessage.error(errorMessage(error, '排行规则保存失败'));
    if (error instanceof ApiError && error.code === 'growth_ranking_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

async function remove(): Promise<void> {
  const current = matchedControl.value;
  if (!current) return;
  if (form.note.trim().length < 4) {
    ElMessage.warning('移除规则前请填写原因');
    return;
  }
  try {
    await ElMessageBox.confirm(
      '移除后该内容将立即恢复算法自然排序，历史操作记录仍会保留。',
      '移除排行规则',
      { type: 'warning', confirmButtonText: '确认移除', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  saving.value = true;
  try {
    await removeGrowthRankingControl(current.rankingKey, current.contentKey, {
      expectedRevision: current.revision,
      note: form.note.trim(),
    });
    ElMessage.success('排行规则已移除');
    emit('update:modelValue', false);
    emit('changed');
  } catch (error) {
    ElMessage.error(errorMessage(error, '排行规则移除失败'));
    if (error instanceof ApiError && error.code === 'growth_ranking_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function controlMode(control: RankingControl | null | undefined): 'normal' | 'pinned' | 'excluded' {
  if (control?.pinned) return 'pinned';
  if (control?.excluded) return 'excluded';
  return 'normal';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    width="min(640px, 94vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="dialog-heading">
        <span>RANKING CONTROL</span>
        <h2>{{ editing ? '调整排行规则' : '添加排行规则' }}</h2>
        <p>人工规则只改变所选榜单，不修改真实行为数据。</p>
      </div>
    </template>

    <div class="ranking-form">
      <ElFormItem label="作用范围" required>
        <ElSelect v-model="form.rankingKey" :disabled="Boolean(current)" filterable>
          <ElOption
            v-for="scope in options.rankingScopes"
            :key="scope"
            :label="rankingScopeLabel(scope)"
            :value="scope"
          />
        </ElSelect>
      </ElFormItem>

      <ElFormItem label="目标内容" required>
        <ElSelect
          v-model="form.contentKey"
          filterable
          remote
          :remote-method="searchCatalog"
          :loading="searching"
          :disabled="Boolean(current)"
          placeholder="输入标题、作者或内容标识搜索"
        >
          <ElOption
            v-for="item in catalog"
            :key="item.stableKey"
            :label="item.title"
            :value="item.stableKey"
          >
            <div class="catalog-option">
              <img v-if="item.coverUrl" :src="item.coverUrl" alt="" />
              <span v-else><Search /></span>
              <div><strong>{{ item.title }}</strong><small>{{ growthContentTypeLabel(item.contentType) }} · {{ item.author || item.stableKey }}</small></div>
            </div>
          </ElOption>
        </ElSelect>
      </ElFormItem>

      <ElFormItem label="排序方式" required>
        <ElSegmented
          v-model="form.mode"
          :options="[
            { label: '自然排序', value: 'normal' },
            { label: '置顶', value: 'pinned' },
            { label: '排除', value: 'excluded' },
          ]"
        />
      </ElFormItem>

      <div v-if="form.mode === 'pinned'" class="mode-notice pinned">
        <ElIcon><StarFilled /></ElIcon><span>内容会排在该范围内所有自然结果之前。</span>
      </div>
      <div v-else-if="form.mode === 'excluded'" class="mode-notice excluded">
        <ElIcon><WarningFilled /></ElIcon><span>内容会从该范围的榜单中隐藏，但不会下架。</span>
      </div>

      <ElFormItem label="人工权重">
        <ElInputNumber v-model="form.manualWeight" :min="-100000" :max="100000" :step="10" controls-position="right" />
        <span class="field-help">在算法得分基础上加减；置顶与排除优先级更高。</span>
      </ElFormItem>

      <ElFormItem label="调整原因" required>
        <ElInput v-model="form.note" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明运营目标、有效期或数据依据" />
      </ElFormItem>
    </div>

    <template #footer>
      <div class="dialog-footer split">
        <ElButton v-if="editing" type="danger" plain :icon="Delete" :disabled="saving" @click="remove">移除规则</ElButton>
        <span v-else />
        <div>
          <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
          <ElButton type="primary" :loading="saving" @click="save">保存规则</ElButton>
        </div>
      </div>
    </template>
  </ElDialog>
</template>

<style scoped>
.dialog-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.dialog-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.ranking-form { display: grid; gap: 2px; }
.ranking-form :deep(.el-form-item) { display: grid; grid-template-columns: 92px minmax(0, 1fr); align-items: start; margin-bottom: 16px; }
.ranking-form :deep(.el-form-item__label) { justify-content: flex-start; line-height: 32px; }
.ranking-form :deep(.el-form-item__content), .ranking-form :deep(.el-select) { width: 100%; min-width: 0; }
.catalog-option { min-height: 44px; display: flex; align-items: center; gap: 9px; }
.catalog-option > img, .catalog-option > span { width: 32px; height: 40px; flex: 0 0 32px; display: grid; place-items: center; border-radius: 5px; object-fit: cover; color: var(--ink-400); background: var(--surface-muted); }
.catalog-option div { min-width: 0; display: grid; gap: 2px; }
.catalog-option strong, .catalog-option small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.catalog-option strong { color: var(--ink-900); font-size: 12px; }
.catalog-option small { color: var(--ink-500); font-size: 10px; }
.mode-notice { display: flex; align-items: center; gap: 8px; margin: -7px 0 15px 92px; padding: 9px 11px; border-radius: 7px; font-size: 11px; }
.mode-notice.pinned { color: #8a5c16; background: #fff5df; }
.mode-notice.excluded { color: #9f4056; background: #fff0f3; }
.field-help { display: block; width: 100%; margin-top: 5px; color: var(--ink-500); font-size: 10px; line-height: 1.45; }
.dialog-footer.split { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
@media (max-width: 560px) {
  .ranking-form :deep(.el-form-item) { grid-template-columns: 1fr; }
  .ranking-form :deep(.el-form-item__label) { line-height: 24px; }
  .mode-notice { margin-left: 0; }
}
</style>
