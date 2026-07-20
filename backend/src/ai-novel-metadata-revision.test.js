import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-ai-metadata-revision-"));
process.env.DB_PATH = path.join(tempDir, "metadata-revision.sqlite");
process.env.TOKEN_SECRET = "ai-metadata-revision-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "ai-metadata-revision-settings-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";
process.env.SMTP_HOST = "";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { hashPassword } = await import("./security.js");
const { run } = await import("./db.js");

test("published AI novel metadata changes stay private until the revision is approved", async () => {
  const app = await buildServer();
  const uploadedFiles = [];
  try {
    run(
      `INSERT INTO users (email, nickname, password_hash, role, status)
       VALUES (?, ?, ?, 'user', 'active')`,
      ["metadata-writer@example.com", "资料作者", hashPassword("writer123")],
    );
    const admin = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const writer = await jsonRequest(app, "POST", "/auth/login", {
      email: "metadata-writer@example.com",
      password: "writer123",
    });
    const initialCover = await uploadCover(app, writer.token);
    uploadedFiles.push(fileName(initialCover.url));
    const updatedCover = await uploadCover(app, writer.token);
    uploadedFiles.push(fileName(updatedCover.url));

    const draft = await jsonRequest(
      app,
      "POST",
      "/creator/ai-novels/drafts",
      {},
      writer.token,
    );
    const saved = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: draft.item.revision,
        title: "旧标题",
        penName: "资料作者",
        category: "科幻",
        coverUrl: initialCover.url,
        description: "旧简介，仅在首发审核通过后显示。",
        serializationStatus: "ongoing",
        chapters: [{ title: "第一章 启程", content: "旧版本正文。" }],
      },
      writer.token,
    );
    const submitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: saved.item.revision },
      writer.token,
    );
    await jsonRequest(
      app,
      "POST",
      `/admin/ai-novels/${draft.item.numericId}/review`,
      { decision: "approve", expectedRevision: submitted.item.revision },
      admin.token,
    );

    const published = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    const changedDraft = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: published.item.revision,
        title: "新标题",
        penName: "资料作者",
        category: "悬疑",
        coverUrl: updatedCover.url,
        description: "新简介，必须在审核通过后才替换 App 中的旧简介。",
        serializationStatus: "completed",
        chapters: published.chapters.map((chapter) => ({
          id: chapter.id,
          publishedChapterId: chapter.publishedChapterId,
          title: chapter.title,
          content: chapter.content,
        })),
      },
      writer.token,
    );
    assert.equal(changedDraft.item.title, "旧标题");
    assert.equal(changedDraft.item.description, "旧简介，仅在首发审核通过后显示。");
    assert.equal(changedDraft.metadataRevision.status, "draft");
    assert.equal(changedDraft.metadataRevision.title, "新标题");
    assert.equal(changedDraft.metadataRevision.description, "新简介，必须在审核通过后才替换 App 中的旧简介。");

    const metadataSubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: changedDraft.item.revision },
      writer.token,
    );
    assert.equal(metadataSubmitted.metadataRevision.status, "pending");
    const publicWhilePending = await jsonRequest(app, "GET", "/ai-novels");
    assert.equal(publicWhilePending.items[0].title, "旧标题");
    assert.equal(publicWhilePending.items[0].description, "旧简介，仅在首发审核通过后显示。");
    assert.equal(publicWhilePending.items[0].serializationStatus, "ongoing");

    const pendingQueue = await jsonRequest(
      app,
      "GET",
      "/admin/ai-novel-review-queue?status=pending",
      undefined,
      admin.token,
    );
    assert.equal(pendingQueue.summary.pendingMetadataCount, 1);
    const queuedBook = pendingQueue.items[0].novels[0];
    assert.equal(queuedBook.metadataRevision.status, "pending");

    await jsonRequest(
      app,
      "POST",
      `/admin/ai-novel-metadata-revisions/${metadataSubmitted.metadataRevision.id}/review`,
      {
        decision: "reject",
        reviewNote: "简介需要说明故事背景后再提交。",
        expectedRevision: metadataSubmitted.metadataRevision.revision,
      },
      admin.token,
    );
    const rejected = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    assert.equal(rejected.item.title, "旧标题");
    assert.equal(rejected.metadataRevision.status, "rejected");
    assert.match(rejected.metadataRevision.reviewNote, /故事背景/);

    const corrected = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: rejected.item.revision,
        title: "新标题",
        penName: "资料作者",
        category: "悬疑",
        coverUrl: updatedCover.url,
        description: "新简介已补充故事背景、核心悬念和主要人物的冲突。",
        serializationStatus: "completed",
        chapters: rejected.chapters.map((chapter) => ({
          id: chapter.id,
          publishedChapterId: chapter.publishedChapterId,
          title: chapter.title,
          content: chapter.content,
        })),
      },
      writer.token,
    );
    const resubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: corrected.item.revision },
      writer.token,
    );
    const batch = await jsonRequest(
      app,
      "POST",
      "/admin/ai-novel-reviews/batch",
      {
        decision: "approve",
        items: [{
          kind: "metadata",
          id: resubmitted.metadataRevision.id,
          expectedRevision: resubmitted.metadataRevision.revision,
        }],
      },
      admin.token,
    );
    assert.deepEqual(batch.reviewed, [{ kind: "metadata", id: resubmitted.metadataRevision.id }]);

    const publicAfterApproval = await jsonRequest(app, "GET", "/ai-novels");
    assert.equal(publicAfterApproval.items[0].title, "新标题");
    assert.equal(publicAfterApproval.items[0].description, "新简介已补充故事背景、核心悬念和主要人物的冲突。");
    assert.equal(publicAfterApproval.items[0].coverUrl, updatedCover.url);
    assert.equal(publicAfterApproval.items[0].serializationStatus, "completed");
    const finalDetail = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    assert.equal(finalDetail.metadataRevision, null);
    assert.deepEqual(finalDetail.metadataReviews.map((event) => event.decision), ["approve", "reject"]);
  } finally {
    await app.close();
    for (const file of uploadedFiles) {
      fs.rmSync(
        path.join(config.rootDir, "data", "uploads", "novel-covers", file),
        { force: true },
      );
    }
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

const pngBytes = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

async function uploadCover(app, token) {
  const boundary = `----metadata-cover-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="cover.png"\r\nContent-Type: image/png\r\n\r\n`,
    ),
    pngBytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const response = await app.inject({
    method: "POST",
    url: `${config.apiPrefix}/creator/ai-novel-covers`,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": `multipart/form-data; boundary=${boundary}`,
    },
    payload,
  });
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

function fileName(url) {
  return String(url).split("/").at(-1);
}

async function jsonRequest(app, method, route, body, token = "") {
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
