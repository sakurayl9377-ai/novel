import {
  ensureGameCatalogSchema,
  gameDefinition,
  publicGameCatalog,
} from "./game-catalog-service.js";
import { runGameServiceControl } from "./game-service-control.js";

export async function gameCatalogRoutes(app, options = {}) {
  ensureGameCatalogSchema();
  const serviceControl =
    typeof options.serviceControl === "function"
      ? options.serviceControl
      : runGameServiceControl;
  const statusTimeoutMs = Math.max(
    1_000,
    Math.min(10_000, Number(options.statusTimeoutMs) || 5_000),
  );

  app.get("/games/catalog", async (_request, reply) => {
    reply.header("Cache-Control", "no-store");
    const games = await Promise.all(
      publicGameCatalog().map(async (game) => {
        const definition = gameDefinition(game.id);
        if (!definition?.serviceGroup) return game;
        try {
          const service = await serviceControl(
            definition.serviceGroup,
            "status",
            { timeoutMs: statusTimeoutMs },
          );
          return service?.status === "running" && service?.active === true
            ? game
            : null;
        } catch {
          return null;
        }
      }),
    );
    return {
      generatedAt: new Date().toISOString(),
      games: games.filter(Boolean),
    };
  });
}
