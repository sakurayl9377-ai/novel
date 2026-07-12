import crypto from "node:crypto";
import { all, db, one, run } from "./db.js";
import { consumeRateLimit } from "./rate-limit.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const contentTypes = new Set(["novel", "manga", "anime"]);
const catalogStatuses = new Set(["pending", "active", "inactive", "missing"]);
const builtInSourceKeys = new Set(["legacy", "manga_baozi", "anime_yinhua"]);
const placementTypes = new Set(["banner", "recommend", "ranking"]);
const placementStatuses = new Set(["draft", "active", "disabled"]);
const cacheScopes = new Set([
  "all",
  "content",
  "home",
  "feature_flags",
  "novel",
  "manga",
  "anime",
  "source",
]);

export async function adminContentRoutes(app) {
  app.get(
    "/admin/content/catalog",
    { preHandler: app.adminRequired },
    async (request) => catalogSearch(request.query || {}),
  );

  app.post(
    "/admin/content/catalog",
    { preHandler: app.adminRequired },
    async (request) => upsertCatalog(request.body || {}),
  );

  app.patch(
    "/admin/content/catalog/:stableKey/aliases",
    { preHandler: app.adminRequired },
    async (request) =>
      updateCatalogAliases(request.params.stableKey, request.body || {}),
  );

  app.patch(
    "/admin/content/catalog/:stableKey/status",
    { preHandler: app.adminRequired },
    async (request) =>
      updateCatalogStatus(request.params.stableKey, request.body || {}),
  );

  app.get(
    "/admin/content/placements",
    { preHandler: app.adminRequired },
    async (request) => placementList(request.query || {}),
  );

  app.get(
    "/admin/content/placements/preview",
    { preHandler: app.adminRequired },
    async (request) => bootstrapPayload(request, request.query || {}, true),
  );

  app.post(
    "/admin/content/placements",
    { preHandler: app.adminRequired },
    async (request) => createPlacement(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/content/placements/:id",
    { preHandler: app.adminRequired },
    async (request) =>
      updatePlacement(request.user.id, request.params.id, request.body || {}),
  );

  app.delete(
    "/admin/content/placements/:id",
    { preHandler: app.adminRequired },
    async (request) => deletePlacement(request.params.id),
  );

  app.get(
    "/admin/content/source-health",
    { preHandler: app.adminRequired },
    async (request) => sourceHealthList(request.query || {}),
  );

  app.post(
    "/admin/content/source-health/record",
    { preHandler: app.adminRequired },
    async (request) =>
      recordSourceProbe(request.user.id, request.body || {}),
  );

  app.get(
    "/admin/content/cache-invalidations",
    { preHandler: app.adminRequired },
    async (request) => cacheInvalidationList(request.query || {}),
  );

  app.post(
    "/admin/content/cache-invalidations",
    { preHandler: app.adminRequired },
    async (request) =>
      createCacheInvalidation(request.user.id, request.body || {}),
  );

  app.get(
    "/admin/content/feature-flags",
    { preHandler: app.adminRequired },
    async () => ({ items: all("SELECT * FROM feature_flags ORDER BY key").map(flagJson) }),
  );

  app.get(
    "/admin/content/feature-flags/:key/history",
    { preHandler: app.adminRequired },
    async (request) => featureFlagHistory(request.params.key),
  );

  app.post(
    "/admin/content/feature-flags",
    { preHandler: app.adminRequired },
    async (request) => createFeatureFlag(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/content/feature-flags/:key",
    { preHandler: app.adminRequired },
    async (request) =>
      updateFeatureFlag(request.user.id, request.params.key, request.body || {}),
  );

  app.delete(
    "/admin/content/feature-flags/:key",
    { preHandler: app.adminRequired },
    async (request) => deleteFeatureFlag(request.params.key),
  );

  app.post(
    "/admin/content/feature-flags/:key/rollback",
    { preHandler: app.adminRequired },
    async (request) =>
      rollbackFeatureFlag(request.user.id, request.params.key, request.body || {}),
  );

  app.get(
    "/app/bootstrap",
    { preHandler: app.authOptional },
    async (request, reply) => {
      reply.header("Cache-Control", "private, no-cache");
      return bootstrapPayload(request, request.query || {}, false);
    },
  );

  app.post(
    "/app/content/observations",
    { preHandler: app.authRequired },
    async (request, reply) => ingestContentObservations(request, reply),
  );
}

function catalogSearch(query) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 120);
  const type = optionalEnum(query.type, contentTypes, "content type");
  const status = optionalEnum(query.status, catalogStatuses, "catalog status");
  const sourceKey = optionalString(query.sourceKey, 120);
  const where = [];
  const params = [];
  if (keyword) {
    const like = `%${keyword}%`;
    where.push(
      "(stable_key LIKE ? OR title LIKE ? OR author LIKE ? OR alias_json LIKE ?)",
    );
    params.push(like, like, like, like);
  }
  if (type) {
    where.push("content_type = ?");
    params.push(type);
  }
  if (status) {
    where.push("status = ?");
    params.push(status);
  }
  if (sourceKey) {
    where.push("source_key = ?");
    params.push(sourceKey);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const total = one(
    `SELECT COUNT(*) AS count FROM content_catalog ${clause}`,
    params,
  ).count;
  const items = all(
    `SELECT * FROM content_catalog ${clause}
     ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(catalogJson);
  return { page, pageSize, total, items };
}

function upsertCatalog(body) {
  const stableKey = validatedKey(body.stableKey, "stableKey");
  const contentType = requiredEnum(body.contentType, contentTypes, "contentType");
  const sourceKey = validatedKey(body.sourceKey, "sourceKey");
  const sourceItemId = requiredString(body.sourceItemId, "sourceItemId", 240);
  const title = requiredString(body.title, "title", 300);
  const author = optionalString(body.author, 200);
  const coverUrl = optionalHttpUrl(body.coverUrl, "coverUrl");
  const status = body.status
    ? requiredEnum(body.status, catalogStatuses, "status")
    : "active";
  const metadataJson = jsonText(body.metadata ?? {}, "metadata", "object", 32_000);
  const aliasJson = JSON.stringify(normalizeAliases(body.aliases || []));
  const existing = one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey]);
  const lastSeenAt =
    normalizeDate(body.lastSeenAt, "lastSeenAt") || existing?.last_seen_at || nowIso();
  const values = {
    contentType,
    sourceKey,
    sourceItemId,
    title,
    author,
    coverUrl,
    status,
    metadataJson,
    aliasJson,
    lastSeenAt,
  };
  if (existing) {
    const unchanged =
      existing.content_type === contentType &&
      existing.source_key === sourceKey &&
      existing.source_item_id === sourceItemId &&
      existing.title === title &&
      existing.author === author &&
      existing.cover_url === coverUrl &&
      existing.status === status &&
      existing.metadata_json === metadataJson &&
      existing.alias_json === aliasJson &&
      existing.last_seen_at === lastSeenAt;
    if (!unchanged) {
      run(
        `UPDATE content_catalog SET content_type = ?, source_key = ?,
         source_item_id = ?, title = ?, author = ?, cover_url = ?, status = ?,
         metadata_json = ?, alias_json = ?, last_seen_at = ?,
         revision = revision + 1, updated_at = datetime('now')
         WHERE stable_key = ?`,
        [
          contentType,
          sourceKey,
          sourceItemId,
          title,
          author,
          coverUrl,
          status,
          metadataJson,
          aliasJson,
          lastSeenAt,
          stableKey,
        ],
      );
    }
    return { item: catalogJson(one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey])), idempotentReplay: unchanged };
  }
  try {
    run(
      `INSERT INTO content_catalog
       (content_type, stable_key, source_key, source_item_id, title, author,
        cover_url, status, metadata_json, alias_json, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [contentType, stableKey, sourceKey, sourceItemId, title, author, coverUrl, status, metadataJson, aliasJson, lastSeenAt],
    );
  } catch (error) {
    if (String(error.message).includes("UNIQUE")) {
      throw conflict("source item is already mapped to another stableKey");
    }
    throw error;
  }
  return { item: catalogJson(one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey])), idempotentReplay: false };
}

