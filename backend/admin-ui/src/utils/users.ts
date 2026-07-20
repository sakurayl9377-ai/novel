import type { AdminUser, UserGender, UserRole, UserStatus } from '@/types/user';

export function userStatusLabel(value: UserStatus | string): string {
  return value === 'banned' ? '已封禁' : '正常';
}

export function userRoleLabel(value: UserRole | string): string {
  return value === 'admin' ? '管理员' : '普通用户';
}

export function userGenderLabel(value: UserGender | string): string {
  return ({ private: '不公开', male: '男', female: '女' } as Record<string, string>)[value]
    || '不公开';
}

export function userBanReasonLabel(value: string): string {
  const [code, ...details] = String(value || '').split(':');
  const label = ({
    community_violation: '社区内容违规',
    fraud: '诈骗或交易风险',
    spam: '批量广告或骚扰',
    security_risk: '账号安全风险',
    account_abuse: '账号滥用',
    other: '其他原因',
    chat_keyword_temp: '聊天关键词临时封禁',
    chat_keyword_permanent: '聊天关键词永久封禁',
    admin_ban_legacy: '旧版后台人工封禁',
  } as Record<string, string>)[code || ''];
  if (!label) return value || '未记录原因';
  return details.length ? `${label} · ${details.join(':')}` : label;
}

export function rewardActionLabel(value: string): string {
  return ({
    admin_adjust_points: '后台调整成长值',
    admin_adjust_coins: '后台调整樱花币',
    daily_signin: '每日签到',
    follow_user: '关注用户',
    comment: '发表评论',
    danmaku: '发送弹幕',
    chat_message: '聊天室发言',
    profile_complete: '完善资料',
    shop_redeem: '商店兑换',
    sso_wallet_debit: '游戏消费扣币',
    sso_wallet_credit: '游戏退款或发奖',
  } as Record<string, string>)[value] || value || '未知账变';
}

export function signedNumber(value: number): string {
  const number = Number(value || 0);
  return number > 0 ? `+${number.toLocaleString()}` : number.toLocaleString();
}

export function maskInstallId(value: string): string {
  const text = String(value || '');
  if (text.length <= 12) return text || '未记录';
  return `${text.slice(0, 6)}…${text.slice(-4)}`;
}

export function userActivityCount(user: AdminUser): number {
  return Number(user.stats.comments || 0)
    + Number(user.stats.danmaku || 0)
    + Number(user.stats.chat || 0);
}

export function userRiskLabel(user: AdminUser): string {
  if (user.status === 'banned') return '账号已封禁';
  if (user.chatViolationTotal >= 5) return '高频聊天违规';
  if (user.chatViolationTotal > 0 || user.stats.reported > 0) return '需要关注';
  return '风险正常';
}
