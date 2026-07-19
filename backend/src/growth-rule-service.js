import { all, db, one, run } from "./db.js";
import {
  growthPrivilegeDefinitions,
  levelThresholds,
  maxLevel,
} from "./growth.js";

const systemPermissions = levelThresholds.map((item) => [
  ...(item.permissions || []),
]);
const defaultRules = levelThresholds.map(ruleSnapshot);
const editableRuleFields = [
  "name",
  "effect",
  "points",
  "dailyPointCap",
  "targetDays",
];
const growthAudiencePredicate = `
  role = 'user'
  AND lower(email) NOT IN ('chatbot@system.local', 'chat-bot@system.local')`;

export function ensureGrowthRulePersistence() {
  let published = publishedRow();
  if (!published) {
    const revision = nextRevision();
    run(
      `INSERT INTO growth_rule_sets
         (revision, state, base_revision, edit_version, rules_json, note,
          created_at, updated_at, published_at)
       VALUES (?, 'published', 0, 1, ?, '系统初始成长规则',
               datetime('now'), datetime('now'), datetime('now'))`,
      [revision, serializeRules(defaultRules)],
    );
    published = publishedRow();
  }
  applyPublishedRules(parseRules(published.rules_json));
}

export function growthRulesWorkbench() {
  const active = requirePublishedSet();
  const draft = draftRow();
  const stats = growthRuleStats(active.rules);
  return {
    generatedAt: new Date().toISOString(),
    active,
    draft: draft ? ruleSetJson(draft) : null,
    impact: draft
      ? growthRuleImpact(active.rules, parseRules(draft.rules_json))
      : null,
    stats,
    capabilities: growthPrivilegeDefinitions.map((item) => ({ ...item })),
    history: historyRows().map(ruleSetJson),
  };
}

export function saveGrowthRulesDraft(adminUserId, body) {
  const rules = normalizeRules(body?.rules);
  const expectedEditVersion = expectedVersion(
    body?.expectedEditVersion,
    "expectedEditVersion",
    0,
  );
  const note = requiredText(body?.note, "note", 300);

  immediateTransaction(() => {
    const active = requirePublishedRow();
    const existing = draftRow();
    if (sameRules(rules, parseRules(active.rules_json))) {
      throw domainError("growth_rules_no_changes");
    }
    if (existing) {
      requireDraftVersion(existing, expectedEditVersion);
      if (Number(existing.base_revision) !== Number(active.revision)) {
        throw domainError("growth_rules_draft_outdated", 409, {
          baseRevision: Number(existing.base_revision),
          activeRevision: Number(active.revision),
        });
      }
      run(
        `UPDATE growth_rule_sets
         SET rules_json = ?, note = ?, admin_user_id = ?,
             edit_version = edit_version + 1, updated_at = datetime('now')
         WHERE id = ? AND edit_version = ?`,
        [
          serializeRules(rules),
          note,
          adminUserId,
          existing.id,
          expectedEditVersion,
        ],
      );
      return;
    }
    if (expectedEditVersion !== 0) {
      throw domainError("growth_rules_draft_revision_conflict", 409, {
        expectedEditVersion,
        currentEditVersion: 0,
      });
    }
    run(
      `INSERT INTO growth_rule_sets
         (revision, state, base_revision, edit_version, rules_json, note,
          admin_user_id, created_at, updated_at)
       VALUES (?, 'draft', ?, 1, ?, ?, ?, datetime('now'), datetime('now'))`,
      [
        nextRevision(),
        Number(active.revision),
        serializeRules(rules),
        note,
        adminUserId,
      ],
    );
  });
  return growthRulesWorkbench();
}

