import { createHash } from "node:crypto";

import { all, db, one, run } from "./db.js";
import { finalizeHorseRaceSeason } from "./growth-operations.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const roundStatuses = new Set(["betting", "locked", "racing", "settling"]);
const betStatuses = new Set(["pending", "won", "lost"]);
const seasonStatuses = new Set(["draft", "active", "paused", "ended"]);
const seasonMetrics = new Set(["rounds", "wins", "bet", "profit"]);
const taskStatuses = new Set(["active", "disabled"]);
const rewardStatuses = new Set(["active", "disabled"]);
const defaultTiers = Object.freeze([
  { key: "bronze", points: 0 },
  { key: "silver", points: 300 },
  { key: "gold", points: 900 },
  { key: "platinum", points: 2000 },
  { key: "diamond", points: 5000 },
]);
const activeUserPredicate = `
  u.role = 'user'
  AND u.status = 'active'
  AND lower(u.email) NOT IN ('chatbot@system.local', 'chat-bot@system.local')`;

export function horseRaceOperationsWorkbench() {
  const currentRound = latestHorseRaceRoundSummary();
  const recentRounds = all(
    `${roundSummarySql()} ORDER BY r.id DESC LIMIT 20`,
  );
  const recentIntegrity = recentRounds.map(roundIntegrity);
  const finance24h = one(
    `SELECT COUNT(*) AS bet_count,
            COUNT(DISTINCT b.user_id) AS participants,
            COALESCE(SUM(b.amount), 0) AS staked,
            COALESCE(SUM(b.payout), 0) AS payout
     FROM horse_race_bets b
     WHERE b.created_at >= datetime('now', '-24 hours')`,
  ) || {};
  const roundCounts = Object.fromEntries(
    all("SELECT status, COUNT(*) AS total FROM horse_race_rounds GROUP BY status")
      .map((row) => [row.status, Number(row.total || 0)]),
  );
  const activeSeason = one(
    `${seasonSummarySql()} WHERE s.status = 'active'
     ORDER BY s.starts_at DESC, s.id DESC LIMIT 1`,
  );
  const lease = one(
    "SELECT * FROM service_leases WHERE lease_key = 'horse-race-ticker'",
  );
  return {
    generatedAt: new Date().toISOString(),
    currentRound,
    service: serviceLeaseJson(lease),
    finance24h: {
      betCount: Number(finance24h.bet_count || 0),
      participants: Number(finance24h.participants || 0),
      totalStaked: Number(finance24h.staked || 0),
      totalPayout: Number(finance24h.payout || 0),
      houseNet: Number(finance24h.staked || 0) - Number(finance24h.payout || 0),
    },
    rounds: {
      total: Number(one("SELECT COUNT(*) AS total FROM horse_race_rounds")?.total || 0),
      betting: Number(roundCounts.betting || 0),
      locked: Number(roundCounts.locked || 0),
      racing: Number(roundCounts.racing || 0),
      settled: Number(roundCounts.settling || 0),
      recentWarnings: recentIntegrity.filter((item) => item.status === "warning").length,
      recentErrors: recentIntegrity.filter((item) => item.status === "error").length,
    },
    season: activeSeason ? seasonAdminJson(activeSeason) : null,
    responsibleGaming: responsibleGamingOverview(),
    rules: raceRuleSummary(),
    options: raceOperationOptions(),
  };
}

export function latestHorseRaceRoundSummary() {
  const latestRound = one(
    `${roundSummarySql()} ORDER BY r.id DESC LIMIT 1`,
  );
  return latestRound ? roundAdminJson(latestRound) : null;
}

export function adminHorseRaceRounds(query = {}) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 80);
  const status = optionalString(query.status, 30).toLowerCase();
  if (status && !roundStatuses.has(status)) throw badRequest("race_round_status_invalid");
  const integrity = optionalString(query.integrity, 20).toLowerCase();
  if (integrity && !new Set(["healthy", "warning", "error"]).has(integrity)) {
    throw badRequest("race_round_integrity_invalid");
  }
  const where = [];
  const params = [];
  if (keyword) {
    where.push("r.round_key LIKE ?");
    params.push(`%${keyword}%`);
  }
  if (status) {
    where.push("r.status = ?");
    params.push(status);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const matchingIntegrity = integrity
    ? all(
        `${roundSummarySql()} ${clause} ORDER BY r.id DESC`,
        params,
      ).map(roundAdminJson).filter((item) => item.integrity.status === integrity)
    : null;
  const items = matchingIntegrity
    ? matchingIntegrity.slice(offset, offset + pageSize)
    : all(
        `${roundSummarySql()} ${clause}
         ORDER BY r.id DESC LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(roundAdminJson);
  return {
    generatedAt: new Date().toISOString(),
    page,
    pageSize,
    total: matchingIntegrity
      ? matchingIntegrity.length
      : Number(one(
          `SELECT COUNT(*) AS total FROM horse_race_rounds r ${clause}`,
          params,
        )?.total || 0),
    items,
    options: raceOperationOptions(),
  };
}

export function adminHorseRaceRoundDetail(idValue, query = {}) {
  const id = positiveId(idValue, "roundId");
  const round = one(`${roundSummarySql()} WHERE r.id = ?`, [id]);
  if (!round) throw notFound("race_round_not_found");
  const horses = parseJsonArray(round.horses_json);
  const settled = isSettledRound(round);
  const totalsByHorse = new Map(all(
    `SELECT horse_index, COUNT(*) AS bet_count,
            COUNT(DISTINCT user_id) AS participants,
            COALESCE(SUM(amount), 0) AS total_staked,
            COALESCE(SUM(payout), 0) AS total_payout
     FROM horse_race_bets WHERE round_id = ?
     GROUP BY horse_index ORDER BY horse_index`,
    [id],
  ).map((row) => [Number(row.horse_index), row]));
  const horseTotals = horses.map((horse, index) => {
    const totals = totalsByHorse.get(index) || {};
    return {
      index,
      name: horse?.name || `#${index + 1}`,
      color: horse?.color || "",
      betCount: Number(totals.bet_count || 0),
      participants: Number(totals.participants || 0),
      totalStaked: Number(totals.total_staked || 0),
      totalPayout: Number(totals.total_payout || 0),
    };
  });
  return {
    generatedAt: new Date().toISOString(),
    item: {
      ...roundAdminJson(round),
      horses,
      odds: parseJsonArray(round.odds_json),
      race: parseJsonObject(round.race_json),
      result: settled ? parseJsonObject(round.result_json) : {},
      fairness: {
        algorithm: Number(round.rules_version || 1) >= 2
          ? "seed-commit-v1"
          : "legacy-seed-v1",
        seedCommit: round.seed_commit || sha256(round.seed || ""),
        seedReveal: settled ? round.seed || "" : "",
        revealVerified: settled
          ? Boolean(round.seed && round.seed_commit === sha256(round.seed))
          : null,
      },
      horseTotals,
    },
    bets: roundBets(id, query),
    rules: raceRuleSummary(Number(round.rules_version || 1)),
    options: raceOperationOptions(),
  };
}

