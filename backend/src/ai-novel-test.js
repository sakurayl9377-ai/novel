import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-ai-test-"));
process.env.DB_PATH = path.join(tempDir, "ai-novel.sqlite");
process.env.TOKEN_SECRET = "ai-novel-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";
process.env.SMTP_HOST = "";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

const app = await buildServer();
const api = config.apiPrefix;

try {
  run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, 'user', 'active')`,
    ["writer@example.com", "测试作者", hashPassword("writer123")],
  );

  const admin = await request("POST", `${api}/auth/login`, {
    email: "admin@admin.local",
    password: "admin123456",
  });
  const writer = await request("POST", `${api}/auth/login`, {
    email: "writer@example.com",
    password: "writer123",
  });

  const submission = await request(
    "POST",
    `${api}/creator/ai-novels`,
    {
      title: "星海测试录",
      penName: "星河",
      category: "科幻",
      description: "用于验证投稿、审核、发布和连载的自动化测试作品。",
      content: "第一章 起航\n飞船驶离港口。\n\n第二章 深空\n众人进入深空。",
    },
    writer.token,
  );
  assert(submission.item.status === "pending", "writer submission must be pending");
  assert(submission.item.chapterCount === 2, "initial upload must split two chapters");

  const beforeReview = await request("GET", `${api}/ai-novels`);
  assert(beforeReview.items.length === 0, "pending novel must not be public");

  const queue = await request(
    "GET",
    `${api}/admin/ai-novels?status=pending`,
    undefined,
    admin.token,
  );
  assert(queue.items.length === 1, "admin must see pending novel");
  await request(
    "POST",
    `${api}/admin/ai-novels/${submission.item.numericId}/review`,
    { decision: "approve" },
    admin.token,
  );

  const published = await request("GET", `${api}/ai-novels`);
  assert(published.items.length === 1, "approved novel must become public");
  const initialChapters = await request(
    "GET",
    `${api}/ai-novels/${submission.item.numericId}/chapters`,
  );
  assert(initialChapters.items.length === 2, "approved initial chapters must be public");

  await request(
    "POST",
    `${api}/creator/ai-novels/${submission.item.numericId}/chapters`,
    { content: "第三章 新世界\n他们发现新世界。\n\n第四章 归航\n舰队踏上归途。" },
    writer.token,
  );
  const beforeChapterReview = await request(
    "GET",
    `${api}/ai-novels/${submission.item.numericId}/chapters`,
  );
  assert(beforeChapterReview.items.length === 2, "pending serial chapters must stay hidden");

  const reviewQueue = await request(
    "GET",
    `${api}/admin/ai-novel-review-queue?status=pending`,
    undefined,
    admin.token,
  );
  const queuedNovel = reviewQueue.items
    .flatMap((author) => author.novels)
    .find((novel) => novel.numericId === submission.item.numericId);
  assert(queuedNovel, "admin review queue must include the pending serial novel");
  assert(queuedNovel.chapterBatches.length === 1, "serial upload must create one review batch");
  const queuedBatch = queuedNovel.chapterBatches[0];
  assert(
    queuedBatch.chapters.length === 2,
    "submission batch must contain both pending serial chapters",
  );
  const submissionBatchId = queuedBatch.id;
  const submissionBatch = await request(
    "GET",
    `${api}/admin/ai-novel-chapter-submission-batches/${submissionBatchId}`,
    undefined,
    admin.token,
  );
  assert(submissionBatch.item.revision === queuedBatch.revision, "batch revision must match review queue");
  assert(submissionBatch.chapters.length === 2, "submission batch must contain both serial chapters");
  await request(
    "POST",
    `${api}/admin/ai-novel-chapter-submission-batches/${submissionBatchId}/review`,
    { decision: "approve", expectedRevision: submissionBatch.item.revision },
    admin.token,
  );

  const finalChapters = await request(
    "GET",
    `${api}/ai-novels/${submission.item.numericId}/chapters`,
  );
  assert(finalChapters.items.length === 4, "approved serial chapters must append publicly");
  const chapterContent = await request(
    "GET",
    `${api}/ai-novels/${submission.item.numericId}/chapters/${finalChapters.items[3].id}`,
  );
  assert(chapterContent.item.content.includes("舰队踏上归途"), "chapter content must be readable");

  console.log("AI novel submission and serialization test passed");
} finally {
  await app.close();
  fs.rmSync(tempDir, { recursive: true, force: true });
}

async function request(method, url, body, token = "") {
  const response = await app.inject({
    method,
    url,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
    },
    payload: body ? JSON.stringify(body) : undefined,
  });
  const data = response.json();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new Error(`${method} ${url} failed: ${response.statusCode} ${JSON.stringify(data)}`);
  }
  return data;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
