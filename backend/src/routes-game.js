import {
  horseRaceHistoryJson,
  horseRaceStateJson,
  placeHorseRaceBet,
} from "./horse-race.js";
import { optionalInt } from "./validators.js";

export async function gameRoutes(app) {
  app.get(
    "/games/horse-race",
    { preHandler: app.authRequired },
    async (request) => ({ item: horseRaceStateJson(request.user.id) }),
  );

  app.post(
    "/games/horse-race/bets",
    { preHandler: app.authRequired },
    async (request) => {
      const state = placeHorseRaceBet({
        userId: request.user.id,
        horseIndex: optionalInt(request.body?.horseIndex, -1),
        amount: optionalInt(request.body?.amount, 0),
        requestId:
          request.body?.requestId || request.headers["idempotency-key"] || "",
      });
      if (typeof app.broadcastHorseRace === "function") {
        app.broadcastHorseRace();
      }
      return { ok: true, item: state };
    },
  );

  app.get(
    "/games/horse-race/history",
    { preHandler: app.authRequired },
    async (request) => ({
      items: horseRaceHistoryJson({
        userId: request.user.id,
        limit: optionalInt(request.query?.limit, 10),
      }),
    }),
  );
}
