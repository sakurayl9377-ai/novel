import { all } from "./db.js";
import { campaignBannerRoutes } from "./campaign-banner-upload.js";
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
import {
  createRaceSeason,
  createRaceSeasonReward,
  createRaceSeasonTask,
  finalizeRaceSeason,
  raceSeasonDetail,
  raceSeasonList,
  updateRaceSeason,
} from "./race-ops-service.js";

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
    async (request) => finalizeRaceSeason(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
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
    async (request) => raceSeasonList(request.query || {}),
  );

  app.get(
    "/admin/growth/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => raceSeasonDetail(request.params.id, request.query || {}),
  );

  app.post(
    "/admin/growth/seasons",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeason(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/growth/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => updateRaceSeason(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/growth/seasons/:id/tasks",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeasonTask(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  app.post(
    "/admin/growth/seasons/:id/rewards",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeasonReward(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  app.get(
    "/admin/growth/leases",
    { preHandler: app.adminRequired },
    async () => ({ items: all("SELECT * FROM service_leases ORDER BY lease_key") }),
  );
}
