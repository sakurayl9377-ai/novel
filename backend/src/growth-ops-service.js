import { all, db, one, run } from "./db.js";
import {
  activityEventNames,
  funnelAnalytics,
  rankingBoard,
  rankingMetrics,
  rankingPeriods,
} from "./growth-operations.js";
import {
  requireExistingCampaignBanner,
  requireOwnedCampaignBanner,
} from "./campaign-banner-upload.js";
import { badRequest, optionalInt, optionalString, pageParams, requiredString } from "./validators.js";

const contentTypes = new Set(["novel", "manga", "anime"]);
const campaignStatuses = new Set(["draft", "active", "paused", "ended"]);
const audienceDefinitions = new Map([
  ["all_registered", { loggedIn: true }],
  ["new_users", { loggedIn: true, segments: ["new_users"] }],
  ["active_users", { loggedIn: true, segments: ["active_users"] }],
  ["readers", { loggedIn: true, segments: ["readers"] }],
  ["anime_viewers", { loggedIn: true, segments: ["anime_viewers"] }],
]);
const userAudiencePredicate = `
  u.role = 'user'
  AND u.status = 'active'
  AND lower(u.email) NOT IN ('chatbot@system.local', 'chat-bot@system.local')`;

export function growthOperationsWorkbench(query = {}) {
  const days = Math.max(1, Math.min(90, optionalInt(query.days, 7)));
  const contentType = normalizedContentType(query.contentType, true);
  const funnel = funnelAnalytics({ days, contentType });
  const rewardTotals = one(
    `SELECT COUNT(*) AS claims,
            COALESCE(SUM(points_awarded), 0) AS points,
            COALESCE(SUM(coins_awarded), 0) AS coins
     FROM reward_claims`,
  );
  return {
    generatedAt: new Date().toISOString(),
    days,
    contentType,
    funnel,
    totals: {
      behaviorEvents: Number(one("SELECT COUNT(*) AS total FROM content_behavior_events")?.total || 0),
      activeUsers30d: Number(one(
        `SELECT COUNT(DISTINCT e.user_id) AS total
         FROM content_behavior_events e JOIN users u ON u.id = e.user_id
         WHERE e.occurred_at >= datetime('now', '-30 days') AND ${userAudiencePredicate}`,
      )?.total || 0),
      activeCampaigns: Number(one("SELECT COUNT(*) AS total FROM campaigns WHERE status = 'active'")?.total || 0),
      rewardClaims: Number(rewardTotals?.claims || 0),
      rewardPoints: Number(rewardTotals?.points || 0),
      rewardCoins: Number(rewardTotals?.coins || 0),
    },
    options: growthOperationOptions(),
  };
}

export function growthOperationRankings(query = {}) {
  const period = optionalString(query.period, 20).toLowerCase() || "weekly";
  const metric = optionalString(query.metric, 30).toLowerCase() || "hot";
  if (!rankingPeriods.has(period) || !rankingMetrics.has(metric)) {
    throw badRequest("growth_ranking_scope_invalid");
  }
  const contentType = normalizedContentType(query.contentType, true);
  const rankingKey = `${period}_${metric}`;
  const controls = all(
    `SELECT r.*, c.title, c.content_type, c.cover_url,
            u.nickname AS admin_nickname, u.email AS admin_email
     FROM content_ranking_controls r
     JOIN content_catalog c ON c.stable_key = r.content_key
     LEFT JOIN users u ON u.id = r.updated_by
     WHERE r.ranking_key IN ('all', ?, ?)
     ORDER BY CASE r.ranking_key WHEN ? THEN 0 WHEN ? THEN 1 ELSE 2 END,
              r.pinned DESC, ABS(r.manual_weight) DESC, r.updated_at DESC`,
    [metric, rankingKey, rankingKey, metric],
  ).map(rankingControlJson);
  return {
    generatedAt: new Date().toISOString(),
    period,
    metric,
    contentType,
    rankingKey,
    items: rankingBoard({
      period,
      metric,
      contentType,
      limit: Math.max(1, Math.min(100, optionalInt(query.limit, 50))),
    }),
    controls,
    events: operationEvents({ entityType: "ranking_control", limit: 40 }),
    options: growthOperationOptions(),
  };
}

export function saveRankingControl(adminId, params, body = {}) {
  const rankingKey = validRankingKey(params.rankingKey);
  const contentKey = requiredString(params.contentKey, "contentKey", 240);
  const catalog = one("SELECT * FROM content_catalog WHERE stable_key = ?", [contentKey]);
  if (!catalog) throw badRequest("growth_ranking_content_not_found");
  const pinned = body.pinned === true;
  const excluded = body.excluded === true;
  if (pinned && excluded) throw badRequest("growth_ranking_control_conflict");
  const manualWeight = boundedNumber(body.manualWeight ?? 0, -100000, 100000, "manualWeight");
  const note = requiredChangeNote(body.note);

  return inImmediateTransaction(() => {
    const current = one(
      "SELECT * FROM content_ranking_controls WHERE ranking_key = ? AND content_key = ?",
      [rankingKey, contentKey],
    );
    requireExpectedRevision(body.expectedRevision, current?.revision || 0, "growth_ranking_revision_conflict");
    const before = current ? rankingControlSnapshot(current) : {};
    if (current) {
      const result = run(
        `UPDATE content_ranking_controls
         SET pinned = ?, excluded = ?, manual_weight = ?, note = ?,
             revision = revision + 1, updated_by = ?, updated_at = datetime('now')
         WHERE ranking_key = ? AND content_key = ? AND revision = ?`,
        [Number(pinned), Number(excluded), manualWeight, note, adminId,
         rankingKey, contentKey, Number(current.revision)],
      );
      if (!result.changes) throw conflict("growth_ranking_revision_conflict");
    } else {
      run(
        `INSERT INTO content_ranking_controls
           (ranking_key, content_key, pinned, excluded, manual_weight, note,
            revision, updated_by)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?)`,
        [rankingKey, contentKey, Number(pinned), Number(excluded), manualWeight, note, adminId],
      );
    }
    const updated = one(
      `SELECT r.*, c.title, c.content_type, c.cover_url,
              u.nickname AS admin_nickname, u.email AS admin_email
       FROM content_ranking_controls r
       JOIN content_catalog c ON c.stable_key = r.content_key
       LEFT JOIN users u ON u.id = r.updated_by
       WHERE r.ranking_key = ? AND r.content_key = ?`,
      [rankingKey, contentKey],
    );
    recordOperationEvent({
      entityType: "ranking_control",
      entityKey: `${rankingKey}:${contentKey}`,
      action: current ? "update" : "create",
      before,
      after: rankingControlSnapshot(updated),
      note,
      adminId,
    });
    return { item: rankingControlJson(updated) };
  });
}

