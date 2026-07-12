import { all, db, one, run } from "./db.js";
import {
  badRequest,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const maxNovelCharacters = 8 * 1024 * 1024;
const maxChapterCount = 1000;

export async function aiNovelRoutes(app) {
  app.get("/ai-novels", async (request) => {
    const { page, pageSize, offset } = pageParams(request.query || {});
    const q = optionalString(request.query?.q, 100);
    const searchSql = q ? "AND (n.title LIKE ? OR n.pen_name LIKE ? OR n.category LIKE ?)" : "";
    const searchParams = q ? Array(3).fill(`%${q}%`) : [];
    const items = all(
      `SELECT n.*, u.nickname AS owner_nickname,
              COUNT(c.id) AS chapter_count
       FROM ai_novels n
       JOIN users u ON u.id = n.user_id
       LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id AND c.status = 'published'
       WHERE n.status = 'published'
         ${searchSql}
       GROUP BY n.id
       ORDER BY n.published_at DESC, n.id DESC
       LIMIT ? OFFSET ?`,
      [...searchParams, pageSize, offset],
    ).map(publicNovelJson);
    const total = one(
      `SELECT COUNT(*) AS count
       FROM ai_novels n
       WHERE n.status = 'published'
         ${searchSql}`,
      searchParams,
    )?.count || 0;
    return { items, page, pageSize, total };
  });

  app.get("/ai-novels/:id", async (request) => {
    return { item: requirePublicNovel(request.params.id) };
  });

  app.get("/ai-novels/:id/chapters", async (request) => {
    const novel = requirePublicNovel(request.params.id);
    const items = all(
      `SELECT id, title, sort_order
       FROM ai_novel_chapters
       WHERE novel_id = ? AND status = 'published'
       ORDER BY sort_order, id`,
      [numericNovelId(request.params.id)],
    ).map((row) => chapterJson(row, novel.id));
    return { items };
  });

  app.get("/ai-novels/:id/chapters/:chapterId", async (request) => {
    const novelId = numericNovelId(request.params.id);
    requirePublicNovel(novelId);
    const row = one(
      `SELECT id, title, content, sort_order
       FROM ai_novel_chapters
       WHERE id = ? AND novel_id = ? AND status = 'published'`,
      [Number(request.params.chapterId), novelId],
    );
    if (!row) throw notFound("chapter_not_found");
    return { item: { ...chapterJson(row, `ai-${novelId}`), content: row.content } };
  });

  app.get(
    "/creator/ai-novels",
    { preHandler: app.authRequired },
    async (request) => ({
      items: creatorNovelRows(request.user.id).map(creatorNovelJson),
    }),
  );

  app.post(
    "/creator/ai-novels",
    { preHandler: app.authRequired, bodyLimit: 12 * 1024 * 1024 },
    async (request) => {
      const payload = novelPayload(request.body || {}, request.user);
      const published = request.user.role === "admin";
      const id = insertNovel({
        ...payload,
        userId: request.user.id,
        status: published ? "published" : "pending",
        reviewerId: published ? request.user.id : null,
      });
      return { item: creatorNovelJson(creatorNovelRow(id)) };
    },
  );

  app.put(
    "/creator/ai-novels/:id",
    { preHandler: app.authRequired, bodyLimit: 12 * 1024 * 1024 },
    async (request) => {
      const id = numericNovelId(request.params.id);
      const existing = one("SELECT * FROM ai_novels WHERE id = ? AND user_id = ?", [
        id,
        request.user.id,
      ]);
      if (!existing) throw notFound("novel_not_found");
      if (existing.status === "published" && request.user.role !== "admin") {
        throw forbidden("published_novel_locked");
      }
      const payload = novelPayload(request.body || {}, request.user);
      replaceNovel(id, payload, request.user.role === "admin", request.user.id);
      return { item: creatorNovelJson(creatorNovelRow(id)) };
    },
  );

  app.post(
    "/creator/ai-novels/:id/chapters",
    { preHandler: app.authRequired, bodyLimit: 12 * 1024 * 1024 },
    async (request) => {
      const novelId = numericNovelId(request.params.id);
      const novel = one("SELECT * FROM ai_novels WHERE id = ? AND user_id = ?", [
        novelId,
        request.user.id,
      ]);
      if (!novel) throw notFound("novel_not_found");
      if (novel.status !== "published") throw forbidden("novel_not_published");
      const content = requiredString(
        request.body?.content,
        "content",
        maxNovelCharacters,
      );
      const chapters = splitNovelChapters(content);
      if (!chapters.length) throw badRequest("chapter content is empty");
      const publish = request.user.role === "admin";
      const startOrder = Number(
        one(
          "SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM ai_novel_chapters WHERE novel_id = ?",
          [novelId],
        )?.next_order || 0,
      );
      insertChapters(
        novelId,
        chapters,
        publish ? "published" : "pending",
        publish ? request.user.id : null,
        startOrder,
      );
      run("UPDATE ai_novels SET updated_at = datetime('now') WHERE id = ?", [novelId]);
      return { items: creatorChapterRows(novelId).map(creatorChapterJson) };
    },
  );

  app.get(
    "/admin/ai-novels",
    { preHandler: app.adminRequired },
    async (request) => {
      const status = optionalString(request.query?.status, 30);
      const where = status ? "WHERE n.status = ?" : "";
      const items = all(
        `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
                COUNT(c.id) AS chapter_count
         FROM ai_novels n
         JOIN users u ON u.id = n.user_id
         LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
         ${where}
         GROUP BY n.id
         ORDER BY CASE n.status WHEN 'pending' THEN 0 ELSE 1 END,
                  n.updated_at DESC, n.id DESC
         LIMIT 200`,
        status ? [status] : [],
      ).map(creatorNovelJson);
      return { items };
    },
  );

  app.get(
    "/admin/ai-novel-chapters",
    { preHandler: app.adminRequired },
    async (request) => {
      const status = optionalString(request.query?.status, 30) || "pending";
      return {
        items: all(
          `SELECT c.*, n.title AS novel_title, n.user_id,
                  u.nickname AS owner_nickname, u.email AS owner_email
           FROM ai_novel_chapters c
           JOIN ai_novels n ON n.id = c.novel_id
           JOIN users u ON u.id = n.user_id
           WHERE c.status = ?
           ORDER BY c.updated_at, c.id
           LIMIT 300`,
          [status],
        ).map(creatorChapterJson),
      };
    },
  );

  app.post(
    "/admin/ai-novels/:id/review",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = numericNovelId(request.params.id);
      const decision = requiredString(request.body?.decision, "decision", 20);
      if (!['approve', 'reject'].includes(decision)) {
        throw badRequest("decision is invalid");
      }
      const reviewNote = optionalString(request.body?.reviewNote, 500);
      if (decision === "reject" && !reviewNote) {
        throw badRequest("reviewNote is required when rejecting");
      }
      const item = one("SELECT * FROM ai_novels WHERE id = ?", [id]);
      if (!item) throw notFound("novel_not_found");
      const status = decision === "approve" ? "published" : "rejected";
      run(
        `UPDATE ai_novels
         SET status = ?, review_note = ?, reviewed_by = ?,
             reviewed_at = datetime('now'),
             published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
             updated_at = datetime('now')
         WHERE id = ?`,
        [status, reviewNote, request.user.id, status, id],
      );
      if (status === "published") {
        run(
          `UPDATE ai_novel_chapters
           SET status = 'published', review_note = '', reviewed_by = ?,
               reviewed_at = datetime('now'), published_at = datetime('now'),
               updated_at = datetime('now')
           WHERE novel_id = ? AND status = 'pending'`,
          [request.user.id, id],
        );
      }
      run(
        `INSERT INTO system_notifications (user_id, title, content, category)
         VALUES (?, ?, ?, 'ai_novel_review')`,
        [
          item.user_id,
          status === "published" ? "AI 小说审核通过" : "AI 小说需要修改",
          status === "published"
            ? `《${item.title}》已审核通过并发布到 AI 创作区。`
            : `《${item.title}》未通过审核：${reviewNote}`,
        ],
      );
      return { item: creatorNovelJson(creatorNovelRow(id)) };
    },
  );

  app.post(
    "/admin/ai-novel-chapters/:chapterId/review",
    { preHandler: app.adminRequired },
    async (request) => {
      const chapterId = Number(request.params.chapterId);
      if (!Number.isInteger(chapterId) || chapterId <= 0) {
        throw badRequest("chapter id is invalid");
      }
      const decision = requiredString(request.body?.decision, "decision", 20);
      if (!["approve", "reject"].includes(decision)) {
        throw badRequest("decision is invalid");
      }
      const reviewNote = optionalString(request.body?.reviewNote, 500);
      if (decision === "reject" && !reviewNote) {
        throw badRequest("reviewNote is required when rejecting");
      }
      const chapter = one(
        `SELECT c.*, n.title AS novel_title, n.user_id
         FROM ai_novel_chapters c
         JOIN ai_novels n ON n.id = c.novel_id
         WHERE c.id = ?`,
        [chapterId],
      );
      if (!chapter) throw notFound("chapter_not_found");
      const status = decision === "approve" ? "published" : "rejected";
      run(
        `UPDATE ai_novel_chapters
         SET status = ?, review_note = ?, reviewed_by = ?,
             reviewed_at = datetime('now'),
             published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
             updated_at = datetime('now')
         WHERE id = ?`,
        [status, reviewNote, request.user.id, status, chapterId],
      );
      run(
        `INSERT INTO system_notifications (user_id, title, content, category)
         VALUES (?, ?, ?, 'ai_novel_review')`,
        [
          chapter.user_id,
          status === "published" ? "连载章节审核通过" : "连载章节需要修改",
          status === "published"
            ? `《${chapter.novel_title}》的“${chapter.title}”已发布。`
            : `《${chapter.novel_title}》的“${chapter.title}”未通过审核：${reviewNote}`,
        ],
      );
      return { item: creatorChapterJson({ ...chapter, status, review_note: reviewNote }) };
    },
  );
}

