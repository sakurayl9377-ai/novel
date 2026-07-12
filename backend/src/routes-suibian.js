import { all, one, run } from './db.js';
import { badRequest, optionalInt, optionalString, pageParams, requiredString } from './validators.js';
import { getSuibianDrama, getSuibianStatus, listSuibianContent, resolveSuibianPlayback, searchSuibianContent } from './suibian-source.js';

export async function suibianRoutes(app) {
  app.get('/suibian/status', async () => getSuibianStatus());

  app.get('/suibian/home', async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    const category = optionalString(request.query?.category, 16) || 'all';
    if (!['all', 'comic', 'short'].includes(category)) throw badRequest('category is invalid');
    return listSuibianContent({ category, page, pageSize });
  });

  app.get('/suibian/search', async (request) => {
    const { page, pageSize } = pageParams(request.query || {});
    return searchSuibianContent(requiredString(request.query?.q, 'q', 100), { page, pageSize });
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
