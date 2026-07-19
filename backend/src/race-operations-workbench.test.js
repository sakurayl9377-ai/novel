import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-race-ops-"));
process.env.DB_PATH = path.join(tempDir, "race-ops.sqlite");
const testTokenSecret = `race-ops-token-${process.pid}-${Date.now()}`;
const testSettingsKey = `race-ops-settings-${process.pid}-${Date.now()}`;
const testAdminPassword = `race-ops-admin-${process.pid}-${Date.now()}`;
const testReaderPassword = `race-ops-reader-${process.pid}-${Date.now()}`;
process.env["TOKEN_SECRET"] = testTokenSecret;
process.env["SETTINGS_ENCRYPTION_KEY"] = testSettingsKey;
process.env.ADMIN_USERNAME = "admin";
process.env["ADMIN_PASSWORD"] = testAdminPassword;

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("race workbench protects fairness data and enforces reviewed season changes", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const adminLogin = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: testAdminPassword,
    });
    const adminToken = adminLogin.token;
    const userId = Number(run(
      `INSERT INTO users
         (email, nickname, password_hash, role, status, sakura_coins)
       VALUES (?, 'Race reader', ?, 'user', 'active', 100)`,
      ["race-reader@example.com", hashPassword(testReaderPassword)],
    ).lastInsertRowid);

    const seed = "race-ops-fixed-seed";
    const seedCommit = createHash("sha256").update(seed).digest("hex");
    const horses = [
      { name: "Sakura One", color: "#df6f91", winRate: 0.55 },
      { name: "Sakura Two", color: "#30866c", winRate: 0.45 },
    ];
    const result = { winnerIndex: 1, checkpoints: [[0, 1], [0, 1]] };
    const roundId = Number(run(
      `INSERT INTO horse_race_rounds
         (status, seed, seed_commit, round_key, rules_version, horses_json,
          odds_json, race_json, result_json, winner_index, phase_started_at)
       VALUES ('betting', ?, ?, 'race-ops-round', 2, ?, '[]', '{}', ?, 1, ?)`,
      [seed, seedCommit, JSON.stringify(horses), JSON.stringify(result), Date.now()],
    ).lastInsertRowid);
    run(
      `INSERT INTO horse_race_bets
         (round_id, user_id, horse_index, amount, odds, payout, status)
       VALUES (?, ?, 1, 10, 2, 0, 'pending')`,
      [roundId, userId],
    );

    const overview = await jsonRequest(
      app,
      "GET",
      "/admin/horse-race/workbench",
      undefined,
      adminToken,
    );
    assert.equal(overview.currentRound.id, roundId);
    assert.equal(overview.currentRound.winnerIndex, -1);
    assert.equal(overview.rules.operatorControlsResult, false);
    assert.equal(overview.responsibleGaming.policy.userControlsMutableByAdmin, false);

    const dashboardOverview = await jsonRequest(
      app,
      "GET",
      "/admin/operations/overview",
      undefined,
      adminToken,
    );
    assert.equal(dashboardOverview.race.current.id, roundId);
    assert.equal(dashboardOverview.race.current.winnerIndex, -1);

    const hiddenResult = await jsonRequest(
      app,
      "GET",
      `/admin/horse-race/rounds/${roundId}`,
      undefined,
      adminToken,
    );
    assert.deepEqual(hiddenResult.item.result, {});
    assert.equal(hiddenResult.item.winnerIndex, -1);
    assert.equal(hiddenResult.item.fairness.seedCommit, seedCommit);
    assert.equal(hiddenResult.item.fairness.seedReveal, "");
    assert.equal(hiddenResult.bets.total, 1);
    assert.throws(
      () => run("UPDATE horse_race_rounds SET seed = 'changed' WHERE id = ?", [roundId]),
      /horse_race_fairness_immutable/,
    );

    run(
      `UPDATE horse_race_rounds
       SET status = 'settling', odds_json = '[2,2]',
           locked_at = datetime('now'), settled_at = datetime('now')
       WHERE id = ?`,
      [roundId],
    );
    const inconsistent = await jsonRequest(
      app,
      "GET",
      "/admin/horse-race/rounds?integrity=error",
      undefined,
      adminToken,
    );
    assert.equal(inconsistent.total, 1);
    assert.equal(inconsistent.items[0].integrity.status, "error");
    assert.ok(inconsistent.items[0].integrity.issues.some(
      (item) => item.code === "pending_bets_after_settlement",
    ));

    run(
      "UPDATE horse_race_bets SET status = 'won', payout = 20 WHERE round_id = ?",
      [roundId],
    );
    const revealed = await jsonRequest(
      app,
      "GET",
      `/admin/horse-race/rounds/${roundId}?betStatus=won&horseIndex=1`,
      undefined,
      adminToken,
    );
    assert.equal(revealed.item.winnerIndex, 1);
    assert.equal(revealed.item.fairness.seedReveal, seed);
    assert.equal(revealed.item.fairness.revealVerified, true);
    assert.equal(revealed.item.integrity.status, "healthy");
    assert.equal(revealed.bets.total, 1);

    const startsAt = new Date(Date.now() - 60_000).toISOString();
    const endsAt = new Date(Date.now() + 7 * 86400_000).toISOString();
    const created = await jsonRequest(
      app,
      "POST",
      "/admin/horse-race/seasons",
      {
        seasonKey: "race-summer-2026",
        title: "Summer race season",
        description: "Reviewed seasonal race competition.",
        startsAt,
        endsAt,
        config: {
          participationPoints: 10,
          winPoints: 25,
          maxProfitBonus: 30,
          tiers: [
            { key: "bronze", points: 0 },
            { key: "silver", points: 300 },
            { key: "gold", points: 900 },
          ],
        },
        changeNote: "Create the reviewed race season draft",
      },
      adminToken,
    );
    assert.equal(created.item.status, "draft");
    assert.equal(created.item.revision, 1);
    const seasonId = created.item.id;

    const withTask = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/tasks`,
      {
        expectedRevision: 1,
        taskKey: "finish-three-rounds",
        title: "Finish three rounds",
        metric: "rounds",
        targetCount: 3,
        rewardPoints: 25,
        rewardCoins: 5,
        status: "active",
        sortOrder: 10,
        changeNote: "Add the reviewed participation task",
      },
      adminToken,
    );
    assert.equal(withTask.item.revision, 2);

    const duplicateTask = await rawJsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/tasks`,
      {
        expectedRevision: 2,
        taskKey: "finish-three-rounds",
        title: "Duplicate task",
        metric: "rounds",
        targetCount: 1,
        changeNote: "Verify task keys remain unique",
      },
      adminToken,
    );
    assert.equal(duplicateTask.statusCode, 409);
    assert.equal(duplicateTask.json().error, "race_season_task_key_conflict");

    const withReward = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/rewards`,
      {
        expectedRevision: 2,
        rewardKey: "champion",
        title: "Season champion",
        tier: "",
        minRank: 1,
        maxRank: 1,
        rewardPoints: 100,
        rewardCoins: 50,
        status: "active",
        changeNote: "Add the reviewed champion reward",
      },
      adminToken,
    );
    assert.equal(withReward.item.revision, 3);
    assert.equal(withReward.budget.maximumCoins, 55);
    const rewardId = withReward.rewards[0].id;

    const withoutBudgetReview = await rawJsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/status`,
      {
        status: "active",
        expectedRevision: 3,
        note: "Try activation without budget review",
      },
      adminToken,
    );
    assert.equal(withoutBudgetReview.statusCode, 400);
    assert.equal(
      withoutBudgetReview.json().error,
      "race_season_budget_acknowledgement_required",
    );

    const activated = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/status`,
      {
        status: "active",
        expectedRevision: 3,
        acknowledgeBudget: true,
        note: "Activate after reviewing schedule and reward exposure",
      },
      adminToken,
    );
    assert.equal(activated.item.status, "active");
    assert.equal(activated.item.revision, 4);

    const activeEdit = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/horse-race/seasons/${seasonId}`,
      {
        expectedRevision: 4,
        title: "Unsafe live edit",
        changeNote: "Active seasons must be paused first",
      },
      adminToken,
    );
    assert.equal(activeEdit.statusCode, 409);
    assert.equal(activeEdit.json().error, "race_season_edit_requires_pause");

    run(
      `INSERT INTO horse_race_season_user_stats
         (season_id, user_id, points, rounds, wins, total_bet, total_payout, tier)
       VALUES (?, ?, 500, 4, 2, 100, 150, 'silver')`,
      [seasonId, userId],
    );
    const paused = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/status`,
      {
        status: "paused",
        expectedRevision: 4,
        note: "Pause before reviewing season configuration",
      },
      adminToken,
    );
    assert.equal(paused.item.revision, 5);

    const changedTerms = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/horse-race/seasons/${seasonId}/rewards/${rewardId}`,
      {
        expectedRevision: 5,
        rewardCoins: 500,
        changeNote: "Reward terms cannot change after participation",
      },
      adminToken,
    );
    assert.equal(changedTerms.statusCode, 409);
    assert.equal(changedTerms.json().error, "race_season_reward_terms_locked");

    const renamedReward = await jsonRequest(
      app,
      "PATCH",
      `/admin/horse-race/seasons/${seasonId}/rewards/${rewardId}`,
      {
        expectedRevision: 5,
        title: "Season champion reward",
        changeNote: "Clarify the reward label without changing terms",
      },
      adminToken,
    );
    assert.equal(renamedReward.item.revision, 6);

    const earlyWithoutReview = await rawJsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/finalize`,
      {
        expectedRevision: 6,
        note: "Try to finalize before the scheduled end",
      },
      adminToken,
    );
    assert.equal(earlyWithoutReview.statusCode, 400);
    assert.equal(
      earlyWithoutReview.json().error,
      "race_season_early_finalize_acknowledgement_required",
    );

    const finalized = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${seasonId}/finalize`,
      {
        expectedRevision: 6,
        acknowledgeEarlyFinalize: true,
        note: "Finalize early after reviewing participant impact",
      },
      adminToken,
    );
    assert.equal(finalized.item.status, "ended");
    assert.equal(finalized.item.revision, 7);
    assert.equal(finalized.finalization.awarded, 1);
    assert.ok(finalized.events.some((event) => event.action === "finalize"));
    assert.equal(
      one("SELECT sakura_coins FROM users WHERE id = ?", [userId]).sakura_coins,
      150,
    );

    const legacyList = await jsonRequest(
      app,
      "GET",
      "/admin/growth/seasons",
      undefined,
      adminToken,
    );
    assert.equal(legacyList.items.some((item) => item.id === seasonId), true);

    const legacySeason = await jsonRequest(
      app,
      "POST",
      "/admin/growth/seasons",
      {
        seasonKey: "legacy-race-ops-season",
        title: "Legacy race operations season",
        startsAt: new Date(Date.now() - 60_000).toISOString(),
        endsAt: new Date(Date.now() + 3_600_000).toISOString(),
        config: { participationPoints: 10, winPoints: 20 },
        changeNote: "Exercise legacy season fallback",
      },
      adminToken,
    );
    assert.equal(legacySeason.item.status, "draft");
    const legacyTask = await jsonRequest(
      app,
      "POST",
      `/admin/growth/seasons/${legacySeason.item.id}/tasks`,
      {
        expectedRevision: legacySeason.item.revision,
        taskKey: "legacy-rounds",
        title: "Legacy rounds task",
        metric: "rounds",
        targetCount: 3,
        rewardCoins: 20,
        changeNote: "Exercise legacy task fallback",
      },
      adminToken,
    );
    const legacyReward = await jsonRequest(
      app,
      "POST",
      `/admin/growth/seasons/${legacySeason.item.id}/rewards`,
      {
        expectedRevision: legacyTask.item.revision,
        rewardKey: "legacy-top-three",
        title: "Legacy top three reward",
        minRank: 1,
        maxRank: 3,
        rewardCoins: 30,
        changeNote: "Exercise legacy reward fallback",
      },
      adminToken,
    );
    const legacyActive = await jsonRequest(
      app,
      "POST",
      `/admin/horse-race/seasons/${legacySeason.item.id}/status`,
      {
        status: "active",
        expectedRevision: legacyReward.item.revision,
        note: "Exercise legacy activation fallback",
        acknowledgeBudget: true,
      },
      adminToken,
    );
    const legacyEnded = await jsonRequest(
      app,
      "POST",
      `/admin/growth/seasons/${legacySeason.item.id}/finalize`,
      {
        expectedRevision: legacyActive.item.revision,
        note: "Exercise legacy finalize fallback",
        acknowledgeEarlyFinalize: true,
      },
      adminToken,
    );
    assert.equal(legacyEnded.item.status, "ended");
    assert.equal(legacyEnded.finalization.awarded, 0);

    run(
      `INSERT INTO horse_race_responsible_settings
         (user_id, cooldown_until, daily_bet_limit)
       VALUES (?, datetime('now', '+1 day'), 100)`,
      [userId],
    );
    const responsible = await jsonRequest(
      app,
      "GET",
      "/admin/horse-race/responsible-gaming",
      undefined,
      adminToken,
    );
    assert.equal(responsible.activeCooldowns, 1);
    assert.equal(responsible.customBetLimits, 1);
    assert.equal(responsible.policy.mode, "aggregate_read_only");
    assert.equal(JSON.stringify(responsible).includes("race-reader@example.com"), false);
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
