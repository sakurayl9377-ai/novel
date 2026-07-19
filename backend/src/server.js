import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import fastifyStatic from '@fastify/static';
import websocket from '@fastify/websocket';
import Fastify from 'fastify';
import { recordAdminAudit } from './admin-audit.js';
import { adminRequired, authOptional, authRequired } from './auth.js';
import { seedChatBotRooms } from './chat-bot.js';
import { config } from './config.js';
import { closeDb, migrate, seedAdmin } from './db.js';
import { ensureGrowthRulePersistence } from './growth-rule-service.js';
import { secureLoggerOptions } from './log-security.js';
import { adminRoutes } from './routes-admin.js';
import { adminContentRoutes } from './routes-admin-content.js';
import { adminGrowthRoutes } from './routes-admin-growth.js';
import { adminGrowthRuleRoutes } from './routes-admin-growth-rules.js';
import { adminOperationsRoutes } from './routes-admin-operations.js';
import { adminNotificationRoutes } from './routes-admin-notifications.js';
import { adminRaceRoutes } from './routes-admin-race.js';
import { adminShopRoutes } from './routes-admin-shop.js';
import { aiNovelRoutes } from './routes-ai-novels.js';
import { authRoutes } from './routes-auth.js';
import { contentRoutes } from './routes-content.js';
import { gameRoutes } from './routes-game.js';
import { growthRoutes } from './routes-growth.js';
import { speechRoutes } from './routes-speech.js';
import { telemetryRoutes } from './routes-telemetry.js';
import { userRoutes } from './routes-user.js';
import {
  startUploadOrphanSweeper,
  stopUploadOrphanSweeper,
} from './upload-lifecycle.js';
import { registerWebSockets } from './websocket.js';

export async function buildServer() {
  migrate();
  seedAdmin();
  ensureGrowthRulePersistence();
  seedChatBotRooms();

  const app = Fastify({
    logger: secureLoggerOptions(),
    trustProxy: config.trustedProxies,
  });

  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    if (status >= 500) app.log.error({ err: error }, 'request failed');
    reply.code(status).send({
      error: error.publicCode || (status >= 500 ? 'internal_error' : error.message),
      ...(error.details === undefined ? {} : { details: error.details }),
    });
  });

  startUploadOrphanSweeper(app.log);

  app.addHook('onClose', async () => {
    await stopUploadOrphanSweeper();
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
  await app.register(multipart, {
    limits: {
      files: 1,
      fields: 8,
      parts: 10,
      fileSize: 5 * 1024 * 1024,
    },
  });
  await app.register(websocket, {
    options: {
      maxPayload: Math.max(
        1024,
        Math.min(1024 * 1024, Number(config.websocketMaxPayloadBytes) || 65536),
      ),
    },
  });

  const adminV2Root = path.join(config.rootDir, 'admin-dist');
  const adminV2Available = fs.existsSync(path.join(adminV2Root, 'index.html'));

  app.get('/health', async () => ({
    ok: true,
    service: 'novel-interaction-backend',
    apiPrefix: config.apiPrefix,
    adminPath: config.adminPath,
    adminV2Available,
  }));

  app.register(
    async (api) => {
      api.register(authRoutes);
      api.register(contentRoutes);
      api.register(gameRoutes);
      api.register(growthRoutes);
      api.register(speechRoutes);
      api.register(telemetryRoutes);
      api.register(aiNovelRoutes);
      api.register(adminRoutes);
      api.register(adminContentRoutes);
      api.register(adminGrowthRoutes);
      api.register(adminGrowthRuleRoutes);
      api.register(adminOperationsRoutes);
      api.register(adminNotificationRoutes);
      api.register(adminRaceRoutes);
      api.register(adminShopRoutes);
      api.register(userRoutes);
    },
    { prefix: config.apiPrefix },
  );

  registerWebSockets(app, config);

  const adminConfigHandler = async (_request, reply) => {
    reply.type('application/javascript');
    return `window.NOVEL_ADMIN_CONFIG = ${JSON.stringify({
      apiPrefix: config.apiPrefix,
      adminPath: config.adminPath,
      wsChatPath: config.wsChatPath,
      wsGamePath: config.wsGamePath,
      wsDanmakuPath: config.wsDanmakuPath,
    })};`;
  };

  app.get(`${config.adminPath}/config.js`, adminConfigHandler);
  app.get(`${config.adminPath}/v2/config.js`, adminConfigHandler);
  app.get(`${config.adminPath}/v2/config.json`, async (_request, reply) => {
    reply.header('Cache-Control', 'no-store');
    return {
      apiPrefix: config.apiPrefix,
      adminPath: config.adminPath,
      wsChatPath: config.wsChatPath,
      wsGamePath: config.wsGamePath,
      wsDanmakuPath: config.wsDanmakuPath,
    };
  });

  if (adminV2Available) {
    await app.register(fastifyStatic, {
      root: adminV2Root,
      prefix: `${config.adminPath}/v2/`,
      decorateReply: false,
    });
  }

  app.get(`${config.adminPath}/v2`, async (_request, reply) => {
    return reply.redirect(`${config.adminPath}/v2/`);
  });

  await app.register(fastifyStatic, {
    root: path.join(config.rootDir, 'public'),
    prefix: `${config.adminPath}/`,
    decorateReply: false,
  });

  app.get(config.adminPath, async (_request, reply) => {
    return reply.redirect(`${config.adminPath}/`);
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
