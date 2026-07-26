import { all, db, one, run } from "./db.js";

const definitions = [
  {
    id: "horse-race",
    route: "horse-race",
    name: "樱花赛马",
    description: "小说 App 内置的实时赛马玩法。",
    entryType: "native",
    requiresLogin: true,
    defaultVisible: true,
    defaultSortOrder: 10,
    serviceGroup: "",
  },
  {
    id: "bailian",
    route: "bailian",
    name: "百练英雄",
    description: "使用小说 App 账号单点登录的养成游戏。",
    entryType: "web",
    requiresLogin: true,
    defaultVisible: false,
    defaultSortOrder: 20,
    serviceGroup: "bailian",
  },
  {
    id: "modao",
    route: "modao",
    name: "魔道修仙",
    description: "通过小说 App 下载、安装并单点登录的修仙游戏。",
    entryType: "apk",
    requiresLogin: true,
    defaultVisible: true,
    defaultSortOrder: 30,
    serviceGroup: "modao",
  },
  {
    id: "kdjx",
    route: "kdjx",
    name: "口袋觉醒",
    description: "通过 Sakura App 下载、安装并授权登录的精灵冒险游戏。",
    entryType: "apk",
    requiresLogin: true,
    defaultVisible: true,
    defaultSortOrder: 40,
    serviceGroup: "kdjx",
  },
];

export const GAME_CATALOG_DEFINITIONS = Object.freeze(
  definitions.map((definition) => Object.freeze({ ...definition })),
);

const definitionsById = new Map(
  GAME_CATALOG_DEFINITIONS.map((definition) => [definition.id, definition]),
);

let schemaReady = false;

export function ensureGameCatalogSchema() {
  if (schemaReady) return;

  db.exec(`
    CREATE TABLE IF NOT EXISTS app_game_catalog_state (
      game_id TEXT PRIMARY KEY,
      visible INTEGER NOT NULL DEFAULT 0 CHECK (visible IN (0, 1)),
      sort_order INTEGER NOT NULL DEFAULT 0,
      updated_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS game_service_control_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      game_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      result TEXT NOT NULL CHECK (result IN ('succeeded', 'failed')),
      error_code TEXT NOT NULL DEFAULT '',
      admin_user_id INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_game_service_control_events_time
      ON game_service_control_events(created_at DESC, id DESC);
  `);

  const insert = db.prepare(
    `INSERT OR IGNORE INTO app_game_catalog_state
       (game_id, visible, sort_order)
     VALUES (?, ?, ?)`,
  );
  for (const definition of GAME_CATALOG_DEFINITIONS) {
    insert.run(
      definition.id,
      definition.defaultVisible ? 1 : 0,
      definition.defaultSortOrder,
    );
  }

  schemaReady = true;
}

export function gameDefinition(gameId) {
  return definitionsById.get(String(gameId || "").trim()) || null;
}

export function publicGameCatalog() {
  ensureGameCatalogSchema();
  return catalogRows()
    .filter((row) => row.visible === 1)
    .map((row) => publicGameJson(row));
}

export function adminGameCatalog() {
  ensureGameCatalogSchema();
  return catalogRows().map((row) => adminGameJson(row));
}

export function adminGameById(gameId) {
  ensureGameCatalogSchema();
  const definition = requireGameDefinition(gameId);
  const row = one(
    `SELECT game_id, visible, sort_order, updated_at
     FROM app_game_catalog_state
     WHERE game_id = ?`,
    [definition.id],
  );
  return adminGameJson(row);
}

export function setGameVisibility(gameId, visible, adminUserId) {
  ensureGameCatalogSchema();
  const definition = requireGameDefinition(gameId);
  if (typeof visible !== "boolean") {
    throw catalogError("game_visibility_invalid", 400);
  }
  run(
    `UPDATE app_game_catalog_state
     SET visible = ?, updated_by = ?, updated_at = datetime('now')
     WHERE game_id = ?`,
    [visible ? 1 : 0, Number(adminUserId) || null, definition.id],
  );
  return adminGameById(definition.id);
}

export function recordGameControlEvent({
  gameId,
  operation,
  result,
  errorCode = "",
  adminUserId,
}) {
  ensureGameCatalogSchema();
  const definition = requireGameDefinition(gameId);
  const safeOperation = String(operation || "").trim();
  const safeResult = String(result || "").trim();
  if (!["start", "stop", "restart"].includes(safeOperation)) {
    throw catalogError("game_action_invalid", 400);
  }
  if (!["succeeded", "failed"].includes(safeResult)) {
    throw catalogError("game_control_result_invalid", 500);
  }
  run(
    `INSERT INTO game_service_control_events
       (game_id, operation, result, error_code, admin_user_id)
     VALUES (?, ?, ?, ?, ?)`,
    [
      definition.id,
      safeOperation,
      safeResult,
      String(errorCode || "").slice(0, 100),
      Number(adminUserId) || null,
    ],
  );
}

function catalogRows() {
  const stateRows = all(
    `SELECT game_id, visible, sort_order, updated_at
     FROM app_game_catalog_state
     ORDER BY sort_order ASC, game_id ASC`,
  );
  const stateById = new Map(stateRows.map((row) => [row.game_id, row]));
  return GAME_CATALOG_DEFINITIONS
    .map((definition) => {
      const state = stateById.get(definition.id);
      return state ? { ...state, definition } : null;
    })
    .filter(Boolean)
    .sort(
      (left, right) =>
        Number(left.sort_order) - Number(right.sort_order) ||
        left.definition.id.localeCompare(right.definition.id),
    );
}

function publicGameJson(row) {
  const { definition } = row;
  return {
    id: definition.id,
    route: definition.route,
    name: definition.name,
    description: definition.description,
    visible: true,
    enabled: true,
    sortOrder: Number(row.sort_order),
    entryType: definition.entryType,
    requiresLogin: definition.requiresLogin,
  };
}

function adminGameJson(row) {
  if (!row) throw catalogError("game_not_found", 404);
  const definition = row.definition || gameDefinition(row.game_id);
  if (!definition) throw catalogError("game_not_found", 404);
  return {
    id: definition.id,
    route: definition.route,
    name: definition.name,
    description: definition.description,
    visible: Number(row.visible) === 1,
    sortOrder: Number(row.sort_order),
    entryType: definition.entryType,
    requiresLogin: definition.requiresLogin,
    controllable: Boolean(definition.serviceGroup),
    updatedAt: row.updated_at,
  };
}

function requireGameDefinition(gameId) {
  const definition = gameDefinition(gameId);
  if (!definition) throw catalogError("game_not_found", 404);
  return definition;
}

function catalogError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.publicCode = code;
  error.statusCode = statusCode;
  return error;
}
