import { randomUUID } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";

import { config } from "./config.js";
import { all, db, one, run } from "./db.js";
import {
  referencedUploadUrls,
  retireManagedUploadKey,
  retireManagedUploadUrls,
  scheduleManagedUploadRetirement,
  scheduleRetiredUploadDeleteRetry,
  isManagedUploadRetired,
} from "./upload-lifecycle.js";
import { enforceRateLimits } from "./rate-limit.js";
import {
  inspectUserUploadUsage,
  managedUploadKeyFromUrl,
  pruneOrphanedUserUploads,
  validateUploadBytes,
  withUploadLock,
  writeUploadAtomically,
} from "./upload-security.js";
import {
  badRequest,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const maxNovelCharacters = 8 * 1024 * 1024;
const maxChapterCount = 1000;
const maxCoverBytes = 5 * 1024 * 1024;
const novelCoverFolder = "novel-covers";
const novelCoverFolders = new Set([novelCoverFolder]);
const novelCoverExtensions = new Map([
  ["image/jpeg", "jpg"],
  ["image/jpg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);

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
       LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
         AND c.status = 'published' AND c.replaces_chapter_id IS NULL
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
       WHERE novel_id = ? AND status = 'published' AND replaces_chapter_id IS NULL
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
       WHERE id = ? AND novel_id = ? AND status = 'published'
         AND replaces_chapter_id IS NULL`,
      [Number(request.params.chapterId), novelId],
    );
    if (!row) throw notFound("chapter_not_found");
    return { item: { ...chapterJson(row, `ai-${novelId}`), content: row.content } };
  });

  app.get("/uploads/content/novel-covers/:file", async (request, reply) => {
    return serveNovelCover(request.params.file, reply);
  });

  app.post(
    "/creator/ai-novel-covers",
    { preHandler: app.authRequired },
    async (request, reply) => {
      const limited = enforceRateLimits(request, reply, [
        {
          scope: "ai_novel_cover_upload_user",
          key: request.user.id,
          limit: 30,
          windowMs: 60 * 60 * 1000,
          error: "novel_cover_upload_rate_limited",
        },
      ]);
      if (limited) return limited;
      return uploadNovelCover(request);
    },
  );

  app.post(
    "/creator/ai-novels/drafts",
    { preHandler: app.authRequired },
    async (request) => {
      const body = request.body || {};
      const title = optionalString(body.title, 100) || "未命名作品";
      const penName = optionalString(body.penName, 50) || request.user.nickname || "匿名作者";
      const category = optionalString(body.category, 40) || "AI原创";
      const serializationStatus = novelSerializationStatus(body.serializationStatus, {
        optional: true,
      }) || "ongoing";
      let coverUrl = optionalString(body.coverUrl, 1000);
      if (coverUrl) coverUrl = requireOwnedNovelCover(coverUrl, request.user.id);
      const description = optionalString(body.description, 2000);
      const result = run(
        `INSERT INTO ai_novels
           (user_id, title, pen_name, category, cover_url, description,
            status, serialization_status)
         VALUES (?, ?, ?, ?, ?, ?, 'draft', ?)`,
        [
          request.user.id,
          title,
          penName,
          category,
          coverUrl,
          description,
          serializationStatus,
        ],
      );
      return creatorNovelDetail(Number(result.lastInsertRowid), request.user.id);
    },
  );

  app.get(
    "/creator/ai-novels/:id",
    { preHandler: app.authRequired },
    async (request) => creatorNovelDetail(numericNovelId(request.params.id), request.user.id),
  );

  app.delete(
    "/creator/ai-novels/:id",
    { preHandler: app.authRequired },
    async (request) => {
      const id = numericNovelId(request.params.id);
      const current = requireOwnedCreatorNovel(id, request.user.id);
      if (!["draft", "rejected"].includes(current.status)) {
        throw conflict("novel_cannot_be_deleted");
      }
      run("DELETE FROM ai_novels WHERE id = ?", [id]);
      cleanupReplacedNovelCover(request, request.user.id, current.cover_url);
      return { ok: true };
    },
  );

  app.put(
    "/creator/ai-novels/:id/draft",
    { preHandler: app.authRequired, bodyLimit: 12 * 1024 * 1024 },
    async (request) => {
      const id = numericNovelId(request.params.id);
      const current = requireOwnedCreatorNovel(id, request.user.id);
      const body = request.body || {};
      requireExpectedRevision(body.expectedRevision, current.revision);
      if (current.status === "pending") throw conflict("novel_review_in_progress");

      const chaptersProvided = Object.hasOwn(body, "chapters");
      const metadataProvided = hasNovelMetadataFields(body);
      const chapters = chaptersProvided
        ? structuredChapters(body.chapters)
        : all(
            `SELECT title, content
             FROM ai_novel_chapters
             WHERE novel_id = ? AND status IN ('draft', 'rejected')
             ORDER BY sort_order, id`,
            [id],
          );
      const published = current.status === "published";
      const nextMetadata = !published || metadataProvided
        ? draftNovelMetadata(body, request.user, current)
        : null;
      if (!published && nextMetadata?.coverUrl) {
        nextMetadata.coverUrl = requireOwnedNovelCover(
          nextMetadata.coverUrl,
          request.user.id,
        );
      }
      if (
        published
        && nextMetadata?.coverUrl
        && nextMetadata.coverUrl !== current.cover_url
      ) {
        nextMetadata.coverUrl = requireOwnedNovelCover(
          nextMetadata.coverUrl,
          request.user.id,
        );
      }

      let replacedMetadataCoverUrl = "";
      db.exec("BEGIN IMMEDIATE");
      try {
        if (!published) {
          run(
            `UPDATE ai_novels
             SET title = ?, pen_name = ?, category = ?, cover_url = ?,
                 description = ?, serialization_status = ?, status = 'draft',
                 revision = revision + 1,
                 updated_at = datetime('now')
             WHERE id = ?`,
            [
              nextMetadata.title,
              nextMetadata.penName,
              nextMetadata.category,
              nextMetadata.coverUrl,
              nextMetadata.description,
              nextMetadata.serializationStatus,
              id,
            ],
          );
        } else {
          if (nextMetadata) {
            replacedMetadataCoverUrl = savePublishedMetadataDraft({
              novel: current,
              metadata: nextMetadata,
            });
          }
          run(
            `UPDATE ai_novels
             SET revision = revision + 1,
                 updated_at = datetime('now')
             WHERE id = ?`,
            [id],
          );
        }
        if (published) {
          if (chaptersProvided) savePublishedChapterDrafts(id, chapters);
        } else {
          run(
            `DELETE FROM ai_novel_chapters
             WHERE novel_id = ? AND status IN ('draft', 'rejected')`,
            [id],
          );
          insertChapters(id, chapters, "draft");
        }
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      if (!published && current.cover_url !== nextMetadata?.coverUrl) {
        cleanupReplacedNovelCover(request, request.user.id, current.cover_url);
      }
      if (replacedMetadataCoverUrl) {
        cleanupReplacedNovelCover(request, request.user.id, replacedMetadataCoverUrl);
      }
      return creatorNovelDetail(id, request.user.id);
    },
  );

  app.post(
    "/creator/ai-novels/:id/submit",
    { preHandler: app.authRequired },
    async (request) => {
      const id = numericNovelId(request.params.id);
      const current = requireOwnedCreatorNovel(id, request.user.id);
      const body = request.body || {};
      requireExpectedRevision(body.expectedRevision, current.revision);
      if (current.status === "pending") throw conflict("novel_review_in_progress");

      const publish = request.user.role === "admin" && body.publishNow === true;
      const chapterRows = all(
        `SELECT * FROM ai_novel_chapters
         WHERE novel_id = ? AND status IN ('draft', 'rejected')
         ORDER BY sort_order, id`,
        [id],
      );
      const published = current.status === "published";
      const metadataRevision = published ? activeMetadataRevision(id) : null;
      const submittingMetadata = Boolean(
        metadataRevision && ["draft", "rejected"].includes(metadataRevision.status),
      );
      if (!chapterRows.length && (!published || !submittingMetadata)) {
        throw badRequest(published ? "novel_changes_are_required" : "novel chapters are required");
      }
      if (
        published &&
        chapterRows.length &&
        one(
          `SELECT 1 AS present
           FROM ai_novel_chapters
           WHERE novel_id = ? AND status = 'pending'
           LIMIT 1`,
          [id],
        )
      ) {
        throw conflict("serial_chapter_review_in_progress");
      }
      if (!published) {
        validateNovelForSubmission(current, chapterRows, { requireManagedCover: true });
      } else {
        if (submittingMetadata) validateMetadataRevisionForSubmission(metadataRevision, current);
        if (chapterRows.length) {
          validateNovelForSubmission(
            current,
            effectivePublishedChapters(id, chapterRows),
            { requireManagedCover: false },
          );
        }
      }
      const nextChapterStatus = publish ? "published" : "pending";

      db.exec("BEGIN IMMEDIATE");
      try {
        let chapterBatchId = null;
        if (published && chapterRows.length) {
          const batch = run(
            `INSERT INTO ai_novel_chapter_submission_batches
               (novel_id, status, review_note, chapter_count, submitted_at,
                reviewed_by, reviewed_at, published_at)
             VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?)`,
            [
              id,
              nextChapterStatus,
              publish ? "管理员直接发布连载章节" : "",
              chapterRows.length,
              publish ? request.user.id : null,
              "",
              "",
            ],
          );
          if (publish) {
            run(
              `UPDATE ai_novel_chapter_submission_batches
               SET reviewed_at = datetime('now'), published_at = datetime('now')
               WHERE id = ?`,
              [Number(batch.lastInsertRowid)],
            );
          }
          chapterBatchId = Number(batch.lastInsertRowid);
        }
        if (chapterRows.length) {
          run(
            `UPDATE ai_novel_chapters
             SET status = ?, review_note = '', revision = revision + 1,
                 submission_batch_id = CASE WHEN ? IS NULL THEN submission_batch_id ELSE ? END,
                 submitted_at = datetime('now'),
                 reviewed_by = CASE WHEN ? THEN ? ELSE NULL END,
                 reviewed_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
                 published_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
                 updated_at = datetime('now')
             WHERE novel_id = ? AND status IN ('draft', 'rejected')`,
            [
              nextChapterStatus,
              chapterBatchId,
              chapterBatchId,
              publish ? 1 : 0,
              publish ? request.user.id : null,
              publish ? 1 : 0,
              publish ? 1 : 0,
              id,
            ],
          );
        }
        if (publish && chapterRows.length) {
          for (const chapter of chapterRows) {
            applyApprovedChapterRevision(chapter, request.user.id);
          }
        }
        if (!published) {
          const nextNovelStatus = publish ? "published" : "pending";
          run(
            `UPDATE ai_novels
             SET status = ?, review_note = '', revision = revision + 1,
                 submitted_at = datetime('now'),
                 reviewed_by = CASE WHEN ? THEN ? ELSE NULL END,
                 reviewed_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
                 published_at = CASE WHEN ? THEN datetime('now') ELSE published_at END,
                 updated_at = datetime('now')
             WHERE id = ?`,
            [
              nextNovelStatus,
              publish ? 1 : 0,
              publish ? request.user.id : null,
              publish ? 1 : 0,
              publish ? 1 : 0,
              id,
            ],
          );
          if (publish) {
            recordNovelReviewEvent({
              novelId: id,
              chapterId: null,
              revision: Number(current.revision || 1) + 1,
              decision: "direct_publish",
              note: "管理员直接发布",
              reviewerId: request.user.id,
            });
          }
        } else {
          if (submittingMetadata) {
            run(
              `UPDATE ai_novel_metadata_revisions
               SET status = 'pending', review_note = '', revision = revision + 1,
                   submitted_at = datetime('now'), reviewed_by = NULL,
                   reviewed_at = '', updated_at = datetime('now')
               WHERE id = ? AND status IN ('draft', 'rejected')`,
              [metadataRevision.id],
            );
          }
          run(
            `UPDATE ai_novels
             SET revision = revision + 1, updated_at = datetime('now')
             WHERE id = ?`,
            [id],
          );
          if (publish && chapterRows.length) {
            recordNovelReviewEvent({
              novelId: id,
              chapterId: null,
              submissionBatchId: chapterBatchId,
              revision: 1,
              decision: "direct_publish",
              note: "管理员直接发布连载章节",
              reviewerId: request.user.id,
            });
          }
        }
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      return creatorNovelDetail(id, request.user.id);
    },
  );

  app.get(
    "/creator/ai-novels",
    { preHandler: app.authRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const status = aiNovelStatus(request.query?.status, { optional: true });
      const q = optionalString(request.query?.q, 100);
      const filters = ["n.user_id = ?"];
      const params = [request.user.id];
      if (status) {
        filters.push("n.status = ?");
        params.push(status);
      }
      if (q) {
        filters.push("(n.title LIKE ? OR n.pen_name LIKE ? OR n.category LIKE ?)");
        params.push(...Array(3).fill(`%${q}%`));
      }
      const where = filters.join(" AND ");
      const items = all(
        `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
                COUNT(CASE WHEN c.replaces_chapter_id IS NULL THEN c.id END) AS chapter_count,
                SUM(CASE WHEN c.status = 'published' AND c.replaces_chapter_id IS NULL THEN 1 ELSE 0 END) AS published_chapter_count,
                SUM(CASE WHEN c.status = 'pending' THEN 1 ELSE 0 END) AS pending_chapter_count
         FROM ai_novels n
         JOIN users u ON u.id = n.user_id
         LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
         WHERE ${where}
         GROUP BY n.id
         ORDER BY n.updated_at DESC, n.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(creatorNovelJson);
      const total = Number(
        one(`SELECT COUNT(*) AS count FROM ai_novels n WHERE ${where}`, params)?.count || 0,
      );
      return { items, page, pageSize, total };
    },
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
          `SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order
           FROM ai_novel_chapters
           WHERE novel_id = ? AND replaces_chapter_id IS NULL`,
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
      run(
        `UPDATE ai_novels
         SET revision = revision + 1, updated_at = datetime('now')
         WHERE id = ?`,
        [novelId],
      );
      return { items: creatorChapterRows(novelId).map(creatorChapterJson) };
    },
  );

  app.get(
    "/admin/ai-novels",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const status = aiNovelStatus(request.query?.status, { optional: true });
      const q = optionalString(request.query?.q, 100);
      const filters = [];
      const params = [];
      if (status) {
        filters.push("n.status = ?");
        params.push(status);
      }
      if (q) {
        filters.push(
          "(n.title LIKE ? OR n.pen_name LIKE ? OR u.nickname LIKE ? OR u.email LIKE ?)",
        );
        params.push(...Array(4).fill(`%${q}%`));
      }
      const where = filters.length ? `WHERE ${filters.join(" AND ")}` : "";
      const items = all(
        `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
                COUNT(CASE WHEN c.replaces_chapter_id IS NULL THEN c.id END) AS chapter_count
         FROM ai_novels n
         JOIN users u ON u.id = n.user_id
         LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
         ${where}
         GROUP BY n.id
         ORDER BY CASE n.status WHEN 'pending' THEN 0 ELSE 1 END,
                   n.updated_at DESC, n.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(creatorNovelJson);
      const total = Number(
        one(
          `SELECT COUNT(*) AS count
           FROM ai_novels n
           JOIN users u ON u.id = n.user_id
           ${where}`,
          params,
        )?.count || 0,
      );
      return { items, page, pageSize, total };
    },
  );

  app.get(
    "/admin/ai-novel-chapters",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const status = aiNovelStatus(request.query?.status, { optional: true }) || "pending";
      const q = optionalString(request.query?.q, 100);
      const searchSql = q
        ? "AND (c.title LIKE ? OR n.title LIKE ? OR u.nickname LIKE ? OR u.email LIKE ?)"
        : "";
      const searchParams = q ? Array(4).fill(`%${q}%`) : [];
      const reviewedOnlySql = status === "pending"
        ? ""
        : `AND EXISTS (
             SELECT 1 FROM ai_novel_review_events event
             WHERE event.chapter_id = c.id
           )`;
      const items = all(
         `SELECT c.*, n.title AS novel_title, n.user_id,
                 original.title AS original_title,
                 original.content AS original_content,
                 original.sort_order AS original_sort_order,
                 u.nickname AS owner_nickname, u.email AS owner_email
          FROM ai_novel_chapters c
          JOIN ai_novels n ON n.id = c.novel_id
          JOIN users u ON u.id = n.user_id
          LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
          WHERE c.status = ? AND n.status = 'published'
            ${reviewedOnlySql} ${searchSql}
         ORDER BY c.updated_at, c.id
         LIMIT ? OFFSET ?`,
        [status, ...searchParams, pageSize, offset],
      ).map(creatorChapterJson);
      const total = Number(
        one(
          `SELECT COUNT(*) AS count
           FROM ai_novel_chapters c
           JOIN ai_novels n ON n.id = c.novel_id
           JOIN users u ON u.id = n.user_id
            WHERE c.status = ? AND n.status = 'published'
              ${reviewedOnlySql} ${searchSql}`,
          [status, ...searchParams],
        )?.count || 0,
      );
      return {
        items,
        page,
        pageSize,
        total,
      };
    },
  );

  app.get(
    "/admin/ai-novel-review-queue",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const status = reviewQueueStatus(request.query?.status);
      const q = optionalString(request.query?.q, 100);
      return groupedReviewQueue({ status, q, page, pageSize, offset });
    },
  );

  app.get(
    "/admin/ai-novels/:id",
    { preHandler: app.adminRequired },
    async (request) => adminNovelDetail(numericNovelId(request.params.id)),
  );

  app.get(
    "/admin/ai-novel-chapters/:chapterId",
    { preHandler: app.adminRequired },
    async (request) => {
      const chapterId = positiveInteger(request.params.chapterId, "chapter id");
      const chapter = one(
        `SELECT c.*, n.title AS novel_title, n.user_id,
                original.title AS original_title,
                original.content AS original_content,
                original.sort_order AS original_sort_order,
                u.nickname AS owner_nickname, u.email AS owner_email
         FROM ai_novel_chapters c
         JOIN ai_novels n ON n.id = c.novel_id
         JOIN users u ON u.id = n.user_id
         LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
         WHERE c.id = ?`,
        [chapterId],
      );
      if (!chapter) throw notFound("chapter_not_found");
      return {
        item: creatorChapterJson(chapter, true),
        reviews: reviewEventRows(chapter.novel_id, chapterId),
      };
    },
  );

  app.get(
    "/admin/ai-novel-metadata-revisions/:revisionId",
    { preHandler: app.adminRequired },
    async (request) => metadataRevisionDetail(
      positiveInteger(request.params.revisionId, "metadata revision id"),
    ),
  );

  app.get(
    "/admin/ai-novel-chapter-submission-batches/:batchId",
    { preHandler: app.adminRequired },
    async (request) => chapterSubmissionBatchDetail(
      positiveInteger(request.params.batchId, "chapter submission batch id"),
    ),
  );

  app.post(
    "/admin/ai-novel-chapter-submission-batches/:batchId/review",
    { preHandler: app.adminRequired },
    async (request) => {
      const batchId = positiveInteger(request.params.batchId, "chapter submission batch id");
      const { decision, reviewNote } = reviewDecisionInput(request.body);
      const batch = requirePendingChapterSubmissionBatch(batchId);
      if (request.body?.expectedRevision !== undefined) {
        requireExpectedRevision(request.body.expectedRevision, batch.revision);
      }
      withReviewTransaction(() => reviewChapterSubmissionBatch({
        batch,
        decision,
        reviewNote,
        reviewerId: request.user.id,
      }));
      return chapterSubmissionBatchDetail(batchId);
    },
  );

  app.post(
    "/admin/ai-novel-reviews/batch",
    { preHandler: app.adminRequired },
    async (request) => {
      const { decision, reviewNote } = reviewDecisionInput(request.body);
      const targets = batchReviewTargets(request.body?.items);
      const result = withReviewTransaction(() => {
        const preparedByKey = new Map();
        for (const target of targets) {
          if (target.kind === "novel") {
            const item = requirePendingNovelReview(target.id);
            requireExpectedRevision(target.expectedRevision, item.revision);
            preparedByKey.set(`novel:${target.id}`, { ...target, item });
            continue;
          }
          if (target.kind === "metadata") {
            const item = requirePendingMetadataRevision(target.id);
            requireExpectedRevision(target.expectedRevision, item.revision);
            preparedByKey.set(`metadata:${target.id}`, { ...target, item });
            continue;
          }
          if (target.kind === "chapter_batch") {
            const item = requirePendingChapterSubmissionBatch(target.id);
            requireExpectedRevision(target.expectedRevision, item.revision);
            preparedByKey.set(`chapter_batch:${target.id}`, { ...target, item });
            continue;
          }
          const chapter = requirePendingChapterReview(target.id);
          const item = requirePendingChapterBatchForChapter(chapter);
          requireChapterBatchExpectedRevision(target.expectedRevision, item, chapter);
          const key = `chapter_batch:${item.id}`;
          if (!preparedByKey.has(key)) {
            preparedByKey.set(key, {
              ...target,
              kind: "chapter_batch",
              id: Number(item.id),
              expectedRevision: Number(item.revision || 1),
              item,
            });
          }
        }
        const prepared = [...preparedByKey.values()];
        const selectedNovelIds = new Set(
          prepared
            .filter((target) => target.kind === "novel")
            .map((target) => target.id),
        );
        if (prepared.some((target) =>
          target.kind === "chapter_batch" && selectedNovelIds.has(Number(target.item.novel_id)))) {
          throw conflict("batch_review_nested_target_conflict");
        }
        const retiredMetadataCovers = [];
        for (const target of prepared) {
          if (target.kind === "novel") {
            reviewNovelSubmission({
              item: target.item,
              decision,
              reviewNote,
              reviewerId: request.user.id,
            });
          } else if (target.kind === "metadata") {
            const metadataResult = reviewMetadataRevision({
              item: target.item,
              decision,
              reviewNote,
              reviewerId: request.user.id,
            });
            if (metadataResult.replacedCoverUrl) {
              retiredMetadataCovers.push({
                userId: target.item.user_id,
                url: metadataResult.replacedCoverUrl,
              });
            }
          } else {
            reviewChapterSubmissionBatch({
              batch: target.item,
              decision,
              reviewNote,
              reviewerId: request.user.id,
            });
          }
        }
        return {
          reviewed: prepared.map((target) => ({ kind: target.kind, id: target.id })),
          retiredMetadataCovers,
        };
      });
      for (const cover of result.retiredMetadataCovers) {
        cleanupReplacedNovelCover(request, cover.userId, cover.url);
      }
      return { reviewed: result.reviewed };
    },
  );

  app.post(
    "/admin/ai-novel-metadata-revisions/:revisionId/review",
    { preHandler: app.adminRequired },
    async (request) => {
      const revisionId = positiveInteger(request.params.revisionId, "metadata revision id");
      const { decision, reviewNote } = reviewDecisionInput(request.body);
      const item = requirePendingMetadataRevision(revisionId);
      if (request.body?.expectedRevision !== undefined) {
        requireExpectedRevision(request.body.expectedRevision, item.revision);
      }
      const result = withReviewTransaction(() => reviewMetadataRevision({
        item,
        decision,
        reviewNote,
        reviewerId: request.user.id,
      }));
      if (result.replacedCoverUrl) {
        cleanupReplacedNovelCover(request, item.user_id, result.replacedCoverUrl);
      }
      return { item: metadataRevisionJson(metadataRevisionRow(revisionId)) };
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
      const item = requirePendingNovelReview(id);
      if (request.body?.expectedRevision !== undefined) {
        requireExpectedRevision(request.body.expectedRevision, item.revision);
      }
      withReviewTransaction(() => reviewNovelSubmission({
        item,
        decision,
        reviewNote,
        reviewerId: request.user.id,
      }));
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
      const chapter = requirePendingChapterReview(chapterId);
      const batch = requirePendingChapterBatchForChapter(chapter);
      if (request.body?.expectedRevision !== undefined) {
        requireChapterBatchExpectedRevision(request.body.expectedRevision, batch, chapter);
      }
      withReviewTransaction(() => reviewChapterSubmissionBatch({
        batch,
        decision,
        reviewNote,
        reviewerId: request.user.id,
      }));
      const updated = one(
        `SELECT c.*, n.title AS novel_title, n.user_id,
                original.title AS original_title,
                original.content AS original_content,
                original.sort_order AS original_sort_order,
                u.nickname AS owner_nickname, u.email AS owner_email
         FROM ai_novel_chapters c
         JOIN ai_novels n ON n.id = c.novel_id
         JOIN users u ON u.id = n.user_id
         LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
         WHERE c.id = ?`,
        [chapterId],
      );
      return {
        item: creatorChapterJson(updated),
        batch: chapterSubmissionBatchJson(chapterSubmissionBatchRow(batch.id)),
      };
    },
  );
}

function groupedReviewQueue({ status, q, page, pageSize, offset }) {
  const scopeSql = reviewQueueScopeSql(status);
  const searchSql = reviewQueueSearchSql(q);
  const searchParams = reviewQueueSearchParams(q);
  const summary = one(
    `SELECT COUNT(DISTINCT CASE WHEN n.status = 'pending' THEN n.id END) AS pending_novel_count,
            COUNT(DISTINCT CASE
              WHEN n.status = 'published' AND metadata.status = 'pending' THEN metadata.id
            END) AS pending_metadata_count,
            COUNT(DISTINCT CASE
              WHEN n.status = 'published' AND c.status = 'pending' THEN c.id
            END) AS pending_chapter_count,
            COUNT(DISTINCT CASE
              WHEN n.status = 'published' AND batch.status = 'pending' THEN batch.id
            END) AS pending_chapter_batch_count
     FROM ai_novels n
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
     LEFT JOIN ai_novel_chapter_submission_batches batch ON batch.novel_id = n.id
     LEFT JOIN ai_novel_metadata_revisions metadata
       ON metadata.novel_id = n.id AND metadata.status = 'pending'`,
  ) || {};
  const total = Number(
    one(
      `SELECT COUNT(DISTINCT n.user_id) AS count
       FROM ai_novels n
       JOIN users u ON u.id = n.user_id
       WHERE ${scopeSql} ${searchSql}`,
      searchParams,
    )?.count || 0,
  );
  const authors = all(
    `SELECT u.id AS owner_id, u.nickname AS owner_nickname, u.email AS owner_email,
            COUNT(DISTINCT n.id) AS novel_count,
            COUNT(DISTINCT CASE WHEN n.status = 'pending' THEN n.id END) AS pending_novel_count,
            COUNT(DISTINCT CASE
              WHEN n.status = 'published' AND metadata.status = 'pending' THEN metadata.id
            END) AS pending_metadata_count,
            COUNT(DISTINCT CASE WHEN n.status = 'published' AND c.status = 'pending' THEN c.id END) AS pending_chapter_count,
            COUNT(DISTINCT CASE
              WHEN n.status = 'published' AND batch.status = 'pending' THEN batch.id
            END) AS pending_chapter_batch_count,
            MAX(n.updated_at) AS last_updated_at
     FROM ai_novels n
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
     LEFT JOIN ai_novel_chapter_submission_batches batch ON batch.novel_id = n.id
     LEFT JOIN ai_novel_metadata_revisions metadata
       ON metadata.novel_id = n.id AND metadata.status = 'pending'
     WHERE ${scopeSql} ${searchSql}
     GROUP BY u.id
     ORDER BY MAX(CASE
                WHEN n.status = 'pending' OR metadata.status = 'pending' OR batch.status = 'pending'
                THEN 1 ELSE 0
              END) DESC,
              last_updated_at DESC, u.id DESC
     LIMIT ? OFFSET ?`,
    [...searchParams, pageSize, offset],
  );
  if (!authors.length) {
    return {
      items: [],
      page,
      pageSize,
      total,
      summary: reviewQueueSummary(summary),
    };
  }

  const ownerIds = authors.map((author) => Number(author.owner_id));
  const ownerPlaceholders = ownerIds.map(() => "?").join(", ");
  const bookRows = all(
    `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
            COUNT(CASE WHEN c.replaces_chapter_id IS NULL THEN c.id END) AS chapter_count,
            SUM(CASE WHEN c.status = 'published' AND c.replaces_chapter_id IS NULL THEN 1 ELSE 0 END) AS published_chapter_count,
            SUM(CASE WHEN c.status = 'pending' THEN 1 ELSE 0 END) AS pending_chapter_count
     FROM ai_novels n
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
     WHERE n.user_id IN (${ownerPlaceholders}) AND ${scopeSql} ${searchSql}
     GROUP BY n.id
     ORDER BY n.user_id,
              CASE n.status WHEN 'pending' THEN 0 ELSE 1 END,
              n.updated_at DESC, n.id DESC`,
    [...ownerIds, ...searchParams],
  );
  const chapterBatchRows = all(
    `SELECT batch.*, n.user_id, n.title AS novel_title,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_chapter_submission_batches batch
     JOIN ai_novels n ON n.id = batch.novel_id
     JOIN users u ON u.id = n.user_id
     WHERE n.user_id IN (${ownerPlaceholders})
       AND batch.status = ? AND ${scopeSql} ${searchSql}
     ORDER BY n.user_id, n.id, batch.submitted_at DESC, batch.id DESC`,
    [...ownerIds, status, ...searchParams],
  ).map(chapterSubmissionBatchJson);
  const chapterRows = all(
    `SELECT c.*, n.title AS novel_title, n.user_id,
            original.title AS original_title,
            original.content AS original_content,
            original.sort_order AS original_sort_order,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_chapters c
     JOIN ai_novels n ON n.id = c.novel_id
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
     WHERE n.user_id IN (${ownerPlaceholders})
       AND c.status = ?
       AND (n.status = 'pending' OR c.submission_batch_id IS NOT NULL)
       AND ${scopeSql} ${searchSql}
     ORDER BY n.user_id, n.id, COALESCE(original.sort_order, c.sort_order), c.id`,
    [...ownerIds, status, ...searchParams],
  ).map(creatorChapterJson);
  const metadataRows = all(
    `SELECT metadata.*, n.user_id, n.title AS novel_title,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_metadata_revisions metadata
     JOIN ai_novels n ON n.id = metadata.novel_id
     JOIN users u ON u.id = n.user_id
     WHERE n.user_id IN (${ownerPlaceholders})
       AND metadata.status = ? AND ${scopeSql} ${searchSql}
     ORDER BY n.user_id, n.id, metadata.updated_at DESC, metadata.id DESC`,
    [...ownerIds, metadataStatusForReviewQueue(status), ...searchParams],
  ).map(metadataRevisionJson);
  const chaptersByNovel = new Map();
  const chapterBatchesById = new Map();
  const chapterBatchesByNovel = new Map();
  for (const batch of chapterBatchRows) {
    batch.chapters = [];
    chapterBatchesById.set(batch.id, batch);
    const batches = chapterBatchesByNovel.get(batch.novelId) || [];
    batches.push(batch);
    chapterBatchesByNovel.set(batch.novelId, batches);
  }
  for (const chapter of chapterRows) {
    const chapters = chaptersByNovel.get(chapter.novelId) || [];
    chapters.push(chapter);
    chaptersByNovel.set(chapter.novelId, chapters);
    if (chapter.submissionBatchId != null) {
      chapterBatchesById.get(chapter.submissionBatchId)?.chapters.push(chapter);
    }
  }
  const metadataByNovel = new Map();
  for (const metadata of metadataRows) {
    if (!metadataByNovel.has(metadata.novelId)) {
      metadataByNovel.set(metadata.novelId, metadata);
    }
  }
  const novelsByAuthor = new Map();
  for (const row of bookRows) {
    const novel = creatorNovelJson(row);
    novel.chapters = chaptersByNovel.get(novel.numericId) || [];
    novel.chapterBatches = chapterBatchesByNovel.get(novel.numericId) || [];
    novel.metadataRevision = metadataByNovel.get(novel.numericId) || null;
    const novels = novelsByAuthor.get(novel.ownerId) || [];
    novels.push(novel);
    novelsByAuthor.set(novel.ownerId, novels);
  }
  return {
    items: authors.map((author) => ({
      ownerId: Number(author.owner_id),
      ownerNickname: author.owner_nickname || "",
      ownerEmail: author.owner_email || "",
      novelCount: Number(author.novel_count || 0),
      pendingNovelCount: Number(author.pending_novel_count || 0),
      pendingMetadataCount: Number(author.pending_metadata_count || 0),
      pendingChapterCount: Number(author.pending_chapter_count || 0),
      pendingChapterBatchCount: Number(author.pending_chapter_batch_count || 0),
      novels: novelsByAuthor.get(Number(author.owner_id)) || [],
    })),
    page,
    pageSize,
    total,
    summary: reviewQueueSummary(summary),
  };
}

function reviewQueueSummary(row) {
  return {
    pendingNovelCount: Number(row.pending_novel_count || 0),
    pendingMetadataCount: Number(row.pending_metadata_count || 0),
    pendingChapterCount: Number(row.pending_chapter_count || 0),
    pendingChapterBatchCount: Number(row.pending_chapter_batch_count || 0),
  };
}

function reviewQueueStatus(value) {
  const status = aiNovelStatus(value, { optional: true }) || "pending";
  if (!["pending", "published", "rejected"].includes(status)) {
    throw badRequest("status is invalid");
  }
  return status;
}

function reviewQueueScopeSql(status) {
  if (status === "pending") {
    return `(n.status = 'pending'
      OR (n.status = 'published' AND EXISTS (
        SELECT 1 FROM ai_novel_chapter_submission_batches pending_batch
        WHERE pending_batch.novel_id = n.id AND pending_batch.status = 'pending'
      ))
      OR (n.status = 'published' AND EXISTS (
        SELECT 1 FROM ai_novel_metadata_revisions pending_metadata
        WHERE pending_metadata.novel_id = n.id AND pending_metadata.status = 'pending'
      )))`;
  }
  if (status === "rejected") {
    return `(n.status = 'rejected'
      OR (n.status = 'published' AND EXISTS (
        SELECT 1 FROM ai_novel_chapter_submission_batches rejected_batch
        WHERE rejected_batch.novel_id = n.id AND rejected_batch.status = 'rejected'
      ))
      OR (n.status = 'published' AND EXISTS (
        SELECT 1 FROM ai_novel_metadata_revisions rejected_metadata
        WHERE rejected_metadata.novel_id = n.id AND rejected_metadata.status = 'rejected'
      )))`;
  }
  return "n.status = 'published'";
}

function reviewQueueSearchSql(q) {
  if (!q) return "";
  return `AND (n.title LIKE ? OR n.pen_name LIKE ? OR u.nickname LIKE ? OR u.email LIKE ?
    OR EXISTS (
      SELECT 1 FROM ai_novel_chapters searched_chapter
      WHERE searched_chapter.novel_id = n.id AND searched_chapter.title LIKE ?
    ) OR EXISTS (
      SELECT 1 FROM ai_novel_metadata_revisions searched_metadata
      WHERE searched_metadata.novel_id = n.id
        AND (searched_metadata.title LIKE ? OR searched_metadata.description LIKE ?)
    ))`;
}

function reviewQueueSearchParams(q) {
  return q ? Array(7).fill(`%${q}%`) : [];
}

function metadataStatusForReviewQueue(status) {
  return status === "published" ? "approved" : status;
}

function reviewDecisionInput(body) {
  const decision = requiredString(body?.decision, "decision", 20);
  if (!["approve", "reject"].includes(decision)) {
    throw badRequest("decision is invalid");
  }
  const reviewNote = optionalString(body?.reviewNote, 500);
  if (decision === "reject" && !reviewNote) {
    throw badRequest("reviewNote is required when rejecting");
  }
  return { decision, reviewNote };
}

function batchReviewTargets(value) {
  if (!Array.isArray(value) || !value.length) {
    throw badRequest("batch_review_items_required");
  }
  if (value.length > 100) throw badRequest("batch_review_limit_exceeded");
  const seen = new Set();
  return value.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw badRequest("batch_review_item_invalid");
    }
    const kind = requiredString(raw.kind, `items[${index}].kind`, 20);
    if (!["novel", "metadata", "chapter", "chapter_batch"].includes(kind)) {
      throw badRequest("batch_review_item_invalid");
    }
    const id = positiveInteger(raw.id, `items[${index}].id`);
    const expectedRevision = positiveInteger(
      raw.expectedRevision,
      `items[${index}].expectedRevision`,
    );
    const key = `${kind}:${id}`;
    if (seen.has(key)) throw badRequest("batch_review_duplicate");
    seen.add(key);
    return { kind, id, expectedRevision };
  });
}

function requirePendingNovelReview(id) {
  const item = one("SELECT * FROM ai_novels WHERE id = ?", [id]);
  if (!item) throw notFound("novel_not_found");
  if (item.status !== "pending") throw conflict("novel_review_not_pending");
  return item;
}

function requirePendingMetadataRevision(revisionId) {
  const item = one(
    `SELECT metadata.*, n.user_id, n.status AS novel_status,
            n.title AS novel_title, n.pen_name AS novel_pen_name,
            n.category AS novel_category, n.cover_url AS novel_cover_url,
            n.description AS novel_description,
            n.serialization_status AS novel_serialization_status
     FROM ai_novel_metadata_revisions metadata
     JOIN ai_novels n ON n.id = metadata.novel_id
     WHERE metadata.id = ?`,
    [revisionId],
  );
  if (!item) throw notFound("metadata_revision_not_found");
  if (item.novel_status !== "published") {
    throw conflict("metadata_revision_requires_published_novel");
  }
  if (item.status !== "pending") throw conflict("metadata_revision_not_pending");
  return item;
}

function requirePendingChapterReview(chapterId) {
  const chapter = one(
    `SELECT c.*, n.title AS novel_title, n.user_id,
            n.status AS novel_status
     FROM ai_novel_chapters c
     JOIN ai_novels n ON n.id = c.novel_id
     WHERE c.id = ?`,
    [chapterId],
  );
  if (!chapter) throw notFound("chapter_not_found");
  if (chapter.novel_status !== "published") {
    throw conflict("chapter_requires_novel_review");
  }
  if (chapter.status !== "pending") {
    throw conflict("chapter_review_not_pending");
  }
  return chapter;
}

function requirePendingChapterSubmissionBatch(batchId) {
  const batch = one(
    `SELECT batch.*, n.title AS novel_title, n.user_id, n.status AS novel_status,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_chapter_submission_batches batch
     JOIN ai_novels n ON n.id = batch.novel_id
     JOIN users u ON u.id = n.user_id
     WHERE batch.id = ?`,
    [batchId],
  );
  if (!batch) throw notFound("chapter_submission_batch_not_found");
  if (batch.novel_status !== "published") {
    throw conflict("chapter_batch_requires_published_novel");
  }
  if (batch.status !== "pending") {
    throw conflict("chapter_submission_batch_not_pending");
  }
  const pendingCount = Number(
    one(
      `SELECT COUNT(*) AS count
       FROM ai_novel_chapters
       WHERE submission_batch_id = ? AND status = 'pending'`,
      [batch.id],
    )?.count || 0,
  );
  if (!pendingCount || pendingCount !== Number(batch.chapter_count || 0)) {
    throw conflict("chapter_submission_batch_conflict");
  }
  return batch;
}

function requirePendingChapterBatchForChapter(chapter) {
  if (chapter.submission_batch_id == null) {
    throw conflict("chapter_submission_batch_not_found");
  }
  return requirePendingChapterSubmissionBatch(Number(chapter.submission_batch_id));
}

function requireChapterBatchExpectedRevision(value, batch, chapter = null) {
  const expectedRevision = positiveInteger(value, "expectedRevision");
  const batchRevision = Number(batch.revision || 1);
  if (expectedRevision === batchRevision) return;
  if (chapter && expectedRevision === Number(chapter.revision || 1)) return;
  const error = conflict("revision_conflict");
  error.details = { expectedRevision, currentRevision: batchRevision };
  throw error;
}

function withReviewTransaction(callback) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = callback();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function reviewNovelSubmission({ item, decision, reviewNote, reviewerId }) {
  const status = decision === "approve" ? "published" : "rejected";
  run(
    `UPDATE ai_novels
     SET status = ?, review_note = ?, reviewed_by = ?,
         revision = revision + 1, reviewed_at = datetime('now'),
         published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
         updated_at = datetime('now')
     WHERE id = ? AND status = 'pending'`,
    [status, reviewNote, reviewerId, status, item.id],
  );
  run(
    `UPDATE ai_novel_chapters
     SET status = ?, review_note = ?, reviewed_by = ?,
         revision = revision + 1, reviewed_at = datetime('now'),
         published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
         updated_at = datetime('now')
     WHERE novel_id = ? AND status = 'pending'`,
    [status, reviewNote, reviewerId, status, item.id],
  );
  recordNovelReviewEvent({
    novelId: item.id,
    chapterId: null,
    revision: Number(item.revision || 1),
    decision,
    note: reviewNote,
    reviewerId,
  });
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
}

function reviewMetadataRevision({ item, decision, reviewNote, reviewerId }) {
  const approved = decision === "approve";
  if (approved) {
    const applied = run(
      `UPDATE ai_novels
       SET title = ?, pen_name = ?, category = ?, cover_url = ?, description = ?,
           serialization_status = ?, revision = revision + 1,
           updated_at = datetime('now')
       WHERE id = ? AND status = 'published'`,
      [
        item.title,
        item.pen_name,
        item.category,
        item.cover_url,
        item.description,
        item.serialization_status,
        item.novel_id,
      ],
    );
    if (Number(applied.changes || 0) !== 1) {
      throw conflict("metadata_revision_apply_conflict");
    }
  }
  const status = approved ? "approved" : "rejected";
  const reviewed = run(
    `UPDATE ai_novel_metadata_revisions
     SET status = ?, review_note = ?, reviewed_by = ?, revision = revision + 1,
         reviewed_at = datetime('now'),
         published_at = CASE WHEN ? THEN datetime('now') ELSE '' END,
         updated_at = datetime('now')
     WHERE id = ? AND status = 'pending'`,
    [status, reviewNote, reviewerId, approved ? 1 : 0, item.id],
  );
  if (Number(reviewed.changes || 0) !== 1) {
    throw conflict("metadata_revision_review_conflict");
  }
  if (approved) {
    run(
      `UPDATE ai_novel_metadata_revisions
       SET cover_url = ''
       WHERE novel_id = ? AND status = 'approved' AND id <> ?
         AND cover_url <> ?`,
      [item.novel_id, item.id, item.cover_url],
    );
  }
  recordMetadataReviewEvent({
    novelId: item.novel_id,
    metadataRevisionId: item.id,
    revision: Number(item.revision || 1),
    decision,
    note: reviewNote,
    reviewerId,
  });
  run(
    `INSERT INTO system_notifications (user_id, title, content, category)
     VALUES (?, ?, ?, 'ai_novel_review')`,
    [
      item.user_id,
      approved ? "作品资料修改审核通过" : "作品资料需要调整",
      approved
        ? `《${item.title}》的标题、简介、封面或连载状态修改已生效。`
        : `《${item.novel_title}》的作品资料修改未通过审核：${reviewNote}`,
    ],
  );
  return {
    replacedCoverUrl: approved && item.novel_cover_url !== item.cover_url
      ? item.novel_cover_url
      : "",
  };
}

function reviewChapterSubmissionBatch({ batch, decision, reviewNote, reviewerId }) {
  const chapters = all(
    `SELECT *
     FROM ai_novel_chapters
     WHERE submission_batch_id = ? AND status = 'pending'
     ORDER BY sort_order, id`,
    [batch.id],
  );
  const chapterCount = chapters.length;
  if (!chapterCount || chapterCount !== Number(batch.chapter_count || 0)) {
    throw conflict("chapter_submission_batch_conflict");
  }

  const status = decision === "approve" ? "published" : "rejected";
  if (decision === "approve") {
    for (const chapter of chapters) {
      applyApprovedChapterRevision(chapter, reviewerId);
    }
  }

  const reviewedChapters = run(
    `UPDATE ai_novel_chapters
     SET status = ?, review_note = ?, reviewed_by = ?,
         revision = revision + 1, reviewed_at = datetime('now'),
         published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
         updated_at = datetime('now')
     WHERE submission_batch_id = ? AND status = 'pending'`,
    [status, reviewNote, reviewerId, status, batch.id],
  );
  if (Number(reviewedChapters.changes || 0) !== chapterCount) {
    throw conflict("chapter_submission_batch_conflict");
  }

  const reviewedBatch = run(
    `UPDATE ai_novel_chapter_submission_batches
     SET status = ?, review_note = ?, reviewed_by = ?, revision = revision + 1,
         reviewed_at = datetime('now'),
         published_at = CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END,
         updated_at = datetime('now')
     WHERE id = ? AND status = 'pending'`,
    [status, reviewNote, reviewerId, status, batch.id],
  );
  if (Number(reviewedBatch.changes || 0) !== 1) {
    throw conflict("chapter_submission_batch_review_conflict");
  }

  run(
    `UPDATE ai_novels
     SET revision = revision + 1, updated_at = datetime('now')
     WHERE id = ?`,
    [batch.novel_id],
  );
  recordNovelReviewEvent({
    novelId: batch.novel_id,
    chapterId: null,
    submissionBatchId: batch.id,
    revision: Number(batch.revision || 1),
    decision,
    note: reviewNote,
    reviewerId,
  });
  for (const chapter of chapters) {
    recordNovelReviewEvent({
      novelId: batch.novel_id,
      chapterId: chapter.id,
      submissionBatchId: batch.id,
      revision: Number(chapter.revision || 1),
      decision,
      note: reviewNote,
      reviewerId,
    });
  }
  run(
    `INSERT INTO system_notifications (user_id, title, content, category)
     VALUES (?, ?, ?, 'ai_novel_review')`,
    [
      batch.user_id,
      status === "published" ? "连载章节批次审核通过" : "连载章节批次需要修改",
      status === "published"
        ? `《${batch.novel_title}》本次提交的 ${chapterCount} 章已审核通过并发布。`
        : `《${batch.novel_title}》本次提交的 ${chapterCount} 章未通过审核，已全部退回：${reviewNote}`,
    ],
  );
  return { chapterCount, status };
}

async function uploadNovelCover(request) {
  let upload;
  try {
    upload = await request.file();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("novel_cover_file_too_large");
    }
    throw error;
  }
  if (!upload) throw badRequest("novel_cover_file_required");

  const mimeType = String(upload.mimetype || "").trim().toLowerCase();
  const extension = novelCoverExtensions.get(mimeType);
  if (!extension) throw badRequest("novel_cover_type_invalid");

  let bytes;
  try {
    bytes = await upload.toBuffer();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("novel_cover_file_too_large");
    }
    throw error;
  }
  if (!bytes.length) throw badRequest("novel_cover_file_required");
  if (bytes.length > maxCoverBytes || upload.file?.truncated) {
    throw payloadTooLarge("novel_cover_file_too_large");
  }
  if (!validateUploadBytes(mimeType, bytes)) {
    throw badRequest("novel_cover_content_invalid");
  }

  const fileName = await withUploadLock(request.user.id, async () => {
    try {
      await pruneOrphanedUserUploads({
        rootDir: config.rootDir,
        apiPrefix: config.apiPrefix,
        folders: novelCoverFolders,
        userId: request.user.id,
        referencedUrls: referencedUploadUrls(),
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: config.uploadOrphanGraceMs,
      });
    } catch (error) {
      warnNovelUploadFailure(request, "stale_orphan_prune", error);
    }

    const usage = await inspectUserUploadUsage({
      rootDir: config.rootDir,
      folders: novelCoverFolders,
      userId: request.user.id,
    });
    const maxFiles = Math.max(1, config.uploadMaxFilesPerUser);
    const maxBytes = Math.max(maxCoverBytes, config.uploadMaxBytesPerUser);
    if (usage.files >= maxFiles) throw badRequest("upload_file_quota_exceeded");
    if (usage.bytes + bytes.length > maxBytes) {
      throw badRequest("upload_storage_quota_exceeded");
    }

    const generated = `${request.user.id}-${Date.now()}-${randomUUID()}.${extension}`;
    await writeUploadAtomically({
      directory: path.join(config.rootDir, "data", "uploads", novelCoverFolder),
      fileName: generated,
      bytes,
    });
    return generated;
  });

  return {
    url: `${config.apiPrefix}/uploads/content/${novelCoverFolder}/${fileName}`,
    mimeType,
    size: bytes.length,
  };
}

async function serveNovelCover(rawFile, reply) {
  const file = String(rawFile || "");
  if (!/^[a-z0-9-]+\.(?:jpe?g|png|webp)$/i.test(file)) {
    throw badRequest("file is invalid");
  }
  if (isManagedUploadRetired(novelCoverFolder, file)) {
    throw notFound("file_not_found");
  }
  const filePath = path.join(
    config.rootDir,
    "data",
    "uploads",
    novelCoverFolder,
    file,
  );
  try {
    const info = await stat(filePath);
    if (!info.isFile()) throw notFound("file_not_found");
  } catch (error) {
    if (error?.statusCode === 404) throw error;
    if (error?.code !== "ENOENT") throw error;
    throw notFound("file_not_found");
  }
  return reply
    .header("Cache-Control", "public, max-age=31536000, immutable")
    .header("X-Content-Type-Options", "nosniff")
    .type(novelCoverContentType(file))
    .send(createReadStream(filePath));
}

function requireOwnedNovelCover(url, userId) {
  const key = managedUploadKeyFromUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: novelCoverFolders,
    userId,
  });
  if (!key) throw badRequest("novel_cover_upload_required");
  const separator = key.indexOf("/");
  const folder = key.slice(0, separator);
  const file = key.slice(separator + 1);
  const filePath = path.join(config.rootDir, "data", "uploads", folder, file);
  if (isManagedUploadRetired(folder, file) || !existsSync(filePath)) {
    throw badRequest("novel_cover_not_found");
  }
  return `${config.apiPrefix}/uploads/content/${key}`;
}

function requireOwnedCreatorNovel(id, userId) {
  const row = one("SELECT * FROM ai_novels WHERE id = ? AND user_id = ?", [
    id,
    userId,
  ]);
  if (!row) throw notFound("novel_not_found");
  return row;
}

function creatorNovelDetail(id, userId) {
  const row = creatorNovelRow(id);
  if (!row || Number(row.user_id) !== Number(userId)) {
    throw notFound("novel_not_found");
  }
  return novelDetailJson(row);
}

function adminNovelDetail(id) {
  const row = creatorNovelRow(id);
  if (!row) throw notFound("novel_not_found");
  return novelDetailJson(row);
}

function metadataRevisionRow(revisionId) {
  return one(
    `SELECT metadata.*, n.user_id, n.title AS novel_title,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_metadata_revisions metadata
     JOIN ai_novels n ON n.id = metadata.novel_id
     JOIN users u ON u.id = n.user_id
     WHERE metadata.id = ?`,
    [revisionId],
  );
}

function metadataRevisionDetail(revisionId) {
  const row = metadataRevisionRow(revisionId);
  if (!row) throw notFound("metadata_revision_not_found");
  const novel = creatorNovelRow(row.novel_id);
  if (!novel) throw notFound("novel_not_found");
  return {
    item: metadataRevisionJson(row),
    novel: creatorNovelJson(novel),
    reviews: metadataReviewEventRows(row.novel_id, revisionId),
  };
}

function chapterSubmissionBatchRow(batchId) {
  return one(
    `SELECT batch.*, n.user_id, n.title AS novel_title,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_chapter_submission_batches batch
     JOIN ai_novels n ON n.id = batch.novel_id
     JOIN users u ON u.id = n.user_id
     WHERE batch.id = ?`,
    [batchId],
  );
}

function chapterSubmissionBatchDetail(batchId) {
  const batch = chapterSubmissionBatchRow(batchId);
  if (!batch) throw notFound("chapter_submission_batch_not_found");
  const novel = creatorNovelRow(batch.novel_id);
  if (!novel) throw notFound("novel_not_found");
  const chapters = all(
    `SELECT c.*, n.title AS novel_title, n.user_id,
            original.title AS original_title,
            original.content AS original_content,
            original.sort_order AS original_sort_order,
            u.nickname AS owner_nickname, u.email AS owner_email
     FROM ai_novel_chapters c
     JOIN ai_novels n ON n.id = c.novel_id
     JOIN users u ON u.id = n.user_id
     LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
     WHERE c.submission_batch_id = ?
     ORDER BY COALESCE(original.sort_order, c.sort_order), c.id`,
    [batchId],
  ).map((chapter) => creatorChapterJson(chapter, true));
  return {
    item: chapterSubmissionBatchJson(batch),
    novel: creatorNovelJson(novel),
    chapters,
    reviews: chapterSubmissionBatchReviewEventRows(batch.novel_id, batchId),
  };
}

function novelDetailJson(row) {
  const novelId = Number(row.id);
  const metadataRevision = activeMetadataRevision(novelId);
  return {
    item: creatorNovelJson(row),
    chapters: creatorChapterRows(novelId).map((chapter) =>
      creatorChapterJson(chapter, true),
    ),
    reviews: reviewEventRows(novelId),
    metadataRevision: metadataRevision ? metadataRevisionJson(metadataRevision) : null,
    metadataReviews: metadataReviewEventRows(novelId),
  };
}

function reviewEventRows(novelId, chapterId) {
  const chapterWhere = chapterId === undefined
    ? ""
    : "AND e.chapter_id = ?";
  const params = chapterId === undefined ? [novelId] : [novelId, chapterId];
  return all(
    `SELECT e.*, u.nickname AS reviewer_nickname, u.email AS reviewer_email
     FROM ai_novel_review_events e
     JOIN users u ON u.id = e.reviewer_id
     WHERE e.novel_id = ? ${chapterWhere}
     ORDER BY e.created_at DESC, e.id DESC`,
    params,
  ).map(novelReviewEventJson);
}

function chapterSubmissionBatchReviewEventRows(novelId, batchId) {
  return all(
    `SELECT e.*, u.nickname AS reviewer_nickname, u.email AS reviewer_email
     FROM ai_novel_review_events e
     JOIN users u ON u.id = e.reviewer_id
     WHERE e.novel_id = ? AND e.submission_batch_id = ? AND e.chapter_id IS NULL
     ORDER BY e.created_at DESC, e.id DESC`,
    [novelId, batchId],
  ).map(novelReviewEventJson);
}

function novelReviewEventJson(event) {
  return {
    id: Number(event.id),
    novelId: Number(event.novel_id),
    chapterId: event.chapter_id == null ? null : Number(event.chapter_id),
    submissionBatchId: event.submission_batch_id == null
      ? null
      : Number(event.submission_batch_id),
    submissionRevision: Number(event.submission_revision || 1),
    decision: event.decision,
    note: event.note || "",
    reviewerId: Number(event.reviewer_id),
    reviewerNickname: event.reviewer_nickname || "",
    reviewerEmail: event.reviewer_email || "",
    createdAt: event.created_at || "",
  };
}

function recordNovelReviewEvent({
  novelId,
  chapterId,
  submissionBatchId = null,
  revision,
  decision,
  note,
  reviewerId,
}) {
  run(
    `INSERT INTO ai_novel_review_events
       (novel_id, chapter_id, submission_batch_id, submission_revision, decision, note, reviewer_id)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [novelId, chapterId, submissionBatchId, revision, decision, note || "", reviewerId],
  );
}

