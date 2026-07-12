import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import { config } from "./config.js";
import { all, db, one, run } from "./db.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

export async function adminOperationsRoutes(app) {
  app.get(
    "/admin/operations/overview",
    { preHandler: app.adminRequired },
    async () => operationsOverview(),
  );

  app.get(
    "/admin/finance/events",
    { preHandler: app.adminRequired },
    async (request) => financeEvents(request.query || {}),
  );

  app.get(
    "/admin/horse-race/rounds",
    { preHandler: app.adminRequired },
    async (request) => horseRaceRounds(request.query || {}),
  );

  app.get(
    "/admin/horse-race/rounds/:id",
    { preHandler: app.adminRequired },
    async (request) => horseRaceRoundDetail(request.params.id),
  );

  app.get(
    "/admin/notifications",
    { preHandler: app.adminRequired },
    async (request) => adminBroadcasts(request.query || {}),
  );

  app.post(
    "/admin/notifications/broadcast",
    { preHandler: app.adminRequired },
    async (request) => createBroadcast(request.user.id, request.body || {}),
  );

  app.get(
    "/admin/audit-logs",
    { preHandler: app.adminRequired },
    async (request) => adminAuditLogs(request.query || {}),
  );

  app.get(
    "/admin/app-versions",
    { preHandler: app.adminRequired },
    async () => appVersionDistribution(),
  );

  app.get(
    "/admin/analytics/overview",
    { preHandler: app.adminRequired },
    async (request) => analyticsOverview(request.query || {}),
  );

  app.get(
    "/admin/analytics/errors",
    { preHandler: app.adminRequired },
    async (request) => analyticsErrors(request.query || {}),
  );

  app.get(
    "/admin/releases",
    { preHandler: app.adminRequired },
    async () => releaseOverview(),
  );
}

function operationsOverview() {
  const dbBytes = fs.existsSync(config.dbPath) ? fs.statSync(config.dbPath).size : 0;
  const memory = process.memoryUsage();
  const currentRace = one(
    `SELECT r.id, r.round_key, r.status, r.rules_version, r.phase_started_at,
            r.winner_index, r.created_at, r.locked_at, r.settled_at,
            COUNT(DISTINCT b.user_id) AS participants,
            COALESCE(SUM(b.amount), 0) AS total_staked,
            COALESCE(SUM(b.payout), 0) AS total_payout
     FROM horse_race_rounds r
     LEFT JOIN horse_race_bets b ON b.round_id = r.id
     GROUP BY r.id
     ORDER BY r.id DESC
     LIMIT 1`,
  );

  return {
    generatedAt: new Date().toISOString(),
    service: {
      status: "online",
      uptimeSeconds: Math.floor(process.uptime()),
      nodeVersion: process.version,
      platform: `${process.platform}/${process.arch}`,
      processMemoryBytes: memory.rss,
      heapUsedBytes: memory.heapUsed,
      systemMemoryBytes: os.totalmem(),
      systemFreeMemoryBytes: os.freemem(),
      loadAverage: os.loadavg(),
      dbBytes,
    },
    users: {
      total: count("users"),
      active24h: countWhere("users", "last_login_at >= datetime('now', '-24 hours')"),
      new24h: countWhere("users", "created_at >= datetime('now', '-24 hours')"),
      banned: countWhere("users", "status = 'banned'"),
    },
    content: {
      comments24h: countWhere("comments", "created_at >= datetime('now', '-24 hours')"),
      danmaku24h: countWhere("danmaku", "created_at >= datetime('now', '-24 hours')"),
      chat24h: countWhere("chat_messages", "created_at >= datetime('now', '-24 hours')"),
      openReports: countWhere("reports", "status = 'open'"),
    },
    economy: one(
      `SELECT COALESCE(SUM(points), 0) AS points_outstanding,
              COALESCE(SUM(sakura_coins), 0) AS coins_outstanding
       FROM users`,
    ),
    economy24h: one(
      `SELECT COALESCE(SUM(CASE WHEN points_delta > 0 THEN points_delta ELSE 0 END), 0) AS points_issued,
              COALESCE(SUM(CASE WHEN coins_delta > 0 THEN coins_delta ELSE 0 END), 0) AS coins_issued,
              COALESCE(ABS(SUM(CASE WHEN coins_delta < 0 THEN coins_delta ELSE 0 END)), 0) AS coins_spent,
              COUNT(*) AS event_count
       FROM user_reward_events
       WHERE created_at >= datetime('now', '-24 hours')`,
    ),
    race: {
      current: currentRace ? raceRoundJson(currentRace) : null,
      rounds24h: countWhere(
        "horse_race_rounds",
        "created_at >= datetime('now', '-24 hours')",
      ),
      ...one(
        `SELECT COALESCE(SUM(amount), 0) AS staked24h,
                COALESCE(SUM(payout), 0) AS payout24h,
                COUNT(DISTINCT user_id) AS participants24h
         FROM horse_race_bets
         WHERE created_at >= datetime('now', '-24 hours')`,
      ),
    },
    messaging: {
      broadcasts24h: countWhere(
        "admin_broadcasts",
        "created_at >= datetime('now', '-24 hours')",
      ),
      unreadNotifications: countWhere(
        "system_notifications",
        "read_at = ''",
      ),
    },
    recentAudit: auditRows({ limit: 8 }),
    recentBroadcasts: broadcastRows({ limit: 6 }),
  };
}

