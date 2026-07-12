import { all, db, one, run } from "./db.js";
import {
  activityEventNames,
  finalizeHorseRaceSeason,
  funnelAnalytics,
  horseRaceSeasonState,
  rankingBoard,
  rankingMetrics,
  rankingPeriods,
} from "./growth-operations.js";
import { badRequest, optionalInt, optionalString, pageParams, requiredString } from "./validators.js";

const campaignStatuses = new Set(["draft", "active", "paused", "ended"]);
const seasonStatuses = new Set(["draft", "active", "paused", "ended"]);
const seasonMetrics = new Set(["rounds", "wins", "bet", "profit"]);

export async function adminGrowthRoutes(app) {
  app.get(
    "/admin/growth/overview",
    { preHandler: app.adminRequired },
    async (request) => growthOverview(request.query || {}),
  );

  app.get(
    "/admin/growth/rankings",
    { preHandler: app.adminRequired },
    async (request) => adminRankings(request.query || {}),
  );

  app.put(
    "/admin/growth/rankings/:rankingKey/:contentKey",
    { preHandler: app.adminRequired },
    async (request) => upsertRankingControl(request.user.id, request.params, request.body || {}),
  );

  app.delete(
    "/admin/growth/rankings/:rankingKey/:contentKey",
    { preHandler: app.adminRequired },
    async (request) => deleteRankingControl(request.params),
  );

  app.get(
    "/admin/growth/campaigns",
    { preHandler: app.adminRequired },
    async (request) => campaignList(request.query || {}),
  );

  app.get(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => campaignDetail(request.params.id),
  );

  app.post(
    "/admin/growth/campaigns",
    { preHandler: app.adminRequired },
    async (request) => createCampaign(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => updateCampaign(request.user.id, request.params.id, request.body || {}),
  );

  app.delete(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => deleteCampaign(request.params.id),
  );

  app.post(
    "/admin/growth/seasons/:id/finalize",
    { preHandler: app.adminRequired },
    async (request) => finalizeHorseRaceSeason(positiveId(request.params.id, "season id")),
  );

  app.post(
    "/admin/growth/campaigns/:id/rollback",
    { preHandler: app.adminRequired },
    async (request) => rollbackCampaign(request.user.id, request.params.id, request.body?.revision),
  );

  app.post(
    "/admin/growth/campaigns/:id/tasks",
    { preHandler: app.adminRequired },
    async (request) => createCampaignTask(request.user.id, request.params.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/campaigns/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => updateCampaignTask(request.user.id, request.params.id, request.params.taskId, request.body || {}),
  );

  app.delete(
    "/admin/growth/campaigns/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => deleteCampaignTask(request.user.id, request.params.id, request.params.taskId),
  );

  app.get(
    "/admin/growth/seasons",
    { preHandler: app.adminRequired },
    async (request) => seasonList(request.query || {}),
  );

  app.get(
    "/admin/growth/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => seasonDetail(request.params.id),
  );

  app.post(
    "/admin/growth/seasons",
    { preHandler: app.adminRequired },
    async (request) => createSeason(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => updateSeason(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/growth/seasons/:id/tasks",
    { preHandler: app.adminRequired },
    async (request) => createSeasonTask(request.params.id, request.body || {}),
  );

  app.post(
    "/admin/growth/seasons/:id/rewards",
    { preHandler: app.adminRequired },
    async (request) => createSeasonReward(request.params.id, request.body || {}),
  );

  app.get(
    "/admin/growth/leases",
    { preHandler: app.adminRequired },
    async () => ({ items: all("SELECT * FROM service_leases ORDER BY lease_key") }),
  );
}

function growthOverview(query) {
  const days = Math.max(1, Math.min(90, optionalInt(query.days, 7)));
  const contentType = optionalString(query.contentType, 20).toLowerCase();
  const funnel = funnelAnalytics({ days, contentType });
  return {
    generatedAt: new Date().toISOString(),
    funnel,
    totals: {
      behaviorEvents: Number(one("SELECT COUNT(*) AS total FROM content_behavior_events")?.total || 0),
      campaignsActive: Number(one("SELECT COUNT(*) AS total FROM campaigns WHERE status = 'active'")?.total || 0),
      rewardsClaimed: Number(one("SELECT COUNT(*) AS total FROM reward_claims")?.total || 0),
      seasonParticipants: Number(one("SELECT COUNT(DISTINCT user_id) AS total FROM horse_race_season_user_stats")?.total || 0),
    },
    season: horseRaceSeasonState(0, 50),
  };
}

function adminRankings(query) {
  const period = optionalString(query.period, 20).toLowerCase() || "weekly";
  const metric = optionalString(query.metric, 30).toLowerCase() || "hot";
  if (!rankingPeriods.has(period) || !rankingMetrics.has(metric)) throw badRequest("ranking is invalid");
  const rankingKey = `${period}_${metric}`;
  return {
    period,
    metric,
    rankingKey,
    items: rankingBoard({
      period,
      metric,
      contentType: optionalString(query.contentType, 20).toLowerCase(),
      limit: optionalInt(query.limit, 100),
    }),
    controls: all(
      `SELECT r.*, c.title, c.content_type
       FROM content_ranking_controls r JOIN content_catalog c ON c.stable_key = r.content_key
       WHERE r.ranking_key IN ('all', ?, ?) ORDER BY r.ranking_key, r.pinned DESC, r.manual_weight DESC`,
      [metric, rankingKey],
    ).map(rankingControlJson),
  };
}

function upsertRankingControl(adminId, params, body) {
  const rankingKey = validRankingKey(params.rankingKey);
  const contentKey = requiredString(params.contentKey, "contentKey", 240);
  if (!one("SELECT 1 FROM content_catalog WHERE stable_key = ?", [contentKey])) {
    throw badRequest("content does not exist in catalog");
  }
  const pinned = body.pinned === true ? 1 : 0;
  const excluded = body.excluded === true ? 1 : 0;
  const manualWeight = boundedNumber(body.manualWeight ?? 0, -100000, 100000, "manualWeight");
  const note = optionalString(body.note, 500);
  run(
    `INSERT INTO content_ranking_controls
     (ranking_key, content_key, pinned, excluded, manual_weight, note, updated_by)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(ranking_key, content_key) DO UPDATE SET
       pinned = excluded.pinned, excluded = excluded.excluded,
       manual_weight = excluded.manual_weight, note = excluded.note,
       updated_by = excluded.updated_by, updated_at = datetime('now')`,
    [rankingKey, contentKey, pinned, excluded, manualWeight, note, adminId],
  );
  return { item: rankingControlJson(one(
    `SELECT r.*, c.title, c.content_type FROM content_ranking_controls r
     JOIN content_catalog c ON c.stable_key = r.content_key
     WHERE r.ranking_key = ? AND r.content_key = ?`,
    [rankingKey, contentKey],
  )) };
}

function deleteRankingControl(params) {
  const rankingKey = validRankingKey(params.rankingKey);
  const contentKey = requiredString(params.contentKey, "contentKey", 240);
  return { deleted: Number(run(
    "DELETE FROM content_ranking_controls WHERE ranking_key = ? AND content_key = ?",
    [rankingKey, contentKey],
  ).changes || 0) > 0 };
}

function campaignList(query) {
  const { page, pageSize, offset } = pageParams(query);
  const status = optionalString(query.status, 30).toLowerCase();
  const where = status ? "WHERE status = ?" : "";
  const params = status ? [status] : [];
  const rows = all(
    `SELECT c.*,
            (SELECT COUNT(*) FROM activity_tasks t WHERE t.campaign_id = c.id) AS task_count,
            (SELECT COUNT(*) FROM reward_claims rc WHERE rc.campaign_id = c.id) AS claim_count
     FROM campaigns c ${where} ORDER BY c.id DESC LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  );
  const tasksByCampaign = new Map();
  if (rows.length) {
    const ids = rows.map((row) => row.id);
    const placeholders = ids.map(() => "?").join(",");
    for (const task of all(
      `SELECT * FROM activity_tasks WHERE campaign_id IN (${placeholders}) ORDER BY sort_order, id`,
      ids,
    )) {
      if (!tasksByCampaign.has(task.campaign_id)) tasksByCampaign.set(task.campaign_id, []);
      tasksByCampaign.get(task.campaign_id).push(taskAdminJson(task));
    }
  }
  return {
    page,
    pageSize,
    total: Number(one(`SELECT COUNT(*) AS total FROM campaigns ${where}`, params)?.total || 0),
    items: rows.map((row) => ({
      ...campaignAdminJson(row),
      tasks: tasksByCampaign.get(row.id) || [],
    })),
  };
}

function campaignDetail(idValue) {
  const id = positiveId(idValue, "campaign id");
  const campaign = one("SELECT * FROM campaigns WHERE id = ?", [id]);
  if (!campaign) throw badRequest("campaign not found");
  return {
    item: campaignAdminJson(campaign),
    tasks: all("SELECT * FROM activity_tasks WHERE campaign_id = ? ORDER BY sort_order, id", [id]).map(taskAdminJson),
    revisions: all(
      "SELECT revision, changed_by, created_at FROM campaign_revisions WHERE campaign_id = ? ORDER BY revision DESC",
      [id],
    ),
  };
}

function createCampaign(adminId, body) {
  const values = campaignInput(body);
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = run(
      `INSERT INTO campaigns
       (campaign_key, title, description, banner_url, status, starts_at, ends_at,
        audience_json, min_version_code, max_version_code, created_by, updated_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [values.campaignKey, values.title, values.description, values.bannerUrl, values.status,
       values.startsAt, values.endsAt, values.audienceJson, values.minVersionCode,
       values.maxVersionCode, adminId, adminId],
    );
    const id = Number(result.lastInsertRowid);
    for (const task of normalizedTasks(body.tasks || [])) insertTask(id, task);
    snapshotCampaign(id, adminId);
    db.exec("COMMIT");
    return campaignDetail(id);
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function updateCampaign(adminId, idValue, body) {
  const id = positiveId(idValue, "campaign id");
  const current = one("SELECT * FROM campaigns WHERE id = ?", [id]);
  if (!current) throw badRequest("campaign not found");
  const values = campaignInput(body, current);
  db.exec("BEGIN IMMEDIATE");
  try {
    const revision = Number(current.revision || 1) + 1;
    run(
      `UPDATE campaigns SET campaign_key = ?, title = ?, description = ?, banner_url = ?,
       status = ?, starts_at = ?, ends_at = ?, audience_json = ?, min_version_code = ?,
       max_version_code = ?, revision = ?, updated_by = ?, updated_at = datetime('now')
       WHERE id = ?`,
      [values.campaignKey, values.title, values.description, values.bannerUrl, values.status,
       values.startsAt, values.endsAt, values.audienceJson, values.minVersionCode,
       values.maxVersionCode, revision, adminId, id],
    );
    if (Array.isArray(body.tasks)) {
      run("UPDATE activity_tasks SET status = 'disabled' WHERE campaign_id = ?", [id]);
      run("DELETE FROM activity_tasks WHERE campaign_id = ? AND id NOT IN (SELECT task_id FROM reward_claims WHERE campaign_id = ?)", [id, id]);
      for (const task of normalizedTasks(body.tasks)) insertTask(id, task);
    }
    snapshotCampaign(id, adminId);
    db.exec("COMMIT");
    return campaignDetail(id);
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function deleteCampaign(idValue) {
  const id = positiveId(idValue, "campaign id");
  if (one("SELECT 1 FROM reward_claims WHERE campaign_id = ? LIMIT 1", [id])) {
    run("UPDATE campaigns SET status = 'ended', updated_at = datetime('now') WHERE id = ?", [id]);
    return { deleted: false, archived: true };
  }
  return { deleted: Number(run("DELETE FROM campaigns WHERE id = ?", [id]).changes || 0) > 0, archived: false };
}

function rollbackCampaign(adminId, idValue, revisionValue) {
  const id = positiveId(idValue, "campaign id");
  const revision = positiveId(revisionValue, "revision");
  const current = one("SELECT * FROM campaigns WHERE id = ?", [id]);
  const snapshot = one(
    "SELECT * FROM campaign_revisions WHERE campaign_id = ? AND revision = ?",
    [id, revision],
  );
  if (!current || !snapshot) throw badRequest("campaign revision not found");
  const campaign = parseJson(snapshot.campaign_json, null);
  const tasks = parseJson(snapshot.tasks_json, []);
  if (!campaign || !Array.isArray(tasks)) throw badRequest("campaign revision is invalid");
  db.exec("BEGIN IMMEDIATE");
  try {
    const nextRevision = Number(current.revision || 1) + 1;
    run(
      `UPDATE campaigns SET campaign_key = ?, title = ?, description = ?, banner_url = ?,
       status = 'paused', starts_at = ?, ends_at = ?, audience_json = ?,
       min_version_code = ?, max_version_code = ?, revision = ?, updated_by = ?,
       updated_at = datetime('now') WHERE id = ?`,
      [campaign.campaign_key, campaign.title, campaign.description, campaign.banner_url,
       campaign.starts_at, campaign.ends_at, campaign.audience_json,
       campaign.min_version_code, campaign.max_version_code, nextRevision, adminId, id],
    );
    run("UPDATE activity_tasks SET status = 'disabled' WHERE campaign_id = ?", [id]);
    run("DELETE FROM activity_tasks WHERE campaign_id = ? AND id NOT IN (SELECT task_id FROM reward_claims WHERE campaign_id = ?)", [id, id]);
    for (const task of tasks) insertTask(id, task);
    snapshotCampaign(id, adminId);
    db.exec("COMMIT");
    return { ...campaignDetail(id), rolledBackFromRevision: revision, revision: nextRevision };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function createCampaignTask(adminId, campaignIdValue, body) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  if (!one("SELECT 1 FROM campaigns WHERE id = ?", [campaignId])) throw badRequest("campaign not found");
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = insertTask(campaignId, taskInput(body));
    bumpAndSnapshotCampaign(campaignId, adminId);
    db.exec("COMMIT");
    return { item: taskAdminJson(one("SELECT * FROM activity_tasks WHERE id = ?", [Number(result.lastInsertRowid)])) };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function updateCampaignTask(adminId, campaignIdValue, taskIdValue, body) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  const taskId = positiveId(taskIdValue, "task id");
  const current = one("SELECT * FROM activity_tasks WHERE id = ? AND campaign_id = ?", [taskId, campaignId]);
  if (!current) throw badRequest("activity task not found");
  const values = taskInput(body, current);
  db.exec("BEGIN IMMEDIATE");
  try {
    run(
      `UPDATE activity_tasks SET task_key = ?, title = ?, description = ?, event_name = ?,
       target_count = ?, reward_points = ?, reward_coins = ?, filters_json = ?,
       sort_order = ?, status = ?, updated_at = datetime('now') WHERE id = ?`,
      [values.taskKey, values.title, values.description, values.eventName, values.targetCount,
       values.rewardPoints, values.rewardCoins, values.filtersJson, values.sortOrder, values.status, taskId],
    );
    bumpAndSnapshotCampaign(campaignId, adminId);
    db.exec("COMMIT");
    return { item: taskAdminJson(one("SELECT * FROM activity_tasks WHERE id = ?", [taskId])) };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function deleteCampaignTask(adminId, campaignIdValue, taskIdValue) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  const taskId = positiveId(taskIdValue, "task id");
  if (one("SELECT 1 FROM reward_claims WHERE task_id = ? LIMIT 1", [taskId])) {
    run("UPDATE activity_tasks SET status = 'disabled', updated_at = datetime('now') WHERE id = ? AND campaign_id = ?", [taskId, campaignId]);
    bumpAndSnapshotCampaign(campaignId, adminId);
    return { deleted: false, archived: true };
  }
  db.exec("BEGIN IMMEDIATE");
  try {
    const deleted = Number(run("DELETE FROM activity_tasks WHERE id = ? AND campaign_id = ?", [taskId, campaignId]).changes || 0) > 0;
    bumpAndSnapshotCampaign(campaignId, adminId);
    db.exec("COMMIT");
    return { deleted, archived: false };
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function seasonList(query) {
  const { page, pageSize, offset } = pageParams(query);
  return {
    page,
    pageSize,
    total: Number(one("SELECT COUNT(*) AS total FROM horse_race_seasons")?.total || 0),
    items: all(
      `SELECT s.*,
              (SELECT COUNT(*) FROM horse_race_season_user_stats us WHERE us.season_id = s.id) AS participants
       FROM horse_race_seasons s ORDER BY s.id DESC LIMIT ? OFFSET ?`,
      [pageSize, offset],
    ).map(seasonAdminJson),
  };
}

function seasonDetail(idValue) {
  const id = positiveId(idValue, "season id");
  const season = one("SELECT * FROM horse_race_seasons WHERE id = ?", [id]);
  if (!season) throw badRequest("season not found");
  return {
    item: seasonAdminJson(season),
    leaderboard: horseRaceSeasonState(0, 100).season?.id === id
      ? horseRaceSeasonState(0, 100).leaderboard
      : all(
          `SELECT s.*, u.nickname, u.avatar_url FROM horse_race_season_user_stats s
           JOIN users u ON u.id = s.user_id WHERE s.season_id = ?
           ORDER BY s.points DESC, s.wins DESC LIMIT 100`,
          [id],
        ),
    tasks: all("SELECT * FROM horse_race_season_tasks WHERE season_id = ? ORDER BY sort_order, id", [id]),
    rewards: all("SELECT * FROM horse_race_season_rewards WHERE season_id = ? ORDER BY min_rank, id", [id]),
  };
}

function createSeason(adminId, body) {
  const values = seasonInput(body);
  db.exec("BEGIN IMMEDIATE");
  try {
    if (values.status === "active") run("UPDATE horse_race_seasons SET status = 'paused' WHERE status = 'active'");
    const result = run(
      `INSERT INTO horse_race_seasons
       (season_key, title, status, starts_at, ends_at, config_json, created_by, updated_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [values.seasonKey, values.title, values.status, values.startsAt, values.endsAt, values.configJson, adminId, adminId],
    );
    const id = Number(result.lastInsertRowid);
    for (const task of Array.isArray(body.tasks) ? body.tasks : []) insertSeasonTask(id, seasonTaskInput(task));
    for (const reward of Array.isArray(body.rewards) ? body.rewards : []) insertSeasonReward(id, seasonRewardInput(reward));
    db.exec("COMMIT");
    return seasonDetail(id);
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function updateSeason(adminId, idValue, body) {
  const id = positiveId(idValue, "season id");
  const current = one("SELECT * FROM horse_race_seasons WHERE id = ?", [id]);
  if (!current) throw badRequest("season not found");
  const values = seasonInput(body, current);
  db.exec("BEGIN IMMEDIATE");
  try {
    if (values.status === "active") run("UPDATE horse_race_seasons SET status = 'paused' WHERE status = 'active' AND id <> ?", [id]);
    run(
      `UPDATE horse_race_seasons SET season_key = ?, title = ?, status = ?, starts_at = ?,
       ends_at = ?, config_json = ?, revision = revision + 1, updated_by = ?,
       updated_at = datetime('now') WHERE id = ?`,
      [values.seasonKey, values.title, values.status, values.startsAt, values.endsAt, values.configJson, adminId, id],
    );
    db.exec("COMMIT");
    return seasonDetail(id);
  } catch (error) {
    safeRollback();
    throw error;
  }
}

function createSeasonTask(seasonIdValue, body) {
  const seasonId = positiveId(seasonIdValue, "season id");
  if (!one("SELECT 1 FROM horse_race_seasons WHERE id = ?", [seasonId])) throw badRequest("season not found");
  const result = insertSeasonTask(seasonId, seasonTaskInput(body));
  return { item: one("SELECT * FROM horse_race_season_tasks WHERE id = ?", [Number(result.lastInsertRowid)]) };
}

function createSeasonReward(seasonIdValue, body) {
  const seasonId = positiveId(seasonIdValue, "season id");
  if (!one("SELECT 1 FROM horse_race_seasons WHERE id = ?", [seasonId])) throw badRequest("season not found");
  const result = insertSeasonReward(seasonId, seasonRewardInput(body));
  return { item: one("SELECT * FROM horse_race_season_rewards WHERE id = ?", [Number(result.lastInsertRowid)]) };
}

function campaignInput(body, current = null) {
  const startsAt = dateText(body.startsAt ?? current?.starts_at ?? "", "startsAt");
  const endsAt = dateText(body.endsAt ?? current?.ends_at ?? "", "endsAt");
  if (startsAt && endsAt && startsAt >= endsAt) throw badRequest("endsAt must be after startsAt");
  const minVersionCode = boundedInt(body.minVersionCode ?? current?.min_version_code ?? 0, 0, 100000000, "minVersionCode");
  const maxVersionCode = boundedInt(body.maxVersionCode ?? current?.max_version_code ?? 0, 0, 100000000, "maxVersionCode");
  if (maxVersionCode && minVersionCode > maxVersionCode) throw badRequest("version range is invalid");
  const status = String(body.status ?? current?.status ?? "draft").toLowerCase();
  if (!campaignStatuses.has(status)) throw badRequest("campaign status is invalid");
  return {
    campaignKey: validKey(body.campaignKey ?? current?.campaign_key, "campaignKey"),
    title: requiredString(body.title ?? current?.title, "title", 200),
    description: optionalString(body.description ?? current?.description, 2000),
    bannerUrl: optionalString(body.bannerUrl ?? current?.banner_url, 1000),
    status,
    startsAt,
    endsAt,
    audienceJson: jsonObject(body.audience ?? parseJson(current?.audience_json, {}), "audience"),
    minVersionCode,
    maxVersionCode,
  };
}

function taskInput(body, current = null) {
  const eventName = String(body.eventName ?? current?.event_name ?? "").toLowerCase();
  if (!activityEventNames.has(eventName)) throw badRequest("task eventName is invalid");
  const status = String(body.status ?? current?.status ?? "active").toLowerCase();
  if (!["active", "disabled"].includes(status)) throw badRequest("task status is invalid");
  return {
    taskKey: validKey(body.taskKey ?? current?.task_key, "taskKey"),
    title: requiredString(body.title ?? current?.title, "title", 200),
    description: optionalString(body.description ?? current?.description, 1000),
    eventName,
    targetCount: boundedInt(body.targetCount ?? current?.target_count ?? 1, 1, 1000000, "targetCount"),
    rewardPoints: boundedInt(body.rewardPoints ?? current?.reward_points ?? 0, 0, 100000, "rewardPoints"),
    rewardCoins: boundedInt(body.rewardCoins ?? current?.reward_coins ?? 0, 0, 100000, "rewardCoins"),
    filtersJson: jsonObject(body.filters ?? parseJson(current?.filters_json, {}), "filters"),
    sortOrder: boundedInt(body.sortOrder ?? current?.sort_order ?? 0, -100000, 100000, "sortOrder"),
    status,
  };
}

function normalizedTasks(tasks) {
  if (!Array.isArray(tasks) || tasks.length > 100) throw badRequest("tasks is invalid");
  return tasks.map((task) => taskInput(task));
}

function insertTask(campaignId, task) {
  const values = task.taskKey
    ? task
    : task.task_key
      ? {
          taskKey: task.task_key,
          title: task.title,
          description: task.description,
          eventName: task.event_name,
          targetCount: task.target_count,
          rewardPoints: task.reward_points,
          rewardCoins: task.reward_coins,
          filtersJson: task.filters_json,
          sortOrder: task.sort_order,
          status: task.status,
        }
      : taskInput(task);
  return run(
    `INSERT INTO activity_tasks
     (campaign_id, task_key, title, description, event_name, target_count,
      reward_points, reward_coins, filters_json, sort_order, status)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(campaign_id, task_key) DO UPDATE SET
       title = excluded.title, description = excluded.description, event_name = excluded.event_name,
       target_count = excluded.target_count, reward_points = excluded.reward_points,
       reward_coins = excluded.reward_coins, filters_json = excluded.filters_json,
       sort_order = excluded.sort_order,
       status = excluded.status,
       updated_at = datetime('now')`,
    [campaignId, values.taskKey || values.task_key, values.title, values.description,
     values.eventName || values.event_name, values.targetCount || values.target_count,
     values.rewardPoints ?? values.reward_points, values.rewardCoins ?? values.reward_coins,
     values.filtersJson || values.filters_json, values.sortOrder ?? values.sort_order,
     values.status || "active"],
  );
}

function snapshotCampaign(campaignId, adminId) {
  const campaign = one("SELECT * FROM campaigns WHERE id = ?", [campaignId]);
  const tasks = all("SELECT * FROM activity_tasks WHERE campaign_id = ? ORDER BY id", [campaignId]);
  run(
    `INSERT OR REPLACE INTO campaign_revisions
     (campaign_id, revision, campaign_json, tasks_json, changed_by)
     VALUES (?, ?, ?, ?, ?)`,
    [campaignId, campaign.revision, JSON.stringify(campaign), JSON.stringify(tasks), adminId],
  );
}

function bumpAndSnapshotCampaign(campaignId, adminId) {
  run(
    "UPDATE campaigns SET revision = revision + 1, updated_by = ?, updated_at = datetime('now') WHERE id = ?",
    [adminId, campaignId],
  );
  snapshotCampaign(campaignId, adminId);
}

function seasonInput(body, current = null) {
  const startsAt = dateText(body.startsAt ?? current?.starts_at, "startsAt", true);
  const endsAt = dateText(body.endsAt ?? current?.ends_at, "endsAt", true);
  if (startsAt >= endsAt) throw badRequest("endsAt must be after startsAt");
  const status = String(body.status ?? current?.status ?? "draft").toLowerCase();
  if (!seasonStatuses.has(status)) throw badRequest("season status is invalid");
  return {
    seasonKey: validKey(body.seasonKey ?? current?.season_key, "seasonKey"),
    title: requiredString(body.title ?? current?.title, "title", 200),
    status,
    startsAt,
    endsAt,
    configJson: jsonObject(body.config ?? parseJson(current?.config_json, {}), "config"),
  };
}

function seasonTaskInput(body) {
  const metric = String(body.metric || "").toLowerCase();
  if (!seasonMetrics.has(metric)) throw badRequest("season task metric is invalid");
  return {
    taskKey: validKey(body.taskKey, "taskKey"),
    title: requiredString(body.title, "title", 200),
    metric,
    targetCount: boundedInt(body.targetCount ?? 1, 1, 10000000, "targetCount"),
    rewardPoints: boundedInt(body.rewardPoints ?? 0, 0, 100000, "rewardPoints"),
    rewardCoins: boundedInt(body.rewardCoins ?? 0, 0, 100000, "rewardCoins"),
    status: body.status === "disabled" ? "disabled" : "active",
    sortOrder: boundedInt(body.sortOrder ?? 0, -100000, 100000, "sortOrder"),
  };
}

function insertSeasonTask(seasonId, task) {
  return run(
    `INSERT INTO horse_race_season_tasks
     (season_id, task_key, title, metric, target_count, reward_points, reward_coins, status, sort_order)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [seasonId, task.taskKey, task.title, task.metric, task.targetCount, task.rewardPoints, task.rewardCoins, task.status, task.sortOrder],
  );
}

function seasonRewardInput(body) {
  return {
    rewardKey: validKey(body.rewardKey, "rewardKey"),
    title: requiredString(body.title, "title", 200),
    tier: optionalString(body.tier, 50),
    minRank: boundedInt(body.minRank ?? 0, 0, 1000000, "minRank"),
    maxRank: boundedInt(body.maxRank ?? 0, 0, 1000000, "maxRank"),
    rewardPoints: boundedInt(body.rewardPoints ?? 0, 0, 100000, "rewardPoints"),
    rewardCoins: boundedInt(body.rewardCoins ?? 0, 0, 100000, "rewardCoins"),
  };
}

function insertSeasonReward(seasonId, reward) {
  return run(
    `INSERT INTO horse_race_season_rewards
     (season_id, reward_key, title, tier, min_rank, max_rank, reward_points, reward_coins)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [seasonId, reward.rewardKey, reward.title, reward.tier, reward.minRank, reward.maxRank, reward.rewardPoints, reward.rewardCoins],
  );
}

function rankingControlJson(row) {
  return {
    rankingKey: row.ranking_key,
    contentKey: row.content_key,
    title: row.title,
    contentType: row.content_type,
    pinned: Boolean(row.pinned),
    excluded: Boolean(row.excluded),
    manualWeight: Number(row.manual_weight || 0),
    note: row.note || "",
    updatedAt: row.updated_at,
  };
}

function campaignAdminJson(row) {
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
    taskCount: Number(row.task_count || 0),
    claimCount: Number(row.claim_count || 0),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function taskAdminJson(row) {
  return {
    id: row.id,
    campaignId: row.campaign_id,
    taskKey: row.task_key,
    title: row.title,
    description: row.description,
    eventName: row.event_name,
    targetCount: Number(row.target_count || 1),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    filters: parseJson(row.filters_json, {}),
    sortOrder: Number(row.sort_order || 0),
    status: row.status,
  };
}

function seasonAdminJson(row) {
  return {
    id: row.id,
    seasonKey: row.season_key,
    title: row.title,
    status: row.status,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    config: parseJson(row.config_json, {}),
    revision: Number(row.revision || 1),
    participants: Number(row.participants || 0),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function validRankingKey(value) {
  const key = validKey(value, "rankingKey");
  if (key === "all" || rankingMetrics.has(key)) return key;
  const [period, metric] = key.split("_");
  if (!rankingPeriods.has(period) || !rankingMetrics.has(metric)) throw badRequest("rankingKey is invalid");
  return key;
}

function validKey(value, name) {
  const text = requiredString(value, name, 120).toLowerCase();
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(text)) throw badRequest(`${name} is invalid`);
  return text;
}

function positiveId(value, name) {
  const id = Math.trunc(Number(value));
  if (!Number.isFinite(id) || id <= 0) throw badRequest(`${name} is invalid`);
  return id;
}

function boundedInt(value, minimum, maximum, name) {
  const number = Math.trunc(Number(value));
  if (!Number.isFinite(number) || number < minimum || number > maximum) throw badRequest(`${name} is invalid`);
  return number;
}

function boundedNumber(value, minimum, maximum, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < minimum || number > maximum) throw badRequest(`${name} is invalid`);
  return number;
}

function dateText(value, name, required = false) {
  const text = String(value || "").trim();
  if (!text) {
    if (required) throw badRequest(`${name} is required`);
    return "";
  }
  const parsed = new Date(text);
  if (!Number.isFinite(parsed.getTime())) throw badRequest(`${name} is invalid`);
  return parsed.toISOString().slice(0, 19).replace("T", " ");
}

function jsonObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw badRequest(`${name} must be an object`);
  const encoded = JSON.stringify(value);
  if (encoded.length > 32000) throw badRequest(`${name} is too large`);
  return encoded;
}

function parseJson(value, fallback) {
  try {
    return JSON.parse(String(value || "")) ?? fallback;
  } catch {
    return fallback;
  }
}

function safeRollback() {
  try {
    db.exec("ROLLBACK");
  } catch {
    // No active transaction.
  }
}
