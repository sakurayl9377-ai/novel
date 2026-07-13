import path from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import websocket from '@fastify/websocket';
import Fastify from 'fastify';
import { recordAdminAudit } from './admin-audit.js';
import { adminRequired, authOptional, authRequired } from './auth.js';
import { seedChatBotRooms } from './chat-bot.js';
import { config } from './config.js';
import { startDbzySyncScheduler, stopDbzySyncScheduler } from './dbzy-sync-scheduler.js';
import { closeDb, migrate, seedAdmin } from './db.js';
import { adminRoutes } from './routes-admin.js';
import { adminContentRoutes } from './routes-admin-content.js';
import { adminGrowthRoutes } from './routes-admin-growth.js';
import { adminOperationsRoutes } from './routes-admin-operations.js';
import { adminVideoRoutes } from './routes-admin-video.js';
import { aiNovelRoutes } from './routes-ai-novels.js';
import { authRoutes } from './routes-auth.js';
import { contentRoutes } from './routes-content.js';
import { gameRoutes } from './routes-game.js';
import { growthRoutes } from './routes-growth.js';
import { speechRoutes } from './routes-speech.js';
import { suibianRoutes } from './routes-suibian.js';
import { telemetryRoutes } from './routes-telemetry.js';
import { userRoutes } from './routes-user.js';
import { registerWebSockets } from './websocket.js';

export async function buildServer() {
  migrate();
  seedAdmin();
  seedChatBotRooms();

  const app = Fastify({
    logger: true,
    trustProxy: config.trustedProxies,
  });

  startDbzySyncScheduler(app.log);

  app.addHook('onClose', async () => {
    stopDbzySyncScheduler();
    closeDb();
  });

  app.addHook('onResponse', async (request, reply) => {
    recordAdminAudit(request, reply);
  });

  app.decorate('authRequired', authRequired);
  app.decorate('authOptional', authOptional);
  app.decorate('adminRequired', adminRequired);

  await app.register(cors, {
    origin: config.corsOrigin === '*' ? true : config.corsOrigin.split(','),
  });
  await app.register(websocket);

  app.get('/health', async () => ({
    ok: true,
    service: 'novel-interaction-backend',
    apiPrefix: config.apiPrefix,
    adminPath: config.adminPath,
  }));

  app.register(
    async (api) => {
      api.register(authRoutes);
      api.register(contentRoutes);
      api.register(gameRoutes);
      api.register(growthRoutes);
      api.register(speechRoutes);
      api.register(suibianRoutes);
      api.register(telemetryRoutes);
      api.register(aiNovelRoutes);
      api.register(adminRoutes);
      api.register(adminContentRoutes);
      api.register(adminGrowthRoutes);
      api.register(adminOperationsRoutes);
      api.register(adminVideoRoutes);
      api.register(userRoutes);
    },
    { prefix: config.apiPrefix },
  );

  registerWebSockets(app, config);

  app.get(`${config.adminPath}/config.js`, async (_request, reply) => {
    reply.type('application/javascript');
    return `window.NOVEL_ADMIN_CONFIG = ${JSON.stringify({
      apiPrefix: config.apiPrefix,
      adminPath: config.adminPath,
      wsChatPath: config.wsChatPath,
      wsGamePath: config.wsGamePath,
      wsDanmakuPath: config.wsDanmakuPath,
    })};`;
  });

  await app.register(fastifyStatic, {
    root: path.join(config.rootDir, 'public'),
    prefix: `${config.adminPath}/`,
    decorateReply: false,
  });

  app.get(config.adminPath, async (_request, reply) => {
    return reply.redirect(`${config.adminPath}/`);
  });

  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    if (status >= 500) app.log.error(error);
    reply.code(status).send({
      error: error.publicCode || (status >= 500 ? 'internal_error' : error.message),
    });
  });

  return app;
}

const isMain = process.argv[1]
  ? fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
  : false;

if (isMain) {
  const app = await buildServer();
  await app.listen({ host: config.host, port: config.port });
}