function updateCatalogAliases(stableKeyValue, body) {
  const stableKey = validatedKey(stableKeyValue, "stableKey");
  const current = one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey]);
  if (!current) throw notFound("content not found");
  const aliases = normalizeAliases(body.aliases);
  const aliasJson = JSON.stringify(aliases);
  if (current.alias_json === aliasJson) {
    return { item: catalogJson(current), idempotentReplay: true };
  }
  const expectedRevision = positiveInt(body.expectedRevision, "expectedRevision");
  const result = run(
    `UPDATE content_catalog SET alias_json = ?, revision = revision + 1,
     updated_at = datetime('now') WHERE stable_key = ? AND revision = ?`,
    [aliasJson, stableKey, expectedRevision],
  );
  if (!Number(result.changes)) throw conflict("content revision changed");
  return { item: catalogJson(one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey])), idempotentReplay: false };
}

function updateCatalogStatus(stableKeyValue, body) {
  const stableKey = validatedKey(stableKeyValue, "stableKey");
  const status = requiredEnum(body.status, catalogStatuses, "status");
  const current = one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey]);
  if (!current) throw notFound("content not found");
  if (current.status === status) {
    return { item: catalogJson(current), idempotentReplay: true };
  }
  const expectedRevision = positiveInt(body.expectedRevision, "expectedRevision");
  const result = run(
    `UPDATE content_catalog SET status = ?, revision = revision + 1,
     updated_at = datetime('now') WHERE stable_key = ? AND revision = ?`,
    [status, stableKey, expectedRevision],
  );
  if (!Number(result.changes)) throw conflict("content revision changed");
  return {
    item: catalogJson(one("SELECT * FROM content_catalog WHERE stable_key = ?", [stableKey])),
    idempotentReplay: false,
  };
}

function placementList(query) {
  const { page, pageSize, offset } = pageParams(query);
  const type = optionalEnum(query.type, placementTypes, "placement type");
  const status = optionalEnum(query.status, placementStatuses, "placement status");
  const position = optionalString(query.position, 80);
  const where = [];
  const params = [];
  if (type) {
    where.push("p.placement_type = ?");
    params.push(type);
  }
  if (status) {
    where.push("p.status = ?");
    params.push(status);
  }
  if (position) {
    where.push("p.position = ?");
    params.push(position);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const total = one(
    `SELECT COUNT(*) AS count FROM home_placements p ${clause}`,
    params,
  ).count;
  const items = all(
    `${placementSelect()} ${clause}
     ORDER BY p.placement_type, p.position, p.sort_order, p.id
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(placementJson);
  return { page, pageSize, total, items };
}

function createPlacement(adminUserId, body) {
  const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  const replay = one(
    "SELECT id FROM home_placements WHERE created_by = ? AND idempotency_key = ?",
    [adminUserId, idempotencyKey],
  );
  if (replay) return { item: placementById(replay.id), idempotentReplay: true };
  const values = placementInput(body);
  requireCatalog(values.contentKey);
  return transaction(() => {
    run(
      `INSERT INTO home_placements
       (placement_type, position, content_key, custom_title, custom_image_url,
        sort_order, starts_at, ends_at, status, audience_json,
        idempotency_key, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        values.placementType,
        values.position,
        values.contentKey,
        values.customTitle,
        values.customImageUrl,
        values.sortOrder,
        values.startsAt,
        values.endsAt,
        values.status,
        values.audienceJson,
        idempotencyKey,
        adminUserId,
      ],
    );
    const id = Number(one("SELECT last_insert_rowid() AS id").id);
    return { item: placementById(id), idempotentReplay: false };
  });
}

