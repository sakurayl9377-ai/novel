import type {
  GrowthLevelRule,
  GrowthRuleSetState,
} from '@/types/growth-rules';

export function cloneGrowthRules(
  rules: readonly GrowthLevelRule[],
): GrowthLevelRule[] {
  return rules.map((rule) => ({
    ...rule,
    permissions: [...rule.permissions],
  }));
}

export function growthRuleValidationError(rules: GrowthLevelRule[]): string {
  if (rules.length !== 7) return '规则必须完整包含 Lv.1 至 Lv.7';
  for (let index = 0; index < rules.length; index += 1) {
    const rule = rules[index];
    if (rule.level !== index + 1) return '等级顺序必须保持为 Lv.1 至 Lv.7';
    if (!rule.name.trim()) return `请填写 Lv.${rule.level} 的等级名称`;
    if (!rule.effect.trim()) return `请填写 Lv.${rule.level} 的等级效果`;
    if (!Number.isSafeInteger(rule.points) || rule.points < 0) {
      return `Lv.${rule.level} 的成长值门槛无效`;
    }
    if (!Number.isSafeInteger(rule.dailyPointCap) || rule.dailyPointCap < 1) {
      return `Lv.${rule.level} 的每日成长上限无效`;
    }
    if (!Number.isSafeInteger(rule.targetDays) || rule.targetDays < 0) {
      return `Lv.${rule.level} 的目标天数无效`;
    }
    if (index === 0 && (rule.points !== 0 || rule.targetDays !== 0)) {
      return 'Lv.1 的成长值门槛与目标天数必须为 0';
    }
    if (index > 0) {
      const previous = rules[index - 1];
      if (rule.points <= previous.points) {
        return `Lv.${rule.level} 的成长值门槛必须高于 Lv.${previous.level}`;
      }
      if (rule.dailyPointCap < previous.dailyPointCap) {
        return `Lv.${rule.level} 的每日上限不能低于 Lv.${previous.level}`;
      }
      if (rule.targetDays < previous.targetDays) {
        return `Lv.${rule.level} 的目标天数不能低于 Lv.${previous.level}`;
      }
    }
  }
  return '';
}

export function growthLevelForPoints(
  rules: GrowthLevelRule[],
  pointsValue: number,
): GrowthLevelRule {
  const points = Math.max(0, Number(pointsValue) || 0);
  return [...rules]
    .reverse()
    .find((item) => points >= item.points) || rules[0];
}

export function growthRuleStateLabel(state: GrowthRuleSetState): string {
  return ({
    draft: '草稿',
    published: '当前发布',
    superseded: '历史发布',
    discarded: '已放弃草稿',
  } as const)[state];
}

export function growthRuleStateTone(
  state: GrowthRuleSetState,
): 'success' | 'warning' | 'info' {
  if (state === 'published') return 'success';
  if (state === 'draft') return 'warning';
  return 'info';
}

export function growthChangedFieldLabel(field: string): string {
  return ({
    name: '名称',
    effect: '等级效果',
    points: '成长值门槛',
    dailyPointCap: '每日上限',
    targetDays: '目标天数',
  } as Record<string, string>)[field] || field;
}