export function removeRankingControl(adminId, params, body = {}) {
  const rankingKey = validRankingKey(params.rankingKey);
  const contentKey = requiredString(params.contentKey, "contentKey", 240);
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const current = one(
      "SELECT * FROM content_ranking_controls WHERE ranking_key = ? AND content_key = ?",
      [rankingKey, contentKey],
    );
    if (!current) throw notFound("growth_ranking_control_not_found");
    requireExpectedRevision(body.expectedRevision, current.revision, "growth_ranking_revision_conflict");
    const result = run(
      `DELETE FROM content_ranking_controls
       WHERE ranking_key = ? AND content_key = ? AND revision = ?`,
      [rankingKey, contentKey, Number(current.revision)],
    );
    if (!result.changes) throw conflict("growth_ranking_revision_conflict");
    recordOperationEvent({
      entityType: "ranking_control",
      entityKey: `${rankingKey}:${contentKey}`,
      action: "remove",
      before: rankingControlSnapshot(current),
      after: {},
      note,
      adminId,
    });
    return { deleted: true };
  });
}

export function growthCampaignList(query = {}) {
  const { page, pageSize, offset } = pageParams(query);
  const status = optionalString(query.status, 30).toLowerCase();
  if (status && !campaignStatuses.has(status)) throw badRequest("growth_campaign_status_invalid");
  const keyword = optionalString(query.q, 120);
  const where = [];
  const params = [];
  if (status) {
    where.push("c.status = ?");
    params.push(status);
  }
  if (keyword) {
    where.push("(c.title LIKE ? OR c.campaign_key LIKE ? OR c.description LIKE ?)");
    const like = `%${keyword}%`;
    params.push(like, like, like);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const rows = all(
    `${campaignSummarySql()} ${clause}
     ORDER BY CASE c.status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END,
              c.updated_at DESC, c.id DESC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  );
  const statusCounts = Object.fromEntries(
    all("SELECT status, COUNT(*) AS total FROM campaigns GROUP BY status")
      .map((row) => [row.status, Number(row.total || 0)]),
  );
  return {
    generatedAt: new Date().toISOString(),
    page,
    pageSize,
    total: Number(one(`SELECT COUNT(*) AS total FROM campaigns c ${clause}`, params)?.total || 0),
    items: rows.map(campaignAdminJson),
    summary: {
      total: Number(one("SELECT COUNT(*) AS total FROM campaigns")?.total || 0),
      draft: Number(statusCounts.draft || 0),
      active: Number(statusCounts.active || 0),
      paused: Number(statusCounts.paused || 0),
      ended: Number(statusCounts.ended || 0),
      pendingClaims: Number(one(
        `SELECT COUNT(*) AS total
         FROM user_activity_progress p
         LEFT JOIN reward_claims rc ON rc.task_id = p.task_id AND rc.user_id = p.user_id
         WHERE p.completed_at <> '' AND rc.id IS NULL`,
      )?.total || 0),
    },
    options: growthOperationOptions(),
  };
}

export function growthCampaignDetail(idValue) {
  const id = positiveId(idValue, "campaign id");
  const row = one(`${campaignSummarySql()} WHERE c.id = ?`, [id]);
  if (!row) throw notFound("growth_campaign_not_found");
  const tasks = campaignTaskRows(id).map(taskAdminJson);
  const item = campaignAdminJson(row);
  return {
    item,
    tasks,
    budget: campaignBudget(row, tasks),
    revisions: all(
      `SELECT r.revision, r.note, r.changed_by, r.created_at,
              u.nickname AS admin_nickname, u.email AS admin_email
       FROM campaign_revisions r LEFT JOIN users u ON u.id = r.changed_by
       WHERE r.campaign_id = ? ORDER BY r.revision DESC`,
      [id],
    ).map(campaignRevisionJson),
    events: operationEvents({ campaignId: id, limit: 80 }),
    transitions: campaignTransitions(item.status),
    options: growthOperationOptions(),
  };
}

export function createGrowthCampaign(adminId, body = {}) {
  const note = requiredChangeNote(body.changeNote);
  const values = campaignInput(body, null, { adminId });
  return inImmediateTransaction(() => {
    if (one("SELECT 1 FROM campaigns WHERE campaign_key = ?", [values.campaignKey])) {
      throw conflict("growth_campaign_key_conflict");
    }
    const result = run(
      `INSERT INTO campaigns
         (campaign_key, title, description, banner_url, status, starts_at,
          ends_at, audience_json, min_version_code, max_version_code,
          revision, created_by, updated_by)
       VALUES (?, ?, ?, ?, 'draft', ?, ?, ?, ?, ?, 1, ?, ?)`,
      [values.campaignKey, values.title, values.description, values.bannerUrl,
       values.startsAt, values.endsAt, values.audienceJson, values.minVersionCode,
       values.maxVersionCode, adminId, adminId],
    );
    const id = Number(result.lastInsertRowid);
    snapshotCampaign(id, adminId, note);
    const after = campaignSnapshot(one("SELECT * FROM campaigns WHERE id = ?", [id]));
    recordOperationEvent({
      entityType: "campaign",
      entityKey: String(id),
      action: "create_draft",
      before: {},
      after,
      note,
      adminId,
    });
    return growthCampaignDetail(id);
  });
}

export function updateGrowthCampaign(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "campaign id");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const current = requireCampaign(id);
    requireCampaignEditable(current);
    requireExpectedRevision(body.expectedRevision, current.revision, "growth_campaign_revision_conflict");
    const values = campaignInput(body, current, { adminId });
    const before = campaignSnapshot(current);
    const result = run(
      `UPDATE campaigns
       SET title = ?, description = ?, banner_url = ?, starts_at = ?, ends_at = ?,
           audience_json = ?, min_version_code = ?, max_version_code = ?,
           revision = revision + 1, updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [values.title, values.description, values.bannerUrl, values.startsAt, values.endsAt,
       values.audienceJson, values.minVersionCode, values.maxVersionCode,
       adminId, id, Number(current.revision)],
    );
    if (!result.changes) throw conflict("growth_campaign_revision_conflict");
    snapshotCampaign(id, adminId, note);
    const after = campaignSnapshot(requireCampaign(id));
    recordOperationEvent({
      entityType: "campaign",
      entityKey: String(id),
      action: "update",
      before,
      after,
      note,
      adminId,
    });
    return growthCampaignDetail(id);
  });
}

