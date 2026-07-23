import {
  adminGameById,
  adminGameCatalog,
  ensureGameCatalogSchema,
  gameDefinition,
  recordGameControlEvent,
  setGameVisibility,
} from "./game-catalog-service.js";
import {
  normalizeGameControlAction,
  runGameServiceControl,
  unavailableGameServiceStatus,
  unmanagedGameServiceStatus,
} from "./game-service-control.js";

export async function adminGameControlRoutes(app, options = {}) {
  ensureGameCatalogSchema();
  const serviceControl =
    typeof options.serviceControl === "function"
      ? options.serviceControl
      : runGameServiceControl;
  const operationsInProgress = new Set();

  app.get(
    "/admin/games/control",
    { preHandler: app.adminRequired },
    async (_request, reply) => {
      reply.header("Cache-Control", "no-store");
      const games = await Promise.all(
        adminGameCatalog().map((game) => gameWithService(game, serviceControl)),
      );
      return { generatedAt: new Date().toISOString(), games };
    },
  );

  app.patch(
    "/admin/games/control/:id/visibility",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header("Cache-Control", "no-store");
      if (typeof request.body?.visible !== "boolean") {
        throw routeError("game_visibility_invalid", 400);
      }
      const definition = gameDefinition(request.params?.id);
      if (!definition) throw routeError("game_not_found", 404);
      const operationKey = gameOperationKey(definition);
      acquireGameOperation(operationsInProgress, operationKey);
      try {
        let service = null;
        if (request.body.visible && definition.serviceGroup) {
          service = await serviceControl(definition.serviceGroup, "status");
          if (service?.status !== "running" || service?.active !== true) {
            throw routeError("game_service_not_running", 409);
          }
        }
        const game = setGameVisibility(
          definition.id,
          request.body.visible,
          request.user.id,
        );
        return {
          game: service
            ? { ...game, service }
            : await gameWithService(game, serviceControl),
        };
      } finally {
        operationsInProgress.delete(operationKey);
      }
    },
  );

  app.post(
    "/admin/games/control/:id/action",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header("Cache-Control", "no-store");
      const game = adminGameById(request.params?.id);
      const definition = gameDefinition(game.id);
      if (!definition?.serviceGroup) {
        throw routeError("game_not_controllable", 400);
      }
      const action = normalizeGameControlAction(request.body?.action);
      const operationKey = gameOperationKey(definition);
      let service;
      acquireGameOperation(operationsInProgress, operationKey);
      try {
        if (action === "stop") {
          // Hide before touching systemd so a successful stop can never leave a
          // stale public entry if a later SQLite audit write is unavailable.
          setGameVisibility(game.id, false, request.user.id);
        }
        service = await serviceControl(definition.serviceGroup, action);
        if (action === "stop") {
          // Reassert the fail-closed state after systemd confirms the stop. The
          // shared operation lock prevents a concurrent visibility request in
          // this process from publishing a game while it is stopping.
          setGameVisibility(game.id, false, request.user.id);
        }
      } catch (error) {
        tryRecordGameControlEvent(
          {
            gameId: game.id,
            operation: action,
            result: "failed",
            errorCode: safeControlError(error),
            adminUserId: request.user.id,
          },
          request,
        );
        throw error;
      } finally {
        operationsInProgress.delete(operationKey);
      }
      tryRecordGameControlEvent(
        {
          gameId: game.id,
          operation: action,
          result: "succeeded",
          adminUserId: request.user.id,
        },
        request,
      );
      return {
        game: {
          ...adminGameById(game.id),
          service,
        },
      };
    },
  );
}

function gameOperationKey(definition) {
  return definition.serviceGroup || `catalog:${definition.id}`;
}

function acquireGameOperation(operationsInProgress, operationKey) {
  if (operationsInProgress.has(operationKey)) {
    throw routeError("game_control_busy", 409);
  }
  operationsInProgress.add(operationKey);
}

async function gameWithService(game, serviceControl) {
  const definition = gameDefinition(game.id);
  if (!definition?.serviceGroup) {
    return { ...game, service: unmanagedGameServiceStatus() };
  }
  try {
    return {
      ...game,
      service: await serviceControl(definition.serviceGroup, "status"),
    };
  } catch {
    return {
      ...game,
      service: unavailableGameServiceStatus(definition.serviceGroup),
    };
  }
}

function tryRecordGameControlEvent(payload, request) {
  try {
    recordGameControlEvent(payload);
  } catch (error) {
    request.log?.warn?.({ error }, "failed to record game control event");
  }
}

function safeControlError(error) {
  const code = String(error?.publicCode || error?.code || error?.message || "");
  return /^game_[a-z0-9_]{1,80}$/.test(code)
    ? code
    : "game_control_failed";
}

function routeError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.publicCode = code;
  error.statusCode = statusCode;
  return error;
}
