import type { FinanceEvent } from '@/types/finance';

export function financeActionLabel(value: string): string {
  return ({
    daily_signin: '每日签到',
    follow_user: '关注用户',
    comment: '发表评论',
    danmaku: '发送弹幕',
    chat_message: '聊天室发言',
    profile_complete: '完善资料',
    shop_redeem: '商店兑换',
    horse_race_bet: '赛马下注',
    horse_race_payout: '赛马返还',
    activity_reward: '活动任务奖励',
    campaign_reward: '活动奖励',
    horse_race_season_task: '赛季任务奖励',
    horse_race_season_reward: '赛季排名奖励',
    admin_adjust_points: '后台调整成长值',
    admin_adjust_coins: '后台调整樱花币',
    sso_wallet_debit: '游戏消费扣币',
    sso_wallet_credit: '游戏退款或发奖',
  } as Record<string, string>)[value] || value || '未知来源';
}

export function financeRelatedTypeLabel(value: string): string {
  return ({
    admin: '管理员操作',
    user: '用户互动',
    shop_item: '商店商品',
    horse_race: '赛马轮次',
    campaign: '运营活动',
    activity_task: '活动任务',
    season: '赛季',
    daily: '每日任务',
    sso_wallet: '第三方游戏',
  } as Record<string, string>)[value] || value || '系统规则';
}

export function financeEventDirection(event: FinanceEvent): 'credit' | 'debit' | 'mixed' | 'zero' {
  const deltas = [Number(event.pointsDelta || 0), Number(event.coinsDelta || 0)];
  const hasCredit = deltas.some((value) => value > 0);
  const hasDebit = deltas.some((value) => value < 0);
  if (hasCredit && hasDebit) return 'mixed';
  if (hasCredit) return 'credit';
  if (hasDebit) return 'debit';
  return 'zero';
}

export function financeEventDirectionLabel(event: FinanceEvent): string {
  return ({ credit: '发放', debit: '扣除', mixed: '混合账变', zero: '零值记录' } as const)[
    financeEventDirection(event)
  ];
}

export function signedAsset(value: number): string {
  const number = Number(value || 0);
  return number > 0 ? `+${number.toLocaleString()}` : number.toLocaleString();
}