export function transitionGrowthCampaign(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "campaign id");
  const targetStatus = String(body.status || "").trim().toLowerCase();
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const current = requireCampaign(id);
    requireExpectedRevision(body.expectedRevision, current.revision, "growth_campaign_revision_conflict");
    if (!campaignTransitions(current.status).includes(targetStatus)) {
      throw conflict("growth_campaign_status_transition_invalid");
    }
    if (targetStatus === "active") {
      validateCampaignActivation(current, body.acknowledgeBudget === true);
    }
    const before = campaignSnapshot(current);
    const result = run(
      `UPDATE campaigns
       SET status = ?, revision = revision + 1, updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [targetStatus, adminId, id, Number(current.revision)],
    );
    if (!result.changes) throw conflict("growth_campaign_revision_conflict");
    snapshotCampaign(id, adminId, note);
    const after = campaignSnapshot(requireCampaign(id));
    recordOperationEvent({
      entityType: "campaign",
      entityKey: String(id),
      action: targetStatus === "active" ? "activate" : targetStatus === "paused" ? "pause" : "end",
      before,
      after,
      note,
      adminId,
    });
    return growthCampaignDetail(id);
  });
}

export function restoreGrowthCampaignRevision(adminId, idValue, body = {}) {
  const id = positiveId(idValue, "campaign id");
  const revision = positiveId(body.revision, "revision");
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const current = requireCampaign(id);
    if (!new Set(["draft", "paused"]).has(current.status)) {
      throw conflict("growth_campaign_restore_requires_pause");
    }
    requireExpectedRevision(body.expectedRevision, current.revision, "growth_campaign_revision_conflict");
    const snapshot = one(
      "SELECT * FROM campaign_revisions WHERE campaign_id = ? AND revision = ?",
      [id, revision],
    );
    if (!snapshot || revision >= Number(current.revision)) {
      throw notFound("growth_campaign_revision_not_found");
    }
    const historicalCampaign = parseJsonObject(snapshot.campaign_json, null);
    const historicalTasks = parseJsonArray(snapshot.tasks_json);
    if (!historicalCampaign || historicalCampaign.campaign_key !== current.campaign_key) {
      throw badRequest("growth_campaign_revision_invalid");
    }
    if (historicalCampaign.banner_url) {
      historicalCampaign.banner_url = requireExistingCampaignBanner(historicalCampaign.banner_url);
    }
    ensureHistoricalTasksRestorable(id, historicalTasks);
    const before = campaignSnapshot(current);
    const nextRevision = Number(current.revision) + 1;
    run(
      `UPDATE campaigns
       SET title = ?, description = ?, banner_url = ?, status = 'paused',
           starts_at = ?, ends_at = ?, audience_json = ?, min_version_code = ?,
           max_version_code = ?, revision = ?, updated_by = ?, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [historicalCampaign.title, historicalCampaign.description || "",
       historicalCampaign.banner_url || "", historicalCampaign.starts_at || "",
       historicalCampaign.ends_at || "", historicalCampaign.audience_json || "{}",
       Number(historicalCampaign.min_version_code || 0),
       Number(historicalCampaign.max_version_code || 0), nextRevision, adminId,
       id, Number(current.revision)],
    );
    replaceRestorableTasks(id, historicalTasks);
    snapshotCampaign(id, adminId, note);
    const after = campaignSnapshot(requireCampaign(id));
    recordOperationEvent({
      entityType: "campaign",
      entityKey: String(id),
      action: "restore_revision",
      before,
      after: { ...after, restoredFromRevision: revision },
      note,
      adminId,
    });
    return { ...growthCampaignDetail(id), restoredFromRevision: revision };
  });
}

