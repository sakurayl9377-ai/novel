import {
  adminHorseRaceRoundDetail,
  adminHorseRaceRounds,
  createRaceSeason,
  createRaceSeasonReward,
  createRaceSeasonTask,
  finalizeRaceSeason,
  horseRaceOperationsWorkbench,
  raceSeasonDetail,
  raceSeasonList,
  removeRaceSeasonReward,
  removeRaceSeasonTask,
  responsibleGamingOverview,
  transitionRaceSeason,
  updateRaceSeason,
  updateRaceSeasonReward,
  updateRaceSeasonTask,
} from "./race-ops-service.js";

export async function adminRaceRoutes(app) {
  app.get(
    "/admin/horse-race/workbench",
    { preHandler: app.adminRequired },
    async () => horseRaceOperationsWorkbench(),
  );

  app.get(
    "/admin/horse-race/rounds",
    { preHandler: app.adminRequired },
    async (request) => adminHorseRaceRounds(request.query || {}),
  );

  app.get(
    "/admin/horse-race/rounds/:id",
    { preHandler: app.adminRequired },
    async (request) => adminHorseRaceRoundDetail(request.params.id, request.query || {}),
  );

  app.get(
    "/admin/horse-race/responsible-gaming",
    { preHandler: app.adminRequired },
    async () => responsibleGamingOverview(),
  );

  app.get(
    "/admin/horse-race/seasons",
    { preHandler: app.adminRequired },
    async (request) => raceSeasonList(request.query || {}),
  );

  app.get(
    "/admin/horse-race/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => raceSeasonDetail(request.params.id, request.query || {}),
  );

  app.post(
    "/admin/horse-race/seasons",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeason(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/horse-race/seasons/:id",
    { preHandler: app.adminRequired },
    async (request) => updateRaceSeason(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/horse-race/seasons/:id/status",
    { preHandler: app.adminRequired },
    async (request) => transitionRaceSeason(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/horse-race/seasons/:id/finalize",
    { preHandler: app.adminRequired },
    async (request) => finalizeRaceSeason(request.user.id, request.params.id, request.body || {}),
  );

  app.post(
    "/admin/horse-race/seasons/:id/tasks",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeasonTask(request.user.id, request.params.id, request.body || {}),
  );

  app.patch(
    "/admin/horse-race/seasons/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => updateRaceSeasonTask(
      request.user.id,
      request.params.id,
      request.params.taskId,
      request.body || {},
    ),
  );

  app.delete(
    "/admin/horse-race/seasons/:id/tasks/:taskId",
    { preHandler: app.adminRequired },
    async (request) => removeRaceSeasonTask(
      request.user.id,
      request.params.id,
      request.params.taskId,
      request.body || {},
    ),
  );

  app.post(
    "/admin/horse-race/seasons/:id/rewards",
    { preHandler: app.adminRequired },
    async (request) => createRaceSeasonReward(request.user.id, request.params.id, request.body || {}),
  );

  app.patch(
    "/admin/horse-race/seasons/:id/rewards/:rewardId",
    { preHandler: app.adminRequired },
    async (request) => updateRaceSeasonReward(
      request.user.id,
      request.params.id,
      request.params.rewardId,
      request.body || {},
    ),
  );

  app.delete(
    "/admin/horse-race/seasons/:id/rewards/:rewardId",
    { preHandler: app.adminRequired },
    async (request) => removeRaceSeasonReward(
      request.user.id,
      request.params.id,
      request.params.rewardId,
      request.body || {},
    ),
  );
}