function updatePlacement(adminUserId, idValue, body) {
  const id = positiveInt(idValue, "placement id");
  const current = one("SELECT * FROM home_placements WHERE id = ?", [id]);
  if (!current) throw notFound("placement not found");
  const requestKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  if (current.idempotency_key === requestKey) {
    return { item: placementById(id), idempotentReplay: true };
  }
  const expectedRevision = positiveInt(body.expectedRevision, "expectedRevision");
  const values = placementInput(body, current);
  requireCatalog(values.contentKey);
  return transaction(() => {
    const result = run(
      `UPDATE home_placements SET placement_type = ?, position = ?,
       content_key = ?, custom_title = ?, custom_image_url = ?, sort_order = ?,
       starts_at = ?, ends_at = ?, status = ?, audience_json = ?,
       revision = revision + 1, idempotency_key = ?, created_by = ?,
       updated_at = datetime('now') WHERE id = ? AND revision = ?`,
      [
        values.placementType,
        values.position,
        values.contentKey,
        values.customTitle,
        values.customImageUrl,
        values.sortOrder,
        values.startsAt,
        values.endsAt,
        values.status,
        values.audienceJson,
        requestKey,
        adminUserId,
        id,
        expectedRevision,
      ],
    );
    if (!Number(result.changes)) throw conflict("placement revision changed");
    return { item: placementById(id), idempotentReplay: false };
  });
}

function deletePlacement(idValue) {
  const id = positiveInt(idValue, "placement id");
  return transaction(() => {
    const result = run("DELETE FROM home_placements WHERE id = ?", [id]);
    return { deleted: Boolean(Number(result.changes)), id };
  });
}

function sourceHealthList(query) {
  const type = optionalEnum(query.type, contentTypes, "content type");
  const sourceKey = optionalString(query.sourceKey, 120);
  const where = [];
  const params = [];
  if (type) {
    where.push("content_type = ?");
    params.push(type);
  }
  if (sourceKey) {
    where.push("source_key = ?");
    params.push(sourceKey);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  return {
    items: all(
      `SELECT * FROM content_source_health ${clause}
       ORDER BY last_probed_at DESC, source_key`,
      params,
    ).map(sourceHealthJson),
  };
}

function recordSourceProbe(adminUserId, body) {
  const contentType = requiredEnum(body.contentType, contentTypes, "contentType");
  const sourceKey = validatedKey(body.sourceKey, "sourceKey");
  const success = requiredBoolean(body.success, "success");
  const latencyMs = boundedInt(body.latencyMs, 0, 600_000, "latencyMs");
  const error = success ? "" : requiredString(body.error, "error", 1000);
  const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  const replay = one(
    `SELECT * FROM content_source_probe_events
     WHERE admin_user_id = ? AND idempotency_key = ?`,
    [adminUserId, idempotencyKey],
  );
  if (replay) {
    if (
      replay.content_type !== contentType ||
      replay.source_key !== sourceKey ||
      Boolean(replay.success) !== success ||
      Number(replay.latency_ms) !== latencyMs ||
      replay.error !== error
    ) {
      throw conflict("idempotency key was already used for a different probe");
    }
    return {
      item: sourceHealthJson(one(
        "SELECT * FROM content_source_health WHERE content_type = ? AND source_key = ?",
        [contentType, sourceKey],
      )),
      idempotentReplay: true,
    };
  }
  return transaction(() => {
    run(
      `INSERT INTO content_source_probe_events
       (content_type, source_key, success, latency_ms, error,
        admin_user_id, idempotency_key)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [contentType, sourceKey, success ? 1 : 0, latencyMs, error, adminUserId, idempotencyKey],
    );
    run(
      `INSERT INTO content_source_health
       (content_type, source_key, request_count, success_count, failure_count,
        latency_total_ms, last_latency_ms, last_error, last_probed_at,
        last_probe_error,
        manual_request_count, manual_success_count, manual_failure_count,
        manual_latency_total_ms)
       VALUES (?, ?, 1, ?, ?, ?, ?, ?, datetime('now'), ?, 1, ?, ?, ?)
       ON CONFLICT(content_type, source_key) DO UPDATE SET
         request_count = request_count + 1,
         success_count = success_count + excluded.success_count,
         failure_count = failure_count + excluded.failure_count,
         latency_total_ms = latency_total_ms + excluded.latency_total_ms,
         last_latency_ms = excluded.last_latency_ms,
         last_error = excluded.last_error,
         last_probe_error = excluded.last_probe_error,
         manual_request_count = manual_request_count + 1,
         manual_success_count = manual_success_count + excluded.manual_success_count,
         manual_failure_count = manual_failure_count + excluded.manual_failure_count,
         manual_latency_total_ms = manual_latency_total_ms + excluded.manual_latency_total_ms,
         last_probed_at = datetime('now'), updated_at = datetime('now')`,
      [
        contentType,
        sourceKey,
        success ? 1 : 0,
        success ? 0 : 1,
        latencyMs,
        latencyMs,
        error,
        error,
        success ? 1 : 0,
        success ? 0 : 1,
        latencyMs,
      ],
    );
    return {
      item: sourceHealthJson(one(
        "SELECT * FROM content_source_health WHERE content_type = ? AND source_key = ?",
        [contentType, sourceKey],
      )),
      idempotentReplay: false,
    };
  });
}

function ingestContentObservations(request, reply) {
  const body = request.body || {};
  const installId = requiredString(body.installId, "installId", 80);
  const rules = [
    consumeRateLimit({
      scope: "content-observation-ip",
      key: request.ip,
      limit: 120,
      windowMs: 60_000,
    }),
    consumeRateLimit({
      scope: "content-observation-install",
      key: installId,
      limit: 30,
      windowMs: 60_000,
    }),
  ];
  const limited = rules.find((item) => item.limited);
  if (limited) {
    reply.header("Retry-After", String(limited.retryAfter));
    return reply.code(429).send({
      error: "content_observation_rate_limited",
      retryAfter: limited.retryAfter,
    });
  }
  if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > 50) {
    throw badRequest("items must contain 1-50 observations");
  }
  const normalized = body.items.map((raw, index) =>
    normalizeContentObservation(raw, index),
  );
  return transaction(() => {
    let accepted = 0;
    let replayed = 0;
    let pendingCatalogItems = 0;
    for (const item of normalized) {
      const existingEvent = one(
        `SELECT id FROM content_observation_events
         WHERE install_id = ? AND observation_id = ?`,
        [installId, item.observationId],
      );
      if (existingEvent) {
        replayed += 1;
        continue;
      }
      ensureKnownObservedSource(item.sourceKey);
      run(
        `INSERT INTO content_observation_events
         (user_id, install_id, observation_id, content_type, stable_key,
          source_key, source_item_id, success, latency_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          request.user?.id || null,
          installId,
          item.observationId,
          item.contentType,
          item.stableKey,
          item.sourceKey,
          item.sourceItemId,
          item.success == null ? null : item.success ? 1 : 0,
          item.latencyMs,
        ],
      );
      const existingCatalog = one(
        "SELECT status FROM content_catalog WHERE stable_key = ?",
        [item.stableKey],
      );
      run(
        `INSERT INTO content_catalog
         (content_type, stable_key, source_key, source_item_id, title, author,
          cover_url, status, metadata_json, alias_json, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, '[]', ?)
         ON CONFLICT(stable_key) DO UPDATE SET
           title = CASE WHEN content_catalog.status = 'pending' THEN excluded.title ELSE content_catalog.title END,
           author = CASE WHEN content_catalog.status = 'pending' THEN excluded.author ELSE content_catalog.author END,
           cover_url = CASE WHEN content_catalog.status = 'pending' THEN excluded.cover_url ELSE content_catalog.cover_url END,
           metadata_json = CASE WHEN content_catalog.status = 'pending' THEN excluded.metadata_json ELSE content_catalog.metadata_json END,
           last_seen_at = excluded.last_seen_at,
           updated_at = datetime('now')`,
        [
          item.contentType,
          item.stableKey,
          item.sourceKey,
          item.sourceItemId,
          item.title,
          item.author,
          item.coverUrl,
          item.metadataJson,
          item.observedAt,
        ],
      );
      if (!existingCatalog) pendingCatalogItems += 1;
      if (item.success != null) {
        recordObservedTraffic({
          contentType: item.contentType,
          sourceKey: item.sourceKey,
          success: item.success,
          latencyMs: item.latencyMs,
          error: item.error,
        });
      }
      accepted += 1;
    }
    return { ok: true, accepted, replayed, pendingCatalogItems };
  });
}