export function createGrowthCampaignTask(adminId, campaignIdValue, body = {}) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const campaign = requireCampaign(campaignId);
    requireCampaignEditable(campaign);
    requireExpectedRevision(body.expectedRevision, campaign.revision, "growth_campaign_revision_conflict");
    const values = campaignTaskInput(body);
    requireTaskKeyAvailable(campaignId, values.taskKey);
    const result = insertCampaignTask(campaignId, values);
    const taskId = Number(result.lastInsertRowid);
    bumpCampaignRevision(campaignId, adminId, campaign.revision);
    snapshotCampaign(campaignId, adminId, note);
    const task = one("SELECT * FROM activity_tasks WHERE id = ?", [taskId]);
    recordOperationEvent({
      entityType: "campaign_task",
      entityKey: `${campaignId}:${taskId}`,
      action: "create",
      before: {},
      after: taskSnapshot(task),
      note,
      adminId,
    });
    return growthCampaignDetail(campaignId);
  });
}

export function updateGrowthCampaignTask(adminId, campaignIdValue, taskIdValue, body = {}) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  const taskId = positiveId(taskIdValue, "task id");
  const note = requiredChangeNote(body.changeNote);
  return inImmediateTransaction(() => {
    const campaign = requireCampaign(campaignId);
    requireCampaignEditable(campaign);
    requireExpectedRevision(body.expectedRevision, campaign.revision, "growth_campaign_revision_conflict");
    const current = one(
      "SELECT * FROM activity_tasks WHERE campaign_id = ? AND id = ?",
      [campaignId, taskId],
    );
    if (!current) throw notFound("growth_campaign_task_not_found");
    const values = campaignTaskInput(body, current);
    requireTaskKeyAvailable(campaignId, values.taskKey, taskId);
    enforceTaskLocks(current, values);
    const before = taskSnapshot(current);
    run(
      `UPDATE activity_tasks
       SET task_key = ?, title = ?, description = ?, event_name = ?, target_count = ?,
           reward_points = ?, reward_coins = ?, filters_json = ?, sort_order = ?,
           status = ?, updated_at = datetime('now')
       WHERE id = ? AND campaign_id = ?`,
      [values.taskKey, values.title, values.description, values.eventName,
       values.targetCount, values.rewardPoints, values.rewardCoins, values.filtersJson,
       values.sortOrder, values.status, taskId, campaignId],
    );
    bumpCampaignRevision(campaignId, adminId, campaign.revision);
    snapshotCampaign(campaignId, adminId, note);
    const updated = one("SELECT * FROM activity_tasks WHERE id = ?", [taskId]);
    recordOperationEvent({
      entityType: "campaign_task",
      entityKey: `${campaignId}:${taskId}`,
      action: "update",
      before,
      after: taskSnapshot(updated),
      note,
      adminId,
    });
    return growthCampaignDetail(campaignId);
  });
}

export function removeGrowthCampaignTask(adminId, campaignIdValue, taskIdValue, body = {}) {
  const campaignId = positiveId(campaignIdValue, "campaign id");
  const taskId = positiveId(taskIdValue, "task id");
  const note = requiredChangeNote(body.note);
  return inImmediateTransaction(() => {
    const campaign = requireCampaign(campaignId);
    requireCampaignEditable(campaign);
    requireExpectedRevision(body.expectedRevision, campaign.revision, "growth_campaign_revision_conflict");
    const current = one(
      "SELECT * FROM activity_tasks WHERE campaign_id = ? AND id = ?",
      [campaignId, taskId],
    );
    if (!current) throw notFound("growth_campaign_task_not_found");
    const locked = taskUsage(taskId).progress > 0;
    if (locked) {
      run(
        "UPDATE activity_tasks SET status = 'disabled', updated_at = datetime('now') WHERE id = ?",
        [taskId],
      );
    } else {
      run("DELETE FROM activity_tasks WHERE id = ?", [taskId]);
    }
    bumpCampaignRevision(campaignId, adminId, campaign.revision);
    snapshotCampaign(campaignId, adminId, note);
    recordOperationEvent({
      entityType: "campaign_task",
      entityKey: `${campaignId}:${taskId}`,
      action: locked ? "disable" : "remove",
      before: taskSnapshot(current),
      after: locked ? taskSnapshot(one("SELECT * FROM activity_tasks WHERE id = ?", [taskId])) : {},
      note,
      adminId,
    });
    return growthCampaignDetail(campaignId);
  });
}

function campaignInput(body, current, { adminId }) {
  if (current && Object.hasOwn(body, "campaignKey") && body.campaignKey !== current.campaign_key) {
    throw conflict("growth_campaign_key_locked");
  }
  const startsAt = dateText(valueFrom(body, "startsAt", current?.starts_at || ""), "startsAt");
  const endsAt = dateText(valueFrom(body, "endsAt", current?.ends_at || ""), "endsAt");
  if (startsAt && endsAt && startsAt >= endsAt) throw badRequest("growth_campaign_date_range_invalid");
  const minVersionCode = boundedInteger(
    valueFrom(body, "minVersionCode", current?.min_version_code || 0),
    "minVersionCode", 0, 100000000,
  );
  const maxVersionCode = boundedInteger(
    valueFrom(body, "maxVersionCode", current?.max_version_code || 0),
    "maxVersionCode", 0, 100000000,
  );
  if (maxVersionCode && minVersionCode > maxVersionCode) {
    throw badRequest("growth_campaign_version_range_invalid");
  }
  let bannerUrl = String(valueFrom(body, "bannerUrl", current?.banner_url || "") || "").trim();
  if (bannerUrl && (!current || bannerUrl !== current.banner_url)) {
    bannerUrl = requireOwnedCampaignBanner(bannerUrl, adminId);
  }
  const audiencePreset = Object.hasOwn(body, "audiencePreset")
    ? validAudiencePreset(body.audiencePreset)
    : current
      ? inferAudiencePreset(current.audience_json)
      : "all_registered";
  if (audiencePreset === "legacy_custom") {
    if (Object.hasOwn(body, "audiencePreset")) throw badRequest("growth_campaign_audience_invalid");
  }
  const audienceJson = audiencePreset === "legacy_custom"
    ? current.audience_json
    : JSON.stringify(audienceDefinitions.get(audiencePreset));
  return {
    campaignKey: current?.campaign_key || validKey(body.campaignKey, "campaignKey"),
    title: requiredString(valueFrom(body, "title", current?.title), "title", 200),
    description: optionalString(valueFrom(body, "description", current?.description), 2000),
    bannerUrl,
    startsAt,
    endsAt,
    audienceJson,
    minVersionCode,
    maxVersionCode,
  };
}

