import {
  acknowledgeLoginRewardNotice,
  activityFeed,
  claimSeasonTaskReward,
  claimActivityReward,
  horseRaceSeasonState,
  ingestContentBehavior,
  rankingBoard,
  recommendations,
  responsibleGamingState,
  syncLoginCampaignRewards,
  startHorseRaceCooldown,
  startHorseRaceSelfExclusion,
  updateResponsibleGaming,
} from "./growth-operations.js";
import { optionalInt, optionalString } from "./validators.js";

export async function growthRoutes(app) {
  app.post(
    "/growth/login-rewards/sync",
    { preHandler: app.authRequired },
    async (request) => syncLoginCampaignRewards({ userId: request.user.id }),
  );

  app.post(
    "/growth/login-rewards/:id/ack",
    { preHandler: app.authRequired },
    async (request) => acknowledgeLoginRewardNotice({
      userId: request.user.id,
      noticeId: optionalInt(request.params.id, 0),
    }),
  );

  app.post(
    "/app/behavior-events",
    { preHandler: app.authOptional },
    async (request) => ingestContentBehavior({ request, body: request.body || {} }),
  );

  app.get(
    "/app/recommendations",
    { preHandler: app.authOptional },
    async (request) => ({
      generatedAt: new Date().toISOString(),
      strategy: "placements+continue+preference+bounded_popularity+cold_start",
      items: recommendations({
        userId: request.user?.id || 0,
        contentType: optionalString(request.query?.contentType, 20).toLowerCase(),
        limit: optionalInt(request.query?.limit, 20),
        versionCode: Math.max(0, optionalInt(request.query?.versionCode, 0)),
        platform: optionalString(request.query?.platform, 30).toLowerCase(),
        installId: optionalString(request.query?.installId, 120),
        ip: request.ip,
      }),
    }),
  );

  app.post(
    "/games/horse-race/season/tasks/:taskId/claim",
    { preHandler: app.authRequired },
    async (request) => ({
      item: claimSeasonTaskReward({
        userId: request.user.id,
        taskId: optionalInt(request.params.taskId, 0),
      }),
    }),
  );

  app.get(
    "/app/rankings",
    { preHandler: app.authOptional },
    async (request) => {
      const period = optionalString(request.query?.period, 20).toLowerCase() || "weekly";
      const metric = optionalString(request.query?.metric, 30).toLowerCase() || "hot";
      return {
        generatedAt: new Date().toISOString(),
        period,
        metric,
        items: rankingBoard({
          period,
          metric,
          contentType: optionalString(request.query?.contentType, 20).toLowerCase(),
          limit: optionalInt(request.query?.limit, 30),
        }),
      };
    },
  );

  app.get(
    "/app/activities",
    { preHandler: app.authOptional },
    async (request) => ({
      items: activityFeed({
        userId: request.user?.id || 0,
        versionCode: Math.max(0, optionalInt(request.query?.versionCode, 0)),
      }),
    }),
  );

  app.post(
    "/app/activities/:campaignId/tasks/:taskId/claim",
    { preHandler: app.authRequired },
    async (request) => ({
      item: claimActivityReward({
        userId: request.user.id,
        campaignId: optionalInt(request.params.campaignId, 0),
        taskId: optionalInt(request.params.taskId, 0),
        idempotencyKey:
          request.body?.idempotencyKey || request.headers["idempotency-key"] || "",
        versionCode: Math.max(0, optionalInt(request.body?.versionCode, 0)),
      }),
    }),
  );

  app.get(
    "/games/horse-race/season",
    { preHandler: app.authOptional },
    async (request) => ({
      item: horseRaceSeasonState(request.user?.id || 0, optionalInt(request.query?.limit, 50)),
    }),
  );

  app.get(
    "/games/horse-race/responsible-gaming",
    { preHandler: app.authRequired },
    async (request) => ({ item: responsibleGamingState(request.user.id) }),
  );

  app.patch(
    "/games/horse-race/responsible-gaming",
    { preHandler: app.authRequired },
    async (request) => ({ item: updateResponsibleGaming(request.user.id, request.body || {}) }),
  );

  app.post(
    "/games/horse-race/responsible-gaming/cooldown",
    { preHandler: app.authRequired },
    async (request) => ({ item: startHorseRaceCooldown(request.user.id, request.body?.hours) }),
  );

  app.post(
    "/games/horse-race/responsible-gaming/self-exclusion",
    { preHandler: app.authRequired },
    async (request) => ({ item: startHorseRaceSelfExclusion(request.user.id, request.body?.days) }),
  );
}