function financeEvents(query) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 80);
  const action = optionalString(query.action || query.status, 80);
  const where = [];
  const params = [];
  if (keyword) {
    where.push(
      "(u.email LIKE ? OR u.nickname LIKE ? OR e.description LIKE ? OR e.related_id LIKE ?)",
    );
    const like = `%${keyword}%`;
    params.push(like, like, like, like);
  }
  if (action) {
    where.push("e.action = ?");
    params.push(action);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const total = one(
    `SELECT COUNT(*) AS count
     FROM user_reward_events e
     JOIN users u ON u.id = e.user_id
     ${clause}`,
    params,
  )?.count || 0;
  const summary = one(
    `SELECT COALESCE(SUM(e.points_delta), 0) AS points_delta,
            COALESCE(SUM(e.coins_delta), 0) AS coins_delta,
            COALESCE(SUM(CASE WHEN e.coins_delta > 0 THEN e.coins_delta ELSE 0 END), 0) AS coins_issued,
            COALESCE(ABS(SUM(CASE WHEN e.coins_delta < 0 THEN e.coins_delta ELSE 0 END)), 0) AS coins_spent
     FROM user_reward_events e
     JOIN users u ON u.id = e.user_id
     ${clause}`,
    params,
  );
  const items = all(
    `SELECT e.*, u.email, u.nickname
     FROM user_reward_events e
     JOIN users u ON u.id = e.user_id
     ${clause}
     ORDER BY e.id DESC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  );
  const actions = all(
    `SELECT action, COUNT(*) AS count
     FROM user_reward_events
     GROUP BY action
     ORDER BY count DESC, action ASC`,
  );
  return { page, pageSize, total, summary, actions, items };
}

function horseRaceRounds(query) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 80);
  const status = optionalString(query.status, 30);
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
  const total = one(
    `SELECT COUNT(*) AS count FROM horse_race_rounds r ${clause}`,
    params,
  )?.count || 0;
  const items = all(
    `SELECT r.id, r.round_key, r.status, r.rules_version, r.phase_started_at,
            r.winner_index, r.created_at, r.locked_at, r.settled_at,
            COUNT(b.id) AS bet_count,
            COUNT(DISTINCT b.user_id) AS participants,
            COALESCE(SUM(b.amount), 0) AS total_staked,
            COALESCE(SUM(b.payout), 0) AS total_payout
     FROM horse_race_rounds r
     LEFT JOIN horse_race_bets b ON b.round_id = r.id
     ${clause}
     GROUP BY r.id
     ORDER BY r.id DESC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(raceRoundJson);
  return { page, pageSize, total, items };
}

function horseRaceRoundDetail(rawId) {
  const id = optionalInt(rawId, 0);
  if (!id) throw badRequest("round id is invalid");
  const round = one(
    `SELECT r.*,
            COUNT(b.id) AS bet_count,
            COUNT(DISTINCT b.user_id) AS participants,
            COALESCE(SUM(b.amount), 0) AS total_staked,
            COALESCE(SUM(b.payout), 0) AS total_payout
     FROM horse_race_rounds r
     LEFT JOIN horse_race_bets b ON b.round_id = r.id
     WHERE r.id = ?
     GROUP BY r.id`,
    [id],
  );
  if (!round) throw badRequest("round not found");
  const horseTotals = all(
    `SELECT horse_index, COUNT(*) AS bet_count,
            COUNT(DISTINCT user_id) AS participants,
            COALESCE(SUM(amount), 0) AS total_staked,
            COALESCE(SUM(payout), 0) AS total_payout
     FROM horse_race_bets
     WHERE round_id = ?
     GROUP BY horse_index
     ORDER BY horse_index`,
    [id],
  );
  const bets = all(
    `SELECT b.*, u.email, u.nickname
     FROM horse_race_bets b
     JOIN users u ON u.id = b.user_id
     WHERE b.round_id = ?
     ORDER BY b.id DESC
     LIMIT 200`,
    [id],
  );
  const settled = round.status === "settling" || Boolean(round.settled_at);
  return {
    item: {
      ...raceRoundJson(round),
      horses: parseJson(round.horses_json, []),
      odds: parseJson(round.odds_json, []),
      race: parseJson(round.race_json, {}),
      result: parseJson(round.result_json, {}),
      fairness: {
        algorithm: Number(round.rules_version || 1) >= 2
          ? "seed-commit-v1"
          : "legacy-seed-v1",
        seedCommit: crypto.createHash("sha256").update(round.seed || "").digest("hex"),
        seedReveal: settled ? round.seed || "" : "",
      },
      horseTotals,
      bets,
    },
  };
}

function adminBroadcasts(query) {
  const { page, pageSize, offset } = pageParams(query);
  const total = count("admin_broadcasts");
  return {
    page,
    pageSize,
    total,
    items: broadcastRows({ limit: pageSize, offset }),
  };
}

function createBroadcast(adminUserId, body) {
  const title = requiredString(body.title, "title", 80);
  const content = requiredString(body.content, "content", 2000);
  const category = optionalString(body.category, 40) || "system";
  let broadcastId = 0;
  let recipientCount = 0;
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = run(
      `INSERT INTO admin_broadcasts
       (admin_user_id, title, content, category)
       VALUES (?, ?, ?, ?)`,
      [adminUserId, title, content, category],
    );
    broadcastId = Number(result.lastInsertRowid || 0);
    const notificationResult = run(
      `INSERT INTO system_notifications (user_id, title, content, category)
       SELECT id, ?, ?, ? FROM users WHERE status = 'active'`,
      [title, content, category],
    );
    recipientCount = Number(notificationResult.changes || 0);
    run(
      "UPDATE admin_broadcasts SET recipient_count = ? WHERE id = ?",
      [recipientCount, broadcastId],
    );
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return {
    ok: true,
    item: broadcastRows({ id: broadcastId, limit: 1 })[0],
    recipientCount,
  };
}

function adminAuditLogs(query) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 80);
  const method = optionalString(query.method || query.status, 12).toUpperCase();
  const rows = auditRows({ keyword, method, limit: pageSize, offset });
  const where = [];
  const params = [];
  if (keyword) {
    where.push("(l.path LIKE ? OR u.email LIKE ? OR u.nickname LIKE ?)");
    const like = `%${keyword}%`;
    params.push(like, like, like);
  }
  if (method) {
    where.push("l.method = ?");
    params.push(method);
  }
  const total = one(
    `SELECT COUNT(*) AS count
     FROM admin_audit_logs l
     LEFT JOIN users u ON u.id = l.admin_user_id
     ${where.length ? `WHERE ${where.join(" AND ")}` : ""}`,
    params,
  )?.count || 0;
  return { page, pageSize, total, items: rows };
}

