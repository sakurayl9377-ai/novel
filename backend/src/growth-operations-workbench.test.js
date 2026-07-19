import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-growth-ops-"));
process.env.DB_PATH = path.join(tempDir, "growth-ops.sqlite");
process.env.TOKEN_SECRET = "growth-ops-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "growth-ops-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { all, one, run } = await import("./db.js");
const { advanceActivityTasks } = await import("./growth-operations.js");
const { hashPassword } = await import("./security.js");

test("growth operations use reviewed ranking and campaign workflows", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const adminLogin = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const adminToken = adminLogin.token;

    run(
      `INSERT INTO content_catalog
         (content_type, stable_key, source_key, source_item_id, title, author, status)
       VALUES ('novel', 'growth:test-novel', 'test', 'growth-1',
               'Growth test novel', 'Test author', 'active')`,
    );
    const userId = Number(run(
      `INSERT INTO users
         (email, nickname, password_hash, role, status, created_at)
       VALUES (?, 'Growth reader', ?, 'user', 'active', datetime('now', '-30 days'))`,
      ["growth-reader@example.com", hashPassword("reader123456")],
    ).lastInsertRowid);
    const userLogin = await jsonRequest(app, "POST", "/auth/login", {
      email: "growth-reader@example.com",
      password: "reader123456",
    });

    const overview = await jsonRequest(
      app,
      "GET",
      "/admin/growth/workbench?days=14&contentType=novel",
      undefined,
      adminToken,
    );
    assert.equal(overview.days, 14);
    assert.equal(overview.contentType, "novel");
    assert.equal(overview.totals.activeCampaigns, 0);
    assert.ok(overview.options.audiencePresets.includes("readers"));

    const invalidRanking = await rawJsonRequest(
      app,
      "PUT",
      "/admin/growth/rankings/weekly_hot/growth%3Atest-novel",
      {
        pinned: true,
        excluded: true,
        manualWeight: 10,
        expectedRevision: 0,
        note: "Mutually exclusive controls",
      },
      adminToken,
    );
    assert.equal(invalidRanking.statusCode, 400);
    assert.equal(invalidRanking.json().error, "growth_ranking_control_conflict");

    const ranked = await jsonRequest(
      app,
      "PUT",
      "/admin/growth/rankings/weekly_hot/growth%3Atest-novel",
      {
        pinned: true,
        excluded: false,
        manualWeight: 25,
        expectedRevision: 0,
        note: "Feature the launch title for one week",
      },
      adminToken,
    );
    assert.equal(ranked.item.revision, 1);
    assert.equal(ranked.item.pinned, true);

    await jsonRequest(
      app,
      "PUT",
      "/admin/growth/rankings/all/growth%3Atest-novel",
      {
        pinned: false,
        excluded: true,
        manualWeight: -100,
        expectedRevision: 0,
        note: "Exclude globally unless a specific board overrides it",
      },
      adminToken,
    );
    const scopedRanking = await jsonRequest(
      app,
      "GET",
      "/admin/growth/rankings?period=weekly&metric=hot",
      undefined,
      adminToken,
    );
    assert.equal(scopedRanking.items.length, 1, "specific rules override global flags");
    assert.equal(scopedRanking.items[0].pinned, true);

    const staleRanking = await rawJsonRequest(
      app,
      "PUT",
      "/admin/growth/rankings/weekly_hot/growth%3Atest-novel",
      {
        pinned: false,
        expectedRevision: 0,
        note: "Attempt a stale ranking overwrite",
      },
      adminToken,
    );
    assert.equal(staleRanking.statusCode, 409);
    assert.equal(staleRanking.json().error, "growth_ranking_revision_conflict");

    const invalidUpload = await uploadMultipart(
      app,
      adminToken,
      Buffer.from("not an image"),
      "image/png",
      "invalid.png",
    );
    assert.equal(invalidUpload.statusCode, 400);
    assert.equal(invalidUpload.json().error, "campaign_banner_content_invalid");
    const firstBanner = await uploadBanner(app, adminToken, "first.png");

    const remoteBanner = await rawJsonRequest(
      app,
      "POST",
      "/admin/growth/campaigns",
      {
        campaignKey: "remote-banner",
        title: "Remote banner campaign",
        bannerUrl: "https://example.com/banner.png",
        audiencePreset: "all_registered",
        changeNote: "External artwork must never be accepted",
      },
      adminToken,
    );
    assert.equal(remoteBanner.statusCode, 400);
    assert.equal(remoteBanner.json().error, "campaign_banner_upload_required");

    const startsAt = new Date(Date.now() - 60_000).toISOString();
    const endsAt = new Date(Date.now() + 7 * 86400_000).toISOString();
    const created = await jsonRequest(
      app,
      "POST",
      "/admin/growth/campaigns",
      {
        campaignKey: "summer-reading-2026",
        title: "Summer reading week",
        description: "Complete a reading start task to receive a reward.",
        bannerUrl: `https://untrusted.example${firstBanner.url}`,
        startsAt,
        endsAt,
        audiencePreset: "all_registered",
        minVersionCode: 100,
        maxVersionCode: 0,
        changeNote: "Create a reviewed campaign draft",
      },
      adminToken,
    );
    assert.equal(created.item.status, "draft");
    assert.equal(created.item.bannerUrl, firstBanner.url);
    assert.equal(created.item.revision, 1);
    assert.equal(created.budget.eligibleUsers, 1);

    const duplicateCampaign = await rawJsonRequest(
      app,
      "POST",
      "/admin/growth/campaigns",
      {
        campaignKey: "summer-reading-2026",
        title: "Duplicate campaign key",
        bannerUrl: firstBanner.url,
        audiencePreset: "all_registered",
        changeNote: "Verify campaign keys cannot be reused",
      },
      adminToken,
    );
    assert.equal(duplicateCampaign.statusCode, 409);
    assert.equal(duplicateCampaign.json().error, "growth_campaign_key_conflict");

    const campaignId = created.item.id;
    const withTask = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/tasks`,
      {
        expectedRevision: created.item.revision,
        taskKey: "start-reading",
        title: "Start reading twice",
        description: "Open a supported title and start reading twice.",
        eventName: "start",
        targetCount: 2,
        rewardPoints: 30,
        rewardCoins: 8,
        contentType: "novel",
        contentKey: "growth:test-novel",
        sortOrder: 10,
        status: "active",
        changeNote: "Add the reviewed reading task",
      },
      adminToken,
    );
    assert.equal(withTask.item.revision, 2);
    assert.equal(withTask.tasks.length, 1);
    assert.equal(withTask.budget.potentialCoins, 8);
    const taskId = withTask.tasks[0].id;

    const duplicateTask = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/tasks`,
      {
        expectedRevision: withTask.item.revision,
        taskKey: "start-reading",
        title: "Duplicate task key",
        eventName: "start",
        targetCount: 1,
        rewardPoints: 1,
        rewardCoins: 1,
        status: "active",
        changeNote: "Verify task keys stay unique within a campaign",
      },
      adminToken,
    );
    assert.equal(duplicateTask.statusCode, 409);
    assert.equal(duplicateTask.json().error, "growth_campaign_task_key_conflict");

    const unacknowledged = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/status`,
      {
        status: "active",
        expectedRevision: withTask.item.revision,
        note: "Activate without reviewing the reward budget",
      },
      adminToken,
    );
    assert.equal(unacknowledged.statusCode, 400);
    assert.equal(
      unacknowledged.json().error,
      "growth_campaign_budget_acknowledgement_required",
    );

    const activated = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/status`,
      {
        status: "active",
        expectedRevision: withTask.item.revision,
        acknowledgeBudget: true,
        note: "Reward exposure and schedule have been reviewed",
      },
      adminToken,
    );
    assert.equal(activated.item.status, "active");
    assert.equal(activated.item.revision, 3);

    const editWhileActive = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/growth/campaigns/${campaignId}`,
      {
        expectedRevision: activated.item.revision,
        title: "Unsafe live edit",
        changeNote: "Active campaigns must be paused first",
      },
      adminToken,
    );
    assert.equal(editWhileActive.statusCode, 409);
    assert.equal(editWhileActive.json().error, "growth_campaign_edit_requires_pause");

    const hiddenForOldVersion = await jsonRequest(
      app,
      "GET",
      "/app/activities?versionCode=50",
      undefined,
      userLogin.token,
    );
    assert.equal(hiddenForOldVersion.items.length, 0);
    const visibleForSupportedVersion = await jsonRequest(
      app,
      "GET",
      "/app/activities?versionCode=100",
      undefined,
      userLogin.token,
    );
    assert.equal(visibleForSupportedVersion.items.length, 1);

    assert.equal(advanceActivityTasks({
      userId,
      eventName: "start",
      context: { contentType: "novel", contentKey: "growth:test-novel", versionCode: 100 },
    }), 1);
    assert.equal(advanceActivityTasks({
      userId,
      eventName: "start",
      context: { contentType: "novel", contentKey: "growth:test-novel", versionCode: 100 },
    }), 1);

    const unsupportedClaim = await rawJsonRequest(
      app,
      "POST",
      `/app/activities/${campaignId}/tasks/${taskId}/claim`,
      { versionCode: 50, idempotencyKey: "unsupported-client" },
      userLogin.token,
    );
    assert.equal(unsupportedClaim.statusCode, 400);
    assert.equal(unsupportedClaim.json().error, "campaign is not available for this user");

    const claimed = await jsonRequest(
      app,
      "POST",
      `/app/activities/${campaignId}/tasks/${taskId}/claim`,
      { versionCode: 100, idempotencyKey: "supported-client" },
      userLogin.token,
    );
    assert.equal(claimed.item.awarded, true);
    assert.equal(claimed.item.points, 30);
    assert.equal(claimed.item.coins, 8);

    const paused = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/status`,
      {
        status: "paused",
        expectedRevision: activated.item.revision,
        note: "Pause the campaign before maintenance",
      },
      adminToken,
    );
    assert.equal(paused.item.revision, 4);

    const rewardChange = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/growth/campaigns/${campaignId}/tasks/${taskId}`,
      {
        expectedRevision: paused.item.revision,
        rewardCoins: 99,
        changeNote: "Claimed rewards cannot be changed retroactively",
      },
      adminToken,
    );
    assert.equal(rewardChange.statusCode, 409);
    assert.equal(rewardChange.json().error, "growth_campaign_task_reward_locked");

    const targetChange = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/growth/campaigns/${campaignId}/tasks/${taskId}`,
      {
        expectedRevision: paused.item.revision,
        targetCount: 10,
        changeNote: "Progress-bearing task identity is immutable",
      },
      adminToken,
    );
    assert.equal(targetChange.statusCode, 409);
    assert.equal(targetChange.json().error, "growth_campaign_task_progress_locked");

    const renamedTask = await jsonRequest(
      app,
      "PATCH",
      `/admin/growth/campaigns/${campaignId}/tasks/${taskId}`,
      {
        expectedRevision: paused.item.revision,
        title: "Start reading twice - clarified",
        changeNote: "Clarify the task label without changing its terms",
      },
      adminToken,
    );
    assert.equal(renamedTask.item.revision, 5);

    const secondBanner = await uploadBanner(app, adminToken, "second.png");
    const refreshed = await jsonRequest(
      app,
      "PATCH",
      `/admin/growth/campaigns/${campaignId}`,
      {
        expectedRevision: renamedTask.item.revision,
        bannerUrl: secondBanner.url,
        changeNote: "Refresh paused campaign artwork",
      },
      adminToken,
    );
    assert.equal(refreshed.item.revision, 6);
    assert.equal(refreshed.item.bannerUrl, secondBanner.url);

    const restored = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaignId}/rollback`,
      {
        revision: 4,
        expectedRevision: refreshed.item.revision,
        note: "Restore the reviewed pre-artwork revision as paused",
      },
      adminToken,
    );
    assert.equal(restored.item.status, "paused");
    assert.equal(restored.item.revision, 7);
    assert.equal(restored.item.bannerUrl, firstBanner.url);
    assert.equal(restored.restoredFromRevision, 4);
    assert.ok(restored.events.some((event) => event.action === "restore_revision"));

    const ended = await jsonRequest(
      app,
      "DELETE",
      `/admin/growth/campaigns/${campaignId}`,
      {
        expectedRevision: restored.item.revision,
        note: "End the campaign while preserving all reward history",
      },
      adminToken,
    );
    assert.equal(ended.item.status, "ended");
    assert.equal(one("SELECT COUNT(*) AS total FROM reward_claims WHERE campaign_id = ?", [campaignId]).total, 1);
    assert.ok(all("SELECT * FROM campaign_revisions WHERE campaign_id = ?", [campaignId]).length >= 7);
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

const pngBytes = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

async function uploadBanner(app, token, fileName) {
  const response = await uploadMultipart(app, token, pngBytes, "image/png", fileName);
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

function uploadMultipart(app, token, bytes, mimeType, fileName) {
  const boundary = `----campaign-banner-${Date.now()}-${Math.random()}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: ${mimeType}\r\n\r\n`,
    ),
    bytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  return app.inject({
    method: "POST",
    url: `${config.apiPrefix}/admin/growth/campaign-banners`,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": `multipart/form-data; boundary=${boundary}`,
    },
    payload,
  });
}

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
