import type {
  CampaignAudiencePreset,
  CampaignStatus,
  RankingMetric,
  RankingPeriod,
} from '@/types/growth-operations';

const contentTypeLabels: Record<string, string> = {
  novel: '小说',
  manga: '漫画',
  anime: '动漫',
};

const rankingMetricLabels: Record<RankingMetric, string> = {
  hot: '近期热度',
  new: '新作趋势',
  following: '收藏关注',
  completion: '完读完播',
};

const audienceLabels: Record<CampaignAudiencePreset, string> = {
  all_registered: '全部注册用户',
  new_users: '近 7 天新用户',
  active_users: '近 30 天活跃用户',
  readers: '小说与漫画读者',
  anime_viewers: '动漫观众',
  legacy_custom: '旧版自定义人群',
};

const eventLabels: Record<string, string> = {
  exposure: '内容曝光',
  click: '点击内容',
  open: '打开详情',
  start: '开始阅读 / 播放',
  complete: '完成阅读 / 播放',
  favorite: '加入收藏',
  horse_race_bet: '完成赛马下注',
  horse_race_round: '完成赛马轮次',
  horse_race_win: '赢得赛马轮次',
};

export function growthContentTypeLabel(type: string): string {
  return contentTypeLabels[type] || '全部内容';
}

export function rankingMetricLabel(metric: string): string {
  return rankingMetricLabels[metric as RankingMetric] || metric;
}

export function rankingPeriodLabel(period: string): string {
  return period === 'daily' ? '日榜' : '周榜';
}

export function rankingScopeLabel(scope: string): string {
  if (scope === 'all') return '全部榜单';
  if (scope in rankingMetricLabels) return `全部${rankingMetricLabel(scope)}`;
  const [period, metric] = scope.split('_') as [RankingPeriod, RankingMetric];
  return `${rankingPeriodLabel(period)} · ${rankingMetricLabel(metric)}`;
}

export function campaignStatusLabel(status: CampaignStatus): string {
  return ({ draft: '草稿', active: '进行中', paused: '已暂停', ended: '已结束' })[status];
}

export function campaignStatusTone(status: CampaignStatus): 'success' | 'warning' | 'info' | undefined {
  return ({ draft: 'info', active: 'success', paused: 'warning', ended: undefined } as const)[status];
}

export function campaignAudienceLabel(preset: CampaignAudiencePreset): string {
  return audienceLabels[preset] || preset;
}

export function growthEventLabel(event: string): string {
  return eventLabels[event] || event;
}

export function growthEventShortLabel(event: string): string {
  return ({
    exposure: '曝光',
    click: '点击',
    open: '打开',
    start: '开始',
    complete: '完成',
    favorite: '收藏',
  } as Record<string, string>)[event] || growthEventLabel(event);
}

export function growthOperationActionLabel(action: string): string {
  return ({
    create: '创建规则',
    update: '修改配置',
    remove: '移除规则',
    create_draft: '创建活动草稿',
    activate: '启用活动',
    pause: '暂停活动',
    end: '结束活动',
    restore_revision: '恢复历史版本',
    disable: '停用任务',
  } as Record<string, string>)[action] || action;
}

export function formatRate(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  return `${(value * 100).toFixed(value >= 0.1 ? 1 : 2)}%`;
}

export function campaignTransitionLabel(status: CampaignStatus): string {
  return ({ draft: '转为草稿', active: '启用活动', paused: '暂停活动', ended: '结束活动' })[status];
}

export function campaignEditable(status: CampaignStatus): boolean {
  return status === 'draft' || status === 'paused';
}