function structuredChapters(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw badRequest("chapters must be an array");
  if (value.length > maxChapterCount) {
    throw badRequest(`chapter count cannot exceed ${maxChapterCount}`);
  }
  let totalCharacters = 0;
  const seenTitles = new Set();
  return value.map((chapter, index) => {
    if (!chapter || typeof chapter !== "object" || Array.isArray(chapter)) {
      throw badRequest(`chapter ${index + 1} is invalid`);
    }
    const title = requiredString(chapter.title, `chapter ${index + 1} title`, 120);
    const content = requiredString(
      chapter.content,
      `chapter ${index + 1} content`,
      maxNovelCharacters,
    );
    const titleKey = title.toLocaleLowerCase();
    if (seenTitles.has(titleKey)) {
      throw badRequest(`chapter title is duplicated: ${title}`);
    }
    seenTitles.add(titleKey);
    totalCharacters += title.length + content.length;
    if (totalCharacters > maxNovelCharacters) {
      throw badRequest("novel content is too long");
    }
    const id = chapter.id == null ? null : positiveInteger(chapter.id, `chapter ${index + 1} id`);
    const publishedChapterId = chapter.publishedChapterId == null
      ? null
      : positiveInteger(
          chapter.publishedChapterId,
          `chapter ${index + 1} publishedChapterId`,
        );
    return { id, publishedChapterId, title, content };
  });
}