export function raceSeasonList(query = {}) {
  const { page, pageSize, offset } = pageParams(query);
  const status = optionalString(query.status, 30).toLowerCase();
  if (status && !seasonStatuses.has(status)) throw badRequest("race_season_status_invalid");
  const keyword = optionalString(query.q, 120);
  const where = [];
  const params = [];
  if (status) {
    where.push("s.status = ?");
    params.push(status);
  }
  if (keyword) {
    where.push("(s.title LIKE ? OR s.season_key LIKE ? OR s.description LIKE ?)");
    const like = `%${keyword}%`;
    params.push(like, like, like);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const statusCounts = Object.fromEntries(
    all("SELECT status, COUNT(*) AS total FROM horse_race_seasons GROUP BY status")
      .map((row) => [row.status, Number(row.total || 0)]),
  );
  return {
    generatedAt: new Date().toISOString(),
    page,
    pageSize,
    total: Number(one(
      `SELECT COUNT(*) AS total FROM horse_race_seasons s ${clause}`,
      params,
    )?.total || 0),
    items: all(
      `${seasonSummarySql()} ${clause}
       ORDER BY CASE s.status WHEN 'active' THEN 0 WHEN 'draft' THEN 1
                    WHEN 'paused' THEN 2 ELSE 3 END,
                s.updated_at DESC, s.id DESC
       LIMIT ? OFFSET ?`,
      [...params, pageSize, offset],
    ).map(seasonAdminJson),
    summary: {
      total: Object.values(statusCounts).reduce((sum, value) => sum + value, 0),
      draft: Number(statusCounts.draft || 0),
      active: Number(statusCounts.active || 0),
      paused: Number(statusCounts.paused || 0),
      ended: Number(statusCounts.ended || 0),
    },
    options: raceOperationOptions(),
  };
}

export function raceSeasonDetail(idValue, query = {}) {
  const id = positiveId(idValue, "seasonId");
  const row = one(`${seasonSummarySql()} WHERE s.id = ?`, [id]);
  if (!row) throw notFound("race_season_not_found");
  const item = seasonAdminJson(row);
  const tasks = seasonTaskRows(id).map(seasonTaskJson);
  const rewards = seasonRewardRows(id).map(seasonRewardJson);
  const leaderboard = seasonLeaderboard(id, query);
  return {
    item,
    tasks,
    rewards,
    leaderboard,
    budget: seasonBudget(row, tasks, rewards),
    events: seasonEvents(id),
    transitions: seasonTransitions(item.status, item.participants),
    warnings: seasonWarnings(rewards),
    options: raceOperationOptions(),
  };
}

export function createRaceSeason(adminId, body = {}) {
  const note = requiredChangeNote(body.changeNote);
  const values = seasonInput(body);
  const initialTasks = Array.isArray(body.tasks) ? body.tasks.map((item) => taskInput(item)) : [];
  const initialRewards = Array.isArray(body.rewards)
    ? body.rewards.map((item) => rewardInput(item, null, values.config))
    : [];
  requireUniqueKeys(initialTasks, "taskKey", "race_season_task_key_conflict");
  requireUniqueKeys(initialRewards, "rewardKey", "race_season_reward_key_conflict");
  return inImmediateTransaction(() => {
    if (one("SELECT 1 FROM horse_race_seasons WHERE season_key = ?", [values.seasonKey])) {
      throw conflict("race_season_key_conflict");
    }
    const result = run(
      `INSERT INTO horse_race_seasons
         (season_key, title, description, status, starts_at, ends_at,
          config_json, revision, created_by, updated_by)
       VALUES (?, ?, ?, 'draft', ?, ?, ?, 1, ?, ?)`,
      [values.seasonKey, values.title, values.description, values.startsAt,
       values.endsAt, JSON.stringify(values.config), adminId, adminId],
    );
    const id = Number(result.lastInsertRowid);
    for (const task of initialTasks) insertSeasonTask(id, task);
    for (const reward of initialRewards) insertSeasonReward(id, reward);
    const after = seasonSnapshot(requireSeason(id));
    recordSeasonEvent({
      seasonId: id,
      entityType: "season",
      entityId: id,
      action: "create_draft",
      before: {},
      after,
      note,
      adminId,
    });
    return raceSeasonDetail(id);
  });
}

export function updateRaceSeason(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "seasonId");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const current = requireSeason(id);
    requireSeasonEditable(current);
    requireExpectedRevision(body.expectedRevision, current.revision);
    if (Object.hasOwn(body, "seasonKey") && body.seasonKey !== current.season_key) {
      throw conflict("race_season_key_locked");
    }
    const values = seasonInput(body, current);
    const participants = seasonParticipantCount(id);
    if (participants > 0 && seasonTermsChanged(current, values)) {
      throw conflict("race_season_terms_locked");
    }
    const before = seasonSnapshot(current);
    const result = run(
      `UPDATE horse_race_seasons
       SET title = ?, description = ?, starts_at = ?, ends_at = ?, config_json = ?,
           revision = revision + 1, updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [values.title, values.description, values.startsAt, values.endsAt,
       JSON.stringify(values.config), adminId, id, Number(current.revision)],
    );
    if (!result.changes) throw revisionConflict(body.expectedRevision, current.revision);
    recordSeasonEvent({
      seasonId: id,
      entityType: "season",
      entityId: id,
      action: "update",
      before,
      after: seasonSnapshot(requireSeason(id)),
      note,
      adminId,
    });
    return raceSeasonDetail(id);
  });
}

export function transitionRaceSeason(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "seasonId");
  const target = optionalString(body.status, 30).toLowerCase();
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const current = requireSeason(id);
    requireExpectedRevision(body.expectedRevision, current.revision);
    const participants = seasonParticipantCount(id);
    if (!seasonTransitions(current.status, participants).includes(target)) {
      throw conflict("race_season_transition_invalid");
    }
    if (target === "active") validateSeasonActivation(current, body, id);
    if (target === "ended" && participants > 0) {
      throw conflict("race_season_finalize_required");
    }
    const before = seasonSnapshot(current);
    const result = run(
      `UPDATE horse_race_seasons
       SET status = ?, revision = revision + 1, updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [target, adminId, id, Number(current.revision)],
    );
    if (!result.changes) throw revisionConflict(body.expectedRevision, current.revision);
    const action = target === "active" ? "activate" : target === "paused" ? "pause" : "cancel";
    recordSeasonEvent({
      seasonId: id,
      entityType: "season",
      entityId: id,
      action,
      before,
      after: seasonSnapshot(requireSeason(id)),
      note,
      adminId,
    });
    return raceSeasonDetail(id);
  });
}