function appVersionDistribution() {
  const versions = all(
    `WITH latest AS (
       SELECT i.*,
              ROW_NUMBER() OVER (
                PARTITION BY i.user_id
                ORDER BY i.last_seen_at DESC, i.id DESC
              ) AS row_number
       FROM user_app_installs i
     )
     SELECT version_name, version_code, platform,
            COUNT(*) AS user_count,
            MAX(last_seen_at) AS last_seen_at
     FROM latest
     WHERE row_number = 1
     GROUP BY version_name, version_code, platform
     ORDER BY version_code DESC, user_count DESC`,
  );
  const latestVersionCode = versions.reduce(
    (highest, item) => Math.max(highest, Number(item.version_code || 0)),
    0,
  );
  const totalUsers = versions.reduce(
    (sum, item) => sum + Number(item.user_count || 0),
    0,
  );
  const currentUsers = versions
    .filter((item) => Number(item.version_code || 0) === latestVersionCode)
    .reduce((sum, item) => sum + Number(item.user_count || 0), 0);
  const registeredUsers = Number(
    one("SELECT COUNT(*) AS count FROM users")?.count || 0,
  );
  const recentInstalls = all(
     `SELECT i.*, u.email, u.nickname
     FROM user_app_installs i
     JOIN users u ON u.id = i.user_id
     ORDER BY i.last_seen_at DESC, i.id DESC
     LIMIT 30`,
  ).map((item) => ({
    id: Number(item.id || 0),
    userId: Number(item.user_id || 0),
    email: item.email || "",
    nickname: item.nickname || "",
    versionName: item.version_name || "",
    versionCode: Number(item.version_code || 0),
    platform: item.platform || "",
    osVersion: item.os_version || "",
    deviceModel: item.device_model || "",
    firstSeenAt: item.first_seen_at || "",
    lastSeenAt: item.last_seen_at || "",
    lastIp: item.last_ip || "",
  }));
  return {
    latestVersionCode,
    registeredUsers,
    reportedUsers: totalUsers,
    unreportedUsers: Math.max(0, registeredUsers - totalUsers),
    currentUsers,
    outdatedUsers: Math.max(0, totalUsers - currentUsers),
    reportingCoverage: registeredUsers
      ? Number((totalUsers / registeredUsers).toFixed(4))
      : 0,
    upgradeCoverage: totalUsers
      ? Number((currentUsers / totalUsers).toFixed(4))
      : 0,
    versions: versions.map((item) => ({
      versionName: item.version_name || "",
      versionCode: Number(item.version_code || 0),
      platform: item.platform || "",
      userCount: Number(item.user_count || 0),
      lastSeenAt: item.last_seen_at || "",
    })),
    recentInstalls,
  };
}

