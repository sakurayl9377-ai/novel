<script setup lang="ts">
import { Lock, Medal, Tickets } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { saveGrowthRulesDraft } from '@/services/growth-rules';
import type {
  GrowthLevelRule,
  GrowthRulesWorkbenchResponse,
} from '@/types/growth-rules';
import {
  cloneGrowthRules,
  growthRuleValidationError,
} from '@/utils/growth-rules';

const props = defineProps<{
  modelValue: boolean;
  sourceRules: GrowthLevelRule[];
  expectedEditVersion: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [value: GrowthRulesWorkbenchResponse];
}>();

const rules = ref<GrowthLevelRule[]>([]);
const note = ref('');
const saving = ref(false);
const openLevels = ref<string[]>(['1']);
const validation = computed(() => growthRuleValidationError(rules.value));

watch(
  [() => props.modelValue, () => props.sourceRules],
  ([open]) => {
    if (!open) return;
    rules.value = cloneGrowthRules(props.sourceRules);
    note.value = '';
    openLevels.value = ['1'];
  },
  { deep: true, immediate: true },
);

async function save(): Promise<void> {
  if (validation.value) {
    ElMessage.warning(validation.value);
    return;
  }
  if (!note.value.trim()) {
    ElMessage.warning('请填写本次草稿调整依据');
    return;
  }
  saving.value = true;
  try {
    const result = await saveGrowthRulesDraft({
      rules: rules.value,
      expectedEditVersion: props.expectedEditVersion,
      note: note.value.trim(),
    });
    emit('saved', result);
    emit('update:modelValue', false);
    ElMessage.success('成长规则草稿已保存');
  } catch (error) {
    ElMessage.error(errorMessage(error, '保存成长规则草稿失败'));
  } finally {
    saving.value = false;
  }
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
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="editor-heading">
        <span>RULE DRAFT</span>
        <h2>{{ expectedEditVersion ? '继续编辑规则草稿' : '创建规则草稿' }}</h2>
        <p>固定能力权限不会随运营文案变化</p>
      </div>
    </template>

    <div class="editor-body">
      <div v-if="validation" class="validation-banner">
        <ElIcon><Tickets /></ElIcon>
        <span>{{ validation }}</span>
      </div>

      <ElCollapse v-model="openLevels" class="level-editor">
        <ElCollapseItem
          v-for="(rule, index) in rules"
          :key="rule.level"
          :name="String(rule.level)"
        >
          <template #title>
            <div class="level-heading">
              <span><ElIcon><Medal /></ElIcon>Lv.{{ rule.level }}</span>
              <strong>{{ rule.name || '未命名等级' }}</strong>
              <small>{{ rule.points.toLocaleString() }} 成长值 · 每日 {{ rule.dailyPointCap }}</small>
            </div>
          </template>

          <div class="level-fields">
            <ElFormItem label="等级名称" required>
              <ElInput v-model="rule.name" maxlength="24" show-word-limit />
            </ElFormItem>
            <ElFormItem label="成长值门槛" required>
              <ElInputNumber
                v-model="rule.points"
                :min="index === 0 ? 0 : rules[index - 1].points + 1"
                :max="index === rules.length - 1 ? 10000000 : Math.max(rules[index + 1].points - 1, rule.points)"
                :step="100"
                :disabled="index === 0"
                controls-position="right"
              />
            </ElFormItem>
            <ElFormItem label="每日成长上限" required>
              <ElInputNumber
                v-model="rule.dailyPointCap"
                :min="index === 0 ? 1 : rules[index - 1].dailyPointCap"
                :max="10000"
                :step="5"
                controls-position="right"
              />
            </ElFormItem>
            <ElFormItem label="目标天数" required>
              <ElInputNumber
                v-model="rule.targetDays"
                :min="index === 0 ? 0 : rules[index - 1].targetDays"
                :max="36500"
                :disabled="index === 0"
                controls-position="right"
              />
            </ElFormItem>
            <ElFormItem class="wide" label="等级效果" required>
              <ElInput
                v-model="rule.effect"
                type="textarea"
                :rows="2"
                maxlength="120"
                show-word-limit
                resize="none"
              />
            </ElFormItem>
            <div class="permission-field wide">
              <div class="permission-title"><ElIcon><Lock /></ElIcon><strong>系统能力权限</strong><span>只读</span></div>
              <div class="permission-tags">
                <ElTag v-for="permission in rule.permissions" :key="permission" effect="plain">{{ permission }}</ElTag>
                <span v-if="!rule.permissions.length">本等级没有新增系统能力</span>
              </div>
            </div>
          </div>
        </ElCollapseItem>
      </ElCollapse>

      <ElFormItem label="草稿调整依据" required>
        <ElInput
          v-model="note"
          type="textarea"
          :rows="3"
          maxlength="300"
          show-word-limit
          resize="none"
          placeholder="记录数据依据、目标或评审结论"
        />
      </ElFormItem>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
        <ElButton type="primary" :loading="saving" :disabled="Boolean(validation)" @click="save">
          保存草稿
        </ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 850; letter-spacing: .1em; }
.editor-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.editor-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.editor-body { display: grid; gap: 16px; }
.validation-banner { display: flex; align-items: center; gap: 9px; padding: 10px 12px; border: 1px solid #efd3a2; border-radius: 7px; color: #8c5a16; background: #fff8ec; font-size: 12px; }
.level-editor { border-top: 0; }
.level-heading { width: 100%; min-width: 0; display: grid; grid-template-columns: 78px minmax(0, 1fr) auto; align-items: center; gap: 10px; padding-right: 12px; }
.level-heading > span { display: inline-flex; align-items: center; gap: 5px; color: var(--sakura-600); font-size: 12px; font-weight: 800; }
.level-heading strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.level-heading small { color: var(--ink-500); font-size: 10px; }
.level-fields { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 16px; padding: 8px 2px 14px; }
.level-fields .wide { grid-column: 1 / -1; }
.level-fields :deep(.el-input-number) { width: 100%; }
.level-fields :deep(.el-form-item__label), .editor-body :deep(.el-form-item__label) { color: var(--ink-700); font-weight: 650; }
.permission-field { padding: 12px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }
.permission-title { display: flex; align-items: center; gap: 7px; margin-bottom: 9px; color: var(--ink-700); font-size: 12px; }
.permission-title span { margin-left: auto; color: var(--ink-500); font-size: 10px; }
.permission-tags { display: flex; flex-wrap: wrap; gap: 6px; color: var(--ink-500); font-size: 11px; }
.drawer-footer { display: flex; justify-content: flex-end; gap: 9px; }
@media (max-width: 640px) {
  .level-heading { grid-template-columns: 64px minmax(0, 1fr); }
  .level-heading small { grid-column: 2; }
  .level-fields { grid-template-columns: 1fr; }
  .level-fields .wide { grid-column: auto; }
}
</style>
