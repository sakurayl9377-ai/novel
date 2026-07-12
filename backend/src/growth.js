export const maxLevel = 7;
export const maxLevelGrowthCap = 99999;

export const levelThresholds = [
  {
    level: 1,
    points: 0,
    name: "初樱",
    effect: "基础头像框",
    dailyPointCap: 60,
    targetDays: 0,
    permissions: ["评论", "普通弹幕", "聊天室文字消息", "照片墙基础位"],
  },
  {
    level: 2,
    points: 420,
    name: "晴樱",
    effect: "空间资料卡微光",
    dailyPointCap: 70,
    targetDays: 7,
    permissions: ["空间皮肤预览", "樱花币商店基础兑换", "照片墙 3 张"],
  },
  {
    level: 3,
    points: 2030,
    name: "绯樱",
    effect: "评论昵称高亮",
    dailyPointCap: 85,
    targetDays: 30,
    permissions: ["关注展示增强", "评论高亮标识", "聊天室图片 URL 消息"],
  },
  {
    level: 4,
    points: 7130,
    name: "夜樱",
    effect: "聊天室入场提示",
    dailyPointCap: 100,
    targetDays: 90,
    permissions: ["聊天室入场特效", "表情包快捷发送", "照片墙 6 张"],
  },
  {
    level: 5,
    points: 22130,
    name: "星樱",
    effect: "动态头像和高级弹幕",
    dailyPointCap: 120,
    targetDays: 240,
    permissions: ["动态头像展示位", "高级弹幕样式", "稀有商店物品兑换"],
  },
  {
    level: 6,
    points: 37130,
    name: "月樱",
    effect: "个人空间背景特效",
    dailyPointCap: 140,
    targetDays: 365,
    permissions: ["空间背景特效", "专属资料卡边框", "照片墙 9 张"],
  },
  {
    level: 7,
    points: 61630,
    name: "曜樱",
    effect: "顶级头像框和专属聊天气泡",
    dailyPointCap: 160,
    targetDays: 540,
    permissions: [
      "顶级头像框",
      "专属聊天气泡",
      "全商店兑换资格",
      "等级满级铭牌",
    ],
  },
];

export function levelFromPoints(pointsValue) {
  const points = Math.max(0, Number(pointsValue) || 0);
  let level = 1;
  for (const item of levelThresholds) {
    if (points >= item.points) level = item.level;
  }
  return level;
}

export function growthFromUser(user, daily = {}) {
  const points = Math.max(0, Number(user?.points) || 0);
  const level = levelFromPoints(points);
  const currentInfo =
    levelThresholds.find((item) => item.level === level) ?? levelThresholds[0];
  const nextInfo = levelThresholds.find((item) => item.level === level + 1);
  const current = currentInfo.points;
  const next = nextInfo?.points ?? Math.max(maxLevelGrowthCap, current + 1);
  const progress = next <= current ? 1 : (points - current) / (next - current);
  const dailyPointsEarned = Math.max(0, Number(daily.points) || 0);
  const dailyCoinsEarned = Math.max(0, Number(daily.coins) || 0);
  const signInStreakDays = Math.max(0, Number(daily.signInStreakDays) || 0);
  return {
    level,
    maxLevel,
    levelName: currentInfo.name,
    levelEffect: currentInfo.effect,
    dailyPointCap: currentInfo.dailyPointCap,
    dailyPointsEarned,
    dailyPointsRemaining: Math.max(
      0,
      currentInfo.dailyPointCap - dailyPointsEarned,
    ),
    dailyCoinsEarned,
    signInStreakDays,
    points,
    sakuraCoins: Math.max(0, Number(user?.sakura_coins) || 0),
    currentLevelPoints: current,
    nextLevelPoints: next,
    progress: Math.max(0, Math.min(1, progress)),
    effects: levelThresholds.map((item) => ({
      level: item.level,
      name: item.name,
      points: item.points,
      effect: item.effect,
      dailyPointCap: item.dailyPointCap,
      targetDays: item.targetDays,
      permissions: item.permissions,
      unlocked: level >= item.level,
    })),
    privileges: privilegesForLevel(level),
  };
}

export function privilegesForLevel(level) {
  return {
    basicComments: level >= 1,
    basicDanmaku: level >= 1,
    chatText: level >= 1,
    dynamicAvatar: level >= 5,
    advancedDanmaku: level >= 5,
    profileSkins: level >= 2,
    profileEffects: level >= 6,
    photoWall: level >= 1,
    chatImages: level >= 3,
    chatStickers: level >= 4,
    chatEntranceEffect: level >= 4,
    exclusiveChatBubble: level >= 7,
    coinShop: level >= 1,
    rareShopItems: level >= 5,
  };
}