function campaignTaskInput(body, current = null) {
  const eventName = String(valueFrom(body, "eventName", current?.event_name) || "").trim().toLowerCase();
  if (!activityEventNames.has(eventName)) throw badRequest("growth_campaign_task_event_invalid");
  const contentType = normalizedContentType(
    valueFrom(body, "contentType", parseJsonObject(current?.filters_json, {}).contentType || ""),
    true,
  );
  const contentKey = optionalString(
    valueFrom(body, "contentKey", parseJsonObject(current?.filters_json, {}).contentKey || ""),
    240,
  );
  if (contentKey) {
    const content = one("SELECT content_type FROM content_catalog WHERE stable_key = ?", [contentKey]);
    if (!content || (contentType && content.content_type !== contentType)) {
      throw badRequest("growth_campaign_task_content_invalid");
    }
  }
  const filters = {
    ...(contentType ? { contentType } : {}),
    ...(contentKey ? { contentKey } : {}),
  };
  const status = String(valueFrom(body, "status", current?.status || "active")).toLowerCase();
  if (!new Set(["active", "disabled"]).has(status)) {
    throw badRequest("growth_campaign_task_status_invalid");
  }
  return {
    taskKey: current?.task_key && !Object.hasOwn(body, "taskKey")
      ? current.task_key
      : validKey(valueFrom(body, "taskKey", current?.task_key), "taskKey"),
    title: requiredString(valueFrom(body, "title", current?.title), "title", 200),
    description: optionalString(valueFrom(body, "description", current?.description), 1000),
    eventName,
    targetCount: boundedInteger(valueFrom(body, "targetCount", current?.target_count || 1), "targetCount", 1, 1000000),
    rewardPoints: boundedInteger(valueFrom(body, "rewardPoints", current?.reward_points || 0), "rewardPoints", 0, 100000),
    rewardCoins: boundedInteger(valueFrom(body, "rewardCoins", current?.reward_coins || 0), "rewardCoins", 0, 100000),
    filtersJson: JSON.stringify(filters),
    sortOrder: boundedInteger(valueFrom(body, "sortOrder", current?.sort_order || 0), "sortOrder", -100000, 100000),
    status,
  };
}

function validateCampaignActivation(campaign, acknowledged) {
  if (!campaign.banner_url) throw badRequest("growth_campaign_banner_required_for_activation");
  requireExistingCampaignBanner(campaign.banner_url);
  if (!campaign.starts_at || !campaign.ends_at || campaign.starts_at >= campaign.ends_at) {
    throw badRequest("growth_campaign_schedule_required_for_activation");
  }
  if (Date.parse(`${campaign.ends_at}Z`) <= Date.now()) {
    throw badRequest("growth_campaign_end_must_be_future");
  }
  if (inferAudiencePreset(campaign.audience_json) === "legacy_custom") {
    throw badRequest("growth_campaign_audience_invalid");
  }
  if (!one(
    "SELECT 1 FROM activity_tasks WHERE campaign_id = ? AND status = 'active' LIMIT 1",
    [campaign.id],
  )) {
    throw badRequest("growth_campaign_task_required_for_activation");
  }
  if (!acknowledged) throw badRequest("growth_campaign_budget_acknowledgement_required");
}

function enforceTaskLocks(current, values) {
  const usage = taskUsage(current.id);
  if (usage.progress > 0) {
    const identityChanged = current.task_key !== values.taskKey ||
      current.event_name !== values.eventName ||
      Number(current.target_count) !== values.targetCount ||
      current.filters_json !== values.filtersJson;
    if (identityChanged) throw conflict("growth_campaign_task_progress_locked");
  }
  if (usage.claims > 0 && (
    Number(current.reward_points) !== values.rewardPoints ||
    Number(current.reward_coins) !== values.rewardCoins
  )) {
    throw conflict("growth_campaign_task_reward_locked");
  }
}

function ensureHistoricalTasksRestorable(campaignId, historicalTasks) {
  const byKey = new Map(historicalTasks.map((task) => [task.task_key, task]));
  for (const current of all("SELECT * FROM activity_tasks WHERE campaign_id = ?", [campaignId])) {
    const usage = taskUsage(current.id);
    if (!usage.progress) continue;
    const historical = byKey.get(current.task_key);
    if (!historical || !lockedTaskShapeEqual(current, historical, usage.claims > 0)) {
      throw conflict("growth_campaign_revision_task_locked");
    }
  }
}

function replaceRestorableTasks(campaignId, historicalTasks) {
  const protectedIds = all(
    `SELECT DISTINCT task_id FROM user_activity_progress WHERE campaign_id = ?
     UNION SELECT DISTINCT task_id FROM reward_claims WHERE campaign_id = ?`,
    [campaignId, campaignId],
  ).map((row) => Number(row.task_id));
  if (protectedIds.length) {
    const placeholders = protectedIds.map(() => "?").join(",");
    run(
      `DELETE FROM activity_tasks WHERE campaign_id = ? AND id NOT IN (${placeholders})`,
      [campaignId, ...protectedIds],
    );
  } else {
    run("DELETE FROM activity_tasks WHERE campaign_id = ?", [campaignId]);
  }
  for (const historical of historicalTasks) {
    insertCampaignTask(campaignId, campaignTaskInputFromSnapshot(historical));
  }
}