export function publishGrowthRulesDraft(adminUserId, body) {
  const expectedEditVersion = expectedVersion(
    body?.expectedEditVersion,
    "expectedEditVersion",
    1,
  );
  const note = requiredText(body?.note, "note", 300);
  let impact;

  immediateTransaction(() => {
    const active = requirePublishedRow();
    const draft = requireDraftRow();
    requireDraftVersion(draft, expectedEditVersion);
    if (Number(draft.base_revision) !== Number(active.revision)) {
      throw domainError("growth_rules_draft_outdated", 409, {
        baseRevision: Number(draft.base_revision),
        activeRevision: Number(active.revision),
      });
    }
    const activeRules = parseRules(active.rules_json);
    const draftRules = parseRules(draft.rules_json);
    impact = growthRuleImpact(activeRules, draftRules);
    if (
      (impact.levelDownUsers > 0 || impact.dailyCapReducedUsers > 0) &&
      body?.acknowledgeImpact !== true
    ) {
      throw domainError("growth_rules_impact_acknowledgement_required", 400, {
        levelDownUsers: impact.levelDownUsers,
        dailyCapReducedUsers: impact.dailyCapReducedUsers,
      });
    }
    run(
      `UPDATE growth_rule_sets
       SET state = 'superseded', updated_at = datetime('now')
       WHERE id = ? AND state = 'published'`,
      [active.id],
    );
    const result = run(
      `UPDATE growth_rule_sets
       SET state = 'published', note = ?, admin_user_id = ?,
           edit_version = edit_version + 1, updated_at = datetime('now'),
           published_at = datetime('now')
       WHERE id = ? AND state = 'draft' AND edit_version = ?`,
      [note, adminUserId, draft.id, expectedEditVersion],
    );
    if (!result.changes) {
      throw domainError("growth_rules_draft_revision_conflict", 409);
    }
  });

  applyPublishedRules(parseRules(requirePublishedRow().rules_json));
  return { ...growthRulesWorkbench(), publishedImpact: impact };
}

export function discardGrowthRulesDraft(adminUserId, body) {
  const expectedEditVersion = expectedVersion(
    body?.expectedEditVersion,
    "expectedEditVersion",
    1,
  );
  const note = requiredText(body?.note, "note", 300);
  immediateTransaction(() => {
    const draft = requireDraftRow();
    requireDraftVersion(draft, expectedEditVersion);
    const result = run(
      `UPDATE growth_rule_sets
       SET state = 'discarded', note = ?, admin_user_id = ?,
           edit_version = edit_version + 1, updated_at = datetime('now')
       WHERE id = ? AND state = 'draft' AND edit_version = ?`,
      [note, adminUserId, draft.id, expectedEditVersion],
    );
    if (!result.changes) {
      throw domainError("growth_rules_draft_revision_conflict", 409);
    }
  });
  return growthRulesWorkbench();
}

export function restoreGrowthRulesRevision(adminUserId, rawRevision, body) {
  const revision = expectedVersion(rawRevision, "revision", 1);
  const note = requiredText(body?.note, "note", 300);
  immediateTransaction(() => {
    const active = requirePublishedRow();
    const source = one(
      `SELECT * FROM growth_rule_sets
       WHERE revision = ? AND state = 'superseded'`,
      [revision],
    );
    if (!source) throw domainError("growth_rules_revision_not_found", 404);
    const existing = draftRow();
    if (existing) {
      if (body?.replaceDraft !== true) {
        throw domainError("growth_rules_draft_exists", 409, {
          editVersion: Number(existing.edit_version),
        });
      }
      const expectedDraftEditVersion = expectedVersion(
        body?.expectedDraftEditVersion,
        "expectedDraftEditVersion",
        1,
      );
      requireDraftVersion(existing, expectedDraftEditVersion);
      run(
        `UPDATE growth_rule_sets
         SET state = 'discarded', note = ?, admin_user_id = ?,
             edit_version = edit_version + 1, updated_at = datetime('now')
         WHERE id = ?`,
        [`被版本 ${revision} 的恢复草稿替换：${note}`, adminUserId, existing.id],
      );
    }
    run(
      `INSERT INTO growth_rule_sets
         (revision, state, base_revision, edit_version, rules_json, note,
          admin_user_id, created_at, updated_at)
       VALUES (?, 'draft', ?, 1, ?, ?, ?, datetime('now'), datetime('now'))`,
      [
        nextRevision(),
        Number(active.revision),
        serializeRules(parseRules(source.rules_json)),
        `从版本 ${revision} 恢复：${note}`,
        adminUserId,
      ],
    );
  });
  return growthRulesWorkbench();
}