export function finalizeRaceSeason(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "seasonId");
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const current = requireSeason(id);
    requireExpectedRevision(body.expectedRevision, current.revision);
    if (!new Set(["active", "paused"]).has(current.status)) {
      throw conflict("race_season_finalize_status_invalid");
    }
    const endsAt = sqlDateMs(current.ends_at);
    if (endsAt > Date.now() && body.acknowledgeEarlyFinalize !== true) {
      throw badRequest("race_season_early_finalize_acknowledgement_required");
    }
    const before = seasonSnapshot(current);
    const result = finalizeHorseRaceSeason(id, { withinTransaction: true });
    const updated = run(
      `UPDATE horse_race_seasons
       SET revision = revision + 1, finalized_by = ?, finalized_at = datetime('now'),
           updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [adminId, adminId, id, Number(current.revision)],
    );
    if (!updated.changes) throw revisionConflict(body.expectedRevision, current.revision);
    recordSeasonEvent({
      seasonId: id,
      entityType: "season",
      entityId: id,
      action: "finalize",
      before,
      after: seasonSnapshot(requireSeason(id)),
      note,
      adminId,
    });
    return { ...raceSeasonDetail(id), finalization: result };
  });
}

export function createRaceSeasonTask(adminId, seasonIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    if (seasonParticipantCount(seasonId) > 0) {
      throw conflict("race_season_structure_locked");
    }
    const values = taskInput(body);
    requireTaskKeyAvailable(seasonId, values.taskKey);
    const result = insertSeasonTask(seasonId, values);
    const taskId = Number(result.lastInsertRowid);
    bumpSeasonRevision(season, adminId);
    const created = requireTask(seasonId, taskId);
    recordSeasonEvent({
      seasonId,
      entityType: "task",
      entityId: taskId,
      action: "create_task",
      before: {},
      after: taskSnapshot(created),
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function updateRaceSeasonTask(adminId, seasonIdValue, taskIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const taskId = positiveId(taskIdValue, "taskId");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    const current = requireTask(seasonId, taskId);
    const values = taskInput(body, current);
    requireTaskKeyAvailable(seasonId, values.taskKey, taskId);
    const usage = taskUsage(taskId);
    if (usage.progress > 0 && taskIdentityChanged(current, values)) {
      throw conflict("race_season_task_progress_locked");
    }
    if (usage.progress > 0 && current.status !== values.status) {
      throw conflict("race_season_task_status_locked");
    }
    if (usage.claims > 0 && taskRewardChanged(current, values)) {
      throw conflict("race_season_task_reward_locked");
    }
    const before = taskSnapshot(current);
    run(
      `UPDATE horse_race_season_tasks
       SET task_key = ?, title = ?, metric = ?, target_count = ?, reward_points = ?,
           reward_coins = ?, status = ?, sort_order = ?, updated_at = datetime('now')
       WHERE id = ? AND season_id = ?`,
      [values.taskKey, values.title, values.metric, values.targetCount,
       values.rewardPoints, values.rewardCoins, values.status, values.sortOrder,
       taskId, seasonId],
    );
    bumpSeasonRevision(season, adminId);
    recordSeasonEvent({
      seasonId,
      entityType: "task",
      entityId: taskId,
      action: "update_task",
      before,
      after: taskSnapshot(requireTask(seasonId, taskId)),
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function removeRaceSeasonTask(adminId, seasonIdValue, taskIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const taskId = positiveId(taskIdValue, "taskId");
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    const current = requireTask(seasonId, taskId);
    const usage = taskUsage(taskId);
    if (usage.progress > 0 || usage.claims > 0) {
      throw conflict("race_season_task_history_locked");
    }
    if (seasonParticipantCount(seasonId) > 0) {
      throw conflict("race_season_structure_locked");
    }
    run("DELETE FROM horse_race_season_tasks WHERE id = ? AND season_id = ?", [taskId, seasonId]);
    bumpSeasonRevision(season, adminId);
    recordSeasonEvent({
      seasonId,
      entityType: "task",
      entityId: taskId,
      action: "remove_task",
      before: taskSnapshot(current),
      after: {},
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function createRaceSeasonReward(adminId, seasonIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    if (seasonParticipantCount(seasonId) > 0) {
      throw conflict("race_season_structure_locked");
    }
    const values = rewardInput(body, null, parseJsonObject(season.config_json));
    requireRewardKeyAvailable(seasonId, values.rewardKey);
    const result = insertSeasonReward(seasonId, values);
    const rewardId = Number(result.lastInsertRowid);
    bumpSeasonRevision(season, adminId);
    const created = requireReward(seasonId, rewardId);
    recordSeasonEvent({
      seasonId,
      entityType: "reward",
      entityId: rewardId,
      action: "create_reward",
      before: {},
      after: rewardSnapshot(created),
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function updateRaceSeasonReward(adminId, seasonIdValue, rewardIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const rewardId = positiveId(rewardIdValue, "rewardId");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    const current = requireReward(seasonId, rewardId);
    const values = rewardInput(body, current, parseJsonObject(season.config_json));
    requireRewardKeyAvailable(seasonId, values.rewardKey, rewardId);
    const usage = rewardUsage(rewardId);
    const participants = seasonParticipantCount(seasonId);
    if ((usage.claims > 0 || participants > 0) && rewardTermsChanged(current, values)) {
      throw conflict("race_season_reward_terms_locked");
    }
    const before = rewardSnapshot(current);
    run(
      `UPDATE horse_race_season_rewards
       SET reward_key = ?, title = ?, tier = ?, min_rank = ?, max_rank = ?,
           reward_points = ?, reward_coins = ?, status = ?, updated_at = datetime('now')
       WHERE id = ? AND season_id = ?`,
      [values.rewardKey, values.title, values.tier, values.minRank, values.maxRank,
       values.rewardPoints, values.rewardCoins, values.status, rewardId, seasonId],
    );
    bumpSeasonRevision(season, adminId);
    recordSeasonEvent({
      seasonId,
      entityType: "reward",
      entityId: rewardId,
      action: "update_reward",
      before,
      after: rewardSnapshot(requireReward(seasonId, rewardId)),
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function removeRaceSeasonReward(adminId, seasonIdValue, rewardIdValue, body = {}) {
  const seasonId = positiveId(seasonIdValue, "seasonId");
  const rewardId = positiveId(rewardIdValue, "rewardId");
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const season = requireSeason(seasonId);
    requireSeasonEditable(season);
    requireExpectedRevision(body.expectedRevision, season.revision);
    const current = requireReward(seasonId, rewardId);
    if (rewardUsage(rewardId).claims > 0 || seasonParticipantCount(seasonId) > 0) {
      throw conflict("race_season_reward_history_locked");
    }
    run("DELETE FROM horse_race_season_rewards WHERE id = ? AND season_id = ?", [rewardId, seasonId]);
    bumpSeasonRevision(season, adminId);
    recordSeasonEvent({
      seasonId,
      entityType: "reward",
      entityId: rewardId,
      action: "remove_reward",
      before: rewardSnapshot(current),
      after: {},
      note,
      adminId,
    });
    return raceSeasonDetail(seasonId);
  });
}

export function responsibleGamingOverview() {
  const settings = one(
    `SELECT COUNT(*) AS configured,
            COALESCE(SUM(CASE WHEN datetime(cooldown_until) > datetime('now') THEN 1 ELSE 0 END), 0) AS cooldown_active,
            COALESCE(SUM(CASE WHEN datetime(self_excluded_until) > datetime('now') THEN 1 ELSE 0 END), 0) AS excluded_active,
            COALESCE(SUM(CASE WHEN daily_bet_limit > 0 THEN 1 ELSE 0 END), 0) AS custom_bet_limits,
            COALESCE(SUM(CASE WHEN daily_loss_limit > 0 THEN 1 ELSE 0 END), 0) AS custom_loss_limits
     FROM horse_race_responsible_settings`,
  ) || {};
  const today = one(
    `SELECT COUNT(*) AS participants,
            COALESCE(SUM(total_bet), 0) AS total_bet,
            COALESCE(SUM(total_payout), 0) AS total_payout,
            COALESCE(SUM(CASE WHEN total_bet > total_payout THEN total_bet - total_payout ELSE 0 END), 0) AS total_loss
     FROM (
       SELECT user_id, SUM(amount) AS total_bet, SUM(payout) AS total_payout
       FROM horse_race_bets
       WHERE date(created_at, '+8 hours') = date('now', '+8 hours')
       GROUP BY user_id
     ) daily`,
  ) || {};
  const thresholdUsers = one(
    `SELECT COUNT(*) AS total FROM (
       SELECT b.user_id,
              SUM(b.amount) - SUM(b.payout) AS net_loss,
              COALESCE(s.reminder_loss_threshold, 500) AS threshold_value
       FROM horse_race_bets b
       LEFT JOIN horse_race_responsible_settings s ON s.user_id = b.user_id
       WHERE date(b.created_at, '+8 hours') = date('now', '+8 hours')
       GROUP BY b.user_id
       HAVING net_loss >= threshold_value AND net_loss > 0
     ) risk`,
  )?.total || 0;
  return {
    configuredUsers: Number(settings.configured || 0),
    activeCooldowns: Number(settings.cooldown_active || 0),
    activeSelfExclusions: Number(settings.excluded_active || 0),
    customBetLimits: Number(settings.custom_bet_limits || 0),
    customLossLimits: Number(settings.custom_loss_limits || 0),
    today: {
      participants: Number(today.participants || 0),
      totalBet: Number(today.total_bet || 0),
      totalPayout: Number(today.total_payout || 0),
      aggregateLoss: Number(today.total_loss || 0),
      usersAtReminderThreshold: Number(thresholdUsers || 0),
    },
    notices: all(
      `SELECT notice_date AS noticeDate, notice_type AS noticeType,
              COUNT(*) AS count, COALESCE(SUM(amount), 0) AS amount
       FROM horse_race_responsible_notices
       WHERE date(notice_date) >= date('now', '-30 days')
       GROUP BY notice_date, notice_type
       ORDER BY notice_date DESC, notice_type
       LIMIT 90`,
    ).map((row) => ({
      noticeDate: row.noticeDate || "",
      noticeType: row.noticeType || "",
      count: Number(row.count || 0),
      amount: Number(row.amount || 0),
    })),
    policy: {
      mode: "aggregate_read_only",
      userControlsMutableByAdmin: false,
    },
  };
}

function roundBets(roundId, query) {
  const { page, pageSize, offset } = pageParams(query);
  const status = optionalString(query.betStatus, 20).toLowerCase();
  if (status && !betStatuses.has(status)) throw badRequest("race_bet_status_invalid");
  const keyword = optionalString(query.betQ, 120);
  let horseIndex = -1;
  if (query.horseIndex !== undefined && String(query.horseIndex).trim() !== "") {
    horseIndex = optionalInt(query.horseIndex, -2);
    if (horseIndex < 0 || horseIndex > 99) throw badRequest("race_bet_horse_index_invalid");
  }
  const where = ["b.round_id = ?"];
  const params = [roundId];
  if (status) {
    where.push("b.status = ?");
    params.push(status);
  }
  if (horseIndex >= 0) {
    where.push("b.horse_index = ?");
    params.push(horseIndex);
  }
  if (keyword) {
    where.push("(u.email LIKE ? OR u.nickname LIKE ? OR CAST(u.id AS TEXT) = ?)");
    const like = `%${keyword}%`;
    params.push(like, like, keyword);
  }
  const clause = `WHERE ${where.join(" AND ")}`;
  return {
    page,
    pageSize,
    total: Number(one(
      `SELECT COUNT(*) AS total
       FROM horse_race_bets b JOIN users u ON u.id = b.user_id ${clause}`,
      params,
    )?.total || 0),
    items: all(
      `SELECT b.*, u.email, u.nickname, u.avatar_url
       FROM horse_race_bets b JOIN users u ON u.id = b.user_id
       ${clause} ORDER BY b.id DESC LIMIT ? OFFSET ?`,
      [...params, pageSize, offset],
    ).map((row) => ({
      id: Number(row.id),
      user: {
        id: Number(row.user_id),
        email: row.email || "",
        nickname: row.nickname || "",
        avatarUrl: row.avatar_url || "",
      },
      horseIndex: Number(row.horse_index),
      amount: Number(row.amount || 0),
      odds: Number(row.odds || 0),
      payout: Number(row.payout || 0),
      status: row.status || "",
      createdAt: row.created_at || "",
    })),
  };
}

function roundSummarySql() {
  return `SELECT r.*,
    (SELECT COUNT(*) FROM horse_race_bets b WHERE b.round_id = r.id) AS bet_count,
    (SELECT COUNT(DISTINCT b.user_id) FROM horse_race_bets b WHERE b.round_id = r.id) AS participants,
    (SELECT COALESCE(SUM(b.amount), 0) FROM horse_race_bets b WHERE b.round_id = r.id) AS total_staked,
    (SELECT COALESCE(SUM(b.payout), 0) FROM horse_race_bets b WHERE b.round_id = r.id) AS total_payout,
    (SELECT COUNT(*) FROM horse_race_bets b WHERE b.round_id = r.id AND b.status = 'pending') AS pending_bets,
    (SELECT COUNT(*) FROM horse_race_bets b
     WHERE b.round_id = r.id AND r.status = 'settling' AND (
       (b.horse_index = r.winner_index AND (
         b.status <> 'won' OR b.payout <> CASE
           WHEN CAST(b.amount * b.odds AS INTEGER) < 1 THEN 1
           ELSE CAST(b.amount * b.odds AS INTEGER) END))
       OR (b.horse_index <> r.winner_index AND (b.status <> 'lost' OR b.payout <> 0))
     )) AS settlement_mismatches,
    (SELECT COUNT(*) FROM horse_race_rounds duplicate
     WHERE duplicate.round_key = r.round_key AND r.round_key <> '') AS duplicate_round_keys
    FROM horse_race_rounds r`;
}

function roundAdminJson(row) {
  const settled = isSettledRound(row);
  const integrity = roundIntegrity(row);
  return {
    id: Number(row.id),
    roundCode: row.round_key || "",
    status: row.status || "",
    rulesVersion: Number(row.rules_version || 1),
    phaseStartedAt: Number(row.phase_started_at || 0),
    phaseEndsAt: roundPhaseEndsAt(row),
    winnerIndex: settled ? Number(row.winner_index) : -1,
    betCount: Number(row.bet_count || 0),
    participants: Number(row.participants || 0),
    totalStaked: Number(row.total_staked || 0),
    totalPayout: Number(row.total_payout || 0),
    houseNet: Number(row.total_staked || 0) - Number(row.total_payout || 0),
    pendingBets: Number(row.pending_bets || 0),
    createdAt: row.created_at || "",
    lockedAt: row.locked_at || "",
    settledAt: row.settled_at || "",
    integrity,
  };
}

function roundIntegrity(row) {
  const issues = [];
  const add = (code, severity, message) => issues.push({ code, severity, message });
  const horses = parseJsonArray(row.horses_json);
  const odds = parseJsonArray(row.odds_json);
  const result = parseJsonObject(row.result_json);
  const settled = isSettledRound(row);
  if (!roundStatuses.has(row.status)) add("status_unknown", "error", "轮次状态不受支持");
  if (!row.seed || !row.seed_commit) add("fairness_commit_missing", "error", "公平承诺数据不完整");
  if (row.seed && row.seed_commit && sha256(row.seed) !== row.seed_commit) {
    add("fairness_commit_mismatch", "error", "种子与已保存承诺值不一致");
  }
  if (horses.length < 2) add("horse_roster_invalid", "error", "参赛马匹数据不完整");
  if (!Number.isInteger(Number(row.winner_index)) || Number(row.winner_index) < 0 || Number(row.winner_index) >= horses.length) {
    add("winner_index_invalid", "error", "预生成赛果索引超出马匹范围");
  }
  if (row.status !== "betting" && odds.length !== horses.length) {
    add("locked_odds_invalid", "error", "封盘赔率数量与马匹数量不一致");
  }
  if (new Set(["locked", "racing", "settling"]).has(row.status) && !row.locked_at) {
    add("locked_timestamp_missing", "warning", "轮次缺少封盘时间");
  }
  if (settled && !row.settled_at) add("settled_timestamp_missing", "error", "已结算轮次缺少结算时间");
  if (settled && Number(row.pending_bets || 0) > 0) {
    add("pending_bets_after_settlement", "error", "结算后仍存在待处理下注");
  }
  if (settled && Number(row.settlement_mismatches || 0) > 0) {
    add("payout_mismatch", "error", "下注状态或返还金额与锁定赔率不一致");
  }
  if (settled && result.winnerIndex !== undefined && Number(result.winnerIndex) !== Number(row.winner_index)) {
    add("result_winner_mismatch", "error", "公开赛果与轮次冠军不一致");
  }
  if (Number(row.duplicate_round_keys || 0) > 1) {
    add("round_key_duplicate", "error", "轮次编号重复");
  }
  const errors = issues.filter((item) => item.severity === "error").length;
  const warnings = issues.filter((item) => item.severity === "warning").length;
  return {
    status: errors > 0 ? "error" : warnings > 0 ? "warning" : "healthy",
    errorCount: errors,
    warningCount: warnings,
    checks: 9,
    issues,
  };
}

function isSettledRound(row) {
  return row.status === "settling" && Boolean(row.settled_at);
}

function roundPhaseEndsAt(row) {
  const start = Number(row.phase_started_at || 0);
  if (!start) return 0;
  const legacy = Number(row.rules_version || 1) < 2;
  const offsets = legacy
    ? { betting: 170 * 60_000, locked: 180 * 60_000, racing: 182 * 60_000, settling: 183 * 60_000 }
    : { betting: 4 * 60_000, locked: 4 * 60_000 + 20_000, racing: 5 * 60_000 + 20_000, settling: 6 * 60_000 };
  return start + (offsets[row.status] || offsets.settling);
}

function raceRuleSummary(version = 2) {
  if (version < 2) {
    return {
      version,
      legacy: true,
      schedule: { timezone: "Asia/Hong_Kong", opensAt: "06:00", closesAt: "24:00" },
      phases: { bettingSeconds: 10200, lockedSeconds: 600, racingSeconds: 120, resultSeconds: 60 },
      limits: { minBet: 1, perHorse: 1000, perRound: 2000, perDay: 20000 },
      payoutRate: 0.9,
      operatorControlsResult: false,
    };
  }
  return {
    version: 2,
    legacy: false,
    schedule: { timezone: "Asia/Hong_Kong", opensAt: "06:00", closesAt: "24:00" },
    phases: { bettingSeconds: 240, lockedSeconds: 20, racingSeconds: 60, resultSeconds: 40 },
    limits: { minBet: 1, perHorse: 1000, perRound: 2000, perDay: 20000 },
    payoutRate: 0.9,
    virtualLiquidity: 2000,
    operatorControlsResult: false,
  };
}

function serviceLeaseJson(row) {
  const leaseUntil = Number(row?.lease_until_ms || 0);
  return {
    leaseKey: "horse-race-ticker",
    active: leaseUntil > Date.now(),
    ownerId: row?.owner_id || "",
    leaseUntil,
    updatedAt: row?.updated_at || "",
  };
}

function seasonSummarySql() {
  return `SELECT s.*,
    (SELECT COUNT(*) FROM horse_race_season_user_stats us WHERE us.season_id = s.id) AS participants,
    (SELECT COUNT(*) FROM horse_race_season_round_results rr WHERE rr.season_id = s.id) AS settlement_records,
    (SELECT COUNT(*) FROM horse_race_season_tasks t WHERE t.season_id = s.id) AS task_count,
    (SELECT COUNT(*) FROM horse_race_season_tasks t WHERE t.season_id = s.id AND t.status = 'active') AS active_task_count,
    (SELECT COUNT(*) FROM horse_race_season_rewards rw WHERE rw.season_id = s.id) AS reward_count,
    (SELECT COUNT(*) FROM horse_race_season_rewards rw WHERE rw.season_id = s.id AND rw.status = 'active') AS active_reward_count,
    (SELECT COUNT(*) FROM horse_race_season_task_progress p WHERE p.season_id = s.id) AS progress_count,
    (SELECT COUNT(*) FROM horse_race_season_task_progress p WHERE p.season_id = s.id AND p.claimed_at <> '') AS task_claim_count,
    (SELECT COUNT(*) FROM horse_race_season_reward_claims c WHERE c.season_id = s.id) AS ranking_claim_count,
    (SELECT COALESCE(SUM(c.points_awarded), 0) FROM horse_race_season_reward_claims c WHERE c.season_id = s.id) AS ranking_awarded_points,
    (SELECT COALESCE(SUM(c.coins_awarded), 0) FROM horse_race_season_reward_claims c WHERE c.season_id = s.id) AS ranking_awarded_coins
    FROM horse_race_seasons s`;
}

function seasonAdminJson(row) {
  return {
    id: Number(row.id),
    seasonKey: row.season_key || "",
    title: row.title || "",
    description: row.description || "",
    status: row.status || "",
    startsAt: row.starts_at || "",
    endsAt: row.ends_at || "",
    config: parseJsonObject(row.config_json),
    revision: Number(row.revision || 1),
    participants: Number(row.participants || 0),
    settlementRecords: Number(row.settlement_records || 0),
    taskCount: Number(row.task_count || 0),
    activeTaskCount: Number(row.active_task_count || 0),
    rewardCount: Number(row.reward_count || 0),
    activeRewardCount: Number(row.active_reward_count || 0),
    progressCount: Number(row.progress_count || 0),
    taskClaimCount: Number(row.task_claim_count || 0),
    rankingClaimCount: Number(row.ranking_claim_count || 0),
    awardedPoints: Number(row.ranking_awarded_points || 0),
    awardedCoins: Number(row.ranking_awarded_coins || 0),
    finalizedAt: row.finalized_at || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function seasonTaskRows(seasonId) {
  return all(
    `SELECT t.*,
            (SELECT COUNT(*) FROM horse_race_season_task_progress p WHERE p.task_id = t.id) AS progress_users,
            (SELECT COUNT(*) FROM horse_race_season_task_progress p WHERE p.task_id = t.id AND p.completed_at <> '') AS completed_users,
            (SELECT COUNT(*) FROM horse_race_season_task_progress p WHERE p.task_id = t.id AND p.claimed_at <> '') AS claim_count
     FROM horse_race_season_tasks t
     WHERE t.season_id = ? ORDER BY t.sort_order, t.id`,
    [seasonId],
  );
}

function seasonRewardRows(seasonId) {
  return all(
    `SELECT r.*,
            (SELECT COUNT(*) FROM horse_race_season_reward_claims c WHERE c.reward_id = r.id) AS claim_count,
            (SELECT COALESCE(SUM(c.points_awarded), 0) FROM horse_race_season_reward_claims c WHERE c.reward_id = r.id) AS awarded_points,
            (SELECT COALESCE(SUM(c.coins_awarded), 0) FROM horse_race_season_reward_claims c WHERE c.reward_id = r.id) AS awarded_coins
     FROM horse_race_season_rewards r
     WHERE r.season_id = ? ORDER BY r.min_rank, r.id`,
    [seasonId],
  );
}

function seasonTaskJson(row) {
  return {
    id: Number(row.id),
    seasonId: Number(row.season_id),
    taskKey: row.task_key || "",
    title: row.title || "",
    metric: row.metric || "",
    targetCount: Number(row.target_count || 1),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    status: row.status || "",
    sortOrder: Number(row.sort_order || 0),
    progressUsers: Number(row.progress_users || 0),
    completedUsers: Number(row.completed_users || 0),
    claimCount: Number(row.claim_count || 0),
    identityLocked: Number(row.progress_users || 0) > 0,
    rewardLocked: Number(row.claim_count || 0) > 0,
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || row.created_at || "",
  };
}

function seasonRewardJson(row) {
  return {
    id: Number(row.id),
    seasonId: Number(row.season_id),
    rewardKey: row.reward_key || "",
    title: row.title || "",
    tier: row.tier || "",
    minRank: Number(row.min_rank || 0),
    maxRank: Number(row.max_rank || 0),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    status: row.status || "",
    claimCount: Number(row.claim_count || 0),
    awardedPoints: Number(row.awarded_points || 0),
    awardedCoins: Number(row.awarded_coins || 0),
    termsLocked: Number(row.claim_count || 0) > 0,
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || row.created_at || "",
  };
}

function seasonLeaderboard(seasonId, query) {
  const { page, pageSize, offset } = pageParams({
    page: query.leaderboardPage || 1,
    pageSize: query.leaderboardPageSize || 20,
  });
  const total = Number(one(
    "SELECT COUNT(*) AS total FROM horse_race_season_user_stats WHERE season_id = ?",
    [seasonId],
  )?.total || 0);
  return {
    page,
    pageSize,
    total,
    items: all(
      `SELECT ranked.*, u.nickname, u.email, u.avatar_url
       FROM (
         SELECT stats.*, ROW_NUMBER() OVER (
           ORDER BY points DESC, wins DESC, total_payout DESC, user_id ASC
         ) AS rank
         FROM horse_race_season_user_stats stats WHERE season_id = ?
       ) ranked JOIN users u ON u.id = ranked.user_id
       ORDER BY ranked.rank LIMIT ? OFFSET ?`,
      [seasonId, pageSize, offset],
    ).map((row) => ({
      rank: Number(row.rank),
      user: {
        id: Number(row.user_id),
        nickname: row.nickname || "",
        email: row.email || "",
        avatarUrl: row.avatar_url || "",
      },
      points: Number(row.points || 0),
      rounds: Number(row.rounds || 0),
      wins: Number(row.wins || 0),
      totalBet: Number(row.total_bet || 0),
      totalPayout: Number(row.total_payout || 0),
      profit: Number(row.total_payout || 0) - Number(row.total_bet || 0),
      tier: row.tier || "bronze",
      updatedAt: row.updated_at || "",
    })),
  };
}

function seasonBudget(season, tasks, rewards) {
  const eligibleUsers = Number(one(
    `SELECT COUNT(*) AS total FROM users u WHERE ${activeUserPredicate}`,
  )?.total || 0);
  const participants = Number(season.participants || seasonParticipantCount(season.id));
  const activeTasks = tasks.filter((item) => item.status === "active");
  const activeRewards = rewards.filter((item) => item.status === "active");
  const taskPointsPerUser = activeTasks.reduce((sum, item) => sum + item.rewardPoints, 0);
  const taskCoinsPerUser = activeTasks.reduce((sum, item) => sum + item.rewardCoins, 0);
  let rankingPoints = 0;
  let rankingCoins = 0;
  const rankingExposure = activeRewards.map((reward) => {
    const minRank = reward.minRank > 0 ? reward.minRank : 1;
    const maxRank = reward.maxRank > 0 ? Math.min(reward.maxRank, eligibleUsers) : eligibleUsers;
    const slots = Math.max(0, maxRank - minRank + 1);
    rankingPoints += slots * reward.rewardPoints;
    rankingCoins += slots * reward.rewardCoins;
    return {
      rewardId: reward.id,
      rewardKey: reward.rewardKey,
      slots,
      points: slots * reward.rewardPoints,
      coins: slots * reward.rewardCoins,
    };
  });
  const taskAwarded = one(
    `SELECT COALESCE(SUM(t.reward_points), 0) AS points,
            COALESCE(SUM(t.reward_coins), 0) AS coins
     FROM horse_race_season_task_progress p
     JOIN horse_race_season_tasks t ON t.id = p.task_id
     WHERE p.season_id = ? AND p.claimed_at <> ''`,
    [season.id],
  ) || {};
  const rankingAwarded = one(
    `SELECT COALESCE(SUM(points_awarded), 0) AS points,
            COALESCE(SUM(coins_awarded), 0) AS coins
     FROM horse_race_season_reward_claims WHERE season_id = ?`,
    [season.id],
  ) || {};
  return {
    eligibleUsers,
    currentParticipants: participants,
    taskPointsPerUser,
    taskCoinsPerUser,
    maximumTaskPoints: eligibleUsers * taskPointsPerUser,
    maximumTaskCoins: eligibleUsers * taskCoinsPerUser,
    maximumRankingPoints: rankingPoints,
    maximumRankingCoins: rankingCoins,
    maximumPoints: eligibleUsers * taskPointsPerUser + rankingPoints,
    maximumCoins: eligibleUsers * taskCoinsPerUser + rankingCoins,
    awardedPoints: Number(taskAwarded.points || 0) + Number(rankingAwarded.points || 0),
    awardedCoins: Number(taskAwarded.coins || 0) + Number(rankingAwarded.coins || 0),
    rankingExposure,
    conservativeUpperBound: true,
  };
}

function seasonWarnings(rewards) {
  const warnings = [];
  const active = rewards.filter((item) => item.status === "active");
  for (let left = 0; left < active.length; left += 1) {
    for (let right = left + 1; right < active.length; right += 1) {
      if (rewardScopesOverlap(active[left], active[right])) {
        warnings.push({
          code: "reward_scope_overlap",
          rewardIds: [active[left].id, active[right].id],
          message: "奖励范围存在重叠，同一用户可能累计获得多份排名奖励",
        });
      }
    }
  }
  return warnings;
}

function rewardScopesOverlap(left, right) {
  if (left.tier && right.tier && left.tier !== right.tier) return false;
  const leftMin = left.minRank || 1;
  const rightMin = right.minRank || 1;
  const leftMax = left.maxRank || Number.MAX_SAFE_INTEGER;
  const rightMax = right.maxRank || Number.MAX_SAFE_INTEGER;
  return leftMin <= rightMax && rightMin <= leftMax;
}

function seasonEvents(seasonId) {
  return all(
    `SELECT e.*, u.nickname AS admin_nickname, u.email AS admin_email
     FROM horse_race_season_events e JOIN users u ON u.id = e.admin_user_id
     WHERE e.season_id = ? ORDER BY e.id DESC LIMIT 100`,
    [seasonId],
  ).map((row) => ({
    id: Number(row.id),
    entityType: row.entity_type || "",
    entityId: Number(row.entity_id || 0),
    action: row.action || "",
    before: parseJsonObject(row.before_json),
    after: parseJsonObject(row.after_json),
    note: row.note || "",
    admin: {
      id: Number(row.admin_user_id),
      nickname: row.admin_nickname || "",
      email: row.admin_email || "",
    },
    createdAt: row.created_at || "",
  }));
}

function seasonInput(body, current = null) {
  const startsAt = dateText(valueFrom(body, "startsAt", current?.starts_at));
  const endsAt = dateText(valueFrom(body, "endsAt", current?.ends_at));
  if (!startsAt) throw badRequest("race_season_starts_at_required");
  if (!endsAt) throw badRequest("race_season_ends_at_required");
  if (sqlDateMs(startsAt) >= sqlDateMs(endsAt)) {
    throw badRequest("race_season_date_range_invalid");
  }
  const configSource = Object.hasOwn(body, "config")
    ? body.config
    : current?.config_json || {};
  return {
    seasonKey: current?.season_key || validKey(body.seasonKey, "seasonKey"),
    title: requiredString(valueFrom(body, "title", current?.title), "title", 200),
    description: optionalText(valueFrom(body, "description", current?.description), 1000),
    startsAt,
    endsAt,
    config: seasonConfigInput(configSource),
  };
}

function seasonConfigInput(value) {
  const config = typeof value === "string" ? parseJsonObject(value) : value;
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw badRequest("race_season_config_invalid");
  }
  const participationPoints = boundedInteger(
    config.participationPoints ?? 10,
    "participationPoints",
    1,
    10000,
  );
  const winPoints = boundedInteger(config.winPoints ?? 20, "winPoints", 0, 10000);
  const maxProfitBonus = boundedInteger(
    config.maxProfitBonus ?? 30,
    "maxProfitBonus",
    0,
    10000,
  );
  const sourceTiers = Array.isArray(config.tiers) && config.tiers.length
    ? config.tiers
    : defaultTiers;
  if (sourceTiers.length > 10) throw badRequest("race_season_tiers_invalid");
  const tiers = sourceTiers.map((item, index) => ({
    key: validKey(item?.key, `tier${index + 1}`),
    points: boundedInteger(item?.points, `tier${index + 1}Points`, 0, 100000000),
  }));
  if (tiers[0]?.key !== "bronze" || tiers[0]?.points !== 0) {
    throw badRequest("race_season_first_tier_invalid");
  }
  if (new Set(tiers.map((item) => item.key)).size !== tiers.length) {
    throw badRequest("race_season_tier_key_conflict");
  }
  for (let index = 1; index < tiers.length; index += 1) {
    if (tiers[index].points <= tiers[index - 1].points) {
      throw badRequest("race_season_tier_threshold_invalid");
    }
  }
  return { participationPoints, winPoints, maxProfitBonus, tiers };
}

function taskInput(body, current = null) {
  const metric = String(valueFrom(body, "metric", current?.metric) || "").toLowerCase();
  if (!seasonMetrics.has(metric)) throw badRequest("race_season_task_metric_invalid");
  const status = String(valueFrom(body, "status", current?.status || "active")).toLowerCase();
  if (!taskStatuses.has(status)) throw badRequest("race_season_task_status_invalid");
  return {
    taskKey: validKey(valueFrom(body, "taskKey", current?.task_key), "taskKey"),
    title: requiredString(valueFrom(body, "title", current?.title), "title", 200),
    metric,
    targetCount: boundedInteger(
      valueFrom(body, "targetCount", current?.target_count ?? 1),
      "targetCount",
      1,
      10000000,
    ),
    rewardPoints: boundedInteger(
      valueFrom(body, "rewardPoints", current?.reward_points ?? 0),
      "rewardPoints",
      0,
      1000000,
    ),
    rewardCoins: boundedInteger(
      valueFrom(body, "rewardCoins", current?.reward_coins ?? 0),
      "rewardCoins",
      0,
      1000000,
    ),
    status,
    sortOrder: boundedInteger(
      valueFrom(body, "sortOrder", current?.sort_order ?? 0),
      "sortOrder",
      -100000,
      100000,
    ),
  };
}

function rewardInput(body, current = null, config = {}) {
  const status = String(valueFrom(body, "status", current?.status || "active")).toLowerCase();
  if (!rewardStatuses.has(status)) throw badRequest("race_season_reward_status_invalid");
  const tier = optionalText(valueFrom(body, "tier", current?.tier), 50).toLowerCase();
  const tierKeys = new Set((config.tiers || defaultTiers).map((item) => item.key));
  if (tier && !tierKeys.has(tier)) throw badRequest("race_season_reward_tier_invalid");
  const minRank = boundedInteger(
    valueFrom(body, "minRank", current?.min_rank ?? 0),
    "minRank",
    0,
    1000000,
  );
  const maxRank = boundedInteger(
    valueFrom(body, "maxRank", current?.max_rank ?? 0),
    "maxRank",
    0,
    1000000,
  );
  if (maxRank > 0 && maxRank < Math.max(1, minRank)) {
    throw badRequest("race_season_reward_rank_range_invalid");
  }
  const rewardPoints = boundedInteger(
    valueFrom(body, "rewardPoints", current?.reward_points ?? 0),
    "rewardPoints",
    0,
    1000000,
  );
  const rewardCoins = boundedInteger(
    valueFrom(body, "rewardCoins", current?.reward_coins ?? 0),
    "rewardCoins",
    0,
    1000000,
  );
  if (rewardPoints === 0 && rewardCoins === 0) {
    throw badRequest("race_season_reward_empty");
  }
  return {
    rewardKey: validKey(valueFrom(body, "rewardKey", current?.reward_key), "rewardKey"),
    title: requiredString(valueFrom(body, "title", current?.title), "title", 200),
    tier,
    minRank,
    maxRank,
    rewardPoints,
    rewardCoins,
    status,
  };
}

function insertSeasonTask(seasonId, task) {
  return run(
    `INSERT INTO horse_race_season_tasks
       (season_id, task_key, title, metric, target_count, reward_points,
        reward_coins, status, sort_order)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [seasonId, task.taskKey, task.title, task.metric, task.targetCount,
     task.rewardPoints, task.rewardCoins, task.status, task.sortOrder],
  );
}