function normalizeContentObservation(raw, index) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw badRequest(`items[${index}] is invalid`);
  }
  const contentType = requiredEnum(
    raw.contentType,
    contentTypes,
    `items[${index}].contentType`,
  );
  const sourceKey = validatedKey(raw.sourceKey, `items[${index}].sourceKey`);
  const success = raw.success === undefined || raw.success === null
    ? null
    : requiredBoolean(raw.success, `items[${index}].success`);
  const metadata = raw.metadata && typeof raw.metadata === "object" && !Array.isArray(raw.metadata)
    ? raw.metadata
    : {};
  return {
    observationId: validatedKey(
      raw.observationId,
      `items[${index}].observationId`,
    ),
    contentType,
    stableKey: validatedKey(raw.stableKey, `items[${index}].stableKey`),
    sourceKey,
    sourceItemId: requiredString(
      raw.sourceItemId,
      `items[${index}].sourceItemId`,
      240,
    ),
    title: requiredString(raw.title, `items[${index}].title`, 300),
    author: optionalString(raw.author, 200),
    coverUrl: optionalHttpUrl(raw.coverUrl, `items[${index}].coverUrl`),
    metadataJson: jsonText(
      { ...metadata, observedFromClient: true },
      `items[${index}].metadata`,
      "object",
      32_000,
    ),
    observedAt: normalizeDate(raw.observedAt, `items[${index}].observedAt`) || nowIso(),
    success,
    latencyMs: boundedInt(raw.latencyMs ?? 0, 0, 600_000, `items[${index}].latencyMs`),
    error: success === false
      ? optionalString(raw.error, 1000) || "observed_failure"
      : "",
  };
}

function ensureKnownObservedSource(sourceKey) {
  if (builtInSourceKeys.has(sourceKey)) return;
  if (one("SELECT 1 FROM content_catalog WHERE source_key = ? LIMIT 1", [sourceKey])) {
    return;
  }
  throw badRequest("sourceKey is not an approved content source");
}

export function recordObservedTraffic({
  contentType,
  sourceKey,
  success,
  latencyMs = 0,
  error = "",
}) {
  if (!contentTypes.has(contentType) || !sourceKey) return false;
  const safeLatency = Math.max(0, Math.min(600_000, Math.trunc(Number(latencyMs) || 0)));
  const safeError = success ? "" : String(error || "observed_failure").slice(0, 1000);
  run(
    `INSERT INTO content_source_health
     (content_type, source_key, request_count, success_count, failure_count,
      latency_total_ms, last_latency_ms, last_error, observed_request_count,
      observed_success_count, observed_failure_count,
      observed_latency_total_ms, last_observed_at, last_observation_error)
     VALUES (?, ?, 1, ?, ?, ?, ?, ?, 1, ?, ?, ?, datetime('now'), ?)
     ON CONFLICT(content_type, source_key) DO UPDATE SET
       request_count = request_count + 1,
       success_count = success_count + excluded.success_count,
       failure_count = failure_count + excluded.failure_count,
       latency_total_ms = latency_total_ms + excluded.latency_total_ms,
       last_latency_ms = excluded.last_latency_ms,
       last_error = excluded.last_error,
       observed_request_count = observed_request_count + 1,
       observed_success_count = observed_success_count + excluded.observed_success_count,
       observed_failure_count = observed_failure_count + excluded.observed_failure_count,
       observed_latency_total_ms = observed_latency_total_ms + excluded.observed_latency_total_ms,
       last_observed_at = datetime('now'),
       last_observation_error = excluded.last_observation_error,
       updated_at = datetime('now')`,
    [
      contentType,
      sourceKey,
      success ? 1 : 0,
      success ? 0 : 1,
      safeLatency,
      safeLatency,
      safeError,
      success ? 1 : 0,
      success ? 0 : 1,
      safeLatency,
      safeError,
    ],
  );
  return true;
}