export function growthRuleImpact(activeRules, proposedRules) {
  const before = normalizeRules(activeRules);
  const after = normalizeRules(proposedRules);
  const rows = all(
    `SELECT before_level, after_level, COUNT(*) AS users
     FROM (
       SELECT ${levelCaseSql(before)} AS before_level,
              ${levelCaseSql(after)} AS after_level
       FROM users
       WHERE ${growthAudiencePredicate}
     )
     GROUP BY before_level, after_level`,
  );
  const beforeDistribution = emptyDistribution();
  const afterDistribution = emptyDistribution();
  let affectedLevelUsers = 0;
  let levelUpUsers = 0;
  let levelDownUsers = 0;
  let dailyCapChangedUsers = 0;
  let dailyCapReducedUsers = 0;
  let totalUsers = 0;
  for (const row of rows) {
    const beforeLevel = Number(row.before_level || 1);
    const afterLevel = Number(row.after_level || 1);
    const users = Number(row.users || 0);
    totalUsers += users;
    beforeDistribution[beforeLevel - 1].users += users;
    afterDistribution[afterLevel - 1].users += users;
    if (beforeLevel !== afterLevel) {
      affectedLevelUsers += users;
      if (afterLevel > beforeLevel) levelUpUsers += users;
      if (afterLevel < beforeLevel) levelDownUsers += users;
    }
    const beforeCap = before[beforeLevel - 1].dailyPointCap;
    const afterCap = after[afterLevel - 1].dailyPointCap;
    if (beforeCap !== afterCap) dailyCapChangedUsers += users;
    if (afterCap < beforeCap) dailyCapReducedUsers += users;
  }
  return {
    totalUsers,
    affectedLevelUsers,
    levelUpUsers,
    levelDownUsers,
    dailyCapChangedUsers,
    dailyCapReducedUsers,
    changedLevels: changedLevels(before, after),
    beforeDistribution,
    afterDistribution,
  };
}

function growthRuleStats(rules) {
  const normalized = normalizeRules(rules);
  const summary = one(
    `SELECT COUNT(*) AS users,
            COALESCE(MIN(points), 0) AS min_points,
            COALESCE(MAX(points), 0) AS max_points,
            COALESCE(AVG(points), 0) AS average_points
     FROM users
     WHERE ${growthAudiencePredicate}`,
  );
  const distribution = emptyDistribution();
  for (const row of all(
    `SELECT computed_level, COUNT(*) AS users
     FROM (
       SELECT ${levelCaseSql(normalized)} AS computed_level
       FROM users
       WHERE ${growthAudiencePredicate}
     )
     GROUP BY computed_level`,
  )) {
    distribution[Number(row.computed_level || 1) - 1].users = Number(
      row.users || 0,
    );
  }
  return {
    users: Number(summary?.users || 0),
    minPoints: Number(summary?.min_points || 0),
    maxPoints: Number(summary?.max_points || 0),
    averagePoints: Number(summary?.average_points || 0),
    distribution,
  };
}

function normalizeRules(value) {
  if (!Array.isArray(value) || value.length !== maxLevel) {
    throw domainError("growth_rules_shape_invalid", 400, {
      expectedLevels: maxLevel,
    });
  }
  const rules = value.map((raw, index) => {
    const item = raw && typeof raw === "object" ? raw : {};
    const level = integer(item.level, "level", 1, maxLevel);
    if (level !== index + 1) {
      throw domainError("growth_rules_level_order_invalid", 400, {
        expectedLevel: index + 1,
      });
    }
    return {
      level,
      points: integer(item.points, "points", 0, 10_000_000),
      name: requiredText(item.name, "name", 24),
      effect: requiredText(item.effect, "effect", 120),
      dailyPointCap: integer(
        item.dailyPointCap,
        "dailyPointCap",
        1,
        10_000,
      ),
      targetDays: integer(item.targetDays, "targetDays", 0, 36_500),
      permissions: [...systemPermissions[index]],
    };
  });
  if (rules[0].points !== 0) {
    throw domainError("growth_rules_level_one_points_invalid");
  }
  if (rules[0].targetDays !== 0) {
    throw domainError("growth_rules_level_one_days_invalid");
  }
  for (let index = 1; index < rules.length; index += 1) {
    const previous = rules[index - 1];
    const current = rules[index];
    if (current.points <= previous.points) {
      throw domainError("growth_rules_threshold_order_invalid", 400, {
        level: current.level,
      });
    }
    if (current.dailyPointCap < previous.dailyPointCap) {
      throw domainError("growth_rules_daily_cap_order_invalid", 400, {
        level: current.level,
      });
    }
    if (current.targetDays < previous.targetDays) {
      throw domainError("growth_rules_target_days_order_invalid", 400, {
        level: current.level,
      });
    }
  }
  return rules;
}

function parseRules(value) {
  try {
    return normalizeRules(JSON.parse(String(value || "[]")));
  } catch (error) {
    if (error?.statusCode) throw error;
    throw domainError("growth_rules_persisted_payload_invalid", 500);
  }
}