function analyticsOverview(query) {
  const days = Math.max(1, Math.min(90, optionalInt(query.days, 7)));
  const window = `-${days} days`;
  const events = one(
    `SELECT COUNT(*) AS event_count,
            COUNT(DISTINCT install_id) AS active_installs,
            COUNT(DISTINCT session_id) AS sessions
     FROM app_telemetry_events
     WHERE created_at >= datetime('now', ?)`,
    [window],
  ) || {};
  const errors = one(
    `SELECT COUNT(*) AS error_count,
            COALESCE(SUM(fatal), 0) AS fatal_count,
            COUNT(DISTINCT CASE WHEN fatal = 1 THEN session_id END) AS crashed_sessions,
            COUNT(DISTINCT fingerprint) AS error_groups
     FROM app_error_reports
     WHERE created_at >= datetime('now', ?)`,
    [window],
  ) || {};
  const sessionCount = Number(events.sessions || 0);
  const crashedSessions = Number(errors.crashed_sessions || 0);

  const dailyRows = all(
    `SELECT date(created_at) AS day,
            COUNT(*) AS event_count,
            COUNT(DISTINCT install_id) AS active_installs,
            COUNT(DISTINCT session_id) AS sessions
     FROM app_telemetry_events
     WHERE created_at >= datetime('now', ?)
     GROUP BY date(created_at)
     ORDER BY day`,
    [window],
  );
  const dailyErrors = new Map(
    all(
      `SELECT date(created_at) AS day,
              COUNT(*) AS error_count,
              COALESCE(SUM(fatal), 0) AS fatal_count
       FROM app_error_reports
       WHERE created_at >= datetime('now', ?)
       GROUP BY date(created_at)`,
      [window],
    ).map((item) => [item.day, item]),
  );

  const topScreens = all(
    `SELECT screen,
            COUNT(*) AS view_count,
            COUNT(DISTINCT install_id) AS unique_installs,
            ROUND(AVG(CASE WHEN duration_ms > 0 THEN duration_ms END)) AS avg_duration_ms,
            MAX(duration_ms) AS max_duration_ms
     FROM app_telemetry_events
     WHERE created_at >= datetime('now', ?)
       AND event_name = 'screen_view'
       AND screen <> ''
     GROUP BY screen
     ORDER BY view_count DESC
     LIMIT 20`,
    [window],
  );
  const topEvents = all(
    `SELECT event_name,
            COUNT(*) AS event_count,
            COUNT(DISTINCT install_id) AS unique_installs,
            ROUND(AVG(CASE WHEN duration_ms > 0 THEN duration_ms END)) AS avg_duration_ms,
            COALESCE(SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END), 0) AS failure_count
     FROM app_telemetry_events
     WHERE created_at >= datetime('now', ?)
     GROUP BY event_name
     ORDER BY event_count DESC
     LIMIT 30`,
    [window],
  );
  const versionRows = all(
    `SELECT version_name, version_code,
            COUNT(DISTINCT install_id) AS active_installs,
            COUNT(*) AS event_count
     FROM app_telemetry_events
     WHERE created_at >= datetime('now', ?)
     GROUP BY version_name, version_code
     ORDER BY version_code DESC, active_installs DESC`,
    [window],
  );

  const frameMetrics = aggregateFrameMetrics(
    all(
      `SELECT metadata
       FROM app_telemetry_events
       WHERE created_at >= datetime('now', ?)
         AND event_name = 'frame_metrics'
       ORDER BY id DESC
       LIMIT 2000`,
      [window],
    ),
  );

  return {
    days,
    generatedAt: new Date().toISOString(),
    summary: {
      events: Number(events.event_count || 0),
      activeInstalls: Number(events.active_installs || 0),
      sessions: sessionCount,
      errors: Number(errors.error_count || 0),
      fatalErrors: Number(errors.fatal_count || 0),
      errorGroups: Number(errors.error_groups || 0),
      crashFreeRate: sessionCount
        ? Number((1 - Math.min(sessionCount, crashedSessions) / sessionCount).toFixed(4))
        : 1,
    },
    frameMetrics,
    daily: dailyRows.map((item) => {
      const error = dailyErrors.get(item.day) || {};
      return {
        day: item.day || '',
        events: Number(item.event_count || 0),
        activeInstalls: Number(item.active_installs || 0),
        sessions: Number(item.sessions || 0),
        errors: Number(error.error_count || 0),
        fatalErrors: Number(error.fatal_count || 0),
      };
    }),
    topScreens: topScreens.map((item) => ({
      screen: item.screen || '',
      views: Number(item.view_count || 0),
      uniqueInstalls: Number(item.unique_installs || 0),
      avgDurationMs: Number(item.avg_duration_ms || 0),
      maxDurationMs: Number(item.max_duration_ms || 0),
    })),
    topEvents: topEvents.map((item) => ({
      name: item.event_name || '',
      count: Number(item.event_count || 0),
      uniqueInstalls: Number(item.unique_installs || 0),
      avgDurationMs: Number(item.avg_duration_ms || 0),
      failures: Number(item.failure_count || 0),
    })),
    versions: versionRows.map((item) => ({
      versionName: item.version_name || '',
      versionCode: Number(item.version_code || 0),
      activeInstalls: Number(item.active_installs || 0),
      events: Number(item.event_count || 0),
    })),
  };
}