function campaignTaskInputFromSnapshot(task) {
  return {
    taskKey: validKey(task.task_key, "taskKey"),
    title: requiredString(task.title, "title", 200),
    description: optionalString(task.description, 1000),
    eventName: activityEventNames.has(task.event_name) ? task.event_name : invalidTaskEvent(),
    targetCount: boundedInteger(task.target_count, "targetCount", 1, 1000000),
    rewardPoints: boundedInteger(task.reward_points, "rewardPoints", 0, 100000),
    rewardCoins: boundedInteger(task.reward_coins, "rewardCoins", 0, 100000),
    filtersJson: JSON.stringify(parseJsonObject(task.filters_json, {})),
    sortOrder: boundedInteger(task.sort_order, "sortOrder", -100000, 100000),
    status: task.status === "disabled" ? "disabled" : "active",
  };
}

function invalidTaskEvent() {
  throw badRequest("growth_campaign_revision_invalid");
}

function lockedTaskShapeEqual(current, historical, includeRewards) {
  return current.event_name === historical.event_name &&
    Number(current.target_count) === Number(historical.target_count) &&
    current.filters_json === historical.filters_json &&
    (!includeRewards || (
      Number(current.reward_points) === Number(historical.reward_points) &&
      Number(current.reward_coins) === Number(historical.reward_coins)
    ));
}

function insertCampaignTask(campaignId, values) {
  return run(
    `INSERT INTO activity_tasks
       (campaign_id, task_key, title, description, event_name, target_count,
        reward_points, reward_coins, filters_json, sort_order, status)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(campaign_id, task_key) DO UPDATE SET
       title = excluded.title, description = excluded.description,
       event_name = excluded.event_name, target_count = excluded.target_count,
       reward_points = excluded.reward_points, reward_coins = excluded.reward_coins,
       filters_json = excluded.filters_json, sort_order = excluded.sort_order,
       status = excluded.status, updated_at = datetime('now')`,
    [campaignId, values.taskKey, values.title, values.description, values.eventName,
     values.targetCount, values.rewardPoints, values.rewardCoins, values.filtersJson,
     values.sortOrder, values.status],
  );
}

function bumpCampaignRevision(campaignId, adminId, expectedRevision) {
  const result = run(
    `UPDATE campaigns
     SET revision = revision + 1, updated_by = ?, updated_at = datetime('now')
     WHERE id = ? AND revision = ?`,
    [adminId, campaignId, Number(expectedRevision)],
  );
  if (!result.changes) throw conflict("growth_campaign_revision_conflict");
}

function snapshotCampaign(campaignId, adminId, note) {
  const campaign = requireCampaign(campaignId);
  const tasks = all("SELECT * FROM activity_tasks WHERE campaign_id = ? ORDER BY sort_order, id", [campaignId]);
  run(
    `INSERT OR REPLACE INTO campaign_revisions
       (campaign_id, revision, campaign_json, tasks_json, note, changed_by)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [campaignId, campaign.revision, JSON.stringify(campaign), JSON.stringify(tasks), note, adminId],
  );
}

function campaignBudget(campaign, tasks) {
  const preset = inferAudiencePreset(campaign.audience_json);
  const eligibleUsers = eligibleAudienceUsers(preset);
  const activeTasks = tasks.filter((task) => task.status === "active");
  const perUserPoints = activeTasks.reduce((sum, task) => sum + task.rewardPoints, 0);
  const perUserCoins = activeTasks.reduce((sum, task) => sum + task.rewardCoins, 0);
  return {
    audiencePreset: preset,
    eligibleUsers,
    activeTasks: activeTasks.length,
    perUserPoints,
    perUserCoins,
    potentialPoints: eligibleUsers * perUserPoints,
    potentialCoins: eligibleUsers * perUserCoins,
    claimedUsers: Number(campaign.claimed_users || 0),
    claims: Number(campaign.claim_count || 0),
    awardedPoints: Number(campaign.awarded_points || 0),
    awardedCoins: Number(campaign.awarded_coins || 0),
  };
}

function eligibleAudienceUsers(preset) {
  let segmentClause = "";
  if (preset === "new_users") segmentClause = "AND u.created_at >= datetime('now', '-7 days')";
  if (preset === "active_users") {
    segmentClause = `AND EXISTS (
      SELECT 1 FROM content_behavior_events e
      WHERE e.user_id = u.id AND e.occurred_at >= datetime('now', '-30 days'))`;
  }
  if (preset === "readers") {
    segmentClause = `AND EXISTS (
      SELECT 1 FROM content_behavior_events e
      WHERE e.user_id = u.id AND e.content_type IN ('novel', 'manga'))`;
  }
  if (preset === "anime_viewers") {
    segmentClause = `AND EXISTS (
      SELECT 1 FROM content_behavior_events e
      WHERE e.user_id = u.id AND e.content_type = 'anime')`;
  }
  return Number(one(
    `SELECT COUNT(*) AS total FROM users u
     WHERE ${userAudiencePredicate} ${segmentClause}`,
  )?.total || 0);
}

function campaignSummarySql() {
  return `SELECT c.*,
    (SELECT COUNT(*) FROM activity_tasks t WHERE t.campaign_id = c.id) AS task_count,
    (SELECT COUNT(*) FROM activity_tasks t WHERE t.campaign_id = c.id AND t.status = 'active') AS active_task_count,
    (SELECT COUNT(*) FROM user_activity_progress p WHERE p.campaign_id = c.id) AS progress_count,
    (SELECT COUNT(*) FROM reward_claims rc WHERE rc.campaign_id = c.id) AS claim_count,
    (SELECT COUNT(DISTINCT rc.user_id) FROM reward_claims rc WHERE rc.campaign_id = c.id) AS claimed_users,
    (SELECT COALESCE(SUM(rc.points_awarded), 0) FROM reward_claims rc WHERE rc.campaign_id = c.id) AS awarded_points,
    (SELECT COALESCE(SUM(rc.coins_awarded), 0) FROM reward_claims rc WHERE rc.campaign_id = c.id) AS awarded_coins
    FROM campaigns c`;
}

function campaignTaskRows(campaignId) {
  return all(
    `SELECT t.*,
            (SELECT COUNT(*) FROM user_activity_progress p WHERE p.task_id = t.id) AS progress_users,
            (SELECT COUNT(*) FROM user_activity_progress p WHERE p.task_id = t.id AND p.completed_at <> '') AS completed_users,
            (SELECT COUNT(*) FROM reward_claims rc WHERE rc.task_id = t.id) AS claim_count
     FROM activity_tasks t WHERE t.campaign_id = ? ORDER BY t.sort_order, t.id`,
    [campaignId],
  );
}

function operationEvents({ entityType = "", campaignId = 0, limit = 50 }) {
  const where = campaignId
    ? `WHERE (e.entity_type = 'campaign' AND e.entity_key = ?)
         OR (e.entity_type = 'campaign_task' AND e.entity_key LIKE ?)`
    : "WHERE e.entity_type = ?";
  const params = campaignId ? [String(campaignId), `${campaignId}:%`] : [entityType];
  return all(
    `SELECT e.*, u.nickname AS admin_nickname, u.email AS admin_email
     FROM growth_operation_events e JOIN users u ON u.id = e.admin_user_id
     ${where} ORDER BY e.id DESC LIMIT ?`,
    [...params, Math.max(1, Math.min(100, limit))],
  ).map(operationEventJson);
}

function recordOperationEvent({ entityType, entityKey, action, before, after, note, adminId }) {
  run(
    `INSERT INTO growth_operation_events
       (entity_type, entity_key, action, before_json, after_json, note, admin_user_id)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [entityType, entityKey, action, JSON.stringify(before || {}), JSON.stringify(after || {}), note, adminId],
  );
}

