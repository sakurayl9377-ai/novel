import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-moderation-"));
process.env.DB_PATH = path.join(tempDir, "moderation.sqlite");
process.env.TOKEN_SECRET = "moderation-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "moderation-settings-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("moderation workbench exposes context, counts, recovery and report actions", async () => {
  const app = await buildServer();
  try {
    const authorId = insertUser("comment-author@example.com", "评论作者");
    const reporterId = insertUser("reporter@example.com", "举报人");
    const parent = run(
      `INSERT INTO comments
         (user_id, target_type, target_id, chapter_id, content, status)
       VALUES (?, 'novel', 'book-1', 'chapter-1', '这是一条需要审核的评论', 'visible')`,
      [authorId],
    );
    const parentId = Number(parent.lastInsertRowid);
    run(
      `INSERT INTO comments
         (user_id, parent_id, target_type, target_id, chapter_id, content, status)
       VALUES (?, ?, 'novel', 'book-1', 'chapter-1', '这是回复内容', 'visible')`,
      [reporterId, parentId],
    );
    run(
      `INSERT INTO comment_target_meta
         (target_type, target_id, target_title, chapter_id, chapter_title)
       VALUES ('novel', 'book-1', '测试小说', 'chapter-1', '第一章')`,
    );
    const report = run(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason)
       VALUES (?, 'comment', ?, '包含不友善内容')`,
      [reporterId, String(parentId)],
    );
    const reportId = Number(report.lastInsertRowid);

    const admin = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = admin.token;

    const comments = await request(
      app,
      "GET",
      "/admin/comments?status=visible&targetType=novel&page=1&pageSize=1",
      undefined,
      token,
    );
    assert.equal(comments.items.length, 1);
    assert.equal(comments.total, 2);
    assert.equal(comments.statusCounts.visible, 2);
    assert.equal(
      comments.targetCounts.find((item) => item.key === "novel")?.count,
      2,
    );

    const context = await request(
      app,
      "GET",
      `/admin/comments/${parentId}/context`,
      undefined,
      token,
    );
    assert.equal(context.item.content, "这是一条需要审核的评论");
    assert.equal(context.replies.length, 1);
    assert.equal(context.reports.length, 1);
    assert.equal(context.target.title, "测试小说");
    assert.equal(context.target.chapterTitle, "第一章");

    await request(
      app,
      "PATCH",
      `/admin/comments/${parentId}/status`,
      { status: "deleted" },
      token,
    );
    assert.equal(one("SELECT status FROM comments WHERE id = ?", [parentId]).status, "deleted");
    await request(
      app,
      "PATCH",
      `/admin/comments/${parentId}/status`,
      { status: "visible" },
      token,
    );
    assert.equal(one("SELECT deleted_at FROM comments WHERE id = ?", [parentId]).deleted_at, null);

    const reports = await request(
      app,
      "GET",
      "/admin/reports?status=open&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(reports.total, 1);
    assert.equal(reports.items[0].preview.content, "这是一条需要审核的评论");
    assert.equal(reports.statusCounts.open, 1);

    await request(
      app,
      "PATCH",
      `/admin/reports/${reportId}`,
      { status: "ignored" },
      token,
    );
    const ignoredReport = one(
      "SELECT status, handled_at, handled_by FROM reports WHERE id = ?",
      [reportId],
    );
    assert.equal(ignoredReport.status, "ignored");
    assert.ok(ignoredReport.handled_at);
    assert.ok(ignoredReport.handled_by);

    await request(
      app,
      "PATCH",
      `/admin/reports/${reportId}`,
      { status: "open" },
      token,
    );
    const reopenedReport = one(
      "SELECT status, handled_at, handled_by FROM reports WHERE id = ?",
      [reportId],
    );
    assert.equal(reopenedReport.status, "open");
    assert.equal(reopenedReport.handled_at, null);
    assert.equal(reopenedReport.handled_by, null);

    await request(
      app,
      "POST",
      `/admin/reports/${reportId}/resolve-delete-target`,
      undefined,
      token,
    );
    assert.equal(one("SELECT status FROM comments WHERE id = ?", [parentId]).status, "deleted");
    assert.equal(one("SELECT status FROM reports WHERE id = ?", [reportId]).status, "resolved");
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
