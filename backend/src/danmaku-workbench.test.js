import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-danmaku-workbench-"));
process.env.DB_PATH = path.join(tempDir, "danmaku.sqlite");
process.env.TOKEN_SECRET = "danmaku-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "danmaku-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("danmaku workbench exposes filters, playback context and recovery", async () => {
  const app = await buildServer();
  try {
    const authorId = insertUser("danmaku-author@example.com", "弹幕作者");
    const reporterId = insertUser("danmaku-reporter@example.com", "举报人");
    const importUserId = insertUser("bilibili-danmaku@import.local", "B站弹幕");
    const videoId = "anime:anime-1:episode:episode-1";
    run(
      `INSERT INTO danmaku_episode_meta
         (canonical_video_id, anime_id, anime_title, episode_id, episode_title)
       VALUES (?, 'anime-1', '测试番剧', 'episode-1', '第一集 相遇')`,
      [videoId],
    );
    run(
      `INSERT INTO danmaku_video_aliases
         (alias_video_id, canonical_video_id, anime_id, episode_id, source_name)
       VALUES ('https://source.example/ep1', ?, 'anime-1', 'episode-1', '测试源')`,
      [videoId],
    );
    const selected = run(
      `INSERT INTO danmaku
         (user_id, video_id, anime_id, episode_id, time_ms, content, color, status)
       VALUES (?, ?, 'anime-1', 'episode-1', 62000, '这里的转场很自然', '#FF6699', 'visible')`,
      [authorId, videoId],
    );
    const selectedId = Number(selected.lastInsertRowid);
    run(
      `INSERT INTO danmaku
         (user_id, video_id, anime_id, episode_id, time_ms, content, status)
       VALUES (?, ?, 'anime-1', 'episode-1', 67000, '前方高能', 'visible')`,
      [importUserId, videoId],
    );
    run(
      `INSERT INTO danmaku
         (user_id, video_id, anime_id, episode_id, time_ms, content, status, deleted_at)
       VALUES (?, ?, 'anime-1', 'episode-1', 91000, '已删除弹幕', 'deleted', datetime('now'))`,
      [reporterId, videoId],
    );
    run(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason)
       VALUES (?, 'danmaku', ?, '疑似剧透')`,
      [reporterId, String(selectedId)],
    );

    const admin = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = admin.token;

    const list = await request(
      app,
      "GET",
      "/admin/danmaku?status=visible&animeId=anime-1&page=1&pageSize=1",
      undefined,
      token,
    );
    assert.equal(list.total, 2);
    assert.equal(list.items.length, 1);
    assert.equal(list.statusCounts.visible, 2);
    assert.equal(list.statusCounts.deleted, 1);
    assert.equal(list.stats.videoCount, 1);
    assert.equal(list.stats.importedCount, 1);

    const animeOptions = await request(
      app,
      "GET",
      "/admin/danmaku/anime-search?status=visible",
      undefined,
      token,
    );
    assert.equal(animeOptions.items[0].animeTitle, "测试番剧");
    assert.equal(animeOptions.items[0].danmakuCount, 2);

    const context = await request(
      app,
      "GET",
      `/admin/danmaku/${selectedId}/context`,
      undefined,
      token,
    );
    assert.equal(context.group.animeTitle, "测试番剧");
    assert.equal(context.group.episodeTitle, "第一集 相遇");
    assert.equal(context.aliases.length, 1);
    assert.equal(context.nearby.length, 1);
    assert.equal(context.nearby[0].isImported, true);
    assert.equal(context.reports.length, 1);

    await request(
      app,
      "PATCH",
      `/admin/danmaku/${selectedId}/status`,
      { status: "deleted" },
      token,
    );
    assert.equal(one("SELECT status FROM danmaku WHERE id = ?", [selectedId]).status, "deleted");
    await request(
      app,
      "PATCH",
      `/admin/danmaku/${selectedId}/status`,
      { status: "visible" },
      token,
    );
    assert.equal(one("SELECT deleted_at FROM danmaku WHERE id = ?", [selectedId]).deleted_at, null);

    const episode = await request(
      app,
      "GET",
      `/admin/danmaku/episodes/detail?videoId=${encodeURIComponent(videoId)}&status=visible&page=1&pageSize=20`,
      undefined,
      token,
    );
    assert.equal(episode.total, 2);
    assert.ok(episode.items.some((item) => item.isImported));
    assert.equal(episode.aliases[0].sourceName, "测试源");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function insertUser(email, nickname) {
  return Number(
    run(
      `INSERT INTO users (email, nickname, password_hash, role, status)
       VALUES (?, ?, ?, 'user', 'active')`,
      [email, nickname, hashPassword("writer123")],
    ).lastInsertRowid,
  );
}

async function request(app, method, route, body, token = "") {
  const response = await app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    payload: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}