function serializeRules(rules) {
  return JSON.stringify(
    normalizeRules(rules).map(({ permissions: _permissions, ...item }) => item),
  );
}

function applyPublishedRules(rules) {
  const normalized = normalizeRules(rules);
  levelThresholds.splice(
    0,
    levelThresholds.length,
    ...normalized.map((item) => ({
      ...item,
      permissions: [...item.permissions],
    })),
  );
}

function publishedRow() {
  return one("SELECT * FROM growth_rule_sets WHERE state = 'published'");
}

function requirePublishedRow() {
  const row = publishedRow();
  if (!row) throw domainError("growth_rules_active_missing", 500);
  return row;
}

function requirePublishedSet() {
  return ruleSetJson(requirePublishedRow());
}

function draftRow() {
  return one("SELECT * FROM growth_rule_sets WHERE state = 'draft'");
}

function requireDraftRow() {
  const row = draftRow();
  if (!row) throw domainError("growth_rules_draft_missing", 404);
  return row;
}

function historyRows() {
  return all(
    `${ruleSetSelect()}
     WHERE g.state <> 'draft'
     ORDER BY g.revision DESC, g.id DESC
     LIMIT 30`,
  );
}

function ruleSetJson(row) {
  const hydrated = row.admin_nickname === undefined
    ? one(`${ruleSetSelect()} WHERE g.id = ?`, [row.id])
    : row;
  return {
    id: Number(hydrated.id),
    revision: Number(hydrated.revision),
    state: hydrated.state,
    baseRevision: Number(hydrated.base_revision || 0),
    editVersion: Number(hydrated.edit_version || 1),
    rules: parseRules(hydrated.rules_json),
    note: hydrated.note || "",
    admin: hydrated.admin_user_id
      ? {
          id: Number(hydrated.admin_user_id),
          nickname: hydrated.admin_nickname || "",
          email: hydrated.admin_email || "",
        }
      : null,
    createdAt: hydrated.created_at || "",
    updatedAt: hydrated.updated_at || "",
    publishedAt: hydrated.published_at || "",
  };
}

function ruleSetSelect() {
  return `SELECT g.*, u.nickname AS admin_nickname, u.email AS admin_email
          FROM growth_rule_sets g
          LEFT JOIN users u ON u.id = g.admin_user_id`;
}

function nextRevision() {
  return Number(
    one("SELECT COALESCE(MAX(revision), 0) + 1 AS next FROM growth_rule_sets")
      ?.next || 1,
  );
}

function ruleSnapshot(item) {
  return {
    level: Number(item.level),
    points: Number(item.points),
    name: String(item.name || ""),
    effect: String(item.effect || ""),
    dailyPointCap: Number(item.dailyPointCap),
    targetDays: Number(item.targetDays),
    permissions: [...(item.permissions || [])],
  };
}

function sameRules(left, right) {
  return serializeRules(left) === serializeRules(right);
}

function changedLevels(before, after) {
  return before.flatMap((item, index) => {
    const fields = editableRuleFields.filter(
      (field) => item[field] !== after[index][field],
    );
    return fields.length ? [{ level: item.level, fields }] : [];
  });
}

function emptyDistribution() {
  return Array.from({ length: maxLevel }, (_, index) => ({
    level: index + 1,
    users: 0,
  }));
}

function levelCaseSql(rules) {
  const clauses = [...rules]
    .reverse()
    .map((item) => `WHEN points >= ${Number(item.points)} THEN ${item.level}`)
    .join(" ");
  return `CASE ${clauses} ELSE 1 END`;
}

function requireDraftVersion(row, expectedEditVersion) {
  if (Number(row.edit_version) !== expectedEditVersion) {
    throw domainError("growth_rules_draft_revision_conflict", 409, {
      expectedEditVersion,
      currentEditVersion: Number(row.edit_version),
    });
  }
}

function expectedVersion(value, name, minimum) {
  return integer(value ?? 0, name, minimum, 1_000_000_000);
}

function integer(value, name, minimum, maximum) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw domainError(`growth_rules_${name}_invalid`);
  }
  return number;
}

function requiredText(value, name, maximum) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximum) {
    throw domainError(`growth_rules_${name}_invalid`);
  }
  return text;
}

function immediateTransaction(task) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = task();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Keep the original transaction error.
    }
    throw error;
  }
}

function domainError(code, statusCode = 400, details) {
  const error = new Error(code);
  error.statusCode = statusCode;
  if (details !== undefined) error.details = details;
  return error;
}