function novelPayload(body, user) {
  const title = requiredString(body.title, "title", 100);
  const penName = optionalString(body.penName, 50) || user.nickname || "匿名作者";
  const category = optionalString(body.category, 40) || "AI原创";
  const coverUrl = optionalString(body.coverUrl, 1000);
  const description = requiredString(body.description, "description", 2000);
  const content = requiredString(body.content, "content", maxNovelCharacters);
  const chapters = splitNovelChapters(content);
  if (!chapters.length) throw badRequest("novel content is empty");
  return { title, penName, category, coverUrl, description, chapters };
}

function splitNovelChapters(rawContent) {
  const content = String(rawContent || "").replace(/\r\n?/g, "\n").trim();
  if (!content) return [];
  const headingPattern = /^(第[^\n]{1,30}[章节回卷部篇][^\n]{0,80}|(?:chapter|chap\.)\s+\d+[^\n]*)\s*$/gim;
  const matches = [...content.matchAll(headingPattern)];
  if (!matches.length) return [{ title: "正文", content }];
  const chapters = [];
  const preface = content.slice(0, matches[0].index).trim();
  if (preface) chapters.push({ title: "序章", content: preface });
  for (let index = 0; index < matches.length; index += 1) {
    const match = matches[index];
    const start = match.index + match[0].length;
    const end = index + 1 < matches.length ? matches[index + 1].index : content.length;
    const chapterContent = content.slice(start, end).trim();
    if (chapterContent) {
      chapters.push({ title: match[0].trim(), content: chapterContent });
    }
    if (chapters.length >= maxChapterCount) break;
  }
  return chapters;
}

