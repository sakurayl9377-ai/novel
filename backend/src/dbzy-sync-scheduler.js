import { config } from './config.js';
import { refreshDbzyNow } from './dbzy-source.js';

const schedulerState = {
  enabled: false,
  running: false,
  intervalMs: 0,
  consecutiveFailures: 0,
  lastStartedAt: null,
  lastSuccessAt: null,
  lastFailureAt: null,
  lastError: null,
  nextRunAt: null,
};
let timer = null;

export function startDbzySyncScheduler(log, options = {}) {
  stopDbzySyncScheduler();
  schedulerState.enabled = options.enabled ?? config.dbzySyncEnabled;
  schedulerState.intervalMs = Math.max(60_000, Number(options.intervalMs ?? config.dbzySyncIntervalMs) || 1_800_000);
  if (!schedulerState.enabled) return getDbzySyncSchedulerStatus();
  schedule(1_000, log, options.refresh || refreshDbzyNow);
  return getDbzySyncSchedulerStatus();
}

export function stopDbzySyncScheduler() {
  if (timer) clearTimeout(timer);
  timer = null;
  schedulerState.running = false;
  schedulerState.nextRunAt = null;
}

export function getDbzySyncSchedulerStatus() {
  return { ...schedulerState };
}

export function computeDbzySyncDelay(intervalMs, consecutiveFailures) {
  const base = Math.max(60_000, Number(intervalMs) || 1_800_000);
  if (!consecutiveFailures) return base;
  return Math.min(6 * 60 * 60 * 1000, base * (2 ** Math.min(4, consecutiveFailures)));
}

function schedule(delayMs, log, refresh) {
  schedulerState.nextRunAt = new Date(Date.now() + delayMs).toISOString();
  timer = setTimeout(async () => {
    if (schedulerState.running) return schedule(schedulerState.intervalMs, log, refresh);
    schedulerState.running = true;
    schedulerState.lastStartedAt = new Date().toISOString();
    schedulerState.nextRunAt = null;
    try {
      await refresh();
      schedulerState.consecutiveFailures = 0;
      schedulerState.lastSuccessAt = new Date().toISOString();
      schedulerState.lastError = null;
    } catch (error) {
      schedulerState.consecutiveFailures += 1;
      schedulerState.lastFailureAt = new Date().toISOString();
      schedulerState.lastError = error?.publicCode || error?.message || 'dbzy_sync_failed';
      log?.warn?.({ error }, 'scheduled dbzy sync failed');
    } finally {
      schedulerState.running = false;
      schedule(computeDbzySyncDelay(schedulerState.intervalMs, schedulerState.consecutiveFailures), log, refresh);
    }
  }, delayMs);
  timer.unref?.();
}
