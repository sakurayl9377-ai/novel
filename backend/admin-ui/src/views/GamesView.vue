<script setup lang="ts">
import {
  CircleCheck,
  Connection,
  Hide,
  Monitor,
  Refresh,
  SwitchButton,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, onMounted, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import {
  controlGameService,
  getGameControls,
  setGameVisibility,
} from '@/services/games';
import type {
  AdminGameControl,
  GameControlWorkbenchResponse,
  GameServiceAction,
  GameServiceUnitState,
} from '@/types/games';
import { formatDateTime } from '@/utils/format';
import {
  gameServiceActionDisabled,
  gameServiceActionLabel,
  gameServiceStatusLabel,
  gameServiceStatusTone,
  gameServiceUnitStatusLabel,
  gameServiceUnitStatusTone,
} from '@/utils/games';

const loading = ref(false);
const initialized = ref(false);
const workbench = ref<GameControlWorkbenchResponse>({ generatedAt: '', games: [] });
const busyKey = ref('');

const visibleCount = computed(() => workbench.value.games.filter((game) => game.visible).length);
const runningCount = computed(() => workbench.value.games.filter((game) => game.service.active).length);
const failedCount = computed(() => workbench.value.games.filter(
  (game) => ['failed', 'partial', 'unknown'].includes(game.service.status),
).length);

onMounted(() => void loadGames());

async function loadGames(silent = false): Promise<void> {
  if (!silent) loading.value = true;
  try {
    const data = await getGameControls();
    workbench.value = {
      ...data,
      games: [...data.games].sort((left, right) =>
        left.sortOrder - right.sortOrder || left.name.localeCompare(right.name)),
    };
  } catch (error) {
    ElMessage.error(errorMessage(error, '游戏状态加载失败'));
  } finally {
    if (!silent) loading.value = false;
    initialized.value = true;
  }
}

async function changeVisibility(game: AdminGameControl, value: string | number | boolean): Promise<void> {
  const visible = Boolean(value);
  const key = `visibility:${game.id}`;
  if (busyKey.value) return;
  busyKey.value = key;
  try {
    const result = await setGameVisibility(game.id, visible);
    replaceGame(result.game);
    ElMessage.success(visible
      ? `“${game.name}”已在 App 游戏中心显示`
      : `“${game.name}”已从 App 游戏中心隐藏`);
    await loadGames(true);
  } catch (error) {
    ElMessage.error(errorMessage(error, '游戏展示状态修改失败'));
  } finally {
    busyKey.value = '';
  }
}

async function confirmServiceAction(game: AdminGameControl, action: GameServiceAction): Promise<void> {
  if (busyKey.value || gameServiceActionDisabled(game, action)) return;
  const actionLabel = gameServiceActionLabel(action);
  const impact = {
    start: '将启动这款游戏的全部服务单元。启动成功不代表会自动在 App 中显示。',
    stop: '将停止这款游戏的全部服务单元，正在游戏中的用户会断开连接；停止成功后系统会同时从 App 游戏中心隐藏该游戏。',
    restart: '将依次重启这款游戏的全部服务单元，在线用户会短暂断开连接。',
  }[action];

  try {
    await ElMessageBox.confirm(
      `${impact} 操作结果会写入审计日志。`,
      `确认${actionLabel}“${game.name}”？`,
      {
        type: action === 'stop' ? 'error' : 'warning',
        confirmButtonText: `确认${actionLabel}`,
        cancelButtonText: '取消',
        confirmButtonClass: action === 'stop' ? 'el-button--danger' : '',
      },
    );
  } catch (error) {
    if (!isDialogCancel(error)) ElMessage.error(errorMessage(error, `${actionLabel}确认失败`));
    return;
  }

  const key = `action:${game.id}:${action}`;
  busyKey.value = key;
  try {
    const result = await controlGameService(game.id, action);
    replaceGame(result.game);
    ElMessage.success(result.message || `“${game.name}”${actionLabel}操作已完成`);
    await loadGames(true);
  } catch (error) {
    ElMessage.error(errorMessage(error, `“${game.name}”${actionLabel}失败`));
    await loadGames(true);
  } finally {
    busyKey.value = '';
  }
}

function replaceGame(next: AdminGameControl): void {
  const index = workbench.value.games.findIndex((game) => game.id === next.id);
  if (index < 0) return;
  workbench.value.games[index] = next;
}

function visibilityBusy(game: AdminGameControl): boolean {
  return busyKey.value === `visibility:${game.id}`;
}

function actionBusy(game: AdminGameControl, action: GameServiceAction): boolean {
  return busyKey.value === `action:${game.id}:${action}`;
}

function asGame(row: unknown): AdminGameControl {
  return row as AdminGameControl;
}

function asUnit(row: unknown): GameServiceUnitState {
  return row as GameServiceUnitState;
}

function isDialogCancel(error: unknown): boolean {
  return error === 'cancel' || error === 'close';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="page-stack games-page">
    <section class="games-hero">
      <div class="hero-copy">
        <span class="eyebrow">GAME OPERATIONS</span>
        <h2>游戏中心与服务器控制</h2>
        <p>展示开关决定用户能否在 App 游戏中心看到游戏；服务器状态来自实时服务检查，启停与重启会留下管理员审计记录。</p>
      </div>
      <ElButton :icon="Refresh" :loading="loading" @click="loadGames()">刷新状态</ElButton>
    </section>

    <ElAlert
      title="停服会自动隐藏，恢复展示需要人工确认"
      type="info"
      :closable="false"
      show-icon
    >
      <template #default>停止服务成功后系统会自动隐藏游戏；恢复时先启动并确认全部服务正常，再单独打开 App 展示开关。</template>
    </ElAlert>

    <ElSkeleton v-if="!initialized && loading" :rows="8" animated />
    <template v-else>
      <section class="metric-grid games-metrics">
        <MetricCard label="已接入游戏" :value="workbench.games.length" hint="后台可管理目录" :icon="Monitor" />
        <MetricCard label="App 中显示" :value="visibleCount" hint="公开游戏目录可见" :icon="View" tone="success" />
        <MetricCard label="服务器运行中" :value="runningCount" hint="聚合服务状态" :icon="Connection" :tone="runningCount ? 'success' : 'default'" />
        <MetricCard label="异常服务" :value="failedCount" hint="失败、部分或未知" :icon="WarningFilled" :tone="failedCount ? 'danger' : 'success'" />
      </section>

      <section class="games-workbench">
        <header class="workbench-heading">
          <div>
            <span>MANAGED GAMES</span>
            <h3>游戏列表</h3>
            <p>最近检查：{{ formatDateTime(workbench.generatedAt) }}</p>
          </div>
          <ElTag type="info" effect="plain">{{ workbench.games.length }} 款</ElTag>
        </header>

        <ElTable
          v-if="workbench.games.length"
          v-loading="loading"
          :data="workbench.games"
          row-key="id"
          class="games-table"
        >
          <ElTableColumn label="游戏" min-width="240">
            <template #default="{ row }">
              <div class="game-identity">
                <span class="game-icon"><ElIcon><Monitor /></ElIcon></span>
                <div>
                  <strong>{{ asGame(row).name }}</strong>
                  <small>{{ asGame(row).description || asGame(row).id }}</small>
                  <code>{{ asGame(row).id }}</code>
                </div>
              </div>
            </template>
          </ElTableColumn>

          <ElTableColumn label="App 游戏中心" width="180">
            <template #default="{ row }">
              <div class="visibility-control">
                <ElSwitch
                  :model-value="asGame(row).visible"
                  :loading="visibilityBusy(asGame(row))"
                  :disabled="Boolean(busyKey) && !visibilityBusy(asGame(row))"
                  inline-prompt
                  active-text="显示"
                  inactive-text="隐藏"
                  @change="changeVisibility(asGame(row), $event)"
                />
                <small>
                  <ElIcon><View v-if="asGame(row).visible" /><Hide v-else /></ElIcon>
                  {{ asGame(row).visible ? '用户目录可见' : '用户目录隐藏' }}
                </small>
              </div>
            </template>
          </ElTableColumn>

          <ElTableColumn label="服务器状态" min-width="265">
            <template #default="{ row }">
              <div class="service-state">
                <div class="service-summary">
                  <ElTag :type="gameServiceStatusTone(asGame(row).service)" effect="plain">
                    {{ gameServiceStatusLabel(asGame(row).service) }}
                  </ElTag>
                  <small>{{ asGame(row).service.enabled ? '开机自启' : '未设自启' }}</small>
                </div>
                <small v-if="asGame(row).service.error" class="service-error">服务状态读取失败，请刷新重试</small>
                <div v-if="asGame(row).service.units.length" class="unit-list">
                  <ElTooltip
                    v-for="unit in asGame(row).service.units"
                    :key="unit.unit"
                    :content="`${unit.unit} · ${unit.status} · ${unit.enabled ? '已启用' : '未启用'}`"
                    placement="top"
                  >
                    <ElTag :type="gameServiceUnitStatusTone(asUnit(unit))" size="small" effect="plain">
                      {{ unit.unit }} · {{ gameServiceUnitStatusLabel(asUnit(unit)) }}
                    </ElTag>
                  </ElTooltip>
                </div>
                <small v-else>未返回服务单元明细</small>
              </div>
            </template>
          </ElTableColumn>

          <ElTableColumn label="服务操作" width="264" align="right" fixed="right">
            <template #default="{ row }">
              <div class="action-buttons">
                <ElButton
                  size="small"
                  type="primary"
                  plain
                  :loading="actionBusy(asGame(row), 'start')"
                  :disabled="Boolean(busyKey) || gameServiceActionDisabled(asGame(row), 'start')"
                  @click="confirmServiceAction(asGame(row), 'start')"
                >
                  启动
                </ElButton>
                <ElButton
                  size="small"
                  :icon="Refresh"
                  :loading="actionBusy(asGame(row), 'restart')"
                  :disabled="Boolean(busyKey) || gameServiceActionDisabled(asGame(row), 'restart')"
                  @click="confirmServiceAction(asGame(row), 'restart')"
                >
                  重启
                </ElButton>
                <ElButton
                  size="small"
                  type="danger"
                  plain
                  :icon="SwitchButton"
                  :loading="actionBusy(asGame(row), 'stop')"
                  :disabled="Boolean(busyKey) || gameServiceActionDisabled(asGame(row), 'stop')"
                  @click="confirmServiceAction(asGame(row), 'stop')"
                >
                  停止
                </ElButton>
              </div>
              <small v-if="!asGame(row).controllable" class="control-unavailable">当前环境未配置控制权限</small>
            </template>
          </ElTableColumn>
        </ElTable>

        <ElEmpty
          v-else
          :image-size="72"
          description="当前没有可管理的游戏"
        />
      </section>

      <ElAlert
        v-if="failedCount"
        title="存在异常游戏服务"
        type="error"
        :closable="false"
        show-icon
      >
        <template #default>先隐藏对应游戏并检查各服务单元，确认全部恢复后再重新对用户开放。</template>
      </ElAlert>
      <ElAlert
        v-else-if="workbench.games.length && runningCount === workbench.games.length"
        title="全部游戏服务运行正常"
        type="success"
        :closable="false"
        show-icon
      >
        <template #default><ElIcon><CircleCheck /></ElIcon> 所有已接入游戏的聚合服务状态均在线。</template>
      </ElAlert>
    </template>
  </div>
</template>

<style scoped>
.games-page { gap: 16px; }
.games-hero { display: flex; min-height: 128px; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid #39769b; border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { max-width: 780px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.games-metrics { grid-template-columns: repeat(4, minmax(150px, 1fr)); gap: 10px; }
.games-metrics :deep(.metric-card) { min-height: 112px; padding: 14px; }
.games-workbench { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.workbench-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 16px 18px; border-bottom: 1px solid var(--line); }
.workbench-heading > div { min-width: 0; display: grid; gap: 3px; }
.workbench-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.workbench-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; letter-spacing: 0; }
.workbench-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.games-table { min-width: 920px; }
.game-identity { display: flex; min-width: 0; align-items: center; gap: 11px; }
.game-icon { width: 38px; height: 38px; display: grid; flex: 0 0 38px; place-items: center; border-radius: 7px; color: #39769b; background: #edf5fa; }
.game-identity > div { min-width: 0; display: grid; gap: 3px; }
.game-identity strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.game-identity small, .game-identity code { overflow: hidden; color: var(--ink-500); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.game-identity code { color: #6d7b83; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.visibility-control, .service-state { display: grid; gap: 8px; }
.visibility-control { justify-items: start; }
.visibility-control small, .service-state > small, .control-unavailable { color: var(--ink-500); font-size: 9px; }
.visibility-control small { display: inline-flex; align-items: center; gap: 4px; }
.service-summary { display: flex; align-items: center; gap: 7px; }
.service-summary small { color: var(--ink-500); font-size: 9px; }
.service-error { color: #b4233e !important; }
.unit-list { display: flex; min-width: 0; flex-wrap: wrap; gap: 5px; }
.unit-list :deep(.el-tag) { max-width: 180px; overflow: hidden; text-overflow: ellipsis; }
.action-buttons { display: flex; justify-content: flex-end; gap: 6px; }
.action-buttons :deep(.el-button + .el-button) { margin-left: 0; }
.control-unavailable { display: block; margin-top: 6px; text-align: right; }
@media (max-width: 1100px) {
  .games-metrics { grid-template-columns: repeat(2, minmax(150px, 1fr)); }
  .games-workbench { overflow-x: auto; }
}
@media (max-width: 720px) {
  .games-hero { align-items: flex-start; flex-direction: column; }
  .games-hero > .el-button { width: 100%; }
}
</style>
