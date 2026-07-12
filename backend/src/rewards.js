import { one, run } from "./db.js";
import { levelFromPoints, levelThresholds } from "./growth.js";

export const dailyRewardCaps = {
  coins: 500,
};

export function dailyPointCapForLevel(level) {
  const info = levelThresholds.find((item) => item.level === level);
  return info?.dailyPointCap ?? levelThresholds[0].dailyPointCap;
}

export const rewardRules = {
  daily_signin: {
    points: 20,
    coins: 500,
    dailyLimit: 1,
    description: "每日签到",
  },
  profile_complete: {
    points: 40,
    coins: 5,
    once: true,
    description: "完善个人资料",
  },
  comment_post: {
    points: 8,
    coins: 1,
    dailyLimit: 5,
    description: "发布评论",
  },
  danmaku_post: {
    points: 3,
    coins: 0,
    dailyLimit: 20,
    description: "发送弹幕",
  },
  chat_message: {
    points: 2,
    coins: 0,
    dailyLimit: 20,
    description: "参与聊天室",
  },
  follow_user: {
    points: 2,
    coins: 0,
    dailyLimit: 10,
    description: "关注用户",
  },
};

export function publicRewardRules() {
  return {
    dailyCaps: dailyRewardCaps,
    levels: levelThresholds,
    actions: Object.entries(rewardRules).map(([action, rule]) => ({
      action,
      points: rule.points,
      coins: rule.coins,
      dailyLimit: rule.dailyLimit ?? null,
      once: rule.once === true,
      description: rule.description,
    })),
  };
}

export function grantReward(userId, action, related = {}) {
  const rule = rewardRules[action];
  if (!rule || !userId) return null;

  if (rule.once) {
    const existing = one(
      `SELECT id FROM user_reward_events
       WHERE user_id = ? AND action = ?
       LIMIT 1`,
      [userId, action],
    );
    if (existing) return null;
  }

  if (rule.dailyLimit) {
    const today = one(
      `SELECT COUNT(*) AS count
       FROM user_reward_events
       WHERE user_id = ?
         AND action = ?
         AND date(created_at) = date('now')`,
      [userId, action],
    );
    if ((today?.count || 0) >= rule.dailyLimit) return null;
  }

  const todayTotal = one(
    `SELECT
       COALESCE(SUM(points_delta), 0) AS points,
       COALESCE(SUM(coins_delta), 0) AS coins
     FROM user_reward_events
     WHERE user_id = ?
       AND date(created_at) = date('now')`,
    [userId],
  );
  const user = one("SELECT points FROM users WHERE id = ?", [userId]);
  const currentPoints = user?.points || 0;
  const currentLevel = levelFromPoints(currentPoints);
  const dailyPointCap = dailyPointCapForLevel(currentLevel);
  const remainingPoints = Math.max(
    0,
    dailyPointCap - (todayTotal?.points || 0),
  );
  const remainingCoins = Math.max(
    0,
    dailyRewardCaps.coins - (todayTotal?.coins || 0),
  );
  const pointsAward = Math.min(rule.points, remainingPoints);
  const coinsAward = Math.min(rule.coins, remainingCoins);
  if (pointsAward <= 0 && coinsAward <= 0) return null;

  const result = run(
    `INSERT INTO user_reward_events
     (user_id, action, points_delta, coins_delta, description, related_type, related_id)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [
      userId,
      action,
      pointsAward,
      coinsAward,
      rule.description,
      related.type || "",
      related.id || "",
    ],
  );
  run(
    `UPDATE users
     SET points = points + ?,
         sakura_coins = sakura_coins + ?,
         level = ?,
         updated_at = datetime('now')
     WHERE id = ?`,
    [
      pointsAward,
      coinsAward,
      levelFromPoints(currentPoints + pointsAward),
      userId,
    ],
  );
  return {
    id: Number(result.lastInsertRowid),
    action,
    points: pointsAward,
    coins: coinsAward,
    description: rule.description,
  };
}