function insertSeasonReward(seasonId, reward) {
  return run(
    `INSERT INTO horse_race_season_rewards
       (season_id, reward_key, title, tier, min_rank, max_rank,
        reward_points, reward_coins, status)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [seasonId, reward.rewardKey, reward.title, reward.tier, reward.minRank,
     reward.maxRank, reward.rewardPoints, reward.rewardCoins, reward.status],
  );
}

function validateSeasonActivation(season, body, seasonId) {
  if (sqlDateMs(season.ends_at) <= Date.now()) {
    throw badRequest("race_season_end_not_future");
  }
  if (one(
    "SELECT 1 FROM horse_race_seasons WHERE status = 'active' AND id <> ?",
    [seasonId],
  )) {
    throw conflict("race_season_active_conflict");
  }
  if (!one(
    "SELECT 1 FROM horse_race_season_rewards WHERE season_id = ? AND status = 'active'",
    [seasonId],
  )) {
    throw badRequest("race_season_active_reward_required");
  }
  if (body.acknowledgeBudget !== true) {
    throw badRequest("race_season_budget_acknowledgement_required");
  }
}

function seasonTransitions(status, participants) {
  if (status === "draft") return ["active", "ended"];
  if (status === "active") return ["paused"];
  if (status === "paused") return participants > 0 ? ["active"] : ["active", "ended"];
  return [];
}

function requireSeason(id) {
  const row = one("SELECT * FROM horse_race_seasons WHERE id = ?", [id]);
  if (!row) throw notFound("race_season_not_found");
  return row;
}

function requireSeasonEditable(season) {
  if (!new Set(["draft", "paused"]).has(season.status)) {
    throw conflict("race_season_edit_requires_pause");
  }
}

function requireTask(seasonId, taskId) {
  const row = one(
    "SELECT * FROM horse_race_season_tasks WHERE season_id = ? AND id = ?",
    [seasonId, taskId],
  );
  if (!row) throw notFound("race_season_task_not_found");
  return row;
}

function requireReward(seasonId, rewardId) {
  const row = one(
    "SELECT * FROM horse_race_season_rewards WHERE season_id = ? AND id = ?",
    [seasonId, rewardId],
  );
  if (!row) throw notFound("race_season_reward_not_found");
  return row;
}

function requireTaskKeyAvailable(seasonId, taskKey, excludedId = 0) {
  const duplicate = excludedId
    ? one(
        "SELECT 1 FROM horse_race_season_tasks WHERE season_id = ? AND task_key = ? AND id <> ?",
        [seasonId, taskKey, excludedId],
      )
    : one(
        "SELECT 1 FROM horse_race_season_tasks WHERE season_id = ? AND task_key = ?",
        [seasonId, taskKey],
      );
  if (duplicate) throw conflict("race_season_task_key_conflict");
}

function requireRewardKeyAvailable(seasonId, rewardKey, excludedId = 0) {
  const duplicate = excludedId
    ? one(
        "SELECT 1 FROM horse_race_season_rewards WHERE season_id = ? AND reward_key = ? AND id <> ?",
        [seasonId, rewardKey, excludedId],
      )
    : one(
        "SELECT 1 FROM horse_race_season_rewards WHERE season_id = ? AND reward_key = ?",
        [seasonId, rewardKey],
      );
  if (duplicate) throw conflict("race_season_reward_key_conflict");
}

function requireUniqueKeys(items, key, errorCode) {
  const values = items.map((item) => item[key]);
  if (new Set(values).size !== values.length) throw conflict(errorCode);
}

function seasonParticipantCount(seasonId) {
  return Number(one(
    "SELECT COUNT(*) AS total FROM horse_race_season_user_stats WHERE season_id = ?",
    [seasonId],
  )?.total || 0);
}

function taskUsage(taskId) {
  return {
    progress: Number(one(
      "SELECT COUNT(*) AS total FROM horse_race_season_task_progress WHERE task_id = ?",
      [taskId],
    )?.total || 0),
    claims: Number(one(
      "SELECT COUNT(*) AS total FROM horse_race_season_task_progress WHERE task_id = ? AND claimed_at <> ''",
      [taskId],
    )?.total || 0),
  };
}

function rewardUsage(rewardId) {
  return {
    claims: Number(one(
      "SELECT COUNT(*) AS total FROM horse_race_season_reward_claims WHERE reward_id = ?",
      [rewardId],
    )?.total || 0),
  };
}

function bumpSeasonRevision(season, adminId) {
  const result = run(
    `UPDATE horse_race_seasons
     SET revision = revision + 1, updated_by = ?, updated_at = datetime('now')
     WHERE id = ? AND revision = ?`,
    [adminId, season.id, Number(season.revision)],
  );
  if (!result.changes) throw revisionConflict(season.revision, season.revision);
}

function seasonTermsChanged(current, values) {
  return current.starts_at !== values.startsAt
    || current.ends_at !== values.endsAt
    || JSON.stringify(parseJsonObject(current.config_json)) !== JSON.stringify(values.config);
}

function taskIdentityChanged(current, values) {
  return current.task_key !== values.taskKey
    || current.metric !== values.metric
    || Number(current.target_count) !== values.targetCount;
}

function taskRewardChanged(current, values) {
  return Number(current.reward_points) !== values.rewardPoints
    || Number(current.reward_coins) !== values.rewardCoins;
}

function rewardTermsChanged(current, values) {
  return current.reward_key !== values.rewardKey
    || current.tier !== values.tier
    || Number(current.min_rank) !== values.minRank
    || Number(current.max_rank) !== values.maxRank
    || Number(current.reward_points) !== values.rewardPoints
    || Number(current.reward_coins) !== values.rewardCoins
    || current.status !== values.status;
}

function seasonSnapshot(row) {
  return {
    id: Number(row.id),
    seasonKey: row.season_key || "",
    title: row.title || "",
    description: row.description || "",
    status: row.status || "",
    startsAt: row.starts_at || "",
    endsAt: row.ends_at || "",
    config: parseJsonObject(row.config_json),
    revision: Number(row.revision || 1),
    finalizedAt: row.finalized_at || "",
  };
}

function taskSnapshot(row) {
  return {
    id: Number(row.id),
    taskKey: row.task_key || "",
    title: row.title || "",
    metric: row.metric || "",
    targetCount: Number(row.target_count || 1),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    status: row.status || "",
    sortOrder: Number(row.sort_order || 0),
  };
}

function rewardSnapshot(row) {
  return {
    id: Number(row.id),
    rewardKey: row.reward_key || "",
    title: row.title || "",
    tier: row.tier || "",
    minRank: Number(row.min_rank || 0),
    maxRank: Number(row.max_rank || 0),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    status: row.status || "",
  };
}

function recordSeasonEvent({ seasonId, entityType, entityId, action, before, after, note, adminId }) {
  run(
    `INSERT INTO horse_race_season_events
       (season_id, entity_type, entity_id, action, before_json, after_json,
        note, admin_user_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [seasonId, entityType, entityId, action, JSON.stringify(before || {}),
     JSON.stringify(after || {}), note, adminId],
  );
}

function raceOperationOptions() {
  return {
    roundStatuses: [...roundStatuses],
    betStatuses: [...betStatuses],
    integrityStatuses: ["healthy", "warning", "error"],
    seasonStatuses: [...seasonStatuses],
    seasonMetrics: [...seasonMetrics],
    taskStatuses: [...taskStatuses],
    rewardStatuses: [...rewardStatuses],
    tiers: defaultTiers,
  };
}

function requiredChangeNote(value) {
  const note = requiredString(value, "note", 500);
  if (note.length < 4) throw badRequest("race_change_note_invalid");
  return note;
}

function requireExpectedRevision(value, currentRevision) {
  const expected = boundedInteger(value, "expectedRevision", 0, 1000000000);
  if (expected !== Number(currentRevision || 0)) {
    throw revisionConflict(expected, currentRevision);
  }
}

function revisionConflict(expectedRevision, currentRevision) {
  const error = conflict("race_season_revision_conflict");
  error.details = {
    expectedRevision: Number(expectedRevision || 0),
    currentRevision: Number(currentRevision || 0),
  };
  return error;
}

function validKey(value, name) {
  const text = requiredString(value, name, 120).toLowerCase();
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(text)) throw badRequest(`${name}_invalid`);
  return text;
}

function positiveId(value, name) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw badRequest(`${name}_invalid`);
  return id;
}

function boundedInteger(value, name, minimum, maximum) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw badRequest(`${name}_invalid`);
  }
  return number;
}

function dateText(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  const parsed = new Date(text);
  if (!Number.isFinite(parsed.getTime())) throw badRequest("race_season_date_invalid");
  return parsed.toISOString().slice(0, 19).replace("T", " ");
}

function sqlDateMs(value) {
  const parsed = Date.parse(`${String(value || "").replace(" ", "T")}Z`);
  return Number.isFinite(parsed) ? parsed : 0;
}

function optionalText(value, maximum) {
  const text = String(value || "").trim();
  if (text.length > maximum) throw badRequest("value_too_long");
  return text;
}

function valueFrom(body, key, fallback) {
  return Object.hasOwn(body, key) ? body[key] : fallback;
}

function parseJsonObject(value, fallback = {}) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value || "{}") : value;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
}

function parseJsonArray(value) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value || "[]") : value;
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function sha256(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function inImmediateTransaction(task) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = task();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original transaction error.
    }
    throw error;
  }
}

function conflict(message) {
  const error = new Error(message);
  error.statusCode = 409;
  return error;
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}
