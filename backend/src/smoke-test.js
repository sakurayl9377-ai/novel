import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-backend-"));
process.env.DB_PATH = path.join(tempDir, "smoke.sqlite");
process.env.TOKEN_SECRET = "smoke-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";
process.env.ALLOW_DEV_AUTH_CODES = "true";
process.env.SMTP_HOST = "";
process.env.SMTP_USER = "";
process.env.SMTP_PASS = "";
process.env.DBZY_SYNC_ENABLED = "false";

const { buildServer } = await import("./server.js");
const { one, run } = await import("./db.js");
const {
  acquireServiceLease,
  recordSeasonSettlement,
} = await import("./growth-operations.js");
const { ensureHorseRaceRound } = await import("./horse-race.js");
const { hashPassword } = await import("./security.js");

const app = await buildServer();
await app.listen({ host: "127.0.0.1", port: 3019 });

try {
  const address = app.server.address();
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const apiPrefix = process.env.API_PREFIX || "/api";

  await request(baseUrl, "/health");
  const auth = await request(baseUrl, `${apiPrefix}/auth/login`, {
    method: "POST",
    body: {
      email: "admin@admin.local",
      password: "admin123456",
    },
  });

  const initialAdminSettings = await request(
    baseUrl,
    `${apiPrefix}/admin/settings`,
    { token: auth.token },
  );
  assert(
    initialAdminSettings.chatBot?.provider === "nvidia" &&
      initialAdminSettings.chatBot?.baseUrl ===
        "https://integrate.api.nvidia.com/v1" &&
      initialAdminSettings.chatBot?.model ===
        "google/diffusiongemma-26b-a4b-it",
    "chat bot should expose the zero-config NVIDIA DiffusionGemma preset",
  );
  assert(
    initialAdminSettings.chatBotProviderPresets?.some?.(
      (item) => item.id === "nvidia",
    ),
    "admin settings should publish chat bot provider presets",
  );

  const videoOverview = await request(
    baseUrl,
    `${apiPrefix}/admin/video/overview?pageSize=5`,
    { token: auth.token },
  );
  assert(
    videoOverview.source && videoOverview.scheduler?.enabled === false,
    "video admin overview should expose source and scheduler status",
  );
  const videoPolicy = await request(
    baseUrl,
    `${apiPrefix}/admin/video/categories/34/policy`,
    {
      method: "PATCH",
      token: auth.token,
      body: {
        mode: "scheduled",
        dailyStart: "00:00",
        dailyEnd: "06:00",
        timezone: "Asia/Hong_Kong",
        ageRestricted: true,
      },
    },
  );
  assert(
    videoPolicy.availability?.policy?.ageRestricted === true,
    "video category policy should be editable through the shared admin",
  );

  const progressBaseTime = Date.now() - 10_000;
  const deviceAInitial = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-a",
        cursor: 0,
        items: [
          {
            contentType: "novel",
            contentKey: "source-a:novel-1",
            sourceKey: "source-a",
            itemId: "novel-1",
            subItemId: "chapter-1",
            payload: { chapterIndex: 1, offset: 120 },
            metadata: { title: "Smoke Novel" },
            clientUpdatedAtMs: progressBaseTime,
          },
        ],
      },
    },
  );
  assert(deviceAInitial.cursor === 1, "first progress write should create revision 1");
  assert(deviceAInitial.items.length === 1, "first sync should return the written item");

  const deviceBInitial = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: { deviceId: "smoke-device-b", cursor: 0, items: [] },
    },
  );
  assert(
    deviceBInitial.items[0]?.payload?.chapterIndex === 1,
    "a second device should receive the first device progress",
  );

  const staleProgress = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-b",
        cursor: deviceBInitial.cursor,
        items: [
          {
            contentType: "novel",
            contentKey: "source-a:novel-1",
            sourceKey: "source-a",
            itemId: "novel-1",
            subItemId: "chapter-0",
            payload: { chapterIndex: 0 },
            clientUpdatedAtMs: progressBaseTime - 1,
          },
        ],
      },
    },
  );
  assert(staleProgress.items.length === 0, "an older write must not create a revision");

  const newerProgress = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-b",
        cursor: deviceBInitial.cursor,
        items: [
          {
            contentType: "novel",
            contentKey: "source-a:novel-1",
            sourceKey: "source-a",
            itemId: "novel-1",
            subItemId: "chapter-2",
            payload: { chapterIndex: 2, offset: 0 },
            clientUpdatedAtMs: progressBaseTime + 100,
          },
        ],
      },
    },
  );
  assert(newerProgress.cursor === 2, "a newer write should advance the revision");
  assert(
    newerProgress.items[0]?.payload?.chapterIndex === 2,
    "a newer write should replace the current progress",
  );

  const tombstoneProgress = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-a",
        cursor: newerProgress.cursor,
        items: [
          {
            contentType: "novel",
            contentKey: "source-a:novel-1",
            sourceKey: "source-a",
            itemId: "novel-1",
            clientUpdatedAtMs: progressBaseTime + 200,
            deleted: true,
          },
        ],
      },
    },
  );
  assert(tombstoneProgress.cursor === 3, "a tombstone should advance the revision");
  assert(tombstoneProgress.items[0]?.deleted === true, "a tombstone should sync");

  await request(baseUrl, `${apiPrefix}/users/me/progress/sync`, {
    method: "POST",
    token: auth.token,
    body: {
      deviceId: "smoke-device-b",
      cursor: tombstoneProgress.cursor,
      items: [
        {
          contentType: "novel",
          contentKey: "source-a:novel-1",
          sourceKey: "source-a",
          itemId: "novel-1",
          payload: { chapterIndex: 99 },
          clientUpdatedAtMs: progressBaseTime + 150,
          deleted: false,
        },
      ],
    },
  });
  const retainedTombstone = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress?cursor=0&limit=10`,
    { token: auth.token },
  );
  assert(retainedTombstone.items.length === 1, "progress identity should remain unique");
  assert(
    retainedTombstone.items[0]?.deleted === true &&
      retainedTombstone.items[0]?.revision === 3,
    "an older device must not resurrect a tombstone",
  );

  const incrementalProgress = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-a",
        cursor: tombstoneProgress.cursor,
        items: [
          {
            contentType: "manga",
            contentKey: "source-b:manga-1",
            sourceKey: "source-b",
            itemId: "manga-1",
            subItemId: "chapter-8",
            payload: { pageIndex: 5 },
            clientUpdatedAtMs: progressBaseTime + 300,
          },
        ],
      },
    },
  );
  assert(
    incrementalProgress.items.length === 1 &&
      incrementalProgress.items[0]?.contentType === "manga" &&
      incrementalProgress.cursor === 4,
    "cursor sync should return only revisions after the supplied cursor",
  );

  const tieInitial = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-m",
        cursor: incrementalProgress.cursor,
        items: [
          {
            contentType: "anime",
            contentKey: "source-c:anime-tie",
            sourceKey: "source-c",
            itemId: "anime-tie",
            subItemId: "episode-1",
            payload: { positionMs: 1000 },
            clientUpdatedAtMs: progressBaseTime + 400,
          },
        ],
      },
    },
  );
  assert(tieInitial.cursor === 5, "tie-break fixture should create revision 5");

  const tieLoser = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-a",
        cursor: tieInitial.cursor,
        items: [
          {
            contentType: "anime",
            contentKey: "source-c:anime-tie",
            sourceKey: "source-c",
            itemId: "anime-tie",
            subItemId: "episode-loser",
            payload: { positionMs: 2000 },
            clientUpdatedAtMs: progressBaseTime + 400,
          },
        ],
      },
    },
  );
  assert(
    tieLoser.cursor === 5 && tieLoser.items.length === 0,
    "same-millisecond write from lexically smaller device must lose",
  );

  const tieWinner = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress/sync`,
    {
      method: "POST",
      token: auth.token,
      body: {
        deviceId: "smoke-device-z",
        cursor: tieInitial.cursor,
        items: [
          {
            contentType: "anime",
            contentKey: "source-c:anime-tie",
            sourceKey: "source-c",
            itemId: "anime-tie",
            subItemId: "episode-winner",
            payload: { positionMs: 3000 },
            clientUpdatedAtMs: progressBaseTime + 400,
          },
        ],
      },
    },
  );
  assert(
    tieWinner.cursor === 6 &&
      tieWinner.items[0]?.subItemId === "episode-winner" &&
      tieWinner.items[0]?.deviceId === "smoke-device-z",
    "same-millisecond write from lexically larger device must win deterministically",
  );

  run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, 'user', 'active')`,
    ["progress-other@example.com", "progress-other", hashPassword("progress-password")],
  );
  const otherAuth = await request(baseUrl, `${apiPrefix}/auth/login`, {
    method: "POST",
    body: {
      email: "progress-other@example.com",
      password: "progress-password",
    },
  });
  const otherUserProgress = await request(
    baseUrl,
    `${apiPrefix}/users/me/progress?cursor=0&limit=10`,
    { token: otherAuth.token },
  );
  assert(otherUserProgress.items.length === 0, "progress must be isolated by user");

  await request(baseUrl, `${apiPrefix}/users/me/progress/sync`, {
    method: "POST",
    token: auth.token,
    expectStatus: 400,
    body: {
      deviceId: "smoke-device-a",
      cursor: 0,
      items: Array.from({ length: 201 }, (_, index) => ({
        contentType: "anime",
        contentKey: `too-many-${index}`,
        clientUpdatedAtMs: progressBaseTime,
      })),
    },
  });
  await request(baseUrl, `${apiPrefix}/users/me/progress/sync`, {
    method: "POST",
    token: auth.token,
    expectStatus: 400,
    body: {
      deviceId: "smoke-device-a",
      cursor: 0,
      items: [
        {
          contentType: "anime",
          contentKey: "oversized-progress",
          payload: { value: "x".repeat(17 * 1024) },
          clientUpdatedAtMs: progressBaseTime,
        },
      ],
    },
  });

  await request(baseUrl, `${apiPrefix}/comments`, {
    method: "POST",
    token: auth.token,
    body: {
      targetType: "novel",
      targetId: "smoke-novel",
      content: "smoke comment",
      rating: 5,
    },
  });

  const comments = await request(
    baseUrl,
    `${apiPrefix}/comments?targetType=novel&targetId=smoke-novel`,
  );
  assert(comments.items.length === 1, "comment list should contain one item");
  const commentSummary = await request(
    baseUrl,
    `${apiPrefix}/comments/summary?targetType=novel&targetId=smoke-novel`,
  );
  assert(
    commentSummary.summary.commentCount === 1,
    "comment summary should count one item",
  );
  assert(
    commentSummary.items.length === 1,
    "comment summary should include preview item",
  );
  const commentGroups = await request(
    baseUrl,
    `${apiPrefix}/admin/comments/groups`,
    { token: auth.token },
  );
  assert(
    commentGroups.items.length === 1,
    "admin comment groups should contain one group",
  );
  const commentDetail = await request(
    baseUrl,
    `${apiPrefix}/admin/comments/groups/detail?targetType=novel&targetId=smoke-novel`,
    { token: auth.token },
  );
  assert(
    commentDetail.items.length === 1,
    "admin comment group detail should contain one item",
  );

  await request(baseUrl, `${apiPrefix}/danmaku`, {
    method: "POST",
    token: auth.token,
    body: {
      videoId: "smoke-video-source-a",
      animeId: "smoke-anime",
      episodeId: "episode-1",
      timeMs: 1200,
      content: "smoke danmaku",
    },
  });
  const aliasDanmaku = await request(
    baseUrl,
    `${apiPrefix}/danmaku?videoId=smoke-video-source-b&animeId=smoke-anime&episodeId=episode-1`,
  );
  assert(
    aliasDanmaku.videoId === "anime:smoke-anime:episode:episode-1",
    "danmaku should resolve to canonical episode id",
  );
  assert(
    aliasDanmaku.items.length === 1,
    "alias danmaku should reuse canonical episode items",
  );
  const danmakuGroups = await request(
    baseUrl,
    `${apiPrefix}/admin/danmaku/groups`,
    { token: auth.token },
  );
  assert(
    danmakuGroups.items.length === 1,
    "admin danmaku groups should contain one group",
  );
  const danmakuDetail = await request(
    baseUrl,
    `${apiPrefix}/admin/danmaku/groups/detail?videoId=anime%3Asmoke-anime%3Aepisode%3Aepisode-1`,
    { token: auth.token },
  );
  assert(
    danmakuDetail.items.length === 1,
    "admin danmaku detail should contain one item",
  );
  const danmakuAnime = await request(
    baseUrl,
    `${apiPrefix}/admin/danmaku/anime-search?q=smoke-anime`,
    { token: auth.token },
  );
  assert(
    danmakuAnime.items.length === 1,
    "admin danmaku anime search should contain one anime",
  );
  const danmakuEpisodes = await request(
    baseUrl,
    `${apiPrefix}/admin/danmaku/anime/smoke-anime/episodes`,
    { token: auth.token },
  );
  assert(
    danmakuEpisodes.items.length === 1,
    "admin danmaku episode search should contain one episode",
  );
  const pagedDanmaku = await request(
    baseUrl,
    `${apiPrefix}/admin/danmaku/episodes/detail?videoId=anime%3Asmoke-anime%3Aepisode%3Aepisode-1&page=1&pageSize=1&q=smoke`,
    { token: auth.token },
  );
  assert(pagedDanmaku.total === 1, "paged danmaku total should be one");
  assert(pagedDanmaku.items.length === 1, "paged danmaku should contain item");

  await request(baseUrl, `${apiPrefix}/reports`, {
    method: "POST",
    token: auth.token,
    body: {
      targetType: "comment",
      targetId: String(comments.items[0].id),
      reason: "smoke report",
    },
  });
  const reports = await request(baseUrl, `${apiPrefix}/admin/reports`, {
    token: auth.token,
  });
  assert(reports.items.length === 1, "admin reports should contain one item");
  assert(
    reports.items[0].preview?.content === "smoke comment",
    "admin report should include target preview",
  );

  const summary = await request(baseUrl, `${apiPrefix}/admin/summary`, {
    token: auth.token,
  });
  assert(summary.comments === 1, "summary comments should be 1");
  assert(summary.danmaku === 1, "summary danmaku should be 1");
  assert(summary.reports === 1, "summary reports should be 1");

  await request(baseUrl, `${apiPrefix}/users/me/app-install`, {
    method: "POST",
    token: auth.token,
    body: {
      installId: "smoke-install-id",
      versionName: "4.0.21",
      versionCode: 36,
      platform: "android",
      osVersion: "Android 16 (SDK 36)",
      deviceModel: "Smoke Phone",
    },
  });

  const invalidUpload = await request(
    baseUrl,
    `${apiPrefix}/users/me/avatar`,
    {
      method: "POST",
      token: auth.token,
      expectStatus: 400,
      body: {
        mimeType: "image/png",
        dataBase64: Buffer.from("not-a-real-png").toString("base64"),
      },
    },
  );
  assert(invalidUpload, "upload should reject bytes that do not match the declared MIME type");
  const adminUsers = await request(
    baseUrl,
    `${apiPrefix}/admin/users?appVersionCode=36`,
    { token: auth.token },
  );
  assert(
    adminUsers.items[0]?.appInstall?.versionCode === 36,
    "admin users should expose the reported app version",
  );
  const appVersions = await request(
    baseUrl,
    `${apiPrefix}/admin/app-versions`,
    { token: auth.token },
  );
  assert(
    appVersions.recentInstalls[0]?.versionCode === 36,
    "admin app versions should expose recent install reports",
  );

  const telemetry = await request(
    baseUrl,
    `${apiPrefix}/app/telemetry/batch`,
    {
      method: "POST",
      token: auth.token,
      body: {
        installId: "smoke-install-id",
        sessionId: "smoke-session-id",
        versionName: "4.0.22",
        versionCode: 37,
        platform: "android",
        osVersion: "Android 16 (SDK 36)",
        deviceModel: "Smoke Phone",
        events: [
          { name: "app_start", occurredAt: new Date().toISOString() },
          {
            name: "screen_view",
            screen: "anime_player",
            durationMs: 4200,
            success: true,
            occurredAt: new Date().toISOString(),
          },
          {
            name: "frame_metrics",
            screen: "anime_player",
            metadata: {
              frames: 100,
              slow16: 5,
              slow32: 2,
              frozen700: 0,
              maxBuildMs: 24.5,
              maxRasterMs: 35.2,
            },
            occurredAt: new Date().toISOString(),
          },
          {
            name: "content_load",
            screen: "manga_reader",
            durationMs: 280,
            success: true,
            metadata: { contentType: "manga", chapterIndex: 1 },
            occurredAt: new Date().toISOString(),
          },
          {
            name: "video_start",
            screen: "anime_player",
            durationMs: 900,
            success: false,
            metadata: { source: "smoke-line", errorType: "TimeoutException" },
            occurredAt: new Date().toISOString(),
          },
        ],
        errors: [
          {
            type: "StateError",
            message: "smoke telemetry error",
            stack: "StateError: smoke telemetry error\\n at smoke-test.js:1",
            screen: "anime_player",
            fatal: true,
            occurredAt: new Date().toISOString(),
          },
        ],
      },
    },
  );
  assert(telemetry.acceptedEvents === 5, "telemetry should accept events");
  assert(telemetry.acceptedErrors === 1, "telemetry should accept errors");
  const analytics = await request(
    baseUrl,
    `${apiPrefix}/admin/analytics/overview?days=7`,
    { token: auth.token },
  );
  assert(analytics.summary.events === 5, "analytics should count events");
  assert(analytics.summary.fatalErrors === 1, "analytics should count fatal errors");
  assert(analytics.frameMetrics.frames === 100, "analytics should aggregate frames");
  const analyticsErrors = await request(
    baseUrl,
    `${apiPrefix}/admin/analytics/errors?days=7&q=smoke`,
    { token: auth.token },
  );
  assert(analyticsErrors.total === 1, "analytics should group errors");
  assert(
    analyticsErrors.items[0]?.message === "smoke telemetry error",
    "analytics should expose the latest error sample",
  );
  const telemetrySourceHealth = await request(
    baseUrl,
    `${apiPrefix}/admin/content/source-health`,
    { token: auth.token },
  );
  const mangaObserved = telemetrySourceHealth.items.find(
    (item) => item.sourceKey === "manga_baozi",
  );
  const animeObserved = telemetrySourceHealth.items.find(
    (item) => item.sourceKey === "anime_yinhua",
  );
  assert(
    mangaObserved?.observedTraffic?.requestCount === 1 &&
      mangaObserved?.observedTraffic?.successCount === 1,
    "real content telemetry should feed observed source health",
  );
  assert(
    animeObserved?.observedTraffic?.failureCount === 1,
    "video source failures should feed observed source health",
  );

  await request(baseUrl, `${apiPrefix}/app/content/observations`, {
    method: "POST",
    expectStatus: 401,
    body: {},
  });
  await request(baseUrl, `${apiPrefix}/app/content/observations`, {
    method: "POST",
    token: auth.token,
    expectStatus: 400,
    body: {
      installId: "smoke-observer",
      items: [
        {
          observationId: "unknown-source-1",
          contentType: "novel",
          stableKey: "unknown:novel-1",
          sourceKey: "unapproved-source",
          sourceItemId: "novel-1",
          title: "Unapproved",
        },
      ],
    },
  });
  const observedCatalog = await request(
    baseUrl,
    `${apiPrefix}/app/content/observations`,
    {
      method: "POST",
      token: auth.token,
      body: {
        installId: "smoke-observer",
        items: [
          {
            observationId: "legacy-observation-1",
            contentType: "novel",
            stableKey: "legacy:observed-novel-1",
            sourceKey: "legacy",
            sourceItemId: "observed-novel-1",
            title: "Observed Pending Novel",
            author: "Observed Author",
            coverUrl: "https://example.com/observed.jpg",
            success: true,
            latencyMs: 410,
            metadata: { category: "observed" },
          },
        ],
      },
    },
  );
  assert(
    observedCatalog.accepted === 1 && observedCatalog.pendingCatalogItems === 1,
    "approved client source observation should create a pending catalog item",
  );
  const observedReplay = await request(
    baseUrl,
    `${apiPrefix}/app/content/observations`,
    {
      method: "POST",
      token: auth.token,
      body: {
        installId: "smoke-observer",
        items: [
          {
            observationId: "legacy-observation-1",
            contentType: "novel",
            stableKey: "legacy:observed-novel-1",
            sourceKey: "legacy",
            sourceItemId: "observed-novel-1",
            title: "Observed Pending Novel",
          },
        ],
      },
    },
  );
  assert(
    observedReplay.accepted === 0 && observedReplay.replayed === 1,
    "content observation retry should be idempotent",
  );
  const pendingCatalog = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog?status=pending&q=Observed`,
    { token: auth.token },
  );
  assert(
    pendingCatalog.items[0]?.status === "pending",
    "observed catalog items must stay pending until admin approval",
  );
  const approvedObservedCatalog = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog/${encodeURIComponent("legacy:observed-novel-1")}/status`,
    {
      method: "PATCH",
      token: auth.token,
      body: { status: "active", expectedRevision: 1 },
    },
  );
  assert(
    approvedObservedCatalog.item?.status === "active" &&
      approvedObservedCatalog.item?.revision === 2,
    "admin should explicitly approve observed catalog content",
  );
  const observedHealth = await request(
    baseUrl,
    `${apiPrefix}/admin/content/source-health?type=novel&sourceKey=legacy`,
    { token: auth.token },
  );
  assert(
    observedHealth.items[0]?.observedTraffic?.requestCount === 1,
    "content observation outcome should feed observed traffic health",
  );

  await request(baseUrl, `${apiPrefix}/admin/content/catalog`, {
    method: "POST",
    expectStatus: 401,
    body: {},
  });
  const catalogCreated = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog`,
    {
      method: "POST",
      token: auth.token,
      body: {
        contentType: "novel",
        stableKey: "smoke-source:novel-ops-1",
        sourceKey: "smoke-source",
        sourceItemId: "novel-ops-1",
        title: "Smoke Operations Novel",
        author: "Smoke Author",
        coverUrl: "https://example.com/smoke.jpg",
        aliases: ["Smoke Alias"],
        metadata: { category: "smoke" },
        lastSeenAt: "2026-07-10T00:00:00.000Z",
      },
    },
  );
  assert(catalogCreated.item?.revision === 1, "catalog create should start at revision 1");
  const catalogReplay = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog`,
    {
      method: "POST",
      token: auth.token,
      body: {
        contentType: "novel",
        stableKey: "smoke-source:novel-ops-1",
        sourceKey: "smoke-source",
        sourceItemId: "novel-ops-1",
        title: "Smoke Operations Novel",
        author: "Smoke Author",
        coverUrl: "https://example.com/smoke.jpg",
        aliases: ["Smoke Alias"],
        metadata: { category: "smoke" },
        lastSeenAt: "2026-07-10T00:00:00.000Z",
      },
    },
  );
  assert(catalogReplay.idempotentReplay, "catalog upsert should be idempotent");
  const catalogAlias = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog/${encodeURIComponent("smoke-source:novel-ops-1")}/aliases`,
    {
      method: "PATCH",
      token: auth.token,
      body: { aliases: ["Smoke Alias", "Smoke Name"], expectedRevision: 1 },
    },
  );
  assert(
    catalogAlias.item?.revision === 2 && catalogAlias.item?.aliases?.length === 2,
    "catalog alias update should use optimistic revision",
  );
  const catalogSearch = await request(
    baseUrl,
    `${apiPrefix}/admin/content/catalog?q=Smoke%20Name&type=novel`,
    { token: auth.token },
  );
  assert(catalogSearch.total === 1, "catalog search should include aliases");

  const activePlacement = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements`,
    {
      method: "POST",
      token: auth.token,
      body: {
        placementType: "banner",
        position: "home-top",
        contentKey: "smoke-source:novel-ops-1",
        customTitle: "Smoke Banner",
        sortOrder: 1,
        status: "active",
        audience: { minVersionCode: 38, platforms: ["android"] },
        idempotencyKey: "smoke-placement-active",
      },
    },
  );
  assert(activePlacement.item?.revision === 1, "placement create should succeed");
  const placementReplay = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements`,
    {
      method: "POST",
      token: auth.token,
      body: {
        placementType: "banner",
        position: "home-top",
        contentKey: "smoke-source:novel-ops-1",
        status: "active",
        audience: {},
        idempotencyKey: "smoke-placement-active",
      },
    },
  );
  assert(placementReplay.idempotentReplay, "placement create should replay by idempotency key");
  const futurePlacement = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements`,
    {
      method: "POST",
      token: auth.token,
      body: {
        placementType: "recommend",
        position: "home-main",
        contentKey: "smoke-source:novel-ops-1",
        startsAt: "2099-01-01T00:00:00.000Z",
        status: "active",
        audience: {},
        idempotencyKey: "smoke-placement-future",
      },
    },
  );
  await request(baseUrl, `${apiPrefix}/admin/content/placements`, {
    method: "POST",
    token: auth.token,
    body: {
      placementType: "ranking",
      position: "home-rank",
      contentKey: "smoke-source:novel-ops-1",
      endsAt: "2020-01-01T00:00:00.000Z",
      status: "active",
      audience: {},
      idempotencyKey: "smoke-placement-expired",
    },
  });
  await request(baseUrl, `${apiPrefix}/admin/content/placements`, {
    method: "POST",
    token: auth.token,
    body: {
      placementType: "recommend",
      position: "member-home",
      contentKey: "smoke-source:novel-ops-1",
      status: "active",
      audience: { loggedIn: true, segments: ["new_users"] },
      idempotencyKey: "smoke-placement-login-only",
    },
  });

  const minimumFlag = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags`,
    {
      method: "POST",
      token: auth.token,
      body: {
        key: "app.minimum_version_code",
        value: 39,
        enabled: true,
        percentageRollout: 100,
        idempotencyKey: "smoke-flag-minimum",
      },
    },
  );
  assert(minimumFlag.item?.revision === 1, "feature flag create should succeed");
  const gatedFlag = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags`,
    {
      method: "POST",
      token: auth.token,
      body: {
        key: "smoke.player_controls",
        value: { layout: "bottom" },
        minVersionCode: 38,
        maxVersionCode: 40,
        enabled: true,
        percentageRollout: 100,
        idempotencyKey: "smoke-flag-player",
      },
    },
  );
  await request(baseUrl, `${apiPrefix}/admin/content/feature-flags`, {
    method: "POST",
    token: auth.token,
    body: {
      key: "smoke.zero_rollout",
      value: true,
      enabled: true,
      percentageRollout: 0,
      idempotencyKey: "smoke-flag-zero",
    },
  });

  const oldBootstrap = await request(
    baseUrl,
    `${apiPrefix}/app/bootstrap?versionCode=37&platform=android&installId=smoke-install`,
  );
  assert(oldBootstrap.client?.updateRequired, "bootstrap should report minimum version requirement");
  assert(!oldBootstrap.features?.["smoke.player_controls"], "bootstrap should filter flags below min version");
  assert(oldBootstrap.placements?.banner?.length === 0, "bootstrap should filter placement audience by version");
  const currentBootstrap = await request(
    baseUrl,
    `${apiPrefix}/app/bootstrap?versionCode=39&platform=android&installId=smoke-install`,
  );
  assert(currentBootstrap.features?.["smoke.player_controls"]?.layout === "bottom", "bootstrap should expose matching feature value");
  assert(currentBootstrap.features?.["smoke.zero_rollout"] === undefined, "bootstrap should exclude zero rollout flags");
  assert(currentBootstrap.placements?.banner?.length === 1, "bootstrap should include active matching placement");
  assert(currentBootstrap.placements?.recommend?.length === 0 && currentBootstrap.placements?.ranking?.length === 0, "bootstrap should enforce placement effective dates");
  assert(currentBootstrap.placements.banner[0].status === undefined, "bootstrap must not expose admin placement fields");
  const futureVersionBootstrap = await request(
    baseUrl,
    `${apiPrefix}/app/bootstrap?versionCode=41&platform=android&installId=smoke-install`,
  );
  assert(futureVersionBootstrap.features?.["smoke.player_controls"] === undefined, "bootstrap should filter flags above max version");
  const loggedInBootstrap = await request(
    baseUrl,
    `${apiPrefix}/app/bootstrap?versionCode=39&platform=android&installId=smoke-install`,
    { token: auth.token },
  );
  assert(loggedInBootstrap.placements?.recommend?.length === 1, "logged-in bootstrap should apply authenticated audience rules");
  const preview = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements/preview?versionCode=39&platform=android&installId=smoke-install`,
    { token: auth.token },
  );
  assert(preview.preview?.placementCount === 2, "admin preview should show matching diagnostics");

  const placementUpdated = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements/${activePlacement.item.id}`,
    {
      method: "PATCH",
      token: auth.token,
      body: {
        expectedRevision: 1,
        idempotencyKey: "smoke-placement-active-update",
        sortOrder: 2,
      },
    },
  );
  assert(placementUpdated.item?.revision === 2 && placementUpdated.item?.sortOrder === 2, "placement update should advance revision");
  const placementDeleted = await request(
    baseUrl,
    `${apiPrefix}/admin/content/placements/${futurePlacement.item.id}`,
    { method: "DELETE", token: auth.token },
  );
  assert(placementDeleted.deleted, "placement delete should succeed");

  const probe = await request(
    baseUrl,
    `${apiPrefix}/admin/content/source-health/record`,
    {
      method: "POST",
      token: auth.token,
      body: {
        contentType: "novel",
        sourceKey: "smoke-source",
        success: false,
        latencyMs: 321,
        error: "smoke timeout",
        idempotencyKey: "smoke-source-probe",
      },
    },
  );
  assert(
    probe.item?.requestCount === 1 &&
      probe.item?.failureCount === 1 &&
      probe.item?.manualProbe?.requestCount === 1 &&
      probe.item?.observedTraffic?.requestCount === 0,
    "source health should aggregate and classify manual probe result",
  );
  const probeReplay = await request(
    baseUrl,
    `${apiPrefix}/admin/content/source-health/record`,
    {
      method: "POST",
      token: auth.token,
      body: {
        contentType: "novel",
        sourceKey: "smoke-source",
        success: false,
        latencyMs: 321,
        error: "smoke timeout",
        idempotencyKey: "smoke-source-probe",
      },
    },
  );
  assert(probeReplay.idempotentReplay && probeReplay.item?.requestCount === 1, "source probe retry must not double count");

  const invalidation = await request(
    baseUrl,
    `${apiPrefix}/admin/content/cache-invalidations`,
    {
      method: "POST",
      token: auth.token,
      body: {
        scope: "all",
        reason: "smoke full refresh",
        idempotencyKey: "smoke-cache-all",
      },
    },
  );
  assert(invalidation.item?.revision === 1, "first invalidation should create cache revision 1");
  const invalidationReplay = await request(
    baseUrl,
    `${apiPrefix}/admin/content/cache-invalidations`,
    {
      method: "POST",
      token: auth.token,
      body: {
        scope: "all",
        reason: "ignored on replay",
        idempotencyKey: "smoke-cache-all",
      },
    },
  );
  assert(invalidationReplay.idempotentReplay && invalidationReplay.item?.revision === 1, "cache invalidation should be idempotent");
  const invalidationTwo = await request(
    baseUrl,
    `${apiPrefix}/admin/content/cache-invalidations`,
    {
      method: "POST",
      token: auth.token,
      body: {
        scope: "content",
        key: "smoke-source:novel-ops-1",
        reason: "smoke item refresh",
        idempotencyKey: "smoke-cache-content",
      },
    },
  );
  assert(invalidationTwo.item?.revision === 2, "cache revision should increase monotonically");
  const cacheBootstrap = await request(
    baseUrl,
    `${apiPrefix}/app/bootstrap?versionCode=39&platform=android&installId=smoke-install`,
  );
  assert(cacheBootstrap.cacheRevision === 2, "bootstrap should expose latest cache revision");

  const flagUpdated = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags/smoke.player_controls`,
    {
      method: "PATCH",
      token: auth.token,
      body: {
        expectedRevision: gatedFlag.item.revision,
        idempotencyKey: "smoke-flag-player-update",
        value: { layout: "compact" },
      },
    },
  );
  assert(flagUpdated.item?.revision === 2 && flagUpdated.item?.value?.layout === "compact", "feature update should create a new revision");
  const flagRollback = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags/smoke.player_controls/rollback`,
    {
      method: "POST",
      token: auth.token,
      body: {
        expectedRevision: 2,
        targetRevision: 1,
        idempotencyKey: "smoke-flag-player-rollback",
      },
    },
  );
  assert(flagRollback.item?.revision === 3 && flagRollback.item?.value?.layout === "bottom", "feature rollback should restore history as a new revision");
  const flagHistory = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags/smoke.player_controls/history`,
    { token: auth.token },
  );
  assert(flagHistory.items?.length === 3, "feature history should retain all revisions");
  const flagDeleted = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags/smoke.zero_rollout`,
    { method: "DELETE", token: auth.token },
  );
  assert(flagDeleted.deleted, "feature flag delete should succeed");
  const flagRecreated = await request(
    baseUrl,
    `${apiPrefix}/admin/content/feature-flags`,
    {
      method: "POST",
      token: auth.token,
      body: {
        key: "smoke.zero_rollout",
        value: false,
        enabled: false,
        percentageRollout: 0,
        idempotencyKey: "smoke-flag-zero-recreated",
      },
    },
  );
  assert(flagRecreated.item?.revision === 2, "deleted feature flag should be recreatable without losing history");

  const contentAudit = await request(
    baseUrl,
    `${apiPrefix}/admin/audit-logs?q=%2Fadmin%2Fcontent%2F&pageSize=100`,
    { token: auth.token },
  );
  assert(contentAudit.total >= 10, "content operation writes should be recorded in admin audit logs");

  const captcha = await request(baseUrl, `${apiPrefix}/auth/captcha`);
  assert(captcha.captchaId, "captcha id should exist");
  assert(captcha.devAnswer, "dev captcha answer should exist in smoke test");
  const emailCode = await request(baseUrl, `${apiPrefix}/auth/email-code`, {
    method: "POST",
    body: {
      email: "smoke-user@example.com",
      purpose: "register",
      captchaId: captcha.captchaId,
      captchaCode: captcha.devAnswer,
    },
  });
  assert(emailCode.retryAfter === 60, "email code retryAfter should be 60");

  const secondCaptcha = await request(baseUrl, `${apiPrefix}/auth/captcha`);
  const cooldown = await request(baseUrl, `${apiPrefix}/auth/email-code`, {
    method: "POST",
    expectStatus: 429,
    body: {
      email: "smoke-user@example.com",
      purpose: "register",
      captchaId: secondCaptcha.captchaId,
      captchaCode: secondCaptcha.devAnswer,
    },
  });
  assert(cooldown.retryAfter > 0, "cooldown retryAfter should be positive");

  run(
    "UPDATE email_verifications SET created_at = datetime('now', '-61 seconds') WHERE purpose = 'register'",
  );
  for (let index = 0; index < 5; index += 1) {
    const dailyCaptcha = await request(baseUrl, `${apiPrefix}/auth/captcha`);
    await request(baseUrl, `${apiPrefix}/auth/email-code`, {
      method: "POST",
      body: {
        email: "daily-limit@example.com",
        purpose: "register",
        captchaId: dailyCaptcha.captchaId,
        captchaCode: dailyCaptcha.devAnswer,
      },
    });
    run(
      "UPDATE email_verifications SET created_at = datetime('now', '-61 seconds') WHERE email = ?",
      ["daily-limit@example.com"],
    );
  }
  const limitedCaptcha = await request(baseUrl, `${apiPrefix}/auth/captcha`);
  const dailyLimit = await request(baseUrl, `${apiPrefix}/auth/email-code`, {
    method: "POST",
    expectStatus: 429,
    body: {
      email: "daily-limit@example.com",
      purpose: "register",
      captchaId: limitedCaptcha.captchaId,
      captchaCode: limitedCaptcha.devAnswer,
    },
  });
  assert(
    dailyLimit.error === "email_code_daily_limit",
    "sixth email code within 24 hours should hit daily limit",
  );
  assert(dailyLimit.retryAfter > 0, "daily limit retryAfter should be positive");

  const resetCaptcha = await request(baseUrl, `${apiPrefix}/auth/captcha`);
  const resetEmailCode = await request(baseUrl, `${apiPrefix}/auth/email-code`, {
    method: "POST",
    body: {
      email: "admin@admin.local",
      purpose: "reset_password",
      captchaId: resetCaptcha.captchaId,
      captchaCode: resetCaptcha.devAnswer,
    },
  });
  assert(resetEmailCode.devCode, "reset password should expose dev code");
  const resetAuth = await request(baseUrl, `${apiPrefix}/auth/reset-password`, {
    method: "POST",
    body: {
      email: "admin@admin.local",
      password: "admin654321",
      emailCode: resetEmailCode.devCode,
    },
  });
  assert(resetAuth.token, "reset password should return a new token");
  const relogin = await request(baseUrl, `${apiPrefix}/auth/login`, {
    method: "POST",
    body: {
      email: "admin@admin.local",
      password: "admin654321",
    },
  });
  assert(relogin.token, "login should accept the reset password");

  // Growth operations: behavior, recommendations, rankings, campaigns,
  // race seasons, responsible-gaming controls and multi-instance leases.
  run(
    `INSERT INTO content_catalog
     (content_type, stable_key, source_key, source_item_id, title, author, status)
     VALUES
       ('novel', 'smoke:growth-one', 'legacy', 'growth-one', 'Growth One', 'Smoke', 'active'),
       ('anime', 'smoke:growth-two', 'anime_yinhua', 'growth-two', 'Growth Two', 'Smoke', 'active'),
       ('novel', 'smoke:growth-pending', 'legacy', 'growth-pending', 'Growth Pending', 'Smoke', 'pending')`,
  );
  run(
    `INSERT INTO home_placements
     (placement_type, position, content_key, sort_order, status, audience_json, created_by)
     VALUES
       ('recommend', 'growth-smoke', 'smoke:growth-one', 99, 'active', '{}', ?),
       ('recommend', 'growth-anonymous', 'smoke:growth-two', 999, 'active', '{"loggedIn":false}', ?)`,
    [relogin.user.id, relogin.user.id],
  );
  await request(baseUrl, `${apiPrefix}/app/telemetry/batch`, {
    method: "POST",
    token: relogin.token,
    body: {
      installId: "smoke-growth-telemetry-install",
      sessionId: "smoke-growth-telemetry-session",
      versionName: "4.0.23",
      versionCode: 38,
      platform: "android",
      events: [
        {
          name: "video_start",
          success: true,
          metadata: { contentKey: "smoke:growth-two" },
        },
      ],
      errors: [],
    },
  });
  assert(
    one(
      `SELECT COUNT(*) AS total FROM content_behavior_events
       WHERE content_key = 'smoke:growth-two' AND event_name = 'start' AND source = 'telemetry'`,
    ).total === 1,
    "known telemetry content events should map into behavior aggregation",
  );

  const behaviorBase = {
    event: "exposure",
    source: "home",
    contentKey: "smoke:growth-one",
    installId: "smoke-growth-install",
    sessionId: "smoke-growth-session",
  };
  const behaviorAccepted = await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
    method: "POST",
    token: relogin.token,
    body: { ...behaviorBase, eventId: "smoke-growth-exposure-0" },
  });
  assert(behaviorAccepted.accepted, "behavior event should be accepted");
  const behaviorReplay = await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
    method: "POST",
    token: relogin.token,
    body: { ...behaviorBase, eventId: "smoke-growth-exposure-0" },
  });
  assert(behaviorReplay.idempotentReplay, "behavior eventId should be idempotent");
  const behaviorConflict = await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
    method: "POST",
    token: relogin.token,
    expectStatus: 409,
    body: {
      ...behaviorBase,
      contentKey: "smoke:growth-two",
      eventId: "smoke-growth-exposure-0",
    },
  });
  assert(
    Boolean(behaviorConflict.error || behaviorConflict.message),
    "eventId reuse with a different payload must be rejected",
  );
  for (let index = 1; index <= 24; index += 1) {
    await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
      method: "POST",
      token: relogin.token,
      body: { ...behaviorBase, eventId: `smoke-growth-exposure-${index}` },
    });
  }
  const cappedBehavior = one(
    `SELECT event_count, unique_actors FROM content_behavior_daily
     WHERE content_key = 'smoke:growth-one' AND event_name = 'exposure'`,
  );
  assert(cappedBehavior.event_count === 20, "ranking aggregate must cap repeated actor events");
  assert(cappedBehavior.unique_actors === 1, "ranking aggregate must deduplicate actors");
  const rejectedBehaviorSource = await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
    method: "POST",
    token: relogin.token,
    expectStatus: 400,
    body: { ...behaviorBase, source: "untrusted", eventId: "smoke-growth-invalid-source" },
  });
  assert(
    Boolean(rejectedBehaviorSource.error || rejectedBehaviorSource.message),
    "behavior source must use whitelist",
  );

  const recommendationsA = await request(baseUrl, `${apiPrefix}/app/recommendations?limit=20`, {
    token: relogin.token,
  });
  const recommendationsB = await request(baseUrl, `${apiPrefix}/app/recommendations?limit=20`, {
    token: relogin.token,
  });
  assert(
    recommendationsA.items[0]?.content?.stableKey === "smoke:growth-one",
    "active placement should explainably lead recommendations",
  );
  assert(
    recommendationsA.items.every((item) => item.content.stableKey !== "smoke:growth-pending"),
    "recommendations must filter pending content",
  );
  assert(
    recommendationsA.items.map((item) => item.content.stableKey).join("|") ===
      recommendationsB.items.map((item) => item.content.stableKey).join("|"),
    "recommendations must be deterministic rather than fake-random",
  );
  assert(recommendationsA.items[0].reasonCodes.includes("placement"), "recommendations should expose reasons");
  assert(
    !recommendationsA.items.find((item) => item.content.stableKey === "smoke:growth-two")?.reasonCodes.includes("placement"),
    "logged-in recommendations must honor placement audience",
  );
  const anonymousRecommendations = await request(
    baseUrl,
    `${apiPrefix}/app/recommendations?installId=smoke-anonymous&platform=android&versionCode=38`,
  );
  assert(
    anonymousRecommendations.items.find((item) => item.content.stableKey === "smoke:growth-two")?.reasonCodes.includes("placement"),
    "anonymous recommendations should include their matching placement",
  );

  await request(baseUrl, `${apiPrefix}/admin/growth/rankings/weekly_hot/smoke:growth-two`, {
    method: "PUT",
    token: relogin.token,
    body: { excluded: true, note: "smoke exclusion" },
  });
  await request(baseUrl, `${apiPrefix}/admin/growth/rankings/weekly_hot/smoke:growth-one`, {
    method: "PUT",
    token: relogin.token,
    body: { pinned: true, manualWeight: 25, note: "smoke pin" },
  });
  const ranking = await request(baseUrl, `${apiPrefix}/app/rankings?period=weekly&metric=hot`);
  assert(ranking.items[0]?.content?.stableKey === "smoke:growth-one", "ranking pin should be applied");
  assert(
    ranking.items.every((item) => item.content.stableKey !== "smoke:growth-two"),
    "ranking exclusion should be applied",
  );

  const campaign = await request(baseUrl, `${apiPrefix}/admin/growth/campaigns`, {
    method: "POST",
    token: relogin.token,
    body: {
      campaignKey: "smoke-growth-campaign",
      title: "Smoke Growth Campaign",
      status: "active",
      startsAt: new Date(Date.now() - 3600000).toISOString(),
      endsAt: new Date(Date.now() + 86400000).toISOString(),
      minVersionCode: 1,
      maxVersionCode: 999,
      audience: { loggedIn: true },
      tasks: [
        {
          taskKey: "start-one",
          title: "Start one item",
          eventName: "start",
          targetCount: 1,
          rewardPoints: 11,
          rewardCoins: 17,
        },
      ],
    },
  });
  const campaignTask = campaign.tasks[0];
  await request(baseUrl, `${apiPrefix}/app/behavior-events`, {
    method: "POST",
    token: relogin.token,
    body: {
      eventId: "smoke-growth-start-one",
      event: "start",
      source: "reader",
      contentKey: "smoke:growth-one",
      installId: "smoke-growth-install",
      sessionId: "smoke-growth-session",
    },
  });
  const activities = await request(baseUrl, `${apiPrefix}/app/activities?versionCode=38`, {
    token: relogin.token,
  });
  assert(activities.items[0]?.tasks[0]?.completed, "behavior event should advance activity task");
  const claimed = await request(
    baseUrl,
    `${apiPrefix}/app/activities/${campaign.item.id}/tasks/${campaignTask.id}/claim`,
    {
      method: "POST",
      token: relogin.token,
      body: { idempotencyKey: "smoke-growth-claim" },
    },
  );
  assert(claimed.item.awarded && claimed.item.coins === 17, "completed activity should award reward once");
  const claimedAgain = await request(
    baseUrl,
    `${apiPrefix}/app/activities/${campaign.item.id}/tasks/${campaignTask.id}/claim`,
    {
      method: "POST",
      token: relogin.token,
      body: { idempotencyKey: "smoke-growth-claim-replay" },
    },
  );
  assert(
    !claimedAgain.item.awarded && claimedAgain.item.points === 0 && claimedAgain.item.coins === 0,
    "duplicate activity claim must award zero",
  );
  await request(baseUrl, `${apiPrefix}/admin/growth/campaigns/${campaign.item.id}`, {
    method: "PATCH",
    token: relogin.token,
    body: { title: "Smoke Growth Campaign v2", status: "paused" },
  });
  const campaignRollback = await request(
    baseUrl,
    `${apiPrefix}/admin/growth/campaigns/${campaign.item.id}/rollback`,
    { method: "POST", token: relogin.token, body: { revision: 1 } },
  );
  assert(
    campaignRollback.item.title === "Smoke Growth Campaign" &&
      campaignRollback.item.status === "paused",
    "campaign rollback should restore configuration and pause it safely",
  );

  const transitionRound = run(
    `INSERT INTO horse_race_rounds
     (status, seed, round_key, horses_json, odds_json, result_json, phase_started_at)
     VALUES ('betting', 'smoke-transition', 'smoke-transition-round',
             '[{"name":"Smoke","winRate":1}]', '[1]', '{}', ?)`,
    [Date.now() - 4 * 60 * 1000 - 1000],
  );
  let transitioned = ensureHorseRaceRound();
  assert(
    transitioned.id === Number(transitionRound.lastInsertRowid) && transitioned.status === "locked",
    "lease-protected race ticker should advance betting to locked",
  );
  run(
    "UPDATE horse_race_rounds SET status = 'locked', phase_started_at = ? WHERE id = ?",
    [Date.now() - 4 * 60 * 1000 - 20 * 1000 - 1000, transitioned.id],
  );
  transitioned = ensureHorseRaceRound();
  assert(transitioned.status === "racing", "race ticker should advance locked to racing");
  run(
    "UPDATE horse_race_rounds SET status = 'racing', phase_started_at = ? WHERE id = ?",
    [Date.now() - 4 * 60 * 1000 - 20 * 1000 - 60 * 1000 - 1000, transitioned.id],
  );
  transitioned = ensureHorseRaceRound();
  assert(transitioned.status === "settling", "race ticker should settle racing rounds automatically");

  const season = await request(baseUrl, `${apiPrefix}/admin/growth/seasons`, {
    method: "POST",
    token: relogin.token,
    body: {
      seasonKey: "smoke-season",
      title: "Smoke Season",
      status: "active",
      startsAt: new Date(Date.now() - 3600000).toISOString(),
      endsAt: new Date(Date.now() + 86400000).toISOString(),
      config: { participationPoints: 10, winPoints: 20 },
      tasks: [{
        taskKey: "round-one",
        title: "One round",
        metric: "rounds",
        targetCount: 1,
        rewardPoints: 7,
        rewardCoins: 13,
      }],
      rewards: [{ rewardKey: "top-one", title: "Top one", minRank: 1, maxRank: 1, rewardCoins: 100 }],
    },
  });
  const roundResult = run(
    `INSERT INTO horse_race_rounds
     (status, seed, round_key, horses_json, result_json, phase_started_at)
     VALUES ('settling', 'smoke-growth', 'smoke-growth-round', '[]', '{}', ?)`,
    [Date.now()],
  );
  const seasonSummary = new Map([[relogin.user.id, { amount: 100, payout: 180 }]]);
  const seasonFirst = recordSeasonSettlement({
    roundId: Number(roundResult.lastInsertRowid),
    summaries: seasonSummary,
  });
  const seasonReplay = recordSeasonSettlement({
    roundId: Number(roundResult.lastInsertRowid),
    summaries: seasonSummary,
  });
  assert(seasonFirst.inserted === 1, "season settlement should insert once");
  assert(seasonReplay.inserted === 0, "season duplicate settlement must award zero points");
  const seasonState = await request(baseUrl, `${apiPrefix}/games/horse-race/season`, {
    token: relogin.token,
  });
  assert(seasonState.item.season.id === season.item.id, "active season should be visible to client");
  assert(seasonState.item.myStats.rounds === 1, "season duplicate settlement must not double rounds");
  const seasonTaskClaim = await request(
    baseUrl,
    `${apiPrefix}/games/horse-race/season/tasks/${season.tasks[0].id}/claim`,
    { method: "POST", token: relogin.token },
  );
  const seasonTaskReplay = await request(
    baseUrl,
    `${apiPrefix}/games/horse-race/season/tasks/${season.tasks[0].id}/claim`,
    { method: "POST", token: relogin.token },
  );
  assert(seasonTaskClaim.item.awarded, "completed season task should award once");
  assert(
    !seasonTaskReplay.item.awarded && seasonTaskReplay.item.coins === 0,
    "season task duplicate claim must award zero",
  );
  const seasonFinalize = await request(
    baseUrl,
    `${apiPrefix}/admin/growth/seasons/${season.item.id}/finalize`,
    { method: "POST", token: relogin.token },
  );
  const seasonFinalizeReplay = await request(
    baseUrl,
    `${apiPrefix}/admin/growth/seasons/${season.item.id}/finalize`,
    { method: "POST", token: relogin.token },
  );
  assert(seasonFinalize.awarded === 1, "season finalize should award matching leaderboard reward");
  assert(seasonFinalizeReplay.awarded === 0, "season finalize replay must award zero");

  await request(baseUrl, `${apiPrefix}/games/horse-race/responsible-gaming/cooldown`, {
    method: "POST",
    token: relogin.token,
    body: { hours: 24 },
  });
  run(
    `INSERT INTO horse_race_rounds
     (status, seed, round_key, horses_json, odds_json, result_json, phase_started_at)
     VALUES ('betting', 'smoke-cooldown', 'smoke-cooldown-round',
             '[{"name":"Smoke","winRate":1}]', '[1]', '{}', ?)`,
    [Date.now()],
  );
  run("UPDATE users SET sakura_coins = 10000 WHERE id = ?", [relogin.user.id]);
  const cooldownBet = await request(baseUrl, `${apiPrefix}/games/horse-race/bets`, {
    method: "POST",
    token: relogin.token,
    expectStatus: 400,
    body: { horseIndex: 0, amount: 1, requestId: "smoke-cooldown-bet" },
  });
  assert(Boolean(cooldownBet.error || cooldownBet.message), "active cooldown must block a bet");

  run(
    `UPDATE horse_race_responsible_settings
     SET cooldown_until = '', daily_loss_limit = 100, daily_bet_limit = 0
     WHERE user_id = ?`,
    [relogin.user.id],
  );
  const lossRound = run(
    `INSERT INTO horse_race_rounds
     (status, seed, round_key, horses_json, odds_json, result_json, phase_started_at)
     VALUES ('settling', 'smoke-loss', 'smoke-loss-round',
             '[{"name":"Smoke","winRate":1}]', '[1]', '{}', ?)`,
    [Date.now()],
  );
  run(
    `INSERT INTO horse_race_bets
     (round_id, user_id, horse_index, amount, odds, payout, status)
     VALUES (?, ?, 0, 90, 1, 0, 'lost')`,
    [Number(lossRound.lastInsertRowid), relogin.user.id],
  );
  run(
    `INSERT INTO horse_race_rounds
     (status, seed, round_key, horses_json, odds_json, result_json, phase_started_at)
     VALUES ('betting', 'smoke-loss-limit', 'smoke-loss-limit-round',
             '[{"name":"Smoke","winRate":1}]', '[1]', '{}', ?)`,
    [Date.now()],
  );
  const lossLimitBet = await request(baseUrl, `${apiPrefix}/games/horse-race/bets`, {
    method: "POST",
    token: relogin.token,
    expectStatus: 400,
    body: { horseIndex: 0, amount: 11, requestId: "smoke-loss-limit-over" },
  });
  assert(
    Boolean(lossLimitBet.error || lossLimitBet.message),
    "daily loss limit must include the new bet's worst-case loss",
  );
  const lossLimitBoundary = await request(baseUrl, `${apiPrefix}/games/horse-race/bets`, {
    method: "POST",
    token: relogin.token,
    body: { horseIndex: 0, amount: 10, requestId: "smoke-loss-limit-boundary" },
  });
  assert(lossLimitBoundary.ok, "a bet exactly reaching the daily loss limit should be allowed");

  assert(
    acquireServiceLease("smoke-lease", { ownerId: "smoke-a", leaseMs: 5000, now: 1000 }),
    "first lease owner should acquire",
  );
  assert(
    !acquireServiceLease("smoke-lease", { ownerId: "smoke-b", leaseMs: 5000, now: 2000 }),
    "second owner must not acquire a live lease",
  );
  assert(
    acquireServiceLease("smoke-lease", { ownerId: "smoke-b", leaseMs: 5000, now: 7000 }),
    "second owner should take over an expired lease",
  );

  const growthAudit = await request(
    baseUrl,
    `${apiPrefix}/admin/audit-logs?q=%2Fadmin%2Fgrowth%2F&pageSize=100`,
    { token: relogin.token },
  );
  assert(growthAudit.total >= 4, "growth admin writes should be audited");
  const growthOverview = await request(baseUrl, `${apiPrefix}/admin/growth/overview?days=7`, {
    token: relogin.token,
  });
  assert(
    growthOverview.funnel.steps.length === 6 && growthOverview.funnel.retention.length >= 1,
    "growth overview should expose funnel and retention aggregates",
  );
  const growthCampaignList = await request(
    baseUrl,
    `${apiPrefix}/admin/growth/campaigns?pageSize=20`,
    { token: relogin.token },
  );
  assert(
    growthCampaignList.items[0]?.tasks?.length === 1,
    "growth campaign list should include manageable task data",
  );

  console.log("smoke ok");
} finally {
  await app.close();
  fs.rmSync(tempDir, {
    recursive: true,
    force: true,
    maxRetries: 5,
    retryDelay: 100,
  });
}

async function request(baseUrl, pathname, options = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method: options.method || "GET",
    headers: {
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (options.expectStatus && response.status === options.expectStatus) {
    return data;
  }
  if (!response.ok) {
    throw new Error(`${pathname} failed: ${response.status} ${data.error}`);
  }
  return data;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