function insertNovel(payload) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = run(
      `INSERT INTO ai_novels
       (user_id, title, pen_name, category, cover_url, description, status,
        reviewed_by, reviewed_at, published_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?,
               CASE WHEN ? IS NULL THEN '' ELSE datetime('now') END,
               CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END)`,
      [
        payload.userId,
        payload.title,
        payload.penName,
        payload.category,
        payload.coverUrl,
        payload.description,
        payload.status,
        payload.reviewerId,
        payload.reviewerId,
        payload.status,
      ],
    );
    const id = Number(result.lastInsertRowid);
    insertChapters(
      id,
      payload.chapters,
      payload.status === "published" ? "published" : "pending",
      payload.reviewerId,
    );
    db.exec("COMMIT");
    return id;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function replaceNovel(id, payload, publish, reviewerId) {
  db.exec("BEGIN IMMEDIATE");
  try {
    run(
      `UPDATE ai_novels
       SET title = ?, pen_name = ?, category = ?, cover_url = ?, description = ?,
           status = ?, review_note = '', reviewed_by = ?,
           reviewed_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
           published_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
           updated_at = datetime('now')
       WHERE id = ?`,
      [
        payload.title,
        payload.penName,
        payload.category,
        payload.coverUrl,
        payload.description,
        publish ? "published" : "pending",
        publish ? reviewerId : null,
        publish ? 1 : 0,
        publish ? 1 : 0,
        id,
      ],
    );
    run("DELETE FROM ai_novel_chapters WHERE novel_id = ?", [id]);
    insertChapters(
      id,
      payload.chapters,
      publish ? "published" : "pending",
      publish ? reviewerId : null,
    );
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function insertChapters(
  novelId,
  chapters,
  status = "pending",
  reviewerId = null,
  startOrder = 0,
) {
  const statement = db.prepare(
    `INSERT INTO ai_novel_chapters
     (novel_id, title, content, sort_order, status, reviewed_by,
      reviewed_at, published_at)
     VALUES (?, ?, ?, ?, ?, ?,
             CASE WHEN ? IS NULL THEN '' ELSE datetime('now') END,
             CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END)`,
  );
  chapters.forEach((chapter, index) => {
    statement.run(
      novelId,
      chapter.title,
      chapter.content,
      startOrder + index,
      status,
      reviewerId,
      reviewerId,
      status,
    );
  });
}

function requirePublicNovel(rawId) {
  const id = numericNovelId(rawId);
  const row = one(
    `SELECT n.*, u.nickname AS owner_nickname,
            COUNT(c.id) AS chapter_count
     FROM ai_novels n
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id AND c.status = 'published'
     WHERE n.id = ? AND n.status = 'published'
     GROUP BY n.id`,
    [id],
  );
  if (!row) throw notFound("novel_not_found");
  return publicNovelJson(row);
}

function creatorNovelRows(userId) {
  return all(
    `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
            COUNT(c.id) AS chapter_count,
            SUM(CASE WHEN c.status = 'published' THEN 1 ELSE 0 END) AS published_chapter_count,
            SUM(CASE WHEN c.status = 'pending' THEN 1 ELSE 0 END) AS pending_chapter_count
     FROM ai_novels n
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
     WHERE n.user_id = ?
     GROUP BY n.id
     ORDER BY n.updated_at DESC, n.id DESC`,
    [userId],
  );
}

function creatorNovelRow(id) {
  return one(
    `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
            COUNT(c.id) AS chapter_count,
            SUM(CASE WHEN c.status = 'published' THEN 1 ELSE 0 END) AS published_chapter_count,
            SUM(CASE WHEN c.status = 'pending' THEN 1 ELSE 0 END) AS pending_chapter_count
     FROM ai_novels n
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
     WHERE n.id = ?
     GROUP BY n.id`,
    [id],
  );
}

function publicNovelJson(row) {
  return {
    id: `ai-${row.id}`,
    title: row.title,
    author: row.pen_name || row.owner_nickname || "AI 创作者",
    coverUrl: row.cover_url || "",
    description: row.description || "",
    category: row.category || "AI原创",
    sourceId: "ai-creation",
    sourceName: "AI 创作区",
    status: "连载中",
    chapterCount: Number(row.chapter_count || 0),
    totalChapters: Number(row.chapter_count || 0),
    publishedAt: row.published_at || "",
    publishedChapterCount: Number(row.published_chapter_count || row.chapter_count || 0),
    pendingChapterCount: Number(row.pending_chapter_count || 0),
  };
}

function creatorChapterRows(novelId) {
  return all(
    `SELECT c.*, n.title AS novel_title, n.user_id
     FROM ai_novel_chapters c
     JOIN ai_novels n ON n.id = c.novel_id
     WHERE c.novel_id = ?
     ORDER BY c.sort_order, c.id`,
    [novelId],
  );
}

function creatorChapterJson(row) {
  return {
    id: Number(row.id),
    novelId: Number(row.novel_id),
    novelTitle: row.novel_title || "",
    title: row.title,
    index: Number(row.sort_order || 0),
    status: row.status,
    reviewNote: row.review_note || "",
    ownerId: Number(row.user_id || 0),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function creatorNovelJson(row) {
  return {
    ...publicNovelJson(row),
    numericId: Number(row.id),
    ownerId: Number(row.user_id),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    status: row.status,
    reviewNote: row.review_note || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
    publishedAt: row.published_at || "",
  };
}

function chapterJson(row, novelId) {
  return {
    id: String(row.id),
    novelId,
    title: row.title,
    index: Number(row.sort_order || 0),
    url: `/ai-novels/${numericNovelId(novelId)}/chapters/${row.id}`,
    isLoaded: false,
  };
}

function numericNovelId(value) {
  const normalized = String(value || "").replace(/^ai-/, "");
  const id = Number(normalized);
  if (!Number.isInteger(id) || id <= 0) throw badRequest("novel id is invalid");
  return id;
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}

function forbidden(message) {
  const error = new Error(message);
  error.statusCode = 403;
  return error;
}