function cacheInvalidationList(query) {
  const { page, pageSize, offset } = pageParams(query);
  const scope = optionalEnum(query.scope, cacheScopes, "scope");
  const where = scope ? "WHERE i.scope = ?" : "";
  const params = scope ? [scope] : [];
  const total = one(
    `SELECT COUNT(*) AS count FROM cache_invalidations i ${where}`,
    params,
  ).count;
  const items = all(
    `SELECT i.*, u.nickname AS created_by_name
     FROM cache_invalidations i LEFT JOIN users u ON u.id = i.created_by
     ${where} ORDER BY i.revision DESC LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(cacheInvalidationJson);
  return { page, pageSize, total, revision: latestCacheRevision(), items };
}

function createCacheInvalidation(adminUserId, body) {
  const scope = requiredEnum(body.scope, cacheScopes, "scope");
  const key = optionalString(body.key, 300);
  if (scope !== "all" && !key) throw badRequest("key is required for scoped invalidation");
  const reason = requiredString(body.reason, "reason", 500);
  const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  const replay = one(
    `SELECT i.*, u.nickname AS created_by_name
     FROM cache_invalidations i LEFT JOIN users u ON u.id = i.created_by
     WHERE i.created_by = ? AND i.idempotency_key = ?`,
    [adminUserId, idempotencyKey],
  );
  if (replay) return { item: cacheInvalidationJson(replay), idempotentReplay: true };
  return transaction(() => {
    const revision = latestCacheRevision() + 1;
    run(
      `INSERT INTO cache_invalidations
       (scope, cache_key, reason, revision, created_by, idempotency_key)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [scope, key, reason, revision, adminUserId, idempotencyKey],
    );
    const item = one(
      `SELECT i.*, u.nickname AS created_by_name
       FROM cache_invalidations i LEFT JOIN users u ON u.id = i.created_by
       WHERE i.revision = ?`,
      [revision],
    );
    return { item: cacheInvalidationJson(item), idempotentReplay: false };
  });
}