function growthOperationOptions() {
  return {
    periods: [...rankingPeriods],
    metrics: [...rankingMetrics],
    contentTypes: [...contentTypes],
    rankingScopes: ["all", ...rankingMetrics, ...[...rankingPeriods].flatMap((period) =>
      [...rankingMetrics].map((metric) => `${period}_${metric}`))],
    campaignStatuses: [...campaignStatuses],
    audiencePresets: [...audienceDefinitions.keys()],
    taskEvents: [...activityEventNames],
  };
}

function rankingControlJson(row) {
  return {
    rankingKey: row.ranking_key,
    contentKey: row.content_key,
    title: row.title || "",
    contentType: row.content_type || "",
    coverUrl: row.cover_url || "",
    pinned: Boolean(row.pinned),
    excluded: Boolean(row.excluded),
    manualWeight: Number(row.manual_weight || 0),
    note: row.note || "",
    revision: Number(row.revision || 1),
    admin: {
      id: Number(row.updated_by || 0),
      nickname: row.admin_nickname || "",
      email: row.admin_email || "",
    },
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function campaignAdminJson(row) {
  return {
    id: Number(row.id),
    campaignKey: row.campaign_key,
    title: row.title,
    description: row.description || "",
    bannerUrl: row.banner_url || "",
    status: row.status,
    startsAt: row.starts_at || "",
    endsAt: row.ends_at || "",
    audiencePreset: inferAudiencePreset(row.audience_json),
    minVersionCode: Number(row.min_version_code || 0),
    maxVersionCode: Number(row.max_version_code || 0),
    revision: Number(row.revision || 1),
    taskCount: Number(row.task_count || 0),
    activeTaskCount: Number(row.active_task_count || 0),
    progressCount: Number(row.progress_count || 0),
    claimCount: Number(row.claim_count || 0),
    claimedUsers: Number(row.claimed_users || 0),
    awardedPoints: Number(row.awarded_points || 0),
    awardedCoins: Number(row.awarded_coins || 0),
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function taskAdminJson(row) {
  const filters = parseJsonObject(row.filters_json, {});
  return {
    id: Number(row.id),
    campaignId: Number(row.campaign_id),
    taskKey: row.task_key,
    title: row.title,
    description: row.description || "",
    eventName: row.event_name,
    targetCount: Number(row.target_count || 1),
    rewardPoints: Number(row.reward_points || 0),
    rewardCoins: Number(row.reward_coins || 0),
    contentType: filters.contentType || "",
    contentKey: filters.contentKey || "",
    sortOrder: Number(row.sort_order || 0),
    status: row.status,
    progressUsers: Number(row.progress_users || 0),
    completedUsers: Number(row.completed_users || 0),
    claimCount: Number(row.claim_count || 0),
    identityLocked: Number(row.progress_users || 0) > 0,
    rewardLocked: Number(row.claim_count || 0) > 0,
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function campaignRevisionJson(row) {
  return {
    revision: Number(row.revision),
    note: row.note || "",
    admin: {
      id: Number(row.changed_by || 0),
      nickname: row.admin_nickname || "",
      email: row.admin_email || "",
    },
    createdAt: row.created_at || "",
  };
}

function operationEventJson(row) {
  return {
    id: Number(row.id),
    entityType: row.entity_type,
    entityKey: row.entity_key,
    action: row.action,
    before: parseJsonObject(row.before_json, {}),
    after: parseJsonObject(row.after_json, {}),
    note: row.note || "",
    admin: {
      id: Number(row.admin_user_id),
      nickname: row.admin_nickname || "",
      email: row.admin_email || "",
    },
    createdAt: row.created_at || "",
  };
}

function rankingControlSnapshot(row) {
  return {
    rankingKey: row.ranking_key,
    contentKey: row.content_key,
    pinned: Boolean(row.pinned),
    excluded: Boolean(row.excluded),
    manualWeight: Number(row.manual_weight || 0),
    revision: Number(row.revision || 1),
  };
}

function campaignSnapshot(row) {
  return {
    id: Number(row.id),
    campaignKey: row.campaign_key,
    title: row.title,
    description: row.description || "",
    bannerUrl: row.banner_url || "",
    status: row.status,
    startsAt: row.starts_at || "",
    endsAt: row.ends_at || "",
    audiencePreset: inferAudiencePreset(row.audience_json),
    minVersionCode: Number(row.min_version_code || 0),
    maxVersionCode: Number(row.max_version_code || 0),
    revision: Number(row.revision || 1),
  };
}

function taskSnapshot(row) {
  if (!row) return {};
  return {
    id: Number(row.id),
    taskKey: row.task_key,
    title: row.title,
    eventName: row.event_name,
    targetCount: Number(row.target_count),
    rewardPoints: Number(row.reward_points),
    rewardCoins: Number(row.reward_coins),
    filters: parseJsonObject(row.filters_json, {}),
    sortOrder: Number(row.sort_order || 0),
    status: row.status,
  };
}

function requireCampaign(id) {
  const row = one("SELECT * FROM campaigns WHERE id = ?", [id]);
  if (!row) throw notFound("growth_campaign_not_found");
  return row;
}

function requireCampaignEditable(campaign) {
  if (!new Set(["draft", "paused"]).has(campaign.status)) {
    throw conflict("growth_campaign_edit_requires_pause");
  }
}

function requireTaskKeyAvailable(campaignId, taskKey, excludedTaskId = 0) {
  const duplicate = excludedTaskId
    ? one(
        "SELECT 1 FROM activity_tasks WHERE campaign_id = ? AND task_key = ? AND id <> ?",
        [campaignId, taskKey, excludedTaskId],
      )
    : one(
        "SELECT 1 FROM activity_tasks WHERE campaign_id = ? AND task_key = ?",
        [campaignId, taskKey],
      );
  if (duplicate) throw conflict("growth_campaign_task_key_conflict");
}

function taskUsage(taskId) {
  return {
    progress: Number(one("SELECT COUNT(*) AS total FROM user_activity_progress WHERE task_id = ?", [taskId])?.total || 0),
    claims: Number(one("SELECT COUNT(*) AS total FROM reward_claims WHERE task_id = ?", [taskId])?.total || 0),
  };
}

function campaignTransitions(status) {
  if (status === "draft") return ["active", "ended"];
  if (status === "active") return ["paused", "ended"];
  if (status === "paused") return ["active", "ended"];
  return [];
}

function inferAudiencePreset(value) {
  const audience = typeof value === "string" ? parseJsonObject(value, {}) : value;
  for (const [key, definition] of audienceDefinitions) {
    if (JSON.stringify(audience) === JSON.stringify(definition)) return key;
  }
  return "legacy_custom";
}

function validAudiencePreset(value) {
  const key = String(value || "").trim().toLowerCase();
  if (!audienceDefinitions.has(key)) throw badRequest("growth_campaign_audience_invalid");
  return key;
}

function validRankingKey(value) {
  const key = validKey(value, "rankingKey");
  if (key === "all" || rankingMetrics.has(key)) return key;
  const [period, metric] = key.split("_");
  if (!rankingPeriods.has(period) || !rankingMetrics.has(metric)) {
    throw badRequest("growth_ranking_scope_invalid");
  }
  return key;
}

function normalizedContentType(value, allowEmpty) {
  const type = String(value || "").trim().toLowerCase();
  if (!type && allowEmpty) return "";
  if (!contentTypes.has(type)) throw badRequest("growth_content_type_invalid");
  return type;
}

function validKey(value, name) {
  const text = requiredString(value, name, 120).toLowerCase();
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(text)) throw badRequest(`${name}_invalid`);
  return text;
}

function requiredChangeNote(value) {
  const note = requiredString(value, "note", 500);
  if (note.length < 4) throw badRequest("growth_change_note_invalid");
  return note;
}

function requireExpectedRevision(value, currentRevision, errorCode) {
  const expected = boundedInteger(value, "expectedRevision", 0, 1000000000);
  if (expected !== Number(currentRevision || 0)) {
    const error = conflict(errorCode);
    error.details = { expectedRevision: expected, currentRevision: Number(currentRevision || 0) };
    throw error;
  }
}

function boundedInteger(value, name, minimum, maximum) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw badRequest(`${name}_invalid`);
  }
  return number;
}

function boundedNumber(value, minimum, maximum, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < minimum || number > maximum) {
    throw badRequest(`${name}_invalid`);
  }
  return number;
}

function positiveId(value, name) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw badRequest(`${name}_invalid`);
  return id;
}

function dateText(value, name) {
  const text = String(value || "").trim();
  if (!text) return "";
  const parsed = new Date(text);
  if (!Number.isFinite(parsed.getTime())) throw badRequest(`${name}_invalid`);
  return parsed.toISOString().slice(0, 19).replace("T", " ");
}

function valueFrom(body, key, fallback) {
  return Object.hasOwn(body, key) ? body[key] : fallback;
}

function parseJsonObject(value, fallback = {}) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value) : value;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
}

function parseJsonArray(value) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value) : value;
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
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