function savePublishedChapterDrafts(novelId, chapters) {
  const publishedRows = all(
    `SELECT * FROM ai_novel_chapters
     WHERE novel_id = ? AND status = 'published' AND replaces_chapter_id IS NULL`,
    [novelId],
  );
  const publishedById = new Map(publishedRows.map((row) => [Number(row.id), row]));
  const editableRows = all(
    `SELECT * FROM ai_novel_chapters
     WHERE novel_id = ? AND status IN ('draft', 'rejected')`,
    [novelId],
  );
  const pendingRows = all(
    `SELECT * FROM ai_novel_chapters
     WHERE novel_id = ? AND status = 'pending'`,
    [novelId],
  );
  const editableRevisions = new Map(
    editableRows
      .filter((row) => row.replaces_chapter_id != null)
      .map((row) => [Number(row.replaces_chapter_id), row]),
  );
  const pendingRevisions = new Map(
    pendingRows
      .filter((row) => row.replaces_chapter_id != null)
      .map((row) => [Number(row.replaces_chapter_id), row]),
  );
  const seenPublishedIds = new Set();

  for (const chapter of chapters.filter((item) => item.publishedChapterId != null)) {
    const publishedChapterId = Number(chapter.publishedChapterId);
    if (seenPublishedIds.has(publishedChapterId)) {
      throw badRequest("published chapter is duplicated");
    }
    seenPublishedIds.add(publishedChapterId);
    const original = publishedById.get(publishedChapterId);
    if (!original) throw badRequest("published chapter is invalid");

    const pendingRevision = pendingRevisions.get(publishedChapterId);
    if (pendingRevision) {
      if (
        pendingRevision.title !== chapter.title
        || pendingRevision.content !== chapter.content
      ) {
        throw conflict("chapter_revision_in_progress");
      }
      continue;
    }

    const editableRevision = editableRevisions.get(publishedChapterId);
    const unchanged = original.title === chapter.title && original.content === chapter.content;
    if (unchanged) {
      if (editableRevision) {
        run("DELETE FROM ai_novel_chapters WHERE id = ?", [editableRevision.id]);
      }
      continue;
    }

    if (editableRevision) {
      run(
        `UPDATE ai_novel_chapters
         SET title = ?, content = ?, status = 'draft', review_note = '',
             revision = revision + 1, updated_at = datetime('now')
         WHERE id = ?`,
        [chapter.title, chapter.content, editableRevision.id],
      );
      continue;
    }

    const revisionOrder = Number(
      one(
        `SELECT COALESCE(MIN(sort_order), 0) - 1 AS next_order
         FROM ai_novel_chapters WHERE novel_id = ?`,
        [novelId],
      )?.next_order ?? -1,
    );
    run(
      `INSERT INTO ai_novel_chapters
       (novel_id, title, content, sort_order, status, replaces_chapter_id)
       VALUES (?, ?, ?, ?, 'draft', ?)`,
      [novelId, chapter.title, chapter.content, revisionOrder, publishedChapterId],
    );
  }

  const additions = chapters.filter((item) => item.publishedChapterId == null);
  const editableAdditions = editableRows.filter((row) => row.replaces_chapter_id == null);
  const editableAdditionsById = new Map(
    editableAdditions.map((row) => [Number(row.id), row]),
  );
  const pendingAdditionsById = new Map(
    pendingRows
      .filter((row) => row.replaces_chapter_id == null)
      .map((row) => [Number(row.id), row]),
  );
  const retainedIds = new Set();
  const maximumOrder = Number(
    one(
      "SELECT COALESCE(MAX(sort_order), -1) AS maximum_order FROM ai_novel_chapters WHERE novel_id = ?",
      [novelId],
    )?.maximum_order ?? -1,
  );
  editableAdditions.forEach((row, index) => {
    run("UPDATE ai_novel_chapters SET sort_order = ? WHERE id = ?", [
      maximumOrder + maxChapterCount + index + 1,
      row.id,
    ]);
  });
  let nextAdditionOrder = Number(
    one(
      `SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order
       FROM ai_novel_chapters
       WHERE novel_id = ? AND replaces_chapter_id IS NULL
         AND status NOT IN ('draft', 'rejected')`,
      [novelId],
    )?.next_order ?? 0,
  );

  for (const chapter of additions) {
    const existingId = chapter.id == null ? null : Number(chapter.id);
    const pendingAddition = existingId == null ? null : pendingAdditionsById.get(existingId);
    if (pendingAddition) {
      if (pendingAddition.title !== chapter.title || pendingAddition.content !== chapter.content) {
        throw conflict("serial_chapter_review_in_progress");
      }
      continue;
    }
    const editableAddition = existingId == null ? null : editableAdditionsById.get(existingId);
    if (existingId != null && !editableAddition) {
      throw badRequest("draft chapter is invalid");
    }
    if (editableAddition) {
      retainedIds.add(existingId);
      run(
        `UPDATE ai_novel_chapters
         SET title = ?, content = ?, sort_order = ?, status = 'draft',
             review_note = '', revision = revision + 1,
             updated_at = datetime('now')
         WHERE id = ?`,
        [chapter.title, chapter.content, nextAdditionOrder, existingId],
      );
    } else {
      run(
        `INSERT INTO ai_novel_chapters
         (novel_id, title, content, sort_order, status)
         VALUES (?, ?, ?, ?, 'draft')`,
        [novelId, chapter.title, chapter.content, nextAdditionOrder],
      );
    }
    nextAdditionOrder += 1;
  }

  for (const row of editableAdditions) {
    if (!retainedIds.has(Number(row.id))) {
      run("DELETE FROM ai_novel_chapters WHERE id = ?", [row.id]);
    }
  }
}

