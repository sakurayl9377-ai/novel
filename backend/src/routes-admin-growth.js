import { all, db, one, run } from "./db.js";
import { campaignBannerRoutes } from "./campaign-banner-upload.js";
import {
  finalizeHorseRaceSeason,
  horseRaceSeasonState,
} from "./growth-operations.js";
import {
  createGrowthCampaign,
  createGrowthCampaignTask,
  growthCampaignDetail,
  growthCampaignList,
  growthOperationRankings,
  growthOperationsWorkbench,
  removeGrowthCampaignTask,
  removeRankingControl,
  restoreGrowthCampaignRevision,
  saveRankingControl,
  transitionGrowthCampaign,
  updateGrowthCampaign,
  updateGrowthCampaignTask,
} from "./growth-ops-service.js";
import { badRequest, optionalString, pageParams, requiredString } from "./validators.js";

const seasonStatuses = new Set(["draft", "active", "paused", "ended"]);
const seasonMetrics = new Set(["rounds", "wins", "bet", "profit"]);

export async function adminGrowthRoutes(app) {
  await campaignBannerRoutes(app);

  app.get(
    "/admin/growth/workbench",
    { preHandler: app.adminRequired },
    async (request) => growthOperationsWorkbench(request.query || {}),
  );

  app.get(
    "/admin/growth/overview",
    { preHandler: app.adminRequired },
    async (request) => growthOperationsWorkbench(request.query || {}),
  );

  app.get(
    "/admin/growth/rankings",
    { preHandler: app.adminRequired },
    async (request) => growthOperationRankings(request.query || {}),
  );

  app.put(
    "/admin/growth/rankings/:rankingKey/:contentKey",
    { preHandler: app.adminRequired },
    async (request) => saveRankingControl(request.user.id, request.params, request.body || {}),
  );

  app.delete(
    "/admin/growth/rankings/:rankingKey/:contentKey",
    { preHandler: app.adminRequired },
    async (request) => removeRankingControl(request.user.id, request.params, request.body || {}),
  );

  app.get(
    "/admin/growth/campaigns",
    { preHandler: app.adminRequired },
    async (request) => growthCampaignList(request.query || {}),
  );

  app.get(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => growthCampaignDetail(request.params.id),
  );

  app.post(
    "/admin/growth/campaigns",
    { preHandler: app.adminRequired },
    async (request) => createGrowthCampaign(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => updateGrowthCampaign(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/growth/campaigns/:id/status",
    { preHandler: app.adminRequired },
    async (request) => transitionGrowthCampaign(request.user.id, request.params.id, request.body || {}),
  );

  app.delete(
    "/admin/growth/campaigns/:id",
    { preHandler: app.adminRequired },
    async (request) => transitionGrowthCampaign(
      request.user.id,
      request.params.id,
      { ...(request.body || {}), status: "ended" },
    ),
  );

  app.post(
    "/admin/growth/seasons/:id/finalize",
    { preHandler: app.adminRequired },
    async (request) => finalizeHorseRaceSeason(positiveId(request.params.id, "season id")),
  );

  app.post(
    "/admin/growth/campaigns/:id/rollback",
    { preHandler: app.adminRequired },
    async (request) => restoreGrowthCampaignRevision(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/growth/campaigns/:id/tasks",
    { preHandler: app.adminRequired },
    async (request) => createGrowthCampaignTask(request.user.id, request.params.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/campaigns/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => updateGrowthCampaignTask(
      request.user.id,
      request.params.id,
      request.params.taskId,
      request.body || {},
    ),
  );

  app.delete(
    "/admin/growth/campaigns/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => removeGrowthCampaignTask(
      request.user.id,
      request.params.id,
      request.params.taskId,
      request.body || {},
    ),
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
