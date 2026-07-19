import type {
  RaceBetStatus,
  RaceIntegrityStatus,
  RaceRoundStatus,
  RaceSeasonMetric,
  RaceSeasonStatus,
} from '@/types/race-operations';

export type ElementTone = 'success' | 'warning' | 'danger' | 'info' | 'primary';

export function raceRoundStatusLabel(status: RaceRoundStatus): string {
  return {
    betting: '投注中',
    locked: '已封盘',
    racing: '比赛中',
    settling: '已结算',
  }[status] || status;
}

export function raceRoundStatusTone(status: RaceRoundStatus): ElementTone {
  return {
    betting: 'primary',
    locked: 'warning',
    racing: 'success',
    settling: 'info',
  }[status] as ElementTone;
}

export function raceIntegrityLabel(status: RaceIntegrityStatus): string {
  return { healthy: '核验正常', warning: '需要留意', error: '存在异常' }[status];
}

export function raceIntegrityTone(status: RaceIntegrityStatus): ElementTone {
  return { healthy: 'success', warning: 'warning', error: 'danger' }[status] as ElementTone;
}

export function raceBetStatusLabel(status: RaceBetStatus): string {
  return { pending: '待结算', won: '已赢得', lost: '未赢得' }[status];
}

export function raceBetStatusTone(status: RaceBetStatus): ElementTone {
  return { pending: 'warning', won: 'success', lost: 'info' }[status] as ElementTone;
}

export function raceSeasonStatusLabel(status: RaceSeasonStatus): string {
  return { draft: '草稿', active: '进行中', paused: '已暂停', ended: '已结束' }[status];
}

export function raceSeasonStatusTone(status: RaceSeasonStatus): ElementTone {
  return { draft: 'info', active: 'success', paused: 'warning', ended: 'danger' }[status] as ElementTone;
}

export function raceSeasonTransitionLabel(status: RaceSeasonStatus): string {
  return { draft: '转为草稿', active: '启用赛季', paused: '暂停赛季', ended: '取消赛季' }[status];
}

export function raceSeasonEditable(status: RaceSeasonStatus): boolean {
  return status === 'draft' || status === 'paused';
}

export function raceMetricLabel(metric: RaceSeasonMetric): string {
  return {
    rounds: '完成轮次',
    wins: '获胜轮次',
    bet: '累计投注',
    profit: '累计正收益',
  }[metric];
}

export function raceTierLabel(key: string): string {
  return {
    bronze: '青铜',
    silver: '白银',
    gold: '黄金',
    platinum: '铂金',
    diamond: '钻石',
  }[key] || key || '不限段位';
}

export function raceSeasonActionLabel(action: string): string {
  return {
    create_draft: '创建赛季草稿',
    update: '修改赛季配置',
    activate: '启用赛季',
    pause: '暂停赛季',
    cancel: '取消赛季',
    finalize: '结算赛季',
    create_task: '添加赛季任务',
    update_task: '修改赛季任务',
    remove_task: '移除赛季任务',
    create_reward: '添加排名奖励',
    update_reward: '修改排名奖励',
    remove_reward: '移除排名奖励',
  }[action] || action;
}

export function formatRaceDuration(seconds: number): string {
  if (seconds < 60) return `${seconds} 秒`;
  if (seconds % 60 === 0) return `${seconds / 60} 分钟`;
  return `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
}

export function raceRewardScopeLabel(value: {
  tier: string;
  minRank: number;
  maxRank: number;
}): string {
  const rank = value.minRank || value.maxRank
    ? `第 ${value.minRank || 1} - ${value.maxRank || '末位'} 名`
    : '全部名次';
  return value.tier ? `${raceTierLabel(value.tier)} · ${rank}` : rank;
}

export function raceNoticeLabel(type: string): string {
  return {
    daily_loss: '每日损失提醒',
    loss_threshold: '损失阈值提醒',
  }[type] || type.replaceAll('_', ' ');
}
