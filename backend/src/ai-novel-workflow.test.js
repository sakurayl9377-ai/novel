import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-ai-workflow-"));
process.env.DB_PATH = path.join(tempDir, "workflow.sqlite");
process.env.TOKEN_SECRET = "ai-workflow-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "ai-workflow-settings-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";
process.env.SMTP_HOST = "";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("AI novel V2 supports upload, draft, review, revision and resubmission", async () => {
  const app = await buildServer();
  const uploadedFiles = [];
  try {
    run(
      `INSERT INTO users (email, nickname, password_hash, role, status)
       VALUES (?, ?, ?, 'user', 'active')`,
      ["workflow-writer@example.com", "流程作者", hashPassword("writer123")],
    );
    const admin = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const writer = await jsonRequest(app, "POST", "/auth/login", {
      email: "workflow-writer@example.com",
      password: "writer123",
    });

    const draft = await jsonRequest(
      app,
      "POST",
      "/creator/ai-novels/drafts",
      {},
      writer.token,
    );
    assert.equal(draft.item.status, "draft");
    assert.equal(draft.item.revision, 1);

    const externalCover = await rawJsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: 1,
        coverUrl: "https://example.com/remote-cover.jpg",
        chapters: [],
      },
      writer.token,
    );
    assert.equal(externalCover.statusCode, 400);
    assert.equal(externalCover.json().error, "novel_cover_upload_required");

    const disguisedImage = await uploadMultipart(
      app,
      writer.token,
      Buffer.from("not a real png"),
      "image/png",
      "fake.png",
    );
    assert.equal(disguisedImage.statusCode, 400);
    assert.equal(disguisedImage.json().error, "novel_cover_content_invalid");

    const cover = await uploadCover(app, writer.token);
    assert.match(cover.url, /\/uploads\/content\/novel-covers\/\d+-[a-z0-9-]+\.png$/);
    uploadedFiles.push(path.basename(cover.url));

    const saved = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: 1,
        title: "月港协议",
        penName: "星海",
        category: "科幻",
        coverUrl: `https://untrusted.example${cover.url}`,
        description: "一支返航舰队在月港发现了被隐藏的旧协议。",
        chapters: [
          { title: "第一章 靠港", content: "舰队在静默中靠近月港。" },
          { title: "第二章 协议", content: "旧协议开始自行解密。" },
        ],
      },
      writer.token,
    );
    assert.equal(saved.item.revision, 2);
    assert.equal(saved.item.coverUrl, cover.url, "stored cover URL must be canonicalized");
    assert.equal(saved.chapters.length, 2);
    assert.equal(saved.chapters[0].content, "舰队在静默中靠近月港。");

    const stale = await rawJsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      { expectedRevision: 1, chapters: saved.chapters },
      writer.token,
    );
    assert.equal(stale.statusCode, 409);
    assert.equal(stale.json().error, "revision_conflict");

    const submitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: 2 },
      writer.token,
    );
    assert.equal(submitted.item.status, "pending");
    assert.equal(submitted.item.revision, 3);
    assert.ok(submitted.chapters.every((chapter) => chapter.status === "pending"));

    const initialChapterQueue = await jsonRequest(
      app,
      "GET",
      "/admin/ai-novel-chapters?status=pending",
      undefined,
      admin.token,
    );
    assert.equal(
      initialChapterQueue.total,
      0,
      "initial submission chapters must stay in whole-novel review",
    );

    const reviewDetail = await jsonRequest(
      app,
      "GET",
      `/admin/ai-novels/${draft.item.numericId}`,
      undefined,
      admin.token,
    );
    assert.equal(reviewDetail.chapters[1].content, "旧协议开始自行解密。");

    const rejected = await jsonRequest(
      app,
      "POST",
      `/admin/ai-novels/${draft.item.numericId}/review`,
      {
        decision: "reject",
        reviewNote: "第二章需要补充协议触发原因。",
        expectedRevision: 3,
      },
      admin.token,
    );
    assert.equal(rejected.item.status, "rejected");
    assert.equal(rejected.item.revision, 4);

    const revised = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: 4,
        title: "月港协议",
        penName: "星海",
        category: "科幻",
        coverUrl: cover.url,
        description: "一支返航舰队在月港发现了被隐藏的旧协议。",
        chapters: [
          { title: "第一章 靠港", content: "舰队在静默中靠近月港。" },
          {
            title: "第二章 协议",
            content: "舰长的生物密钥触发旧协议，密文开始自行解密。",
          },
        ],
      },
      writer.token,
    );
    assert.equal(revised.item.status, "draft");
    assert.equal(revised.item.revision, 5);
    assert.equal(revised.reviews.length, 1);
    assert.equal(revised.reviews[0].decision, "reject");

    const resubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: 5 },
      writer.token,
    );
    assert.equal(resubmitted.item.revision, 6);

    const approved = await jsonRequest(
      app,
      "POST",
      `/admin/ai-novels/${draft.item.numericId}/review`,
      { decision: "approve", expectedRevision: 6 },
      admin.token,
    );
    assert.equal(approved.item.status, "published");
    assert.equal(approved.item.revision, 7);

    const publicList = await jsonRequest(app, "GET", "/ai-novels");
    assert.equal(publicList.total, 1);
    const publicChapters = await jsonRequest(
      app,
      "GET",
      `/ai-novels/${draft.item.numericId}/chapters`,
    );
    assert.equal(publicChapters.items.length, 2);
    const publicChapter = await jsonRequest(
      app,
      "GET",
      `/ai-novels/${draft.item.numericId}/chapters/${publicChapters.items[1].id}`,
    );
    assert.match(publicChapter.item.content, /生物密钥/);

    const publishedDetail = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    const publishedOriginals = publishedDetail.chapters.filter(
      (chapter) => chapter.status === "published" && chapter.replacesChapterId == null,
    );
    assert.equal(publishedOriginals.length, 2);
    assert.ok(publishedOriginals.every((chapter) => chapter.changeType === "published"));
    const secondPublishedChapter = publishedOriginals[1];

    const revisionDraft = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: publishedDetail.item.revision,
        serializationStatus: "completed",
        chapters: publishedOriginals.map((chapter) => ({
          id: chapter.id,
          publishedChapterId: chapter.id,
          title: chapter.title,
          content: chapter.id === secondPublishedChapter.id
            ? "舰长修订了生物密钥的触发规则，旧协议重新开始解密。"
            : chapter.content,
        })),
      },
      writer.token,
    );
    assert.equal(revisionDraft.item.serializationStatus, "completed");
    const revisionProposal = revisionDraft.chapters.find(
      (chapter) => chapter.replacesChapterId === secondPublishedChapter.id,
    );
    assert.equal(revisionProposal?.status, "draft");
    assert.equal(revisionProposal?.changeType, "update");

    const revisionSubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: revisionDraft.item.revision },
      writer.token,
    );
    const pendingRevision = revisionSubmitted.chapters.find(
      (chapter) => chapter.replacesChapterId === secondPublishedChapter.id,
    );
    assert.equal(pendingRevision?.status, "pending");

    const publicDuringRevision = await jsonRequest(
      app,
      "GET",
      `/ai-novels/${draft.item.numericId}/chapters/${secondPublishedChapter.id}`,
    );
    assert.match(publicDuringRevision.item.content, /生物密钥/);
    assert.doesNotMatch(publicDuringRevision.item.content, /修订了/);

    const revisionQueue = await jsonRequest(
      app,
      "GET",
      "/admin/ai-novel-chapters?status=pending",
      undefined,
      admin.token,
    );
    assert.equal(revisionQueue.total, 1);
    assert.equal(revisionQueue.items[0].changeType, "update");
    const revisionReviewDetail = await jsonRequest(
      app,
      "GET",
      `/admin/ai-novel-chapters/${revisionQueue.items[0].id}`,
      undefined,
      admin.token,
    );
    assert.match(revisionReviewDetail.item.originalContent, /生物密钥/);
    assert.match(revisionReviewDetail.item.content, /修订了/);

    await jsonRequest(
      app,
      "POST",
      `/admin/ai-novel-chapters/${revisionQueue.items[0].id}/review`,
      {
        decision: "reject",
        reviewNote: "触发规则还需交代来源。",
        expectedRevision: revisionQueue.items[0].revision,
      },
      admin.token,
    );
    const publicAfterRevisionRejection = await jsonRequest(
      app,
      "GET",
      `/ai-novels/${draft.item.numericId}/chapters/${secondPublishedChapter.id}`,
    );
    assert.doesNotMatch(publicAfterRevisionRejection.item.content, /修订了/);

    const rejectedRevisionDetail = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    const rejectedRevision = rejectedRevisionDetail.chapters.find(
      (chapter) => chapter.replacesChapterId === secondPublishedChapter.id,
    );
    const revisedAgain = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: rejectedRevisionDetail.item.revision,
        serializationStatus: "completed",
        chapters: publishedOriginals.map((chapter) => ({
          id: chapter.id === secondPublishedChapter.id ? rejectedRevision.id : chapter.id,
          publishedChapterId: chapter.id,
          title: chapter.title,
          content: chapter.id === secondPublishedChapter.id
            ? "舰长从航行日志找到生物密钥来源，触发旧协议并完成解密。"
            : chapter.content,
        })),
      },
      writer.token,
    );
    const revisedProposal = revisedAgain.chapters.find(
      (chapter) => chapter.replacesChapterId === secondPublishedChapter.id,
    );
    assert.equal(revisedProposal.id, rejectedRevision.id);
    assert.equal(revisedProposal.status, "draft");

    const revisedAgainSubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: revisedAgain.item.revision },
      writer.token,
    );
    const resubmittedRevision = revisedAgainSubmitted.chapters.find(
      (chapter) => chapter.replacesChapterId === secondPublishedChapter.id,
    );
    await jsonRequest(
      app,
      "POST",
      `/admin/ai-novel-chapters/${resubmittedRevision.id}/review`,
      {
        decision: "approve",
        expectedRevision: resubmittedRevision.revision,
      },
      admin.token,
    );

    const publicAfterRevisionApproval = await jsonRequest(
      app,
      "GET",
      `/ai-novels/${draft.item.numericId}/chapters/${secondPublishedChapter.id}`,
    );
    assert.match(publicAfterRevisionApproval.item.content, /航行日志/);
    const publicAfterCompletion = await jsonRequest(app, "GET", "/ai-novels");
    assert.equal(publicAfterCompletion.items[0].serializationStatus, "completed");
    assert.equal(publicAfterCompletion.items[0].status, "已完结");

    const afterRevisionApproval = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    assert.equal(afterRevisionApproval.chapters.length, 2);
    assert.ok(afterRevisionApproval.chapters.every(
      (chapter) => chapter.status === "published" && chapter.replacesChapterId == null,
    ));

    const approvedRevisionQueue = await jsonRequest(
      app,
      "GET",
      "/admin/ai-novel-chapters?status=published",
      undefined,
      admin.token,
    );
    assert.equal(approvedRevisionQueue.total, 1);
    assert.equal(approvedRevisionQueue.items[0].changeType, "update");
    const approvedRevisionDetail = await jsonRequest(
      app,
      "GET",
      `/admin/ai-novel-chapters/${approvedRevisionQueue.items[0].id}`,
      undefined,
      admin.token,
    );
    assert.deepEqual(
      approvedRevisionDetail.reviews.map((event) => event.decision),
      ["approve", "reject"],
    );

    const coverResponse = await app.inject({
      method: "GET",
      url: cover.url,
    });
    assert.equal(coverResponse.statusCode, 200);
    assert.equal(coverResponse.headers["content-type"], "image/png");
    assert.deepEqual(coverResponse.rawPayload.subarray(0, 8), pngBytes.subarray(0, 8));

    const serialDraft = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: afterRevisionApproval.item.revision,
        chapters: [{ title: "第三章 回声", content: "深空回声指向失联的前哨站。" }],
      },
      writer.token,
    );
    assert.equal(serialDraft.item.revision, afterRevisionApproval.item.revision + 1);
    const serialSubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: serialDraft.item.revision },
      writer.token,
    );
    assert.equal(serialSubmitted.item.status, "published");
    assert.equal(serialSubmitted.item.revision, serialDraft.item.revision + 1);

    const serialQueue = await jsonRequest(
      app,
      "GET",
      "/admin/ai-novel-chapters?status=pending",
      undefined,
      admin.token,
    );
    assert.equal(serialQueue.total, 1);
    const pendingSerial = serialQueue.items[0];
    const serialReviewDetail = await jsonRequest(
      app,
      "GET",
      `/admin/ai-novel-chapters/${pendingSerial.id}`,
      undefined,
      admin.token,
    );
    assert.match(serialReviewDetail.item.content, /前哨站/);

    const futureDraft = await jsonRequest(
      app,
      "PUT",
      `/creator/ai-novels/${draft.item.numericId}/draft`,
      {
        expectedRevision: serialSubmitted.item.revision,
        chapters: [{ title: "第四章 前哨", content: "舰队抵达沉默的前哨站。" }],
      },
      writer.token,
    );
    const overlappingSubmit = await rawJsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: futureDraft.item.revision },
      writer.token,
    );
    assert.equal(overlappingSubmit.statusCode, 409);
    assert.equal(overlappingSubmit.json().error, "serial_chapter_review_in_progress");

    await jsonRequest(
      app,
      "POST",
      `/admin/ai-novel-chapters/${pendingSerial.id}/review`,
      { decision: "approve", expectedRevision: pendingSerial.revision },
      admin.token,
    );
    const afterSerialReview = await jsonRequest(
      app,
      "GET",
      `/creator/ai-novels/${draft.item.numericId}`,
      undefined,
      writer.token,
    );
    const fourthSubmitted = await jsonRequest(
      app,
      "POST",
      `/creator/ai-novels/${draft.item.numericId}/submit`,
      { expectedRevision: afterSerialReview.item.revision },
      writer.token,
    );
    assert.equal(
      fourthSubmitted.chapters.filter((chapter) => chapter.status === "pending").length,
      1,
    );
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
  const response = await uploadMultipart(app, token, pngBytes, "image/png", "cover.png");
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

function uploadMultipart(app, token, bytes, mimeType, fileName) {
  const boundary = `----novel-cover-${Date.now()}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: ${mimeType}\r\n\r\n`,
    ),
    bytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  return app.inject({
    method: "POST",
    url: `${config.apiPrefix}/creator/ai-novel-covers`,
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
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    payload: body === undefined ? undefined : JSON.stringify(body),
  });
}
