<script setup lang="ts">
import {
  Clock,
  Delete,
  EditPen,
  Histogram,
  Lock,
  Medal,
  Promotion,
  Refresh,
  TrendCharts,
  User,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import GrowthRuleEditorDrawer from '@/components/growth-rules/GrowthRuleEditorDrawer.vue';
import GrowthRulePublishDialog from '@/components/growth-rules/GrowthRulePublishDialog.vue';
import {
  discardGrowthRulesDraft,
  getGrowthRulesWorkbench,
  restoreGrowthRulesRevision,
} from '@/services/growth-rules';
import type {
  GrowthLevelRule,
  GrowthRuleSetRecord,
  GrowthRulesWorkbenchResponse,
} from '@/types/growth-rules';
import { formatDateTime } from '@/utils/format';
import {
  growthChangedFieldLabel,
  growthLevelForPoints,
  growthRuleStateLabel,
  growthRuleStateTone,
} from '@/utils/growth-rules';

const loading = ref(false);
const data = ref<GrowthRulesWorkbenchResponse | null>(null);
const editorOpen = ref(false);
const publishOpen = ref(false);
const discardOpen = ref(false);
const restoreOpen = ref(false);
const selectedRevision = ref<GrowthRuleSetRecord | null>(null);
const discardNote = ref('');
const restoreNote = ref('');
const replaceDraft = ref(false);
const decisionSaving = ref(false);
const ruleMode = ref<'active' | 'draft'>('active');
const openLevels = ref<string[]>(['1']);
const simulatorPoints = ref(500);

const modeOptions = computed(() => [
  { label: `当前版本 ${data.value?.active.revision || '-'}`, value: 'active' },
  ...(data.value?.draft
    ? [{ label: `草稿版本 ${data.value.draft.revision}`, value: 'draft' as const }]
    : []),
]);
const displayedRules = computed<GrowthLevelRule[]>(() => {
  if (!data.value) return [];
  return ruleMode.value === 'draft' && data.value.draft
    ? data.value.draft.rules
    : data.value.active.rules;
});
const activeSimulation = computed(() =>
  data.value ? growthLevelForPoints(data.value.active.rules, simulatorPoints.value) : null,
);
const draftSimulation = computed(() =>
  data.value?.draft
    ? growthLevelForPoints(data.value.draft.rules, simulatorPoints.value)
    : null,
);
const riskyDraft = computed(
  () =>
    Number(data.value?.impact?.levelDownUsers || 0) > 0 ||
    Number(data.value?.impact?.dailyCapReducedUsers || 0) > 0,
);

onMounted(load);

async function load(): Promise<void> {
  loading.value = true;
  try {
    data.value = await getGrowthRulesWorkbench();
    if (!data.value.draft) ruleMode.value = 'active';
  } catch (error) {
    ElMessage.error(errorMessage(error, '加载成长规则失败'));
  } finally {
    loading.value = false;
  }
}

function openEditor(): void {
  editorOpen.value = true;
}

function afterMutation(value: GrowthRulesWorkbenchResponse): void {
  data.value = value;
  ruleMode.value = value.draft ? 'draft' : 'active';
}

function openDiscard(): void {
  discardNote.value = '';
  discardOpen.value = true;
}

async function discardDraft(): Promise<void> {
  if (!data.value?.draft || !discardNote.value.trim()) return;
  decisionSaving.value = true;
  try {
    afterMutation(
      await discardGrowthRulesDraft({
        expectedEditVersion: data.value.draft.editVersion,
        note: discardNote.value.trim(),
      }),
    );
    discardOpen.value = false;
    ElMessage.success('规则草稿已放弃，记录已保留');
  } catch (error) {
    ElMessage.error(errorMessage(error, '放弃规则草稿失败'));
  } finally {
    decisionSaving.value = false;
  }
}

function openRestore(item: GrowthRuleSetRecord): void {
  selectedRevision.value = item;
  restoreNote.value = '';
  replaceDraft.value = false;
  restoreOpen.value = true;
}

async function restoreRevision(): Promise<void> {
  if (!data.value || !selectedRevision.value || !restoreNote.value.trim()) return;
  if (data.value.draft && !replaceDraft.value) return;
  decisionSaving.value = true;
  try {
    afterMutation(
      await restoreGrowthRulesRevision(selectedRevision.value.revision, {
        note: restoreNote.value.trim(),
        replaceDraft: Boolean(data.value.draft),
        ...(data.value.draft
          ? { expectedDraftEditVersion: data.value.draft.editVersion }
          : {}),
      }),
    );
    restoreOpen.value = false;
    ElMessage.success(`版本 ${selectedRevision.value.revision} 已恢复为新草稿`);
  } catch (error) {
    ElMessage.error(errorMessage(error, '恢复历史规则失败'));
  } finally {
    decisionSaving.value = false;
  }
}

function usersForLevel(level: number): number {
  if (!data.value) return 0;
  const distribution =
    ruleMode.value === 'draft' && data.value.impact
      ? data.value.impact.afterDistribution
      : data.value.stats.distribution;
  return distribution.find((item) => item.level === level)?.users || 0;
}

function changedFields(level: number): string[] {
  return (
    data.value?.impact?.changedLevels.find((item) => item.level === level)?.fields || []
  ).map(growthChangedFieldLabel);
}

function historyItems(): GrowthRuleSetRecord[] {
  return (data.value?.history || []).filter(
    (item) => item.state !== 'published' || item.revision !== data.value?.active.revision,
  );
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div v-loading="loading" class="page-stack growth-rules-page">
    <template v-if="data">
      <section class="rules-hero">
        <div class="hero-copy">
          <span>GROWTH POLICY</span>
          <h2>成长值规则先评估影响，再进入生产</h2>
          <p>当前发布版本 {{ data.active.revision }} · {{ formatDateTime(data.active.publishedAt) }}</p>
        </div>
        <div class="hero-actions">
          <div class="version-state" :class="{ draft: data.draft }">
            <ElIcon><WarningFilled v-if="data.draft" /><Lock v-else /></ElIcon>
            <div><strong>{{ data.draft ? `草稿版本 ${data.draft.revision}` : '没有待发布草稿' }}</strong><small>{{ data.draft ? `基于版本 ${data.draft.baseRevision}` : '生产规则已锁定' }}</small></div>
          </div>
          <ElButton :icon="EditPen" @click="openEditor">{{ data.draft ? '继续编辑' : '创建草稿' }}</ElButton>
          <ElButton v-if="data.draft" type="primary" :icon="Promotion" @click="publishOpen = true">发布规则</ElButton>
        </div>
      </section>

      <section class="metric-grid rules-metrics">
        <MetricCard label="当前版本" :value="data.active.revision" :icon="Medal" hint="已发布规则" tone="success" />
        <MetricCard label="用户总量" :value="data.stats.users.toLocaleString()" :icon="User" hint="纳入影响计算" />
        <MetricCard label="等级变化" :value="(data.impact?.affectedLevelUsers || 0).toLocaleString()" :icon="TrendCharts" :hint="data.draft ? '草稿发布后' : '没有待评估草稿'" />
        <MetricCard label="上限降低" :value="(data.impact?.dailyCapReducedUsers || 0).toLocaleString()" :icon="WarningFilled" :hint="riskyDraft ? '发布前需要确认' : '未发现负面影响'" :tone="riskyDraft ? 'warning' : 'success'" />
        <MetricCard label="平均成长值" :value="Math.round(data.stats.averagePoints).toLocaleString()" :icon="Histogram" :hint="`最高 ${data.stats.maxPoints.toLocaleString()}`" />
      </section>

      <section v-if="data.draft && data.impact" class="impact-band" :class="{ risky: riskyDraft }">
        <div><span>DRAFT IMPACT</span><strong>{{ data.impact.changedLevels.length }} 个等级发生配置变化</strong></div>
        <dl>
          <div><dt>升级</dt><dd>{{ data.impact.levelUpUsers }}</dd></div>
          <div><dt>降级</dt><dd>{{ data.impact.levelDownUsers }}</dd></div>
          <div><dt>每日上限变化</dt><dd>{{ data.impact.dailyCapChangedUsers }}</dd></div>
          <div><dt>每日上限降低</dt><dd>{{ data.impact.dailyCapReducedUsers }}</dd></div>
        </dl>
        <ElButton text type="danger" :icon="Delete" @click="openDiscard">放弃草稿</ElButton>
      </section>

      <section class="rules-section">
        <header class="section-heading">
          <div><span>LEVEL POLICY</span><h3>等级阈值与每日上限</h3><p>{{ displayedRules.length }} 个固定等级</p></div>
          <ElSegmented v-model="ruleMode" :options="modeOptions" />
        </header>

        <ElCollapse v-model="openLevels" class="rules-collapse">
          <ElCollapseItem v-for="rule in displayedRules" :key="rule.level" :name="String(rule.level)">
            <template #title>
              <div class="rule-summary">
                <span>Lv.{{ rule.level }}</span>
                <strong>{{ rule.name }}</strong>
                <div><b>{{ rule.points.toLocaleString() }}</b><small>成长值门槛</small></div>
                <div><b>{{ rule.dailyPointCap }}</b><small>每日上限</small></div>
                <div><b>{{ usersForLevel(rule.level).toLocaleString() }}</b><small>当前用户</small></div>
                <ElTag v-if="ruleMode === 'draft' && changedFields(rule.level).length" type="warning" effect="plain">{{ changedFields(rule.level).join('、') }}</ElTag>
              </div>
            </template>
            <div class="rule-detail">
              <div class="effect-copy"><span>等级效果</span><strong>{{ rule.effect }}</strong><small>目标 {{ rule.targetDays }} 天</small></div>
              <div class="permission-list">
                <span v-for="permission in rule.permissions" :key="permission">{{ permission }}</span>
                <small v-if="!rule.permissions.length">本等级没有新增系统能力</small>
              </div>
            </div>
          </ElCollapseItem>
        </ElCollapse>

        <div class="simulator-strip">
          <div><span>POINT SIMULATOR</span><strong>成长值结果校验</strong></div>
          <ElInputNumber v-model="simulatorPoints" :min="0" :max="10000000" :step="100" controls-position="right" />
          <div class="simulation-result"><span>当前规则</span><strong>Lv.{{ activeSimulation?.level }} {{ activeSimulation?.name }}</strong><small>每日上限 {{ activeSimulation?.dailyPointCap }}</small></div>
          <ElIcon><Refresh /></ElIcon>
          <div class="simulation-result" :class="{ changed: draftSimulation && draftSimulation.level !== activeSimulation?.level }"><span>草稿规则</span><strong v-if="draftSimulation">Lv.{{ draftSimulation.level }} {{ draftSimulation.name }}</strong><strong v-else>没有草稿</strong><small v-if="draftSimulation">每日上限 {{ draftSimulation.dailyPointCap }}</small></div>
        </div>
      </section>

      <section class="capability-section">
        <header class="section-heading">
          <div><span>SYSTEM CAPABILITIES</span><h3>固定能力解锁矩阵</h3><p>实际由服务端和客户端共同执行</p></div>
          <ElTag type="info" effect="plain"><ElIcon><Lock /></ElIcon>只读</ElTag>
        </header>
        <div class="capability-levels">
          <div v-for="level in 7" :key="level">
            <strong>Lv.{{ level }}</strong>
            <span v-for="item in data.capabilities.filter((capability) => capability.unlockLevel === level)" :key="item.key">{{ item.label }}</span>
            <small v-if="!data.capabilities.some((item) => item.unlockLevel === level)">无新增能力</small>
          </div>
        </div>
      </section>

      <section class="history-section">
        <header class="section-heading">
          <div><span>VERSION HISTORY</span><h3>发布与草稿记录</h3><p>历史规则只允许恢复为新草稿</p></div>
          <ElButton :icon="Refresh" @click="load">刷新</ElButton>
        </header>
        <div class="history-list">
          <article v-for="item in historyItems()" :key="item.id">
            <span class="history-icon"><ElIcon><Clock /></ElIcon></span>
            <div class="history-main"><div><strong>版本 {{ item.revision }}</strong><ElTag :type="growthRuleStateTone(item.state)" size="small" effect="plain">{{ growthRuleStateLabel(item.state) }}</ElTag></div><p>{{ item.note || '没有记录说明' }}</p><small>{{ item.admin?.nickname || item.admin?.email || '系统' }} · {{ formatDateTime(item.updatedAt) }}</small></div>
            <ElButton v-if="item.state === 'superseded'" :icon="Refresh" @click="openRestore(item)">恢复为草稿</ElButton>
          </article>
          <ElEmpty v-if="!historyItems().length" :image-size="56" description="暂无历史版本" />
        </div>
      </section>
    </template>

    <GrowthRuleEditorDrawer
      v-if="data"
      v-model="editorOpen"
      :source-rules="data.draft?.rules || data.active.rules"
      :expected-edit-version="data.draft?.editVersion || 0"
      @saved="afterMutation"
    />
    <GrowthRulePublishDialog
      v-if="data"
      v-model="publishOpen"
      :draft="data.draft"
      :impact="data.impact"
      @published="afterMutation"
    />

    <ElDialog v-model="discardOpen" width="min(500px, 94vw)" title="放弃规则草稿" destroy-on-close>
      <div class="decision-body"><p>草稿内容不会生效，版本与操作说明会保留在审计历史中。</p><ElFormItem label="放弃原因" required><ElInput v-model="discardNote" type="textarea" :rows="3" maxlength="300" show-word-limit resize="none" /></ElFormItem></div>
      <template #footer><ElButton @click="discardOpen = false">取消</ElButton><ElButton type="danger" :loading="decisionSaving" :disabled="!discardNote.trim()" @click="discardDraft">确认放弃</ElButton></template>
    </ElDialog>

    <ElDialog v-model="restoreOpen" width="min(540px, 94vw)" :title="`恢复版本 ${selectedRevision?.revision || ''}`" destroy-on-close>
      <div class="decision-body"><p>历史规则会复制成基于当前发布版本的新草稿，不会直接改变生产规则。</p><ElFormItem label="恢复原因" required><ElInput v-model="restoreNote" type="textarea" :rows="3" maxlength="300" show-word-limit resize="none" /></ElFormItem><ElCheckbox v-if="data?.draft" v-model="replaceDraft">放弃并替换当前草稿版本 {{ data.draft.revision }}</ElCheckbox></div>
      <template #footer><ElButton @click="restoreOpen = false">取消</ElButton><ElButton type="primary" :loading="decisionSaving" :disabled="!restoreNote.trim() || Boolean(data?.draft && !replaceDraft)" @click="restoreRevision">创建恢复草稿</ElButton></template>
    </ElDialog>
  </div>
</template>

<style scoped>
.growth-rules-page { gap: 18px; }
.rules-hero { min-height: 128px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid #4d9b78; border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.hero-copy > span, .section-heading span, .impact-band > div > span { color: var(--sakura-600); font-size: 10px; font-weight: 850; letter-spacing: .1em; }
.hero-copy h2 { margin: 5px 0 7px; color: var(--ink-900); font-size: 23px; line-height: 1.25; letter-spacing: 0; }
.hero-copy p { margin: 0; color: var(--ink-500); font-size: 12px; }
.hero-actions { display: flex; align-items: center; gap: 9px; flex: 0 0 auto; }
.version-state { min-width: 220px; display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 9px; padding: 9px 11px; border: 1px solid #c9dfd5; border-radius: 8px; color: #2e6e53; background: #f3faf7; }
.version-state.draft { color: #8c5a16; border-color: #efd3a2; background: #fff8ec; }
.version-state > div { min-width: 0; display: grid; gap: 2px; }
.version-state strong { font-size: 11px; }
.version-state small { font-size: 9px; opacity: .78; }
.rules-metrics { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.impact-band { display: grid; grid-template-columns: minmax(210px, 1fr) minmax(420px, 1.5fr) auto; align-items: center; gap: 20px; padding: 14px 18px; border: 1px solid #bddfce; border-radius: 8px; background: #f3faf7; }
.impact-band.risky { border-color: #efd3a2; background: #fff8ec; }
.impact-band > div { display: grid; gap: 4px; }
.impact-band > div strong { color: var(--ink-900); font-size: 13px; }
.impact-band dl { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); margin: 0; }
.impact-band dl > div { padding: 2px 13px; border-left: 1px solid rgb(100 120 110 / 18%); }
.impact-band dt { color: var(--ink-500); font-size: 10px; }
.impact-band dd { margin: 3px 0 0; color: var(--ink-900); font-size: 17px; font-weight: 800; }
.rules-section, .capability-section, .history-section { min-width: 0; padding: 18px; border: 1px solid var(--line); border-radius: 8px; background: white; box-shadow: 0 8px 20px rgb(42 29 39 / 3%); }
.section-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
.section-heading h3 { margin: 3px 0 0; color: var(--ink-900); font-size: 17px; letter-spacing: 0; }
.section-heading p { margin: 3px 0 0; color: var(--ink-500); font-size: 11px; }
.rules-collapse { border-top: 0; }
.rule-summary { width: 100%; min-width: 0; display: grid; grid-template-columns: 68px minmax(130px, 1fr) repeat(3, minmax(80px, .55fr)) auto; align-items: center; gap: 12px; padding-right: 12px; }
.rule-summary > span { color: var(--sakura-600); font-weight: 850; }
.rule-summary > strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.rule-summary > div { min-width: 0; display: grid; gap: 1px; }
.rule-summary b { color: var(--ink-900); font-size: 12px; }
.rule-summary small { color: var(--ink-500); font-size: 9px; }
.rule-detail { display: grid; grid-template-columns: minmax(180px, .7fr) minmax(0, 1.3fr); gap: 18px; padding: 10px 8px 16px 80px; }
.effect-copy { display: grid; gap: 4px; }
.effect-copy span, .effect-copy small { color: var(--ink-500); font-size: 10px; }
.effect-copy strong { color: var(--ink-900); font-size: 12px; line-height: 1.5; }
.permission-list { display: flex; align-content: flex-start; flex-wrap: wrap; gap: 6px; }
.permission-list span { padding: 4px 7px; border-radius: 5px; color: #456879; background: #eef5f8; font-size: 10px; }
.permission-list small { color: var(--ink-500); font-size: 10px; }
.simulator-strip { display: grid; grid-template-columns: minmax(150px, .8fr) 170px minmax(150px, 1fr) auto minmax(150px, 1fr); align-items: center; gap: 14px; margin: 16px -18px -18px; padding: 14px 18px; border-top: 1px solid var(--line); background: var(--surface-muted); }
.simulator-strip > div:first-child { display: grid; gap: 4px; }
.simulator-strip > div:first-child span { color: var(--sakura-600); font-size: 9px; font-weight: 850; letter-spacing: .09em; }
.simulator-strip > div:first-child strong { color: var(--ink-900); font-size: 12px; }
.simulation-result { min-width: 0; display: grid; gap: 2px; }
.simulation-result span, .simulation-result small { color: var(--ink-500); font-size: 9px; }
.simulation-result strong { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.simulation-result.changed strong { color: #a5555f; }
.capability-levels { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; }
.capability-levels > div { min-width: 0; display: grid; align-content: start; gap: 6px; padding: 12px; border-right: 1px solid var(--line); }
.capability-levels > div:last-child { border-right: 0; }
.capability-levels strong { color: var(--sakura-600); font-size: 12px; }
.capability-levels span { color: var(--ink-700); font-size: 10px; line-height: 1.4; }
.capability-levels small { color: var(--ink-400); font-size: 9px; }
.history-list { display: grid; }
.history-list article { min-width: 0; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px; padding: 12px 2px; border-bottom: 1px solid var(--line); }
.history-icon { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 7px; color: #526d7b; background: #eef4f6; }
.history-main { min-width: 0; }
.history-main > div { display: flex; align-items: center; gap: 7px; }
.history-main strong { color: var(--ink-900); font-size: 13px; }
.history-main p { overflow: hidden; margin: 4px 0 3px; color: var(--ink-700); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.history-main small { color: var(--ink-500); font-size: 9px; }
.decision-body { display: grid; gap: 13px; }
.decision-body > p { margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
@media (max-width: 1180px) {
  .rules-metrics { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .rule-summary { grid-template-columns: 60px minmax(120px, 1fr) repeat(2, minmax(70px, .5fr)) auto; }
  .rule-summary > div:nth-of-type(3) { display: none; }
  .capability-levels { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .capability-levels > div { border-bottom: 1px solid var(--line); }
}
@media (max-width: 900px) {
  .rules-hero { align-items: flex-start; flex-direction: column; }
  .hero-actions { width: 100%; flex-wrap: wrap; }
  .version-state { flex: 1 1 100%; }
  .impact-band { grid-template-columns: 1fr; }
  .impact-band dl { order: 2; }
  .simulator-strip { grid-template-columns: 1fr 1fr; }
  .simulator-strip > .el-icon { display: none; }
  .capability-levels { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
@media (max-width: 640px) {
  .rules-hero { padding: 17px; }
  .hero-copy h2 { font-size: 19px; }
  .hero-actions > .el-button { flex: 1; }
  .rules-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .impact-band dl { grid-template-columns: repeat(2, minmax(0, 1fr)); row-gap: 10px; }
  .rule-summary { grid-template-columns: 48px minmax(0, 1fr) auto; gap: 7px; }
  .rule-summary > div { display: none; }
  .rule-summary > .el-tag { grid-column: 2 / -1; justify-self: start; }
  .rule-detail { grid-template-columns: 1fr; padding-left: 8px; }
  .simulator-strip { grid-template-columns: 1fr; }
  .capability-levels { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .history-list article { grid-template-columns: auto minmax(0, 1fr); }
  .history-list article > .el-button { grid-column: 2; justify-self: start; }
}
</style>
