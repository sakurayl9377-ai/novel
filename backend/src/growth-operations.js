import crypto, { randomUUID } from "node:crypto";

import { all, db, one, run } from "./db.js";
import { levelFromPoints } from "./growth.js";
import { consumeRateLimit } from "./rate-limit.js";
import { badRequest } from "./validators.js";

export const behaviorEvents = new Set([
  "exposure",
  "click",
  "open",
  "start",
  "complete",
  "favorite",
]);
export const behaviorSources = new Set([
  "home",
  "search",
  "detail",
  "recommendation",
  "ranking",
  "continue",
  "reader",
  "player",
  "library",
  "activity",
  "telemetry",
]);
export const rankingMetrics = new Set(["hot", "new", "following", "completion"]);
export const rankingPeriods = new Set(["daily", "weekly"]);
export const activityEventNames = new Set([
  ...behaviorEvents,
  "horse_race_bet",
  "horse_race_round",
  "horse_race_win",
]);

const aggregateCaps = {
  exposure: 20,
  click: 10,
  open: 10,
  start: 6,
  complete: 3,
  favorite: 2,
};
const processOwnerId = `novel-${process.pid}-${randomUUID()}`;

export function ingestContentBehavior({
  request,
  body,
  skipRateLimit = false,
  withinTransaction = false,
}) {
  const eventId = normalizedIdentifier(body.eventId, "eventId", 120);
  const eventName = String(body.event || body.eventName || "").trim().toLowerCase();
  if (!behaviorEvents.has(eventName)) throw badRequest("behavior event is invalid");
  const source = String(body.source || "").trim().toLowerCase();
  if (!behaviorSources.has(source)) throw badRequest("behavior source is invalid");
  const contentKey = normalizedIdentifier(body.contentKey, "contentKey", 240, true);
  const catalog = one(
    "SELECT stable_key, content_type FROM content_catalog WHERE stable_key = ?",
    [contentKey],
  );
  if (!catalog) throw badRequest("content does not exist in catalog");
  const installId = normalizedIdentifier(body.installId, "installId", 120);
  const sessionId = optionalText(body.sessionId, 120);
  const userId = Number(request?.user?.id || body.userId || 0) || null;
  const actorKey = userId
    ? `user:${userId}`
    : `install:${sha256(installId).slice(0, 32)}`;
  const occurredAt = normalizedOccurredAt(body.occurredAt);
  const existing = one(
    `SELECT id, user_id, install_id, session_id, content_key, event_name, source
     FROM content_behavior_events WHERE event_id = ?`,
    [eventId],
  );
  if (existing) {
    assertBehaviorReplay(existing, { userId, installId, sessionId, contentKey, eventName, source });
    return { accepted: false, idempotentReplay: true, aggregated: false };
  }

  if (!skipRateLimit) enforceBehaviorRate(request?.ip, installId);

  let metadataJson = "{}";
  if (body.metadata && typeof body.metadata === "object" && !Array.isArray(body.metadata)) {
    const encoded = JSON.stringify(body.metadata);
    metadataJson = encoded.length <= 4000 ? encoded : JSON.stringify({ truncated: true });
  }

  if (!withinTransaction) db.exec("BEGIN IMMEDIATE");
  try {
    const replay = one(
      `SELECT id, user_id, install_id, session_id, content_key, event_name, source
       FROM content_behavior_events WHERE event_id = ?`,
      [eventId],
    );
    if (replay) {
      assertBehaviorReplay(replay, { userId, installId, sessionId, contentKey, eventName, source });
      if (!withinTransaction) db.exec("COMMIT");
      return { accepted: false, idempotentReplay: true, aggregated: false };
    }
    run(
      `INSERT INTO content_behavior_events
       (event_id, user_id, install_id, session_id, actor_key, content_key,
        content_type, event_name, source, metadata_json, occurred_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        eventId,
        userId,
        installId,
        sessionId,
        actorKey,
        contentKey,
        catalog.content_type,
        eventName,
        source,
        metadataJson,
        occurredAt,
      ],
    );
    const aggregated = aggregateBehavior({
      eventDate: occurredAt.slice(0, 10),
      contentKey,
      contentType: catalog.content_type,
      eventName,
      actorKey,
    });
    if (aggregated && userId) {
      advanceActivityTasks({
        userId,
        eventName,
        amount: 1,
        context: {
          contentType: catalog.content_type,
          contentKey,
          versionCode: Number(body.versionCode || body.metadata?.versionCode || 0),
        },
      });
    }
    if (!withinTransaction) {
      db.exec("COMMIT");
      pruneGrowthData();
    }
    return {
      accepted: true,
      idempotentReplay: false,
      aggregated,
      aggregateCapped: !aggregated,
    };
  } catch (error) {
    if (!withinTransaction) safeRollback();
    throw error;
  }
}

export function recordBehaviorFromTelemetry({
  telemetryId,
  userId,
  installId,
  sessionId,
  eventName,
  raw,
  versionCode = 0,
}) {
  const mapped = telemetryBehavior(eventName, raw);
  if (!mapped) return null;
  const contentKey = String(raw?.metadata?.contentKey || raw?.metadata?.stableKey || "").trim();
  if (!contentKey || !one("SELECT 1 FROM content_catalog WHERE stable_key = ?", [contentKey])) {
    return null;
  }
  try {
    return ingestContentBehavior({
      request: { user: userId ? { id: userId } : null, ip: "telemetry" },
      skipRateLimit: true,
      withinTransaction: true,
      body: {
        eventId: `telemetry:${telemetryId}`,
        event: mapped,
        source: "telemetry",
        contentKey,
        installId,
        sessionId,
        occurredAt: raw.occurredAt,
        metadata: { telemetryEvent: eventName },
        versionCode,
      },
    });
  } catch {
    return null;
  }
}

export function recommendations({
  userId = 0,
  contentType = "",
  limit = 20,
  versionCode = 0,
  platform = "unknown",
  installId = "",
  ip = "",
} = {}) {
  const safeLimit = Math.max(1, Math.min(50, Number(limit) || 20));
  const typeClause = ["novel", "manga", "anime"].includes(contentType)
    ? "AND c.content_type = ?"
    : "";
  const typeParams = typeClause ? [contentType] : [];
  const rows = all(
    `SELECT c.*,
       COALESCE(SUM(CASE WHEN d.event_name = 'exposure' THEN d.unique_actors ELSE 0 END), 0) AS exposures,
       COALESCE(SUM(CASE WHEN d.event_name = 'click' THEN d.unique_actors ELSE 0 END), 0) AS clicks,
       COALESCE(SUM(CASE WHEN d.event_name = 'open' THEN d.unique_actors ELSE 0 END), 0) AS opens,
       COALESCE(SUM(CASE WHEN d.event_name = 'start' THEN d.unique_actors ELSE 0 END), 0) AS starts,
       COALESCE(SUM(CASE WHEN d.event_name = 'complete' THEN d.unique_actors ELSE 0 END), 0) AS completes,
       COALESCE(SUM(CASE WHEN d.event_name = 'favorite' THEN d.unique_actors ELSE 0 END), 0) AS favorites
     FROM content_catalog c
     LEFT JOIN content_behavior_daily d ON d.content_key = c.stable_key
       AND date(d.event_date) >= date('now', '-30 days')
     WHERE c.status = 'active' ${typeClause}
     GROUP BY c.stable_key
     ORDER BY c.stable_key`,
    typeParams,
  );
  const byKey = new Map(rows.map((row) => [row.stable_key, candidate(row)]));

  const placements = all(
    `SELECT p.content_key, p.position, p.sort_order, p.audience_json
     FROM home_placements p JOIN content_catalog c ON c.stable_key = p.content_key
     WHERE p.status = 'active' AND p.placement_type = 'recommend'
       AND c.status = 'active'
       AND (p.starts_at = '' OR datetime(p.starts_at) <= datetime('now'))
       AND (p.ends_at = '' OR datetime(p.ends_at) > datetime('now'))
     ORDER BY p.sort_order DESC, p.id ASC`,
  );
  const placementIdentity = userId
    ? `user:${userId}`
    : installId
      ? `install:${installId}`
      : `anonymous:${ip || "unknown"}`;
  placements
    .filter((placement) => placementAudienceMatches(placement.audience_json, {
      userId,
      versionCode,
      platform: String(platform || "unknown").toLowerCase(),
      identity: placementIdentity,
      salt: `recommendation:${placement.content_key}`,
    }))
    .forEach((placement, index) => {
    const item = byKey.get(placement.content_key);
    if (!item) return;
    item.score += 1200 + Number(placement.sort_order || 0) - index;
    addReason(item, "运营推荐位", "placement");
    });

  const preferences = new Map();
  if (userId) {
    for (const row of all(
      `SELECT content_type,
         SUM(CASE event_name WHEN 'favorite' THEN 8 WHEN 'complete' THEN 6
             WHEN 'start' THEN 4 WHEN 'open' THEN 2 ELSE 1 END) AS weight
       FROM content_behavior_events
       WHERE user_id = ? AND occurred_at >= datetime('now', '-45 days')
       GROUP BY content_type`,
      [userId],
    )) preferences.set(row.content_type, Number(row.weight || 0));

    for (const progress of all(
      `SELECT p.content_key, p.updated_at
       FROM user_content_progress p
       JOIN content_catalog c ON c.stable_key = p.content_key AND c.status = 'active'
       WHERE p.user_id = ? AND p.deleted_at IS NULL
       ORDER BY p.updated_at DESC LIMIT 20`,
      [userId],
    )) {
      const item = byKey.get(progress.content_key);
      if (!item) continue;
      item.score += 1600;
      item.continueProgress = true;
      addReason(item, "继续上次阅读或观看", "continue");
    }
  }

  for (const item of byKey.values()) {
    const signals = item.signals;
    const hotScore =
      signals.favorites * 12 +
      signals.completes * 10 +
      signals.starts * 5 +
      signals.opens * 3 +
      signals.clicks * 2 +
      Math.min(signals.exposures, 200) * 0.15;
    item.score += hotScore;
    if (hotScore > 0) addReason(item, "近期真实热度", "trending");
    const preference = preferences.get(item.content.contentType) || 0;
    if (preference > 0) {
      item.score += Math.min(300, preference * 5);
      addReason(item, `偏好${contentTypeLabel(item.content.contentType)}`, "preference");
    }
    const ageDays = Math.max(
      0,
      (Date.now() - Date.parse(`${item.content.createdAt}Z`)) / 86400000,
    );
    item.score += Math.max(0, 30 - ageDays);
    if (!item.reasons.length) addReason(item, "内容目录冷启动排序", "cold_start");
  }

  return [...byKey.values()]
    .sort(compareCandidates)
    .slice(0, safeLimit)
    .map((item, index) => ({ ...item, rank: index + 1 }));
}

export function rankingBoard({ period = "weekly", metric = "hot", contentType = "", limit = 30 } = {}) {
  if (!rankingPeriods.has(period)) throw badRequest("ranking period is invalid");
  if (!rankingMetrics.has(metric)) throw badRequest("ranking metric is invalid");
  const days = period === "daily" ? 1 : 7;
  const safeLimit = Math.max(1, Math.min(100, Number(limit) || 30));
  const typeClause = ["novel", "manga", "anime"].includes(contentType)
    ? "AND c.content_type = ?"
    : "";
  const rows = all(
    `SELECT c.*,
       COALESCE(SUM(CASE WHEN d.event_name = 'exposure' THEN d.unique_actors ELSE 0 END), 0) AS exposures,
       COALESCE(SUM(CASE WHEN d.event_name = 'click' THEN d.unique_actors ELSE 0 END), 0) AS clicks,
       COALESCE(SUM(CASE WHEN d.event_name = 'open' THEN d.unique_actors ELSE 0 END), 0) AS opens,
       COALESCE(SUM(CASE WHEN d.event_name = 'start' THEN d.unique_actors ELSE 0 END), 0) AS starts,
       COALESCE(SUM(CASE WHEN d.event_name = 'complete' THEN d.unique_actors ELSE 0 END), 0) AS completes,
       COALESCE(SUM(CASE WHEN d.event_name = 'favorite' THEN d.unique_actors ELSE 0 END), 0) AS favorites
     FROM content_catalog c
     LEFT JOIN content_behavior_daily d ON d.content_key = c.stable_key
       AND date(d.event_date) >= date('now', ?)
     WHERE c.status = 'active' ${typeClause}
     GROUP BY c.stable_key`,
    [`-${days - 1} days`, ...(["novel", "manga", "anime"].includes(contentType) ? [contentType] : [])],
  );
  const controls = rankingControls(`${period}_${metric}`, metric);
  const now = Date.now();
  return rows
    .map((row) => {
      const control = controls.get(row.stable_key) || {};
      const signals = numericSignals(row);
      const ageDays = Math.max(0, (now - Date.parse(`${row.created_at}Z`)) / 86400000);
      let score = 0;
      if (metric === "hot") {
        score = signals.favorites * 14 + signals.completes * 12 + signals.starts * 6 + signals.opens * 3 + signals.clicks * 2;
      } else if (metric === "new") {
        if (ageDays > 45) return null;
        score = Math.max(0, 450 - ageDays * 10) + signals.starts * 5 + signals.favorites * 8;
      } else if (metric === "following") {
        score = signals.favorites * 20 + signals.starts * 4 + signals.opens * 2;
      } else {
        const rate = signals.starts > 0 ? signals.completes / signals.starts : 0;
        score = signals.completes * 18 + Math.min(1, rate) * 100;
      }
      score += Number(control.manualWeight || 0);
      return {
        content: contentJson(row),
        score: roundScore(score),
        pinned: Boolean(control.pinned),
        excluded: Boolean(control.excluded),
        signals: { ...signals, completionRate: signals.starts ? signals.completes / signals.starts : 0 },
        explanation: rankingExplanation(metric),
      };
    })
    .filter((item) => item && !item.excluded)
    .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.score - a.score || a.content.stableKey.localeCompare(b.content.stableKey))
    .slice(0, safeLimit)
    .map((item, index) => ({ ...item, rank: index + 1 }));
}

export function activityFeed({ userId = 0, versionCode = 0 } = {}) {
  const campaigns = all(
    `SELECT * FROM campaigns
     WHERE status = 'active'
       AND (starts_at = '' OR datetime(starts_at) <= datetime('now'))
       AND (ends_at = '' OR datetime(ends_at) > datetime('now'))
       AND (min_version_code = 0 OR min_version_code <= ?)
       AND (max_version_code = 0 OR max_version_code >= ?)
     ORDER BY starts_at DESC, id DESC`,
    [versionCode, versionCode],
  );
  return campaigns
    .filter((campaign) => audienceAllows(campaign.audience_json, userId))
    .map((campaign) => ({
      ...campaignJson(campaign),
      tasks: all(
        `SELECT t.*, COALESCE(p.progress_count, 0) AS progress_count,
                COALESCE(p.completed_at, '') AS completed_at,
                rc.id AS claim_id
         FROM activity_tasks t
         LEFT JOIN user_activity_progress p
           ON p.task_id = t.id AND p.user_id = ?
         LEFT JOIN reward_claims rc
           ON rc.task_id = t.id AND rc.user_id = ?
         WHERE t.campaign_id = ? AND t.status = 'active'
         ORDER BY t.sort_order, t.id`,
        [userId || 0, userId || 0, campaign.id],
      ).map(activityTaskJson),
    }));
}

export function claimActivityReward({ userId, campaignId, taskId, idempotencyKey = "" }) {
  const task = one(
    `SELECT t.*, c.status AS campaign_status, c.starts_at, c.ends_at
     FROM activity_tasks t JOIN campaigns c ON c.id = t.campaign_id
     WHERE t.id = ? AND t.campaign_id = ?`,
    [taskId, campaignId],
  );
  if (!task || task.status !== "active") throw badRequest("activity task not found");
  if (task.campaign_status !== "active" || !dateWindowActive(task.starts_at, task.ends_at)) {
    throw badRequest("campaign is not active");
  }
  const existing = one(
    "SELECT * FROM reward_claims WHERE task_id = ? AND user_id = ?",
    [taskId, userId],
  );
  if (existing) return zeroReward(existing.id, true);

  db.exec("BEGIN IMMEDIATE");
  try {
    const replay = one(
      "SELECT * FROM reward_claims WHERE task_id = ? AND user_id = ?",
      [taskId, userId],
    );
    if (replay) {
      db.exec("COMMIT");
      return zeroReward(replay.id, true);
    }
    const progress = one(
      "SELECT * FROM user_activity_progress WHERE task_id = ? AND user_id = ?",
      [taskId, userId],
    );
    if (!progress || Number(progress.progress_count) < Number(task.target_count)) {
      throw badRequest("activity task is incomplete");
    }
    const result = run(
      `INSERT INTO reward_claims
       (campaign_id, task_id, user_id, points_awarded, coins_awarded, idempotency_key)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [campaignId, taskId, userId, task.reward_points, task.reward_coins, optionalText(idempotencyKey, 120)],
    );
    creditDynamicReward({
      userId,
      points: task.reward_points,
      coins: task.reward_coins,
      action: "activity_reward",
      description: task.title,
      relatedType: "campaign",
      relatedId: String(campaignId),
    });
    db.exec("COMMIT");
    return {
      claimId: Number(result.lastInsertRowid),
      awarded: true,
      idempotentReplay: false,
      points: Number(task.reward_points || 0),
      coins: Number(task.reward_coins || 0),
    };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

export function advanceActivityTasks({ userId, eventName, amount = 1, context = {} }) {
  if (!userId || !activityEventNames.has(eventName)) return 0;
  let advanced = 0;
  const tasks = all(
    `SELECT t.*, c.audience_json, c.min_version_code, c.max_version_code
     FROM activity_tasks t JOIN campaigns c ON c.id = t.campaign_id
     WHERE t.status = 'active' AND t.event_name = ? AND c.status = 'active'
       AND (c.starts_at = '' OR datetime(c.starts_at) <= datetime('now'))
       AND (c.ends_at = '' OR datetime(c.ends_at) > datetime('now'))`,
    [eventName],
  );
  for (const task of tasks) {
    if (!campaignTaskAllows(task, userId, context)) continue;
    if (!activityFilterMatches(task.filters_json, context)) continue;
    run(
      `INSERT INTO user_activity_progress
       (campaign_id, task_id, user_id, progress_count, completed_at)
       VALUES (?, ?, ?, ?, CASE WHEN ? >= ? THEN datetime('now') ELSE '' END)
       ON CONFLICT(campaign_id, task_id, user_id) DO UPDATE SET
         progress_count = MIN(?, user_activity_progress.progress_count + excluded.progress_count),
         completed_at = CASE
           WHEN user_activity_progress.completed_at <> '' THEN user_activity_progress.completed_at
           WHEN user_activity_progress.progress_count + excluded.progress_count >= ? THEN datetime('now')
           ELSE '' END,
         updated_at = datetime('now')`,
      [
        task.campaign_id,
        task.id,
        userId,
        Math.max(1, Number(amount) || 1),
        Math.max(1, Number(amount) || 1),
        task.target_count,
        task.target_count,
        task.target_count,
      ],
    );
    advanced += 1;
  }
  return advanced;
}

export function activeHorseRaceSeason() {
  return one(
    `SELECT * FROM horse_race_seasons
     WHERE status = 'active'
       AND datetime(starts_at) <= datetime('now')
       AND datetime(ends_at) > datetime('now')
     ORDER BY starts_at DESC, id DESC LIMIT 1`,
  );
}

export function recordSeasonSettlement({ roundId, summaries }) {
  const season = activeHorseRaceSeason();
  const config = parseJson(season?.config_json, {});
  let inserted = 0;
  for (const [userIdRaw, summary] of summaries) {
    const userId = Number(userIdRaw);
    const won = Number(summary.payout || 0) > 0 ? 1 : 0;
    const profit = Number(summary.payout || 0) - Number(summary.amount || 0);
    const growthEvent = run(
      `INSERT OR IGNORE INTO horse_race_round_growth_events (round_id, user_id)
       VALUES (?, ?)`,
      [roundId, userId],
    );
    if (Number(growthEvent.changes)) {
      advanceActivityTasks({ userId, eventName: "horse_race_round", amount: 1, context: { roundId } });
      if (won) advanceActivityTasks({ userId, eventName: "horse_race_win", amount: 1, context: { roundId } });
      maybeCreateDailyLossNotice(userId);
    }
    if (!season) continue;
    const points = Math.max(
      1,
      Number(config.participationPoints || 10) +
        (won ? Number(config.winPoints || 20) : 0) +
        Math.min(Number(config.maxProfitBonus || 30), Math.floor(Math.max(0, profit) / 100)),
    );
    const result = run(
      `INSERT OR IGNORE INTO horse_race_season_round_results
       (season_id, round_id, user_id, points_awarded, amount, payout, won)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [season.id, roundId, userId, points, summary.amount, summary.payout, won],
    );
    if (!Number(result.changes)) continue;
    inserted += 1;
    run(
      `INSERT INTO horse_race_season_user_stats
       (season_id, user_id, points, rounds, wins, total_bet, total_payout, tier)
       VALUES (?, ?, ?, 1, ?, ?, ?, ?)
       ON CONFLICT(season_id, user_id) DO UPDATE SET
         points = points + excluded.points,
         rounds = rounds + 1,
         wins = wins + excluded.wins,
         total_bet = total_bet + excluded.total_bet,
         total_payout = total_payout + excluded.total_payout,
         updated_at = datetime('now')`,
      [season.id, userId, points, won, summary.amount, summary.payout, tierForPoints(points, config)],
    );
    const updated = one(
      "SELECT points FROM horse_race_season_user_stats WHERE season_id = ? AND user_id = ?",
      [season.id, userId],
    );
    run(
      "UPDATE horse_race_season_user_stats SET tier = ? WHERE season_id = ? AND user_id = ?",
      [tierForPoints(updated?.points || 0, config), season.id, userId],
    );
    advanceSeasonTasks({ seasonId: season.id, userId, metric: "rounds", amount: 1 });
    advanceSeasonTasks({ seasonId: season.id, userId, metric: "bet", amount: summary.amount });
    if (won) advanceSeasonTasks({ seasonId: season.id, userId, metric: "wins", amount: 1 });
    if (profit > 0) advanceSeasonTasks({ seasonId: season.id, userId, metric: "profit", amount: profit });
  }
  return { seasonId: season?.id || 0, inserted };
}

export function horseRaceSeasonState(userId = 0, limit = 50) {
  const season = activeHorseRaceSeason() || one(
    "SELECT * FROM horse_race_seasons ORDER BY ends_at DESC, id DESC LIMIT 1",
  );
  if (!season) return { season: null, leaderboard: [], myStats: null, tasks: [], rewards: [] };
  const leaderboard = all(
    `SELECT s.*, u.nickname, u.avatar_url
     FROM horse_race_season_user_stats s JOIN users u ON u.id = s.user_id
     WHERE s.season_id = ? AND u.status = 'active'
     ORDER BY s.points DESC, s.wins DESC, s.total_payout DESC, s.user_id ASC LIMIT ?`,
    [season.id, Math.max(1, Math.min(100, Number(limit) || 50))],
  ).map((row, index) => ({ ...seasonStatsJson(row), rank: index + 1 }));
  const myStats = userId
    ? one("SELECT * FROM horse_race_season_user_stats WHERE season_id = ? AND user_id = ?", [season.id, userId])
    : null;
  const tasks = userId
    ? all(
        `SELECT t.*, COALESCE(p.progress_count, 0) AS progress_count,
                COALESCE(p.completed_at, '') AS completed_at,
                COALESCE(p.claimed_at, '') AS claimed_at
         FROM horse_race_season_tasks t LEFT JOIN horse_race_season_task_progress p
           ON p.task_id = t.id AND p.user_id = ?
         WHERE t.season_id = ? AND t.status = 'active'
         ORDER BY t.sort_order, t.id`,
        [userId, season.id],
      ).map(seasonTaskJson)
    : [];
  return {
    season: seasonJson(season),
    leaderboard,
    myStats: myStats ? seasonStatsJson(myStats) : null,
    tasks,
    rewards: all(
      "SELECT * FROM horse_race_season_rewards WHERE season_id = ? AND status = 'active' ORDER BY min_rank, id",
      [season.id],
    ).map(seasonRewardJson),
  };
}

export function claimSeasonTaskReward({ userId, taskId }) {
  const task = one(
    `SELECT t.*, s.status AS season_status, s.starts_at, s.ends_at,
            COALESCE(p.progress_count, 0) AS progress_count,
            COALESCE(p.claimed_at, '') AS claimed_at
     FROM horse_race_season_tasks t
     JOIN horse_race_seasons s ON s.id = t.season_id
     LEFT JOIN horse_race_season_task_progress p
       ON p.task_id = t.id AND p.user_id = ?
     WHERE t.id = ?`,
    [userId, taskId],
  );
  if (!task || task.status !== "active") throw badRequest("season task not found");
  if (Number(task.progress_count || 0) < Number(task.target_count || 1)) {
    throw badRequest("season task is incomplete");
  }
  if (task.claimed_at) return zeroReward(0, true);
  db.exec("BEGIN IMMEDIATE");
  try {
    const updated = run(
      `UPDATE horse_race_season_task_progress SET claimed_at = datetime('now')
       WHERE task_id = ? AND user_id = ? AND claimed_at = ''`,
      [taskId, userId],
    );
    if (!Number(updated.changes)) {
      db.exec("COMMIT");
      return zeroReward(0, true);
    }
    creditDynamicReward({
      userId,
      points: task.reward_points,
      coins: task.reward_coins,
      action: "horse_race_season_task",
      description: task.title,
      relatedType: "horse_race_season",
      relatedId: String(task.season_id),
    });
    db.exec("COMMIT");
    return {
      awarded: true,
      idempotentReplay: false,
      points: Number(task.reward_points || 0),
      coins: Number(task.reward_coins || 0),
    };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

export function finalizeHorseRaceSeason(seasonId) {
  const season = one("SELECT * FROM horse_race_seasons WHERE id = ?", [seasonId]);
  if (!season) throw badRequest("season not found");
  db.exec("BEGIN IMMEDIATE");
  try {
    const stats = all(
      `SELECT s.*, ROW_NUMBER() OVER (
         ORDER BY s.points DESC, s.wins DESC, s.total_payout DESC, s.user_id ASC
       ) AS rank
       FROM horse_race_season_user_stats s WHERE s.season_id = ?`,
      [seasonId],
    );
    const rewards = all(
      "SELECT * FROM horse_race_season_rewards WHERE season_id = ? AND status = 'active' ORDER BY id",
      [seasonId],
    );
    let awarded = 0;
    for (const stat of stats) {
      for (const reward of rewards) {
        if (reward.tier && reward.tier !== stat.tier) continue;
        if (Number(reward.min_rank || 0) > 0 && Number(stat.rank) < Number(reward.min_rank)) continue;
        if (Number(reward.max_rank || 0) > 0 && Number(stat.rank) > Number(reward.max_rank)) continue;
        const claim = run(
          `INSERT OR IGNORE INTO horse_race_season_reward_claims
           (season_id, reward_id, user_id, points_awarded, coins_awarded)
           VALUES (?, ?, ?, ?, ?)`,
          [seasonId, reward.id, stat.user_id, reward.reward_points, reward.reward_coins],
        );
        if (!Number(claim.changes)) continue;
        awarded += 1;
        creditDynamicReward({
          userId: stat.user_id,
          points: reward.reward_points,
          coins: reward.reward_coins,
          action: "horse_race_season_reward",
          description: reward.title,
          relatedType: "horse_race_season",
          relatedId: String(seasonId),
        });
      }
    }
    run(
      "UPDATE horse_race_seasons SET status = 'ended', updated_at = datetime('now') WHERE id = ?",
      [seasonId],
    );
    db.exec("COMMIT");
    return { seasonId: Number(seasonId), awarded };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

export function responsibleGamingState(userId) {
  const settings = one(
    "SELECT * FROM horse_race_responsible_settings WHERE user_id = ?",
    [userId],
  ) || {};
  const totals = dailyHorseRaceTotals(userId);
  return {
    cooldownUntil: settings.cooldown_until || "",
    selfExcludedUntil: settings.self_excluded_until || "",
    dailyBetLimit: Number(settings.daily_bet_limit || 0),
    dailyLossLimit: Number(settings.daily_loss_limit || 0),
    reminderLossThreshold: Number(settings.reminder_loss_threshold || 500),
    todayBet: totals.bet,
    todayPayout: totals.payout,
    todayLoss: Math.max(0, totals.bet - totals.payout),
  };
}

export function updateResponsibleGaming(userId, body) {
  const current = responsibleGamingState(userId);
  const dailyBetLimit = boundedOptionalLimit(body.dailyBetLimit, current.dailyBetLimit, 20_000);
  const dailyLossLimit = boundedOptionalLimit(body.dailyLossLimit, current.dailyLossLimit, 20_000);
  const reminderLossThreshold = boundedOptionalLimit(
    body.reminderLossThreshold,
    current.reminderLossThreshold,
    20_000,
    1,
  );
  run(
    `INSERT INTO horse_race_responsible_settings
     (user_id, daily_bet_limit, daily_loss_limit, reminder_loss_threshold)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       daily_bet_limit = excluded.daily_bet_limit,
       daily_loss_limit = excluded.daily_loss_limit,
       reminder_loss_threshold = excluded.reminder_loss_threshold,
       updated_at = datetime('now')`,
    [userId, dailyBetLimit, dailyLossLimit, reminderLossThreshold],
  );
  return responsibleGamingState(userId);
}

export function startHorseRaceCooldown(userId, hoursValue) {
  const hours = Math.max(1, Math.min(720, Math.trunc(Number(hoursValue) || 24)));
  const requested = new Date(Date.now() + hours * 3600000).toISOString().slice(0, 19).replace("T", " ");
  run(
    `INSERT INTO horse_race_responsible_settings (user_id, cooldown_until)
     VALUES (?, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       cooldown_until = CASE WHEN cooldown_until > excluded.cooldown_until THEN cooldown_until ELSE excluded.cooldown_until END,
       updated_at = datetime('now')`,
    [userId, requested],
  );
  return responsibleGamingState(userId);
}

export function startHorseRaceSelfExclusion(userId, daysValue) {
  const days = Math.max(1, Math.min(3650, Math.trunc(Number(daysValue) || 7)));
  const requested = new Date(Date.now() + days * 86400000).toISOString().slice(0, 19).replace("T", " ");
  run(
    `INSERT INTO horse_race_responsible_settings (user_id, self_excluded_until)
     VALUES (?, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       self_excluded_until = CASE WHEN self_excluded_until > excluded.self_excluded_until THEN self_excluded_until ELSE excluded.self_excluded_until END,
       updated_at = datetime('now')`,
    [userId, requested],
  );
  return responsibleGamingState(userId);
}

export function assertHorseRaceBetAllowed({ userId, additionalAmount }) {
  const settings = responsibleGamingState(userId);
  const nowSql = new Date().toISOString().slice(0, 19).replace("T", " ");
  if (settings.selfExcludedUntil && settings.selfExcludedUntil > nowSql) {
    throw badRequest("horse_race_self_excluded");
  }
  if (settings.cooldownUntil && settings.cooldownUntil > nowSql) {
    throw badRequest("horse_race_cooldown_active");
  }
  if (settings.dailyBetLimit > 0 && settings.todayBet + Number(additionalAmount || 0) > settings.dailyBetLimit) {
    throw badRequest("horse_race_self_daily_bet_limit");
  }
  if (
    settings.dailyLossLimit > 0 &&
    settings.todayLoss + Number(additionalAmount || 0) > settings.dailyLossLimit
  ) {
    throw badRequest("horse_race_self_daily_loss_limit");
  }
  return settings;
}

export function acquireServiceLease(leaseKey, { ownerId = processOwnerId, leaseMs = 5000, now = Date.now() } = {}) {
  const key = normalizedIdentifier(leaseKey, "leaseKey", 120);
  const until = now + Math.max(1000, Math.min(60000, Number(leaseMs) || 5000));
  db.exec("BEGIN IMMEDIATE");
  try {
    const current = one("SELECT * FROM service_leases WHERE lease_key = ?", [key]);
    if (current && current.owner_id !== ownerId && Number(current.lease_until_ms) > now) {
      db.exec("COMMIT");
      return false;
    }
    run(
      `INSERT INTO service_leases (lease_key, owner_id, lease_until_ms)
       VALUES (?, ?, ?)
       ON CONFLICT(lease_key) DO UPDATE SET
         owner_id = excluded.owner_id,
         lease_until_ms = excluded.lease_until_ms,
         updated_at = datetime('now')`,
      [key, ownerId, until],
    );
    db.exec("COMMIT");
    return true;
  } catch (error) {
    safeRollback();
    throw error;
  }
}

export function releaseServiceLease(leaseKey, ownerId = processOwnerId) {
  return Number(run(
    "DELETE FROM service_leases WHERE lease_key = ? AND owner_id = ?",
    [leaseKey, ownerId],
  ).changes || 0) > 0;
}

export function growthLeaderOwnerId() {
  return processOwnerId;
}

export function funnelAnalytics({ days = 7, contentType = "" } = {}) {
  const safeDays = Math.max(1, Math.min(90, Number(days) || 7));
  const typeClause = ["novel", "manga", "anime"].includes(contentType)
    ? "AND content_type = ?"
    : "";
  const params = [`-${safeDays - 1} days`, ...(["novel", "manga", "anime"].includes(contentType) ? [contentType] : [])];
  const totals = Object.fromEntries(
    all(
      `SELECT event_name, SUM(event_count) AS events, SUM(unique_actors) AS actors
       FROM content_behavior_daily
       WHERE date(event_date) >= date('now', ?) ${typeClause}
       GROUP BY event_name`,
      params,
    ).map((row) => [row.event_name, { events: Number(row.events || 0), actors: Number(row.actors || 0) }]),
  );
  const order = ["exposure", "click", "open", "start", "complete", "favorite"];
  return {
    days: safeDays,
    steps: order.map((event, index) => {
      const current = totals[event] || { events: 0, actors: 0 };
      const previous = index ? totals[order[index - 1]] || { actors: 0 } : null;
      return {
        event,
        ...current,
        conversionFromPrevious: previous?.actors ? current.actors / previous.actors : null,
      };
    }),
    content: all(
      `SELECT d.content_key, c.title, c.content_type,
              SUM(CASE WHEN d.event_name = 'exposure' THEN d.unique_actors ELSE 0 END) AS exposures,
              SUM(CASE WHEN d.event_name = 'open' THEN d.unique_actors ELSE 0 END) AS opens,
              SUM(CASE WHEN d.event_name = 'start' THEN d.unique_actors ELSE 0 END) AS starts,
              SUM(CASE WHEN d.event_name = 'complete' THEN d.unique_actors ELSE 0 END) AS completes
       FROM content_behavior_daily d JOIN content_catalog c ON c.stable_key = d.content_key
       WHERE date(d.event_date) >= date('now', ?) ${typeClause.replace("content_type", "c.content_type")}
       GROUP BY d.content_key ORDER BY starts DESC, opens DESC LIMIT 100`,
      params,
    ).map((row) => ({
      contentKey: row.content_key,
      title: row.title,
      contentType: row.content_type,
      exposures: Number(row.exposures || 0),
      opens: Number(row.opens || 0),
      starts: Number(row.starts || 0),
      completes: Number(row.completes || 0),
      openRate: Number(row.exposures) ? Number(row.opens) / Number(row.exposures) : 0,
      completionRate: Number(row.starts) ? Number(row.completes) / Number(row.starts) : 0,
    })),
    retention: retentionSummary(safeDays),
  };
}

function aggregateBehavior({ eventDate, contentKey, contentType, eventName, actorKey }) {
  const actor = one(
    `SELECT accepted_count FROM content_behavior_daily_actors
     WHERE event_date = ? AND content_key = ? AND event_name = ? AND actor_key = ?`,
    [eventDate, contentKey, eventName, actorKey],
  );
  if (Number(actor?.accepted_count || 0) >= aggregateCaps[eventName]) return false;
  const firstActorEvent = !actor;
  run(
    `INSERT INTO content_behavior_daily_actors
     (event_date, content_key, event_name, actor_key, accepted_count)
     VALUES (?, ?, ?, ?, 1)
     ON CONFLICT(event_date, content_key, event_name, actor_key) DO UPDATE SET
       accepted_count = accepted_count + 1,
       updated_at = datetime('now')`,
    [eventDate, contentKey, eventName, actorKey],
  );
  run(
    `INSERT INTO content_behavior_daily
     (event_date, content_key, content_type, event_name, event_count, unique_actors)
     VALUES (?, ?, ?, ?, 1, ?)
     ON CONFLICT(event_date, content_key, event_name) DO UPDATE SET
       event_count = event_count + 1,
       unique_actors = unique_actors + excluded.unique_actors,
       updated_at = datetime('now')`,
    [eventDate, contentKey, contentType, eventName, firstActorEvent ? 1 : 0],
  );
  return true;
}

function advanceSeasonTasks({ seasonId, userId, metric, amount }) {
  const tasks = all(
    "SELECT * FROM horse_race_season_tasks WHERE season_id = ? AND metric = ? AND status = 'active'",
    [seasonId, metric],
  );
  for (const task of tasks) {
    run(
      `INSERT INTO horse_race_season_task_progress
       (season_id, task_id, user_id, progress_count, completed_at)
       VALUES (?, ?, ?, ?, CASE WHEN ? >= ? THEN datetime('now') ELSE '' END)
       ON CONFLICT(task_id, user_id) DO UPDATE SET
         progress_count = MIN(?, horse_race_season_task_progress.progress_count + excluded.progress_count),
         completed_at = CASE
           WHEN horse_race_season_task_progress.completed_at <> '' THEN horse_race_season_task_progress.completed_at
           WHEN horse_race_season_task_progress.progress_count + excluded.progress_count >= ? THEN datetime('now')
           ELSE '' END`,
      [seasonId, task.id, userId, amount, amount, task.target_count, task.target_count, task.target_count],
    );
  }
}

function maybeCreateDailyLossNotice(userId) {
  const settings = responsibleGamingState(userId);
  if (settings.todayLoss < settings.reminderLossThreshold) return false;
  const day = new Date().toISOString().slice(0, 10);
  const result = run(
    `INSERT OR IGNORE INTO horse_race_responsible_notices
     (user_id, notice_date, notice_type, amount) VALUES (?, ?, 'daily_loss', ?)`,
    [userId, day, settings.todayLoss],
  );
  if (!Number(result.changes)) return false;
  run(
    `INSERT INTO system_notifications (user_id, title, content, category)
     VALUES (?, '赛马理性参与提醒', ?, 'horse_race_responsible')`,
    [userId, `你今天在赛马玩法中的净支出已达到 ${settings.todayLoss} 樱花币。建议暂停参与，或开启冷静期和每日限额。`],
  );
  return true;
}

function dailyHorseRaceTotals(userId) {
  const dayStart = Math.floor((Date.now() + 8 * 3600000) / 86400000) * 86400000 - 8 * 3600000;
  const row = one(
    `SELECT COALESCE(SUM(b.amount), 0) AS bet,
            COALESCE(SUM(CASE WHEN b.status <> 'pending' THEN b.payout ELSE 0 END), 0) AS payout
     FROM horse_race_bets b JOIN horse_race_rounds r ON r.id = b.round_id
     WHERE b.user_id = ? AND r.phase_started_at >= ? AND r.phase_started_at < ?`,
    [userId, dayStart, dayStart + 86400000],
  );
  return { bet: Number(row?.bet || 0), payout: Number(row?.payout || 0) };
}

function creditDynamicReward({ userId, points, coins, action, description, relatedType, relatedId }) {
  const safePoints = Math.max(0, Math.trunc(Number(points) || 0));
  const safeCoins = Math.max(0, Math.trunc(Number(coins) || 0));
  const user = one("SELECT points FROM users WHERE id = ?", [userId]);
  if (!user) throw badRequest("user not found");
  run(
    `INSERT INTO user_reward_events
     (user_id, action, points_delta, coins_delta, description, related_type, related_id)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [userId, action, safePoints, safeCoins, description, relatedType, relatedId],
  );
  run(
    `UPDATE users SET points = points + ?, sakura_coins = sakura_coins + ?,
       level = ?, updated_at = datetime('now') WHERE id = ?`,
    [safePoints, safeCoins, levelFromPoints(Number(user.points || 0) + safePoints), userId],
  );
}

function rankingControls(...keys) {
  const rows = all(
    `SELECT * FROM content_ranking_controls
     WHERE ranking_key IN (${["all", ...keys].map(() => "?").join(",")})
     ORDER BY CASE WHEN ranking_key = 'all' THEN 0 ELSE 1 END`,
    ["all", ...keys],
  );
  const result = new Map();
  for (const row of rows) {
    const current = result.get(row.content_key) || {};
    result.set(row.content_key, {
      pinned: Boolean(row.pinned) || Boolean(current.pinned),
      excluded: Boolean(row.excluded) || Boolean(current.excluded),
      manualWeight: Number(current.manualWeight || 0) + Number(row.manual_weight || 0),
    });
  }
  return result;
}

function retentionSummary(days) {
  const cohorts = all(
    `WITH first_seen AS (
       SELECT actor_key, MIN(date(occurred_at)) AS cohort_date
       FROM content_behavior_events
       WHERE occurred_at >= datetime('now', ?)
       GROUP BY actor_key
     )
     SELECT f.cohort_date,
            COUNT(*) AS cohort_size,
            COUNT(DISTINCT CASE WHEN date(e.occurred_at) = date(f.cohort_date, '+1 day') THEN f.actor_key END) AS day1,
            COUNT(DISTINCT CASE WHEN date(e.occurred_at) = date(f.cohort_date, '+7 day') THEN f.actor_key END) AS day7
     FROM first_seen f LEFT JOIN content_behavior_events e ON e.actor_key = f.actor_key
     GROUP BY f.cohort_date ORDER BY f.cohort_date DESC`,
    [`-${Math.max(8, days)} days`],
  );
  return cohorts.map((row) => ({
    cohortDate: row.cohort_date,
    cohortSize: Number(row.cohort_size || 0),
    day1: Number(row.day1 || 0),
    day7: Number(row.day7 || 0),
    day1Rate: Number(row.cohort_size) ? Number(row.day1) / Number(row.cohort_size) : 0,
    day7Rate: Number(row.cohort_size) ? Number(row.day7) / Number(row.cohort_size) : 0,
  }));
}

function telemetryBehavior(eventName, raw) {
  const name = String(eventName || "").toLowerCase();
  if (name === "content_exposure") return "exposure";
  if (name === "content_click") return "click";
  if (["content_open", "detail_open"].includes(name)) return "open";
  if (["video_start", "reading_start", "content_start"].includes(name) && raw?.success !== false) return "start";
  if (["content_complete", "reading_complete", "video_complete"].includes(name)) return "complete";
  if (["favorite_add", "bookshelf_add"].includes(name)) return "favorite";
  return null;
}

function enforceBehaviorRate(ip, installId) {
  const install = consumeRateLimit({ scope: "behavior-install", key: installId, limit: 120, windowMs: 60000 });
  const address = consumeRateLimit({ scope: "behavior-ip", key: String(ip || "unknown"), limit: 300, windowMs: 60000 });
  if (install.limited || address.limited) {
    const error = new Error("behavior_rate_limited");
    error.statusCode = 429;
    throw error;
  }
}

function assertBehaviorReplay(existing, expected) {
  if (
    Number(existing.user_id || 0) !== Number(expected.userId || 0) ||
    existing.install_id !== expected.installId ||
    existing.session_id !== expected.sessionId ||
    existing.content_key !== expected.contentKey ||
    existing.event_name !== expected.eventName ||
    existing.source !== expected.source
  ) {
    const error = new Error("behavior_event_id_conflict");
    error.statusCode = 409;
    throw error;
  }
}

let lastGrowthPrunedAt = 0;
function pruneGrowthData() {
  const now = Date.now();
  if (now - lastGrowthPrunedAt < 60 * 60 * 1000) return;
  lastGrowthPrunedAt = now;
  run("DELETE FROM content_behavior_events WHERE occurred_at < datetime('now', '-180 days')");
  run("DELETE FROM content_behavior_daily WHERE date(event_date) < date('now', '-400 days')");
  run("DELETE FROM content_behavior_daily_actors WHERE date(event_date) < date('now', '-400 days')");
  run("DELETE FROM service_leases WHERE lease_until_ms < ?", [now - 86400000]);
}

function candidate(row) {
  return {
    content: contentJson(row),
    score: 0,
    continueProgress: false,
    reasons: [],
    reasonCodes: [],
    signals: numericSignals(row),
  };
}

function addReason(item, text, code) {
  if (!item.reasonCodes.includes(code)) {
    item.reasonCodes.push(code);
    item.reasons.push(text);
  }
}

function compareCandidates(left, right) {
  return Number(right.continueProgress) - Number(left.continueProgress) ||
    right.score - left.score ||
    left.content.stableKey.localeCompare(right.content.stableKey);
}

function numericSignals(row) {
  return {
    exposures: Number(row.exposures || 0),
    clicks: Number(row.clicks || 0),
    opens: Number(row.opens || 0),
    starts: Number(row.starts || 0),
    completes: Number(row.completes || 0),
    favorites: Number(row.favorites || 0),
  };
}

function contentJson(row) {
  return {
    stableKey: row.stable_key,
    contentType: row.content_type,
    sourceKey: row.source_key,
    sourceItemId: row.source_item_id,
    title: row.title,
    author: row.author,
    coverUrl: row.cover_url,
    metadata: parseJson(row.metadata_json, {}),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function campaignJson(row) {
  return {
    id: row.id,
    campaignKey: row.campaign_key,
    title: row.title,
    description: row.description,
    bannerUrl: row.banner_url,
    status: row.status,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    audience: parseJson(row.audience_json, {}),
    minVersionCode: Number(row.min_version_code || 0),
    maxVersionCode: Number(row.max_version_code || 0),
    revision: Number(row.revision || 1),
  };
}

function activityTaskJson(row) {
  return {
    id: row.id,
    taskKey: row.task_key,
    title: row.title,
    description: row.description,
    eventName: row.event_name,
    targetCount: Number(row.target_count || 1),
    progressCount: Math.min(Number(row.target_count || 1), Number(row.progress_count || 0)),
    completed: Boolean(row.completed_at),
    claimed: Boolean(row.claim_id),
    reward: { points: Number(row.reward_points || 0), coins: Number(row.reward_coins || 0) },
  };
}

function seasonJson(row) {
  return {
    id: row.id,
    seasonKey: row.season_key,
    title: row.title,
    status: row.status,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    config: parseJson(row.config_json, {}),
    revision: Number(row.revision || 1),
  };
}

function seasonStatsJson(row) {
  return {
    userId: row.user_id,
    nickname: row.nickname || "",
    avatarUrl: row.avatar_url || "",
    points: Number(row.points || 0),
    rounds: Number(row.rounds || 0),
    wins: Number(row.wins || 0),
    totalBet: Number(row.total_bet || 0),
    totalPayout: Number(row.total_payout || 0),
    tier: row.tier || "bronze",
  };
}

function seasonTaskJson(row) {
  return {
    id: row.id,
    taskKey: row.task_key,
    title: row.title,
    metric: row.metric,
    targetCount: Number(row.target_count || 1),
    progressCount: Math.min(Number(row.target_count || 1), Number(row.progress_count || 0)),
    completed: Boolean(row.completed_at),
    claimed: Boolean(row.claimed_at),
    reward: { points: Number(row.reward_points || 0), coins: Number(row.reward_coins || 0) },
  };
}

function seasonRewardJson(row) {
  return {
    id: row.id,
    rewardKey: row.reward_key,
    title: row.title,
    tier: row.tier,
    minRank: Number(row.min_rank || 0),
    maxRank: Number(row.max_rank || 0),
    reward: { points: Number(row.reward_points || 0), coins: Number(row.reward_coins || 0) },
  };
}

function tierForPoints(pointsValue, config) {
  const points = Number(pointsValue || 0);
  const tiers = Array.isArray(config.tiers) && config.tiers.length
    ? config.tiers
    : [
        { key: "bronze", points: 0 },
        { key: "silver", points: 300 },
        { key: "gold", points: 900 },
        { key: "platinum", points: 2000 },
        { key: "diamond", points: 5000 },
      ];
  return [...tiers]
    .sort((a, b) => Number(a.points || 0) - Number(b.points || 0))
    .reduce((tier, item) => points >= Number(item.points || 0) ? String(item.key || tier) : tier, "bronze");
}

function activityFilterMatches(value, context) {
  const filters = parseJson(value, {});
  if (filters.contentType && filters.contentType !== context.contentType) return false;
  if (filters.contentKey && filters.contentKey !== context.contentKey) return false;
  return true;
}

function campaignTaskAllows(task, userId, context) {
  if (!audienceAllows(task.audience_json, userId)) return false;
  let versionCode = Number(context.versionCode || 0);
  if (!versionCode) {
    versionCode = Number(one(
      `SELECT version_code FROM user_app_installs
       WHERE user_id = ? ORDER BY last_seen_at DESC, id DESC LIMIT 1`,
      [userId],
    )?.version_code || 0);
  }
  if (Number(task.min_version_code || 0) > 0 && versionCode < Number(task.min_version_code)) {
    return false;
  }
  if (Number(task.max_version_code || 0) > 0 && versionCode > Number(task.max_version_code)) {
    return false;
  }
  return true;
}

function audienceAllows(value, userId) {
  const audience = parseJson(value, {});
  if (audience.loggedIn === true && !userId) return false;
  if (audience.loggedIn === false && userId) return false;
  if (Array.isArray(audience.userIds) && audience.userIds.length) {
    if (!audience.userIds.map(Number).includes(Number(userId))) return false;
  }
  if (Array.isArray(audience.segments) && audience.segments.length) {
    if (!userId || !audience.segments.some((segment) => userMatchesSegment(userId, segment))) return false;
  }
  return true;
}

function userMatchesSegment(userId, segmentValue) {
  const segment = String(segmentValue || "").toLowerCase();
  if (segment === "new_users") {
    return Boolean(one(
      "SELECT 1 FROM users WHERE id = ? AND created_at >= datetime('now', '-7 days')",
      [userId],
    ));
  }
  if (segment === "active_users") {
    return Boolean(one(
      `SELECT 1 FROM content_behavior_events
       WHERE user_id = ? AND occurred_at >= datetime('now', '-30 days') LIMIT 1`,
      [userId],
    ));
  }
  if (segment === "race_players") {
    return Boolean(one("SELECT 1 FROM horse_race_bets WHERE user_id = ? LIMIT 1", [userId]));
  }
  if (segment === "readers") {
    return Boolean(one(
      `SELECT 1 FROM content_behavior_events
       WHERE user_id = ? AND content_type IN ('novel', 'manga') LIMIT 1`,
      [userId],
    ));
  }
  if (segment === "anime_viewers") {
    return Boolean(one(
      `SELECT 1 FROM content_behavior_events
       WHERE user_id = ? AND content_type = 'anime' LIMIT 1`,
      [userId],
    ));
  }
  return false;
}

function placementAudienceMatches(value, context) {
  const audience = parseJson(value, {});
  if (audience.loggedIn === true && !context.userId) return false;
  if (audience.loggedIn === false && context.userId) return false;
  if (Number(audience.minVersionCode || 0) > Number(context.versionCode || 0)) return false;
  if (
    Number(audience.maxVersionCode || 0) > 0 &&
    Number(context.versionCode || 0) > Number(audience.maxVersionCode)
  ) return false;
  if (
    Array.isArray(audience.platforms) &&
    audience.platforms.length &&
    !audience.platforms.map((item) => String(item).toLowerCase()).includes(context.platform)
  ) return false;
  const percentage = Number(audience.percentage ?? 100);
  if (percentage <= 0) return false;
  if (percentage >= 100) return true;
  const bucket = Number.parseInt(sha256(`${context.salt}|${context.identity}`).slice(0, 8), 16) % 100;
  return bucket < percentage;
}

function rankingExplanation(metric) {
  if (metric === "new") return "新作时效、真实开始阅读/观看与收藏综合排序";
  if (metric === "following") return "去重收藏用户为主，结合开始和打开人数排序";
  if (metric === "completion") return "去重完读/完播人数与完成率综合排序";
  return "近期开启、开始、完成和收藏的去重用户综合排序";
}

function contentTypeLabel(type) {
  return type === "novel" ? "小说" : type === "manga" ? "漫画" : "动漫";
}

function zeroReward(claimId, replay) {
  return { claimId: Number(claimId || 0), awarded: false, idempotentReplay: replay, points: 0, coins: 0 };
}

function dateWindowActive(startsAt, endsAt) {
  const now = Date.now();
  return (!startsAt || Date.parse(`${startsAt}Z`) <= now) && (!endsAt || Date.parse(`${endsAt}Z`) > now);
}

function boundedOptionalLimit(value, fallback, maximum, minimum = 10) {
  if (value === undefined) return Number(fallback || 0);
  const number = Math.trunc(Number(value));
  if (!Number.isFinite(number) || number < 0 || number > maximum || (number > 0 && number < minimum)) {
    throw badRequest("responsible gaming limit is invalid");
  }
  return number;
}

function normalizedOccurredAt(value) {
  const parsed = new Date(String(value || ""));
  const date = Number.isFinite(parsed.getTime()) ? parsed : new Date();
  if (date.getTime() > Date.now() + 5 * 60000 || date.getTime() < Date.now() - 30 * 86400000) {
    throw badRequest("occurredAt is outside accepted window");
  }
  return date.toISOString().slice(0, 19).replace("T", " ");
}

function normalizedIdentifier(value, name, maxLength, allowColon = false) {
  const text = String(value || "").trim();
  const pattern = allowColon ? /^[A-Za-z0-9._:/-]+$/ : /^[A-Za-z0-9._:-]+$/;
  if (!text || text.length > maxLength || !pattern.test(text)) throw badRequest(`${name} is invalid`);
  return text;
}

function optionalText(value, maxLength) {
  return String(value || "").trim().slice(0, maxLength);
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function parseJson(value, fallback) {
  try {
    const parsed = JSON.parse(String(value || ""));
    return parsed ?? fallback;
  } catch {
    return fallback;
  }
}

function roundScore(value) {
  return Math.round(Number(value || 0) * 100) / 100;
}

function safeRollback() {
  try {
    db.exec("ROLLBACK");
  } catch {
    // No active transaction.
  }
}
