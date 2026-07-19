import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-growth-rules-"));
process.env.DB_PATH = path.join(tempDir, "growth-rules.sqlite");
process.env.TOKEN_SECRET = "growth-rules-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "growth-rules-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { levelFromPoints } = await import("./growth.js");

test("growth rules use reviewed drafts, impact checks, and immutable history", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const login = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = login.token;

    const baseline = await jsonRequest(
      app,
      "GET",
      "/admin/growth/rules/workbench",
      undefined,
      token,
    );
    assert.equal(baseline.active.revision, 1);
    assert.equal(baseline.active.rules.length, 7);
    assert.equal(baseline.active.rules[1].points, 420);
    assert.equal(baseline.draft, null);
    assert.equal(baseline.stats.users, 0, "admin and system bot are excluded");
    assert.ok(
      baseline.capabilities.some(
        (item) => item.key === "chatEntranceEffect" && item.unlockLevel === 4,
      ),
    );

    const unchanged = await rawJsonRequest(
      app,
      "PUT",
      "/admin/growth/rules/draft",
      {
        rules: baseline.active.rules,
        expectedEditVersion: 0,
        note: "Attempt to create a draft without any rule changes",
      },
      token,
    );
    assert.equal(unchanged.statusCode, 400);
    assert.equal(unchanged.json().error, "growth_rules_no_changes");

    run(
      `INSERT INTO users
         (email, nickname, password_hash, status, points, sakura_coins)
       VALUES ('rule-impact@example.com', 'Rule impact', 'unused', 'active', 500, 0)`,
    );

    const invalidRules = structuredClone(baseline.active.rules);
    invalidRules[2].points = invalidRules[1].points;
    const invalid = await rawJsonRequest(
      app,
      "PUT",
      "/admin/growth/rules/draft",
      { rules: invalidRules, expectedEditVersion: 0 },
      token,
    );
    assert.equal(invalid.statusCode, 400);
    assert.equal(invalid.json().error, "growth_rules_threshold_order_invalid");

    const proposedRules = structuredClone(baseline.active.rules);
    proposedRules[1].points = 600;
    proposedRules[1].permissions = ["Untrusted client permission"];
    const drafted = await jsonRequest(
      app,
      "PUT",
      "/admin/growth/rules/draft",
      {
        rules: proposedRules,
        expectedEditVersion: 0,
        note: "Review a higher level-two threshold",
      },
      token,
    );
    assert.equal(drafted.draft.editVersion, 1);
    assert.equal(drafted.draft.baseRevision, 1);
    assert.equal(drafted.impact.levelDownUsers, 1);
    assert.equal(drafted.impact.dailyCapReducedUsers, 1);
    assert.equal(drafted.impact.totalUsers, 1);
    assert.equal(drafted.stats.users, 1);
    assert.equal(drafted.stats.averagePoints, 500);
    assert.deepEqual(
      drafted.draft.rules[1].permissions,
      baseline.active.rules[1].permissions,
      "system capabilities cannot be changed by an admin payload",
    );

    const legacyBeforePublish = await jsonRequest(
      app,
      "GET",
      "/admin/growth/rules",
      undefined,
      token,
    );
    assert.equal(legacyBeforePublish.levels[1].points, 420);
    assert.equal(levelFromPoints(500), 2);

    const staleDraft = await rawJsonRequest(
      app,
      "PUT",
      "/admin/growth/rules/draft",
      {
        rules: proposedRules,
        expectedEditVersion: 0,
        note: "Attempt a stale draft overwrite",
      },
      token,
    );
    assert.equal(staleDraft.statusCode, 409);
    assert.equal(staleDraft.json().error, "growth_rules_draft_revision_conflict");

    const unsafePublish = await rawJsonRequest(
      app,
      "POST",
      "/admin/growth/rules/draft/publish",
      {
        expectedEditVersion: 1,
        note: "Publish without reviewing the downgrade impact",
      },
      token,
    );
    assert.equal(unsafePublish.statusCode, 400);
    assert.equal(
      unsafePublish.json().error,
      "growth_rules_impact_acknowledgement_required",
    );

    const published = await jsonRequest(
      app,
      "POST",
      "/admin/growth/rules/draft/publish",
      {
        expectedEditVersion: 1,
        acknowledgeImpact: true,
        note: "Threshold impact reviewed against the current user base",
      },
      token,
    );
    assert.equal(published.active.revision, 2);
    assert.equal(published.active.rules[1].points, 600);
    assert.equal(published.draft, null);
    assert.equal(published.publishedImpact.levelDownUsers, 1);
    assert.equal(levelFromPoints(500), 1);

    const persisted = one(
      "SELECT state, note FROM growth_rule_sets WHERE revision = 2",
    );
    assert.equal(persisted.state, "published");
    assert.match(persisted.note, /impact reviewed/i);

    const currentRestore = await rawJsonRequest(
      app,
      "POST",
      "/admin/growth/rules/revisions/2/restore-draft",
      { note: "Current production version is not historical" },
      token,
    );
    assert.equal(currentRestore.statusCode, 404);
    assert.equal(currentRestore.json().error, "growth_rules_revision_not_found");

    const restored = await jsonRequest(
      app,
      "POST",
      "/admin/growth/rules/revisions/1/restore-draft",
      { note: "Prepare a reviewed rollback to the original thresholds" },
      token,
    );
    assert.equal(restored.draft.rules[1].points, 420);
    assert.equal(restored.draft.baseRevision, 2);
    assert.equal(restored.impact.levelUpUsers, 1);
    assert.equal(levelFromPoints(500), 1, "restoring only creates a draft");

    const discarded = await jsonRequest(
      app,
      "POST",
      "/admin/growth/rules/draft/discard",
      {
        expectedEditVersion: restored.draft.editVersion,
        note: "Rollback proposal was reviewed and cancelled",
      },
      token,
    );
    assert.equal(discarded.draft, null);
    assert.ok(
      discarded.history.some(
        (item) => item.state === "discarded" && item.revision === 3,
      ),
    );
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

async function jsonRequest(app, method, route, body, token = "") {
  const response = await rawJsonRequest(app, method, route, body, token);
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}

function rawJsonRequest(app, method, route, body, token = "") {
  return app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { payload: JSON.stringify(body) }),
  });
}