function analyticsErrors(query) {
  const { page, pageSize, offset } = pageParams(query);
  const days = Math.max(1, Math.min(180, optionalInt(query.days, 30)));
  const keyword = optionalString(query.q, 120);
  const versionCode = Math.max(0, optionalInt(query.versionCode, 0));
  const fatalOnly = String(query.fatal || '') === '1' || query.fatal === true;
  const where = ["created_at >= datetime('now', ?)"];
  const params = [`-${days} days`];
  if (keyword) {
    where.push('(error_type LIKE ? OR message LIKE ? OR stack LIKE ? OR screen LIKE ?)');
    const like = `%${keyword}%`;
    params.push(like, like, like, like);
  }
  if (versionCode > 0) {
    where.push('version_code = ?');
    params.push(versionCode);
  }
  if (fatalOnly) where.push('fatal = 1');
  const whereSql = where.join(' AND ');
  const total = Number(
    one(
      `SELECT COUNT(DISTINCT fingerprint) AS count
       FROM app_error_reports
       WHERE ${whereSql}`,
      params,
    )?.count || 0,
  );
  const groups = all(
    `SELECT fingerprint,
            COUNT(*) AS occurrence_count,
            COUNT(DISTINCT install_id) AS affected_installs,
            COALESCE(SUM(fatal), 0) AS fatal_count,
            MIN(created_at) AS first_seen_at,
            MAX(created_at) AS last_seen_at,
            MAX(version_code) AS latest_version_code
     FROM app_error_reports
     WHERE ${whereSql}
     GROUP BY fingerprint
     ORDER BY last_seen_at DESC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  );
  const items = groups.map((group) => {
    const sample = one(
      `SELECT error_type, message, stack, screen, fatal, metadata,
              version_name, version_code, platform, os_version,
              device_model, occurred_at, created_at
       FROM app_error_reports
       WHERE fingerprint = ?
       ORDER BY id DESC
       LIMIT 1`,
      [group.fingerprint],
    ) || {};
    return {
      fingerprint: group.fingerprint || '',
      occurrences: Number(group.occurrence_count || 0),
      affectedInstalls: Number(group.affected_installs || 0),
      fatalCount: Number(group.fatal_count || 0),
      firstSeenAt: group.first_seen_at || '',
      lastSeenAt: group.last_seen_at || '',
      latestVersionCode: Number(group.latest_version_code || 0),
      type: sample.error_type || '',
      message: sample.message || '',
      stack: sample.stack || '',
      screen: sample.screen || '',
      fatal: Boolean(sample.fatal),
      metadata: parseJson(sample.metadata, {}),
      versionName: sample.version_name || '',
      versionCode: Number(sample.version_code || 0),
      platform: sample.platform || '',
      osVersion: sample.os_version || '',
      deviceModel: sample.device_model || '',
      occurredAt: sample.occurred_at || '',
    };
  });
  return { page, pageSize, total, days, items };
}

function aggregateFrameMetrics(rows) {
  const total = {
    samples: 0,
    frames: 0,
    slow16: 0,
    slow32: 0,
    frozen700: 0,
    maxBuildMs: 0,
    maxRasterMs: 0,
  };
  for (const row of rows) {
    const value = parseJson(row.metadata, {});
    total.samples += 1;
    total.frames += Math.max(0, Number(value.frames || 0));
    total.slow16 += Math.max(0, Number(value.slow16 || 0));
    total.slow32 += Math.max(0, Number(value.slow32 || 0));
    total.frozen700 += Math.max(0, Number(value.frozen700 || 0));
    total.maxBuildMs = Math.max(total.maxBuildMs, Number(value.maxBuildMs || 0));
    total.maxRasterMs = Math.max(total.maxRasterMs, Number(value.maxRasterMs || 0));
  }
  return {
    ...total,
    slow16Rate: total.frames ? Number((total.slow16 / total.frames).toFixed(4)) : 0,
    slow32Rate: total.frames ? Number((total.slow32 / total.frames).toFixed(4)) : 0,
  };
}

function releaseOverview() {
  const releaseDir = config.appReleaseDir;
  if (!fs.existsSync(releaseDir)) {
    return {
      configured: false,
      current: null,
      apk: { exists: false, sizeBytes: 0, modifiedAt: "" },
      history: [],
      backups: [],
    };
  }

  const current = readJsonFile(`${releaseDir}/version.json`);
  const apkPath = `${releaseDir}/app-release.apk`;
  const apkStat = fs.existsSync(apkPath) ? fs.statSync(apkPath) : null;
  const names = fs.readdirSync(releaseDir, { withFileTypes: true });
  const history = names
    .filter(
      (item) =>
        item.isFile() &&
        /^version-\d+\.\d+\.\d+\.json$/i.test(item.name),
    )
    .map((item) => readJsonFile(`${releaseDir}/${item.name}`))
    .filter(Boolean)
    .sort((left, right) => Number(right.versionCode || 0) - Number(left.versionCode || 0))
    .slice(0, 50);
  const backups = names
    .filter((item) => item.isDirectory() && item.name.startsWith("backup-"))
    .map((item) => item.name)
    .sort()
    .reverse()
    .slice(0, 30);

  return {
    configured: true,
    current,
    apk: {
      exists: Boolean(apkStat),
      sizeBytes: Number(apkStat?.size || 0),
      modifiedAt: apkStat?.mtime?.toISOString() || "",
    },
    history,
    backups,
  };
}

function auditRows({ keyword = "", method = "", limit = 20, offset = 0 }) {
  const where = [];
  const params = [];
  if (keyword) {
    where.push("(l.path LIKE ? OR u.email LIKE ? OR u.nickname LIKE ?)");
    const like = `%${keyword}%`;
    params.push(like, like, like);
  }
  if (method) {
    where.push("l.method = ?");
    params.push(method);
  }
  return all(
    `SELECT l.*, u.email, u.nickname
     FROM admin_audit_logs l
     LEFT JOIN users u ON u.id = l.admin_user_id
     ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
     ORDER BY l.id DESC
     LIMIT ? OFFSET ?`,
    [...params, limit, offset],
  );
}

function broadcastRows({ id = 0, limit = 20, offset = 0 }) {
  return all(
    `SELECT b.*, u.email, u.nickname
     FROM admin_broadcasts b
     LEFT JOIN users u ON u.id = b.admin_user_id
     ${id ? "WHERE b.id = ?" : ""}
     ORDER BY b.id DESC
     LIMIT ? OFFSET ?`,
    id ? [id, limit, offset] : [limit, offset],
  );
}

function raceRoundJson(row) {
  return {
    id: Number(row.id || 0),
    roundCode: row.round_key || "",
    status: row.status || "",
    rulesVersion: Number(row.rules_version || 1),
    phaseStartedAt: Number(row.phase_started_at || 0),
    winnerIndex: Number(row.winner_index ?? -1),
    betCount: Number(row.bet_count || 0),
    participants: Number(row.participants || 0),
    totalStaked: Number(row.total_staked || 0),
    totalPayout: Number(row.total_payout || 0),
    houseNet: Number(row.total_staked || 0) - Number(row.total_payout || 0),
    createdAt: row.created_at || "",
    lockedAt: row.locked_at || "",
    settledAt: row.settled_at || "",
  };
}

function count(table) {
  return one(`SELECT COUNT(*) AS count FROM ${table}`)?.count || 0;
}

function countWhere(table, where) {
  return one(`SELECT COUNT(*) AS count FROM ${table} WHERE ${where}`)?.count || 0;
}

function parseJson(value, fallback) {
  try {
    return JSON.parse(value || "");
  } catch {
    return fallback;
  }
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}
