import { execFile } from "node:child_process";

export const GAME_CONTROL_HELPER_PATH =
  "/usr/local/sbin/novel-game-service-control";

const actionSet = new Set(["status", "start", "stop", "restart"]);
const statusSet = new Set([
  "running",
  "stopped",
  "failed",
  "activating",
  "deactivating",
  "unknown",
]);
const helperErrorSet = new Set([
  "game_control_action_failed",
  "game_control_action_invalid",
  "game_control_busy",
  "game_control_game_invalid",
  "game_control_not_root",
  "game_control_service_unavailable",
  "game_control_state_mismatch",
  "game_control_timeout",
]);
const unitGroups = Object.freeze({
  bailian: Object.freeze([
    "bailian-game.service",
    "bailian-backstage.service",
  ]),
  modao: Object.freeze([
    "modao-redis.service",
    "modao-static.service",
    "modao-account.service",
    "modao-game.service",
  ]),
});

export function unmanagedGameServiceStatus() {
  return {
    unit: "",
    status: "unmanaged",
    active: true,
    enabled: true,
    checkedAt: new Date().toISOString(),
    units: [],
  };
}

export function unavailableGameServiceStatus(gameId) {
  return {
    unit: String(gameId || ""),
    status: "unknown",
    active: false,
    enabled: false,
    checkedAt: new Date().toISOString(),
    units: [],
    error: "game_control_unavailable",
  };
}

export function runGameServiceControl(
  gameId,
  action,
  {
    execFileImpl = execFile,
    timeoutMs = 120_000,
  } = {},
) {
  const safeGameId = normalizeGameId(gameId);
  const safeAction = normalizeAction(action);
  return new Promise((resolve, reject) => {
    execFileImpl(
      "sudo",
      ["-n", GAME_CONTROL_HELPER_PATH, safeGameId, safeAction],
      {
        encoding: "utf8",
        timeout: Math.max(1_000, Math.min(180_000, Number(timeoutMs) || 120_000)),
        maxBuffer: 64 * 1024,
        windowsHide: true,
      },
      (error, stdout) => {
        const decoded = decodeHelperOutput(stdout);
        if (error || decoded?.ok !== true) {
          const code = helperErrorSet.has(decoded?.error)
            ? decoded.error
            : error?.killed
              ? "game_control_timeout"
              : "game_control_unavailable";
          reject(serviceError(code, code === "game_control_busy" ? 409 : 503));
          return;
        }
        try {
          resolve(sanitizeServiceStatus(safeGameId, decoded.data));
        } catch {
          reject(serviceError("game_control_unavailable", 503));
        }
      },
    );
  });
}

export function normalizeGameControlAction(value) {
  return normalizeAction(value);
}

function normalizeGameId(value) {
  const gameId = String(value || "").trim();
  if (!Object.hasOwn(unitGroups, gameId)) {
    throw serviceError("game_not_controllable", 400);
  }
  return gameId;
}

function normalizeAction(value) {
  const action = String(value || "").trim().toLowerCase();
  if (!actionSet.has(action)) {
    throw serviceError("game_action_invalid", 400);
  }
  return action;
}

function decodeHelperOutput(stdout) {
  try {
    const decoded = JSON.parse(String(stdout || "").trim());
    return decoded && typeof decoded === "object" ? decoded : null;
  } catch {
    return null;
  }
}

function sanitizeServiceStatus(gameId, raw) {
  if (!raw || typeof raw !== "object" || raw.gameId !== gameId) {
    throw new Error("invalid_helper_response");
  }
  const expectedUnits = unitGroups[gameId];
  if (!Array.isArray(raw.units) || raw.units.length !== expectedUnits.length) {
    throw new Error("invalid_helper_response");
  }
  const rawByUnit = new Map();
  for (const item of raw.units) {
    if (
      !item ||
      typeof item !== "object" ||
      typeof item.unit !== "string" ||
      rawByUnit.has(item.unit) ||
      !expectedUnits.includes(item.unit)
    ) {
      throw new Error("invalid_helper_response");
    }
    const status = String(item.status || "");
    if (!statusSet.has(status)) throw new Error("invalid_helper_response");
    rawByUnit.set(item.unit, {
      unit: item.unit,
      status,
      active: item.active === true,
      enabled: item.enabled === true,
      unitFileState: safeUnitFileState(item.unitFileState),
    });
  }
  const units = expectedUnits.map((unit) => rawByUnit.get(unit));
  if (units.some((unit) => !unit)) throw new Error("invalid_helper_response");
  return {
    unit: gameId,
    status: aggregateStatus(units),
    active: units.every((unit) => unit.active),
    enabled: units.every((unit) => unit.enabled),
    checkedAt: new Date().toISOString(),
    units,
  };
}

function safeUnitFileState(value) {
  const state = String(value || "").trim().toLowerCase();
  return /^[a-z][a-z0-9_-]{0,31}$/.test(state) ? state : "unknown";
}

function aggregateStatus(units) {
  if (units.every((unit) => unit.status === "running")) return "running";
  if (units.every((unit) => unit.status === "stopped")) return "stopped";
  if (units.some((unit) => unit.status === "failed")) return "failed";
  if (
    units.every((unit) =>
      ["running", "activating"].includes(unit.status),
    ) &&
    units.some((unit) => unit.status === "activating")
  ) {
    return "activating";
  }
  if (
    units.every((unit) =>
      ["stopped", "deactivating"].includes(unit.status),
    ) &&
    units.some((unit) => unit.status === "deactivating")
  ) {
    return "deactivating";
  }
  if (units.every((unit) => unit.status === "unknown")) return "unknown";
  return "partial";
}

function serviceError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.publicCode = code;
  error.statusCode = statusCode;
  return error;
}