function effectivePublishedChapters(novelId, submittedRows) {
  const publishedRows = all(
    `SELECT * FROM ai_novel_chapters
     WHERE novel_id = ? AND status = 'published' AND replaces_chapter_id IS NULL
     ORDER BY sort_order, id`,
    [novelId],
  );
  const replacements = new Map();
  const additions = [];
  for (const chapter of submittedRows) {
    if (chapter.replaces_chapter_id == null) {
      additions.push(chapter);
      continue;
    }
    const sourceId = Number(chapter.replaces_chapter_id);
    if (replacements.has(sourceId)) throw badRequest("published chapter is duplicated");
    replacements.set(sourceId, chapter);
  }
  const publishedIds = new Set(publishedRows.map((chapter) => Number(chapter.id)));
  for (const sourceId of replacements.keys()) {
    if (!publishedIds.has(sourceId)) throw badRequest("published chapter is invalid");
  }
  return [
    ...publishedRows.map((chapter) => replacements.get(Number(chapter.id)) || chapter),
    ...additions,
  ];
}

function applyApprovedChapterRevision(chapter, reviewerId) {
  if (chapter.replaces_chapter_id == null) return;
  const result = run(
    `UPDATE ai_novel_chapters
     SET title = ?, content = ?, revision = revision + 1,
         reviewed_by = ?, reviewed_at = datetime('now'),
         published_at = datetime('now'), updated_at = datetime('now')
     WHERE id = ? AND novel_id = ? AND status = 'published'
       AND replaces_chapter_id IS NULL`,
    [
      chapter.title,
      chapter.content,
      reviewerId,
      chapter.replaces_chapter_id,
      chapter.novel_id,
    ],
  );
  if (Number(result.changes || 0) !== 1) {
    throw conflict("published_chapter_revision_conflict");
  }
}

