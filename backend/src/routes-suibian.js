import { all, run } from './db.js';
import { badRequest, optionalInt, optionalString, pageParams, requiredString } from './validators.js';
import { getSuibianDrama, getSuibianStatus, listSuibianContent, resolveSuibianPlayback, searchSuibianContent } from './suibian-source.js';
import {
  getDbzyCategories,
  getDbzyItem,
  getDbzyMovieHome,
  getDbzyShortFeed,
  getDbzyStatus,
  listDbzyMovies,
  resolveDbzyPlayback,
  searchDbzyCache,
  withoutDbzyPlayback,
} from './dbzy-source.js';

export async function suibianRoutes(app) {
  app.get('/suibian/status', async () => getSuibianStatus());

  app.get('/suibian/sources/status', async () => ({
    catalog: await getSuibianStatus(),
    dbzy: await getDbzyStatus(),
  }));

  app.get('/suibian/categories', async () => getDbzyCategories());

  app.get('/suibian/movies/home', async (request) => {
    const home = await getDbzyMovieHome({ sectionSize: optionalInt(request.query?.sectionSize, 12) });
    // The existing server-managed catalog remains an optional AI-comic supplement.
    try {
      const ai = await listSuibianContent({ category: 'comic', page: 1, pageSize: 12 });
      if (ai.items.length) home.sections.unshift({ id: 'ai-comic', title: 'AI 漫剧', categoryId: 'ai-comic', items: ai.items });
    } catch {
      // A missing optional catalog must never take the official movie source down.
    }
    return home;
  });

  app.get('/suibian/movies', async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    return listDbzyMovies({
      categoryId: optionalInt(request.query?.categoryId, 1),
      page,
      pageSize,
    });
  });

  app.get('/suibian/movies/:id', async (request, reply) => {
    const item = await getDbzyItem(requiredString(request.params?.id, 'id', 100));
    return item ? withoutDbzyPlayback(item) : reply.code(404).send({ error: 'not_found' });
  });

  app.get('/suibian/movies/:id/episodes/:episodeIndex/playback', async (request, reply) => {
    const episodeIndex = optionalInt(request.params?.episodeIndex, -1);
    if (episodeIndex < 0 || episodeIndex > 10000) throw badRequest('episodeIndex is invalid');
    const playback = await resolveDbzyPlayback(requiredString(request.params?.id, 'id', 100), episodeIndex);
    return playback || reply.code(404).send({ error: 'episode_unavailable' });
  });

  app.get('/suibian/shorts/feed', async (request) => getDbzyShortFeed({
    categoryId: optionalInt(request.query?.categoryId, 37),
    pageSize: optionalInt(request.query?.pageSize, 12),
  }));

  app.get('/suibian/shorts/:id', async (request, reply) => {
    const item = await getDbzyItem(requiredString(request.params?.id, 'id', 100));
    if (!item || item.category !== 'short') return reply.code(404).send({ error: 'not_found' });
    return withoutDbzyPlayback(item);
  });

  app.get('/suibian/shorts/:id/episodes/:episodeIndex/playback', async (request, reply) => {
    const episodeIndex = optionalInt(request.params?.episodeIndex, -1);
    if (episodeIndex < 0 || episodeIndex > 10000) throw badRequest('episodeIndex is invalid');
    const item = await getDbzyItem(requiredString(request.params?.id, 'id', 100));
    if (!item || item.category !== 'short') return reply.code(404).send({ error: 'episode_unavailable' });
    return item.episodes[episodeIndex] || reply.code(404).send({ error: 'episode_unavailable' });
  });

  app.get('/suibian/home', async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    const category = optionalString(request.query?.category, 16) || 'all';
    if (!['all', 'comic', 'short'].includes(category)) throw badRequest('category is invalid');
    return listSuibianContent({ category, page, pageSize });
  });

  app.get('/suibian/search', async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    const q = requiredString(request.query?.q, 'q', 100);
    const dbzy = await searchDbzyCache(q, { page, pageSize });
    if (dbzy.items.length || page > 1) return dbzy;
    try {
      return await searchSuibianContent(q, { page, pageSize });
    } catch {
      return dbzy;
    }
  });

  app.get('/suibian/dramas/:id', async (request, reply) => {
    const drama = await getSuibianDrama(requiredString(request.params?.id, 'id', 100));
    return drama || reply.code(404).send({ error: 'not_found' });
  });

  app.get('/suibian/dramas/:id/episodes/:episodeIndex/playback', async (request, reply) => {
    const episodeIndex = optionalInt(request.params?.episodeIndex, -1);
    if (episodeIndex < 0 || episodeIndex > 10000) throw badRequest('episodeIndex is invalid');
    const playback = await resolveSuibianPlayback(requiredString(request.params?.id, 'id', 100), episodeIndex);
    return playback || reply.code(404).send({ error: 'episode_unavailable' });
  });

  app.get('/suibian/me/favorites', { preHandler: app.authRequired }, async (request) => ({
    items: all(`SELECT drama_id AS dramaId, title, category, created_at AS createdAt, updated_at AS updatedAt FROM suibian_favorites WHERE user_id = ? ORDER BY updated_at DESC`, [request.user.id]),
  }));

  app.put('/suibian/me/favorites/:dramaId', { preHandler: app.authRequired }, async (request) => {
    const dramaId = requiredString(request.params?.dramaId, 'dramaId', 100);
    const body = request.body || {};
    run(`INSERT INTO suibian_favorites (user_id, drama_id, title, category) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, drama_id) DO UPDATE SET title = excluded.title, category = excluded.category, updated_at = datetime('now')`, [request.user.id, dramaId, optionalString(body.title, 200), optionalString(body.category, 16)]);
    return { favorited: true };
  });

  app.delete('/suibian/me/favorites/:dramaId', { preHandler: app.authRequired }, async (request) => {
    run('DELETE FROM suibian_favorites WHERE user_id = ? AND drama_id = ?', [request.user.id, requiredString(request.params?.dramaId, 'dramaId', 100)]);
    return { favorited: false };
  });

  app.get('/suibian/me/history', { preHandler: app.authRequired }, async (request) => ({
    items: all(`SELECT drama_id AS dramaId, episode_index AS episodeIndex, episode_title AS episodeTitle, position_ms AS positionMs, duration_ms AS durationMs, title, category, updated_at AS updatedAt FROM suibian_watch_history WHERE user_id = ? ORDER BY updated_at DESC LIMIT 100`, [request.user.id]),
  }));

  app.put('/suibian/me/history/:dramaId', { preHandler: app.authRequired }, async (request) => {
    const body = request.body || {};
    const dramaId = requiredString(request.params?.dramaId, 'dramaId', 100);
    const episodeIndex = optionalInt(body.episodeIndex, 0);
    const positionMs = optionalInt(body.positionMs, 0);
    const durationMs = optionalInt(body.durationMs, 0);
    if (episodeIndex < 0 || positionMs < 0 || durationMs < 0) throw badRequest('history position is invalid');
    run(`INSERT INTO suibian_watch_history (user_id, drama_id, episode_index, episode_title, position_ms, duration_ms, title, category) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(user_id, drama_id) DO UPDATE SET episode_index = excluded.episode_index, episode_title = excluded.episode_title, position_ms = excluded.position_ms, duration_ms = excluded.duration_ms, title = excluded.title, category = excluded.category, updated_at = datetime('now')`, [request.user.id, dramaId, episodeIndex, optionalString(body.episodeTitle, 100), positionMs, durationMs, optionalString(body.title, 200), optionalString(body.category, 16)]);
    return { saved: true };
  });
}