function createFeatureFlag(adminUserId, body) {
  const key = validatedKey(body.key, "key");
  const existing = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
  const values = flagInput(body);
  if (existing) {
    if (flagMatches(existing, values)) {
      return { item: flagJson(existing), idempotentReplay: true };
    }
    throw conflict("feature flag already exists");
  }
  return transaction(() => {
    const revision = Number(
      one(
        "SELECT COALESCE(MAX(revision), 0) + 1 AS revision FROM feature_flag_history WHERE flag_key = ?",
        [key],
      ).revision,
    );
    run(
      `INSERT INTO feature_flags
       (key, value_json, min_version_code, max_version_code,
        percentage_rollout, enabled, revision, idempotency_key, updated_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [key, values.valueJson, values.minVersionCode, values.maxVersionCode, values.percentageRollout, values.enabled, revision, optionalString(body.idempotencyKey, 120), adminUserId],
    );
    const item = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
    insertFlagHistory(item, adminUserId);
    return { item: flagJson(item), idempotentReplay: false };
  });
}

function updateFeatureFlag(adminUserId, keyValue, body) {
  const key = validatedKey(keyValue, "key");
  const current = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
  if (!current) throw notFound("feature flag not found");
  const requestKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  if (current.idempotency_key === requestKey) {
    return { item: flagJson(current), idempotentReplay: true };
  }
  const expectedRevision = positiveInt(body.expectedRevision, "expectedRevision");
  const values = flagInput(body, current);
  return transaction(() => {
    const result = run(
      `UPDATE feature_flags SET value_json = ?, min_version_code = ?,
       max_version_code = ?, percentage_rollout = ?, enabled = ?,
       revision = revision + 1, idempotency_key = ?, updated_by = ?,
       updated_at = datetime('now') WHERE key = ? AND revision = ?`,
      [values.valueJson, values.minVersionCode, values.maxVersionCode, values.percentageRollout, values.enabled, requestKey, adminUserId, key, expectedRevision],
    );
    if (!Number(result.changes)) throw conflict("feature flag revision changed");
    const item = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
    insertFlagHistory(item, adminUserId);
    return { item: flagJson(item), idempotentReplay: false };
  });
}

function deleteFeatureFlag(keyValue) {
  const key = validatedKey(keyValue, "key");
  return transaction(() => {
    const result = run("DELETE FROM feature_flags WHERE key = ?", [key]);
    return { deleted: Boolean(Number(result.changes)), key };
  });
}

function rollbackFeatureFlag(adminUserId, keyValue, body) {
  const key = validatedKey(keyValue, "key");
  const current = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
  if (!current) throw notFound("feature flag not found");
  const expectedRevision = positiveInt(body.expectedRevision, "expectedRevision");
  const targetRevision = positiveInt(body.targetRevision, "targetRevision");
  const requestKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  if (current.idempotency_key === requestKey) {
    return { item: flagJson(current), idempotentReplay: true };
  }
  const target = one(
    "SELECT * FROM feature_flag_history WHERE flag_key = ? AND revision = ?",
    [key, targetRevision],
  );
  if (!target) throw notFound("feature flag history revision not found");
  return transaction(() => {
    const result = run(
      `UPDATE feature_flags SET value_json = ?, min_version_code = ?,
       max_version_code = ?, percentage_rollout = ?, enabled = ?,
       revision = revision + 1, idempotency_key = ?, updated_by = ?,
       updated_at = datetime('now') WHERE key = ? AND revision = ?`,
      [target.value_json, target.min_version_code, target.max_version_code, target.percentage_rollout, target.enabled, requestKey, adminUserId, key, expectedRevision],
    );
    if (!Number(result.changes)) throw conflict("feature flag revision changed");
    const item = one("SELECT * FROM feature_flags WHERE key = ?", [key]);
    insertFlagHistory(item, adminUserId);
    return { item: flagJson(item), rolledBackFromRevision: targetRevision, idempotentReplay: false };
  });
}

function featureFlagHistory(keyValue) {
  const key = validatedKey(keyValue, "key");
  return {
    key,
    items: all(
      `SELECT h.*, u.nickname AS changed_by_name
       FROM feature_flag_history h LEFT JOIN users u ON u.id = h.changed_by
       WHERE h.flag_key = ? ORDER BY h.revision DESC LIMIT 100`,
      [key],
    ).map((row) => ({
      revision: row.revision,
      value: parseJson(row.value_json, null),
      minVersionCode: row.min_version_code,
      maxVersionCode: row.max_version_code,
      percentageRollout: row.percentage_rollout,
      enabled: Boolean(row.enabled),
      changedBy: row.changed_by_name || "",
      createdAt: row.created_at,
    })),
  };
}

function bootstrapPayload(request, query, includeDiagnostics) {
  const context = bootstrapContext(request, query);
  const placementRows = all(
    `${placementSelect()}
     WHERE p.status = 'active' AND c.status = 'active'
       AND (p.starts_at = '' OR datetime(p.starts_at) <= datetime('now'))
       AND (p.ends_at = '' OR datetime(p.ends_at) > datetime('now'))
     ORDER BY p.placement_type, p.position, p.sort_order, p.id`,
  );
  const matchedPlacements = placementRows.filter((row) =>
    audienceMatches(parseJson(row.audience_json, {}), context, `placement:${row.id}`),
  );
  const flags = {};
  const matchedFlagKeys = [];
  for (const row of all("SELECT * FROM feature_flags WHERE enabled = 1 ORDER BY key")) {
    if (!versionMatches(row.min_version_code, row.max_version_code, context.versionCode)) continue;
    if (!percentageMatches(row.percentage_rollout, context.identity, `flag:${row.key}`)) continue;
    flags[row.key] = parseJson(row.value_json, null);
    matchedFlagKeys.push(row.key);
  }
  const minimumVersionCode = minimumVersionFromFlags(flags);
  const placements = { banner: [], recommend: [], ranking: [] };
  for (const row of matchedPlacements) {
    placements[row.placement_type].push(publicPlacementJson(row));
  }
  const payload = {
    generatedAt: nowIso(),
    cacheRevision: latestCacheRevision(),
    client: {
      versionCode: context.versionCode,
      rolloutBucket: rolloutBucket(context.identity, "bootstrap"),
      minimumVersionCode,
      updateRequired: minimumVersionCode > 0 && context.versionCode > 0 && context.versionCode < minimumVersionCode,
    },
    placements,
    features: flags,
  };
  if (includeDiagnostics) {
    payload.preview = {
      identity: context.identity,
      loggedIn: context.loggedIn,
      platform: context.platform,
      matchedFlagKeys,
      placementCount: matchedPlacements.length,
    };
  }
  return payload;
}

function placementInput(body, current = null) {
  const placementType = body.placementType === undefined && current
    ? current.placement_type
    : requiredEnum(body.placementType, placementTypes, "placementType");
  const position = body.position === undefined && current
    ? current.position
    : requiredString(body.position, "position", 80);
  const contentKey = body.contentKey === undefined && current
    ? current.content_key
    : validatedKey(body.contentKey, "contentKey");
  const customTitle = body.customTitle === undefined && current
    ? current.custom_title
    : optionalString(body.customTitle, 300);
  const customImageUrl = body.customImageUrl === undefined && current
    ? current.custom_image_url
    : optionalHttpUrl(body.customImageUrl, "customImageUrl");
  const sortOrder = body.sortOrder === undefined && current
    ? current.sort_order
    : boundedInt(body.sortOrder ?? 0, -100_000, 100_000, "sortOrder");
  const startsAt = body.startsAt === undefined && current
    ? current.starts_at
    : normalizeDate(body.startsAt, "startsAt");
  const endsAt = body.endsAt === undefined && current
    ? current.ends_at
    : normalizeDate(body.endsAt, "endsAt");
  if (startsAt && endsAt && Date.parse(startsAt) >= Date.parse(endsAt)) {
    throw badRequest("endsAt must be after startsAt");
  }
  const status = body.status === undefined && current
    ? current.status
    : requiredEnum(body.status || "draft", placementStatuses, "status");
  const audienceJson = body.audience === undefined && current
    ? current.audience_json
    : JSON.stringify(normalizeAudience(body.audience || {}));
  return { placementType, position, contentKey, customTitle, customImageUrl, sortOrder, startsAt, endsAt, status, audienceJson };
}

function flagInput(body, current = null) {
  const valueJson = body.value === undefined && current
    ? current.value_json
    : jsonText(body.value ?? null, "value", "any", 32_000);
  const minVersionCode = body.minVersionCode === undefined && current
    ? current.min_version_code
    : boundedInt(body.minVersionCode ?? 0, 0, 10_000_000, "minVersionCode");
  const maxVersionCode = body.maxVersionCode === undefined && current
    ? current.max_version_code
    : boundedInt(body.maxVersionCode ?? 0, 0, 10_000_000, "maxVersionCode");
  if (maxVersionCode > 0 && minVersionCode > maxVersionCode) {
    throw badRequest("maxVersionCode must be zero or >= minVersionCode");
  }
  const percentageRollout = body.percentageRollout === undefined && current
    ? current.percentage_rollout
    : boundedInt(body.percentageRollout ?? 100, 0, 100, "percentageRollout");
  const enabled = body.enabled === undefined && current
    ? current.enabled
    : requiredBoolean(body.enabled ?? false, "enabled") ? 1 : 0;
  return { valueJson, minVersionCode, maxVersionCode, percentageRollout, enabled };
}

function normalizeAudience(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw badRequest("audience must be an object");
  }
  const audience = {};
  if (value.minVersionCode !== undefined) audience.minVersionCode = boundedInt(value.minVersionCode, 0, 10_000_000, "audience.minVersionCode");
  if (value.maxVersionCode !== undefined) audience.maxVersionCode = boundedInt(value.maxVersionCode, 0, 10_000_000, "audience.maxVersionCode");
  if (audience.maxVersionCode > 0 && (audience.minVersionCode || 0) > audience.maxVersionCode) throw badRequest("audience maxVersionCode is invalid");
  if (value.percentage !== undefined) audience.percentage = boundedInt(value.percentage, 0, 100, "audience.percentage");
  if (value.loggedIn !== undefined) audience.loggedIn = requiredBoolean(value.loggedIn, "audience.loggedIn");
  if (value.platforms !== undefined) {
    if (!Array.isArray(value.platforms) || value.platforms.length > 10) throw badRequest("audience.platforms is invalid");
    audience.platforms = [...new Set(value.platforms.map((item) => requiredString(item, "platform", 32).toLowerCase()))];
  }
  return audience;
}

function audienceMatches(audience, context, salt) {
  if (!audience || typeof audience !== "object" || Array.isArray(audience)) return false;
  if (!versionMatches(audience.minVersionCode || 0, audience.maxVersionCode || 0, context.versionCode)) return false;
  if (audience.loggedIn !== undefined && Boolean(audience.loggedIn) !== context.loggedIn) return false;
  if (Array.isArray(audience.platforms) && audience.platforms.length && !audience.platforms.includes(context.platform)) return false;
  return percentageMatches(audience.percentage ?? 100, context.identity, salt);
}

function bootstrapContext(request, query) {
  const versionCode = boundedInt(query.versionCode ?? 0, 0, 10_000_000, "versionCode");
  const installId = optionalString(query.installId, 160);
  const platform = (optionalString(query.platform, 32) || "unknown").toLowerCase();
  const userIdentity = request.user?.id ? `user:${request.user.id}` : "";
  const identity = userIdentity || (installId ? `install:${installId}` : `anonymous:${String(request.ip || "unknown")}`);
  return { versionCode, platform, identity, loggedIn: Boolean(request.user) };
}

function versionMatches(minVersionCode, maxVersionCode, versionCode) {
  if (Number(minVersionCode) > 0 && Number(versionCode) < Number(minVersionCode)) return false;
  if (Number(maxVersionCode) > 0 && Number(versionCode) > Number(maxVersionCode)) return false;
  return true;
}

function percentageMatches(percentage, identity, salt) {
  const number = Number(percentage);
  if (number <= 0) return false;
  if (number >= 100) return true;
  return rolloutBucket(identity, salt) < number;
}

function rolloutBucket(identity, salt) {
  const digest = crypto.createHash("sha256").update(`${salt}|${identity}`).digest();
  return digest.readUInt32BE(0) % 100;
}

function minimumVersionFromFlags(flags) {
  const raw = flags["app.minimum_version_code"] ?? flags.appMinimumVersionCode ?? 0;
  const value = typeof raw === "object" && raw ? raw.versionCode : raw;
  return Math.max(0, Number.isFinite(Number(value)) ? Math.trunc(Number(value)) : 0);
}

function placementSelect() {
  return `SELECT p.*, c.content_type, c.title, c.author, c.cover_url,
                 c.status AS content_status, c.source_key, c.source_item_id
          FROM home_placements p
          JOIN content_catalog c ON c.stable_key = p.content_key`;
}

function placementById(id) {
  const row = one(`${placementSelect()} WHERE p.id = ?`, [id]);
  return row ? placementJson(row) : null;
}

function requireCatalog(stableKey) {
  if (!one("SELECT 1 FROM content_catalog WHERE stable_key = ?", [stableKey])) {
    throw badRequest("contentKey does not exist in catalog");
  }
}

function catalogJson(row) {
  return {
    id: row.id,
    contentType: row.content_type,
    stableKey: row.stable_key,
    sourceKey: row.source_key,
    sourceItemId: row.source_item_id,
    title: row.title,
    author: row.author,
    coverUrl: row.cover_url,
    status: row.status,
    metadata: parseJson(row.metadata_json, {}),
    aliases: parseJson(row.alias_json, []),
    lastSeenAt: row.last_seen_at,
    revision: row.revision,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function placementJson(row) {
  return {
    id: row.id,
    placementType: row.placement_type,
    position: row.position,
    contentKey: row.content_key,
    customTitle: row.custom_title,
    customImageUrl: row.custom_image_url,
    sortOrder: row.sort_order,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    status: row.status,
    audience: parseJson(row.audience_json, {}),
    revision: row.revision,
    content: {
      contentType: row.content_type,
      title: row.title,
      author: row.author,
      coverUrl: row.cover_url,
      status: row.content_status,
      sourceKey: row.source_key,
      sourceItemId: row.source_item_id,
    },
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function publicPlacementJson(row) {
  return {
    type: row.placement_type,
    position: row.position,
    contentKey: row.content_key,
    contentType: row.content_type,
    title: row.custom_title || row.title,
    author: row.author,
    imageUrl: row.custom_image_url || row.cover_url,
    sourceKey: row.source_key,
    sourceItemId: row.source_item_id,
  };
}

function sourceHealthJson(row) {
  if (!row) return null;
  const requestCount = Number(row.request_count || 0);
  return {
    contentType: row.content_type,
    sourceKey: row.source_key,
    requestCount,
    successCount: Number(row.success_count || 0),
    failureCount: Number(row.failure_count || 0),
    successRate: requestCount ? Number(row.success_count || 0) / requestCount : null,
    averageLatencyMs: requestCount ? Math.round(Number(row.latency_total_ms || 0) / requestCount) : 0,
    lastLatencyMs: Number(row.last_latency_ms || 0),
    lastError: row.last_error,
    lastProbedAt: row.last_probed_at,
    manualProbe: {
      requestCount: Number(row.manual_request_count || 0),
      successCount: Number(row.manual_success_count || 0),
      failureCount: Number(row.manual_failure_count || 0),
      averageLatencyMs: Number(row.manual_request_count || 0)
        ? Math.round(Number(row.manual_latency_total_ms || 0) / Number(row.manual_request_count))
        : 0,
      lastAt: row.last_probed_at,
      lastError: row.last_probe_error,
    },
    observedTraffic: {
      requestCount: Number(row.observed_request_count || 0),
      successCount: Number(row.observed_success_count || 0),
      failureCount: Number(row.observed_failure_count || 0),
      averageLatencyMs: Number(row.observed_request_count || 0)
        ? Math.round(Number(row.observed_latency_total_ms || 0) / Number(row.observed_request_count))
        : 0,
      lastAt: row.last_observed_at,
      lastError: row.last_observation_error,
    },
    updatedAt: row.updated_at,
  };
}

function flagJson(row) {
  return {
    key: row.key,
    value: parseJson(row.value_json, null),
    minVersionCode: row.min_version_code,
    maxVersionCode: row.max_version_code,
    percentageRollout: row.percentage_rollout,
    enabled: Boolean(row.enabled),
    revision: row.revision,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function cacheInvalidationJson(row) {
  return {
    id: row.id,
    scope: row.scope,
    key: row.cache_key,
    reason: row.reason,
    revision: row.revision,
    createdBy: row.created_by_name || "",
    createdAt: row.created_at,
  };
}

function insertFlagHistory(row, adminUserId) {
  run(
    `INSERT INTO feature_flag_history
     (flag_key, revision, value_json, min_version_code, max_version_code,
      percentage_rollout, enabled, changed_by)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [row.key, row.revision, row.value_json, row.min_version_code, row.max_version_code, row.percentage_rollout, row.enabled, adminUserId],
  );
}

function flagMatches(row, values) {
  return row.value_json === values.valueJson &&
    Number(row.min_version_code) === values.minVersionCode &&
    Number(row.max_version_code) === values.maxVersionCode &&
    Number(row.percentage_rollout) === values.percentageRollout &&
    Number(row.enabled) === values.enabled;
}

function latestCacheRevision() {
  return Number(one("SELECT COALESCE(MAX(revision), 0) AS revision FROM cache_invalidations").revision || 0);
}

function normalizeAliases(value) {
  if (!Array.isArray(value) || value.length > 100) throw badRequest("aliases must be an array with at most 100 items");
  return [...new Set(value.map((item) => requiredString(item, "alias", 200)))];
}

function jsonText(value, name, expectedType, maxLength) {
  if (value === undefined) throw badRequest(`${name} is required`);
  if (expectedType === "object" && (!value || typeof value !== "object" || Array.isArray(value))) {
    throw badRequest(`${name} must be an object`);
  }
  let text;
  try {
    text = JSON.stringify(value);
  } catch {
    throw badRequest(`${name} must be valid JSON`);
  }
  if (text.length > maxLength) throw badRequest(`${name} is too large`);
  return text;
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

function validatedKey(value, name) {
  const key = requiredString(value, name, 160);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(key)) {
    throw badRequest(`${name} contains invalid characters`);
  }
  return key;
}

function optionalHttpUrl(value, name) {
  const text = optionalString(value, 2000);
  if (!text) return "";
  let url;
  try {
    url = new URL(text);
  } catch {
    throw badRequest(`${name} must be a valid URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw badRequest(`${name} must use http or https`);
  }
  return url.toString();
}

function normalizeDate(value, name) {
  const text = optionalString(value, 80);
  if (!text) return "";
  const timestamp = Date.parse(text);
  if (!Number.isFinite(timestamp)) throw badRequest(`${name} is invalid`);
  return new Date(timestamp).toISOString();
}

function requiredEnum(value, allowed, name) {
  const text = requiredString(value, name, 80);
  if (!allowed.has(text)) throw badRequest(`${name} is invalid`);
  return text;
}

function optionalEnum(value, allowed, name) {
  const text = optionalString(value, 80);
  if (!text) return "";
  if (!allowed.has(text)) throw badRequest(`${name} is invalid`);
  return text;
}

function requiredBoolean(value, name) {
  if (value === true || value === false) return value;
  if (value === 1 || value === "1" || value === "true") return true;
  if (value === 0 || value === "0" || value === "false") return false;
  throw badRequest(`${name} must be boolean`);
}

function boundedInt(value, min, max, name) {
  const number = optionalInt(value, Number.NaN);
  if (!Number.isInteger(number) || number < min || number > max) {
    throw badRequest(`${name} must be between ${min} and ${max}`);
  }
  return number;
}

function positiveInt(value, name) {
  return boundedInt(value, 1, Number.MAX_SAFE_INTEGER, name);
}

function transaction(action) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = action();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function nowIso() {
  return new Date().toISOString();
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}

function conflict(message) {
  const error = new Error(message);
  error.statusCode = 409;
  return error;
}