function draftNovelMetadata(body, user, current = {}) {
  const value = (key, column, maxLength, fallback = "") =>
    Object.hasOwn(body, key)
      ? optionalString(body[key], maxLength)
      : optionalString(current[column], maxLength) || fallback;
  return {
    title: value("title", "title", 100, "未命名作品") || "未命名作品",
    penName:
      value("penName", "pen_name", 50, user.nickname || "匿名作者") ||
      user.nickname ||
      "匿名作者",
    category: value("category", "category", 40, "AI原创") || "AI原创",
    coverUrl: value("coverUrl", "cover_url", 1000),
    description: value("description", "description", 2000),
    serializationStatus: Object.hasOwn(body, "serializationStatus")
      ? novelSerializationStatus(body.serializationStatus)
      : novelSerializationStatus(current.serialization_status, { optional: true }) || "ongoing",
  };
}

function hasNovelMetadataFields(body) {
  return [
    "title",
    "penName",
    "category",
    "coverUrl",
    "description",
    "serializationStatus",
  ].some((key) => Object.hasOwn(body, key));
}

function activeMetadataRevision(novelId) {
  return one(
    `SELECT * FROM ai_novel_metadata_revisions
     WHERE novel_id = ? AND status IN ('draft', 'pending', 'rejected')
     ORDER BY id DESC
     LIMIT 1`,
    [novelId],
  );
}

