import { all, one, run } from './db.js';
import {
  getDbzyAdminCategories,
  getDbzyAdminItem,
  getDbzyAdminOverview,
  getDbzyStatus,
  refreshDbzyNow,
} from './dbzy-source.js';
import { VIDEO_POLICY_MODES, categoryAvailability } from './video-category-policy.js';
import { getDbzySyncSchedulerStatus } from './dbzy-sync-scheduler.js';
import { badRequest, optionalInt, optionalString, pageParams, requiredString } from './validators.js';

export async function adminVideoRoutes(app) {
  app.get('/admin/video/overview', { preHandler: app.adminRequired }, async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    const categoryId = optionalInt(request.query?.categoryId, 0);
    const items = await getDbzyAdminOverview({
      query: optionalString(request.query?.q, 120),
      categoryId,
      kind: optionalString(request.query?.kind, 20),
      visibility: optionalString(request.query?.visibility, 20),
      page,
      pageSize,
    });
    const categories = await getDbzyAdminCategories();
    const source = await getDbzyStatus();
    return {
      ...items,
      categories,
      source,
      scheduler: getDbzySyncSchedulerStatus(),
      counts: {
        total: items.total,
        hidden: Number(one(`SELECT COUNT(*) AS count FROM video_content_overrides WHERE source_key = 'dbzy' AND visibility = 'hidden'`)?.count || 0),
        shorts: categories.filter((item) => [37, 43, 44, 45, 46, 47, 48, 49].includes(item.id)).reduce((sum, item) => sum + item.itemCount, 0),
      },
      integrations: {
        commentsPath: '/admin/comments/target-search',
        danmakuPath: '/admin/danmaku/anime-search',
        contentCatalogPath: '/admin/content/catalog',
        featureFlagsPath: '/admin/content/feature-flags',
      },
    };
  });

  app.get('/admin/video/items/:id', { preHandler: app.adminRequired }, async (request, reply) => {
    const item = await getDbzyAdminItem(requiredString(request.params?.id, 'id', 100));
    return item || reply.code(404).send({ error: 'not_found' });
  });

  app.patch('/admin/video/items/:id/visibility', { preHandler: app.adminRequired }, async (request) => {
    const id = requiredString(request.params?.id, 'id', 100);
    const visibility = requiredString(request.body?.visibility, 'visibility', 20);
    if (!['active', 'hidden'].includes(visibility)) throw badRequest('visibility is invalid');
    const note = optionalString(request.body?.note, 500);
    const item = await getDbzyAdminItem(id);
    if (!item) throw badRequest('video item not found');
    run(
      `INSERT INTO video_content_overrides (source_key, source_item_id, visibility, note, updated_by)
       VALUES ('dbzy', ?, ?, ?, ?)
       ON CONFLICT(source_key, source_item_id) DO UPDATE SET
         visibility = excluded.visibility, note = excluded.note,
         updated_by = excluded.updated_by, updated_at = datetime('now')`,
      [id, visibility, note, request.user.id],
    );
    return { item: await getDbzyAdminItem(id) };
  });

  app.patch('/admin/video/categories/:categoryId/policy', { preHandler: app.adminRequired }, async (request) => {
    const categoryId = optionalInt(request.params?.categoryId, 0);
    if (categoryId <= 0) throw badRequest('categoryId is invalid');
    const mode = requiredString(request.body?.mode, 'mode', 20);
    if (!VIDEO_POLICY_MODES.has(mode)) throw badRequest('mode is invalid');
    const dailyStart = validateTime(request.body?.dailyStart, 'dailyStart');
    const dailyEnd = validateTime(request.body?.dailyEnd, 'dailyEnd');
    const timezone = validateTimezone(request.body?.timezone);
    const ageRestricted = Boolean(request.body?.ageRestricted);
    run(
      `INSERT INTO video_category_policies
       (source_key, category_id, mode, daily_start, daily_end, timezone, age_restricted, updated_by)
       VALUES ('dbzy', ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(source_key, category_id) DO UPDATE SET
         mode = excluded.mode, daily_start = excluded.daily_start,
         daily_end = excluded.daily_end, timezone = excluded.timezone,
         age_restricted = excluded.age_restricted, updated_by = excluded.updated_by,
         updated_at = datetime('now')`,
      [categoryId, mode, dailyStart, dailyEnd, timezone, ageRestricted ? 1 : 0, request.user.id],
    );
    return { availability: categoryAvailability('dbzy', categoryId) };
  });

  app.post('/admin/video/source/refresh', { preHandler: app.adminRequired }, async () => ({
    refreshed: true,
    source: await refreshDbzyNow(),
  }));

  app.get('/admin/video/source/activity', { preHandler: app.adminRequired }, async () => ({
    source: await getDbzyStatus(),
    scheduler: getDbzySyncSchedulerStatus(),
    recentOverrides: all(
      `SELECT o.source_item_id AS sourceItemId, o.visibility, o.note,
              o.updated_at AS updatedAt, u.nickname AS updatedBy
       FROM video_content_overrides o LEFT JOIN users u ON u.id = o.updated_by
       WHERE o.source_key = 'dbzy' ORDER BY o.updated_at DESC LIMIT 20`,
    ),
    recentPolicies: all(
      `SELECT p.category_id AS categoryId, p.mode, p.daily_start AS dailyStart,
              p.daily_end AS dailyEnd, p.timezone, p.age_restricted AS ageRestricted,
              p.updated_at AS updatedAt, u.nickname AS updatedBy
       FROM video_category_policies p LEFT JOIN users u ON u.id = p.updated_by
       WHERE p.source_key = 'dbzy' ORDER BY p.updated_at DESC LIMIT 20`,
    ),
  }));
}

function validateTime(value, field) {
  const text = requiredString(value, field, 5);
  if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(text)) throw badRequest(`${field} is invalid`);
  return text;
}

function validateTimezone(value) {
  const timezone = requiredString(value, 'timezone', 80);
  try {
    new Intl.DateTimeFormat('en', { timeZone: timezone }).format();
  } catch {
    throw badRequest('timezone is invalid');
  }
  return timezone;
}