function metadataRevisionJson(row) {
  return {
    id: Number(row.id),
    novelId: Number(row.novel_id),
    novelTitle: row.novel_title || "",
    title: row.title,
    penName: row.pen_name || "",
    category: row.category || "AI原创",
    coverUrl: row.cover_url || "",
    description: row.description || "",
    serializationStatus: row.serialization_status || "ongoing",
    status: row.status,
    reviewNote: row.review_note || "",
    revision: Number(row.revision || 1),
    ownerId: Number(row.user_id || 0),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    submittedAt: row.submitted_at || "",
    reviewedAt: row.reviewed_at || "",
    publishedAt: row.published_at || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function chapterSubmissionBatchJson(row) {
  return {
    id: Number(row.id),
    novelId: Number(row.novel_id),
    novelTitle: row.novel_title || "",
    status: row.status,
    reviewNote: row.review_note || "",
    revision: Number(row.revision || 1),
    chapterCount: Number(row.chapter_count || 0),
    ownerId: Number(row.user_id || 0),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    submittedAt: row.submitted_at || "",
    reviewedAt: row.reviewed_at || "",
    publishedAt: row.published_at || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
}

function metadataReviewEventRows(novelId, metadataRevisionId) {
  const revisionWhere = metadataRevisionId === undefined
    ? ""
    : "AND event.metadata_revision_id = ?";
  const params = metadataRevisionId === undefined
    ? [novelId]
    : [novelId, metadataRevisionId];
  return all(
    `SELECT event.*, u.nickname AS reviewer_nickname, u.email AS reviewer_email
     FROM ai_novel_metadata_review_events event
     JOIN users u ON u.id = event.reviewer_id
     WHERE event.novel_id = ? ${revisionWhere}
     ORDER BY event.created_at DESC, event.id DESC`,
    params,
  ).map((event) => ({
    id: Number(event.id),
    novelId: Number(event.novel_id),
    metadataRevisionId: Number(event.metadata_revision_id),
    submissionRevision: Number(event.submission_revision || 1),
    decision: event.decision,
    note: event.note || "",
    reviewerId: Number(event.reviewer_id),
    reviewerNickname: event.reviewer_nickname || "",
    reviewerEmail: event.reviewer_email || "",
    createdAt: event.created_at || "",
  }));
}

function recordMetadataReviewEvent({
  novelId,
  metadataRevisionId,
  revision,
  decision,
  note,
  reviewerId,
}) {
  run(
    `INSERT INTO ai_novel_metadata_review_events
       (novel_id, metadata_revision_id, submission_revision, decision, note, reviewer_id)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [novelId, metadataRevisionId, revision, decision, note || "", reviewerId],
  );
}

function metadataMatches(row, metadata) {
  return row.title === metadata.title
    && row.pen_name === metadata.penName
    && row.category === metadata.category
    && row.cover_url === metadata.coverUrl
    && row.description === metadata.description
    && (row.serialization_status || "ongoing") === metadata.serializationStatus;
}

function savePublishedMetadataDraft({ novel, metadata }) {
  const existing = activeMetadataRevision(novel.id);
  if (existing?.status === "pending") {
    if (!metadataMatches(existing, metadata)) {
      throw conflict("metadata_review_in_progress");
    }
    return "";
  }
  if (metadataMatches(novel, metadata)) {
    if (!existing) return "";
    run("DELETE FROM ai_novel_metadata_revisions WHERE id = ?", [existing.id]);
    return existing.cover_url !== novel.cover_url ? existing.cover_url : "";
  }
  if (existing) {
    run(
      `UPDATE ai_novel_metadata_revisions
       SET title = ?, pen_name = ?, category = ?, cover_url = ?, description = ?,
           serialization_status = ?, status = 'draft', review_note = '',
           reviewed_by = NULL, reviewed_at = '', revision = revision + 1,
           updated_at = datetime('now')
       WHERE id = ?`,
      [
        metadata.title,
        metadata.penName,
        metadata.category,
        metadata.coverUrl,
        metadata.description,
        metadata.serializationStatus,
        existing.id,
      ],
    );
    return existing.cover_url !== metadata.coverUrl
      && existing.cover_url !== novel.cover_url
      ? existing.cover_url
      : "";
  }
  run(
    `INSERT INTO ai_novel_metadata_revisions
       (novel_id, title, pen_name, category, cover_url, description,
        serialization_status, status)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'draft')`,
    [
      novel.id,
      metadata.title,
      metadata.penName,
      metadata.category,
      metadata.coverUrl,
      metadata.description,
      metadata.serializationStatus,
    ],
  );
  return "";
}

function validateMetadataRevisionForSubmission(metadata, novel) {
  requiredString(metadata.title, "title", 100);
  requiredString(metadata.pen_name, "penName", 50);
  requiredString(metadata.category, "category", 40);
  requiredString(metadata.description, "description", 2000);
  novelSerializationStatus(metadata.serialization_status);
  const coverUrl = requiredString(metadata.cover_url, "coverUrl", 1000);
  if (coverUrl !== novel.cover_url) {
    requireOwnedNovelCover(coverUrl, novel.user_id);
  }
}

function validateNovelForSubmission(
  novel,
  chapters,
  { requireManagedCover = true } = {},
) {
  requiredString(novel.title, "title", 100);
  requiredString(novel.pen_name, "penName", 50);
  requiredString(novel.category, "category", 40);
  requiredString(novel.description, "description", 2000);
  if (requireManagedCover) {
    const coverUrl = requiredString(novel.cover_url, "coverUrl", 1000);
    requireOwnedNovelCover(coverUrl, novel.user_id);
  }
  structuredChapters(
    chapters.map((chapter) => ({ title: chapter.title, content: chapter.content })),
  );
}

function requireExpectedRevision(value, currentRevision) {
  const revision = positiveInteger(value, "expectedRevision");
  if (revision !== Number(currentRevision || 1)) {
    const error = conflict("revision_conflict");
    error.details = { expectedRevision: revision, currentRevision: Number(currentRevision || 1) };
    throw error;
  }
}

function positiveInteger(value, name) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number <= 0) {
    throw badRequest(`${name} is invalid`);
  }
  return number;
}

function cleanupReplacedNovelCover(request, userId, url) {
  if (!url) return;
  try {
    const result = retireManagedUploadUrls({ userId, urls: [url] });
    if (result.failedCount > 0) scheduleRetiredUploadDeleteRetry(request.log);
  } catch (error) {
    warnNovelUploadFailure(request, "replaced_cover_retirement", error);
    scheduleManagedUploadRetirement({
      userId,
      urls: [url],
      logger: request.log,
    });
  }
}

function warnNovelUploadFailure(request, phase, error) {
  request.log?.warn?.(
    {
      uploadLifecycle: {
        phase,
        errorCode: error?.code || "novel_cover_cleanup_failed",
      },
    },
    "AI novel cover lifecycle cleanup failed",
  );
}

function novelCoverContentType(file) {
  const extension = path.extname(file).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  return "image/jpeg";
}

function payloadTooLarge(message) {
  const error = new Error(message);
  error.statusCode = 413;
  return error;
}

function novelPayload(body, user) {
  const title = requiredString(body.title, "title", 100);
  const penName = optionalString(body.penName, 50) || user.nickname || "匿名作者";
  const category = optionalString(body.category, 40) || "AI原创";
  const coverUrl = optionalString(body.coverUrl, 1000);
  const description = requiredString(body.description, "description", 2000);
  const serializationStatus = novelSerializationStatus(body.serializationStatus, {
    optional: true,
  }) || "ongoing";
  const content = requiredString(body.content, "content", maxNovelCharacters);
  const chapters = splitNovelChapters(content);
  if (!chapters.length) throw badRequest("novel content is empty");
  return {
    title,
    penName,
    category,
    coverUrl,
    description,
    serializationStatus,
    chapters,
  };
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
    if (chapters.length > maxChapterCount) {
      throw badRequest(`chapter count cannot exceed ${maxChapterCount}`);
    }
  }
  return chapters;
}

function insertNovel(payload) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = run(
      `INSERT INTO ai_novels
       (user_id, title, pen_name, category, cover_url, description,
        serialization_status, status, submitted_at, reviewed_by, reviewed_at,
        published_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), ?,
                 CASE WHEN ? IS NULL THEN '' ELSE datetime('now') END,
                 CASE WHEN ? = 'published' THEN datetime('now') ELSE '' END)`,
      [
        payload.userId,
        payload.title,
        payload.penName,
        payload.category,
        payload.coverUrl,
        payload.description,
        payload.serializationStatus,
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
            serialization_status = ?,
            status = ?, review_note = '', reviewed_by = ?,
           revision = revision + 1, submitted_at = datetime('now'),
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
        payload.serializationStatus,
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
     (novel_id, title, content, sort_order, status, submitted_at, reviewed_by,
      reviewed_at, published_at)
     VALUES (?, ?, ?, ?, ?,
             CASE WHEN ? IN ('pending', 'published') THEN datetime('now') ELSE '' END,
             ?,
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
     LEFT JOIN ai_novel_chapters c ON c.novel_id = n.id
       AND c.status = 'published' AND c.replaces_chapter_id IS NULL
     WHERE n.id = ? AND n.status = 'published'
     GROUP BY n.id`,
    [id],
  );
  if (!row) throw notFound("novel_not_found");
  return publicNovelJson(row);
}

function creatorNovelRow(id) {
  return one(
    `SELECT n.*, u.nickname AS owner_nickname, u.email AS owner_email,
             COUNT(CASE WHEN c.replaces_chapter_id IS NULL THEN c.id END) AS chapter_count,
             SUM(CASE WHEN c.status = 'published' AND c.replaces_chapter_id IS NULL THEN 1 ELSE 0 END) AS published_chapter_count,
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
    serializationStatus: row.serialization_status || "ongoing",
    status: row.serialization_status === "completed" ? "已完结" : "连载中",
    chapterCount: Number(row.chapter_count || 0),
    totalChapters: Number(row.chapter_count || 0),
    publishedAt: row.published_at || "",
    publishedChapterCount: Number(row.published_chapter_count || row.chapter_count || 0),
    pendingChapterCount: Number(row.pending_chapter_count || 0),
  };
}

function creatorChapterRows(novelId) {
  return all(
    `SELECT c.*, n.title AS novel_title, n.user_id,
            original.title AS original_title,
            original.content AS original_content,
            original.sort_order AS original_sort_order
     FROM ai_novel_chapters c
     JOIN ai_novels n ON n.id = c.novel_id
     LEFT JOIN ai_novel_chapters original ON original.id = c.replaces_chapter_id
     WHERE c.novel_id = ?
       AND (c.replaces_chapter_id IS NULL
            OR c.status IN ('draft', 'pending', 'rejected'))
     ORDER BY COALESCE(original.sort_order, c.sort_order),
              CASE WHEN c.replaces_chapter_id IS NULL THEN 0 ELSE 1 END,
              c.id`,
    [novelId],
  );
}

function creatorChapterJson(row, includeContent = false) {
  const item = {
    id: Number(row.id),
    novelId: Number(row.novel_id),
    novelTitle: row.novel_title || "",
    title: row.title,
    index: Number(row.original_sort_order ?? row.sort_order ?? 0),
    status: row.status,
    replacesChapterId: row.replaces_chapter_id == null
      ? null
      : Number(row.replaces_chapter_id),
    publishedChapterId: row.replaces_chapter_id == null
      ? (row.status === "published" ? Number(row.id) : null)
      : Number(row.replaces_chapter_id),
    changeType: row.replaces_chapter_id != null
      ? "update"
      : row.status === "published"
        ? "published"
        : "add",
    reviewNote: row.review_note || "",
    revision: Number(row.revision || 1),
    submissionBatchId: row.submission_batch_id == null
      ? null
      : Number(row.submission_batch_id),
    submittedAt: row.submitted_at || "",
    reviewedAt: row.reviewed_at || "",
    publishedAt: row.published_at || "",
    ownerId: Number(row.user_id || 0),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || "",
  };
  if (includeContent) {
    item.content = row.content || "";
    item.originalTitle = row.original_title || "";
    item.originalContent = row.original_content || "";
  }
  return item;
}

function creatorNovelJson(row) {
  return {
    ...publicNovelJson(row),
    numericId: Number(row.id),
    ownerId: Number(row.user_id),
    ownerNickname: row.owner_nickname || "",
    ownerEmail: row.owner_email || "",
    status: row.status,
    serializationStatus: row.serialization_status || "ongoing",
    reviewNote: row.review_note || "",
    revision: Number(row.revision || 1),
    submittedAt: row.submitted_at || "",
    reviewedAt: row.reviewed_at || "",
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

function aiNovelStatus(value, { optional = false } = {}) {
  const status = optionalString(value, 30);
  if (!status && optional) return "";
  if (!["draft", "pending", "published", "rejected"].includes(status)) {
    throw badRequest("status is invalid");
  }
  return status;
}

function novelSerializationStatus(value, { optional = false } = {}) {
  const status = optionalString(value, 30);
  if (!status && optional) return "";
  if (!["ongoing", "completed"].includes(status)) {
    throw badRequest("serialization status is invalid");
  }
  return status;
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

function conflict(message) {
  const error = new Error(message);
  error.statusCode = 409;
  return error;
}
