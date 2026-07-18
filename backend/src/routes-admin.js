import { all, db, one, run } from "./db.js";
import {
  fetchAnimeSourceDetail,
  searchAnimeSource,
} from "./anime-source.js";
import {
  appAnnouncementChanged,
  appAnnouncementSettings,
  normalizeAppAnnouncementSettings,
} from "./app-announcement.js";
import {
  fetchBilibiliSeason,
  fetchBilibiliDanmakuSummary,
  searchBilibiliBangumi,
  syncBilibiliDanmakuToTarget,
} from "./bilibili-danmaku.js";
import {
  chatBotProviderPresets,
  chatBotSkins,
  ensureChatBotMember,
  ensureChatBotWelcomeMessage,
  normalizeChatBotSkinId,
  resolveChatBotProviderSettings,
  testChatBotReply,
} from "./chat-bot.js";
import { growthFromUser, levelFromPoints, levelThresholds } from "./growth.js";
import { recordKnownUserBanIps } from "./chat-moderation.js";
import { chatJson } from "./websocket.js";
import {
  canonicalDanmakuVideoId,
  commentJson,
  danmakuJson,
} from "./routes-content.js";
import { defaultAsrHostUrl, iflytekSpeechDefaults } from "./speech-defaults.js";
import { encryptSettingSecret } from "./settings-secrets.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const visible = "status = 'visible'";
const manageableTargets = new Set(["comment", "danmaku", "chat", "user"]);
const bilibiliImportEmail = "bilibili-danmaku@import.local";
const chatRoomCategories = [
  { key: "novel", label: "小说" },
  { key: "anime", label: "动漫" },
  { key: "manga", label: "漫画" },
];

export async function adminRoutes(app) {
  app.get("/admin/summary", { preHandler: app.adminRequired }, async () => {
    const users = one("SELECT COUNT(*) AS count FROM users").count;
    const bannedUsers = one(
      "SELECT COUNT(*) AS count FROM users WHERE status = 'banned'",
    ).count;
    const comments = one(
      `SELECT COUNT(*) AS count FROM comments WHERE ${visible}`,
    ).count;
    const danmaku = one(
      `SELECT COUNT(*) AS count FROM danmaku WHERE ${visible}`,
    ).count;
    const chat = one(
      `SELECT COUNT(*) AS count FROM chat_messages WHERE ${visible}`,
    ).count;
    const reports = one(
      "SELECT COUNT(*) AS count FROM reports WHERE status = 'open'",
    ).count;
    const commentTargets = one(
      `SELECT COUNT(*) AS count
       FROM (
         SELECT 1 FROM comments
         WHERE ${visible}
         GROUP BY target_type, target_id, chapter_id, episode_id
       )`,
    ).count;
    const danmakuGroups = one(
      `SELECT COUNT(*) AS count
       FROM (
         SELECT 1 FROM danmaku
         WHERE ${visible}
         GROUP BY video_id
       )`,
    ).count;
    const chatRooms = one(
      `SELECT COUNT(*) AS count
       FROM (
         SELECT 1 FROM chat_messages
         WHERE ${visible}
         GROUP BY room_id
       )`,
    ).count;
    const aliases = one(
      "SELECT COUNT(*) AS count FROM danmaku_video_aliases",
    ).count;
    const reportStatus = statusCounts("reports", "status");

    return {
      users,
      bannedUsers,
      comments,
      danmaku,
      chat,
      reports,
      commentTargets,
      danmakuGroups,
      chatRooms,
      aliases,
      reportStatus,
      recentReports: reportRows({ status: "open", limit: 6 }),
      activeCommentTargets: commentGroups({ limit: 6 }).items,
      activeDanmakuGroups: danmakuGroupsQuery({ limit: 6 }).items,
      activeChatRooms: chatRoomsQuery({ limit: 6 }).items,
    };
  });

  app.get(
    "/admin/users",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const keyword = optionalString(request.query?.q, 80);
      const status = optionalString(request.query?.status, 20);
      const appVersionCode = Math.max(
        0,
        optionalInt(request.query?.appVersionCode, 0),
      );
      const where = [];
      const params = [];

      if (keyword) {
        where.push("(u.email LIKE ? OR u.nickname LIKE ?)");
        params.push(`%${keyword}%`, `%${keyword}%`);
      }
      if (status) {
        where.push("u.status = ?");
        params.push(status);
      }
      if (appVersionCode > 0) {
        where.push("latest_app.version_code = ?");
        params.push(appVersionCode);
      }

      const items = all(
        `WITH latest_app AS (
           SELECT i.*,
                  ROW_NUMBER() OVER (
                    PARTITION BY i.user_id
                    ORDER BY i.last_seen_at DESC, i.id DESC
                  ) AS row_number
           FROM user_app_installs i
         )
         SELECT
         u.id, u.email, u.nickname, u.avatar_url, u.gender, u.bio, u.signature,
         u.space_title, u.profile_banner_url, u.dynamic_avatar_url,
         u.profile_theme, u.points, u.sakura_coins, u.level, u.role, u.status,
         u.created_at, u.last_login_at, u.register_ip, u.last_login_ip,
         u.banned_until, u.ban_reason, u.chat_violation_total,
         u.chat_temp_ban_count,
         latest_app.version_name AS app_version_name,
         latest_app.version_code AS app_version_code,
         latest_app.platform AS app_platform,
         latest_app.device_model AS app_device_model,
         latest_app.os_version AS app_os_version,
         latest_app.last_seen_at AS app_last_seen_at,
         COUNT(DISTINCT c.id) AS comment_count,
         COUNT(DISTINCT d.id) AS danmaku_count,
         COUNT(DISTINCT m.id) AS chat_count,
         COUNT(DISTINCT rr.id) AS report_count,
         COUNT(DISTINCT rt.id) AS reported_count
       FROM users u
       LEFT JOIN latest_app
         ON latest_app.user_id = u.id AND latest_app.row_number = 1
       LEFT JOIN comments c ON c.user_id = u.id
       LEFT JOIN danmaku d ON d.user_id = u.id
       LEFT JOIN chat_messages m ON m.user_id = u.id
       LEFT JOIN reports rr ON rr.reporter_id = u.id
       LEFT JOIN reports rt
         ON rt.target_type = 'user' AND rt.target_id = CAST(u.id AS TEXT)
       ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
       GROUP BY u.id
       ORDER BY u.id DESC
       LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(userAdminJson);
      return { page, pageSize, items };
    },
  );

  app.get(
    "/admin/users/:id/activity",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("user id is invalid");
      const user = one(
        `SELECT id, email, nickname, avatar_url, gender, bio, signature,
                space_title, profile_banner_url, dynamic_avatar_url,
                profile_theme, points, sakura_coins, level,
                role, status, created_at, last_login_at, register_ip,
                last_login_ip, banned_until, ban_reason,
                chat_violation_total, chat_temp_ban_count,
                (SELECT i.version_name FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_version_name,
                (SELECT i.version_code FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_version_code,
                (SELECT i.platform FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_platform,
                (SELECT i.device_model FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_device_model,
                (SELECT i.os_version FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_os_version,
                (SELECT i.last_seen_at FROM user_app_installs i
                 WHERE i.user_id = users.id
                 ORDER BY i.last_seen_at DESC, i.id DESC LIMIT 1)
                  AS app_last_seen_at
         FROM users
         WHERE id = ?`,
        [id],
      );
      if (!user) throw badRequest("user not found");
      return {
        user: userAdminJson({
          ...user,
          comment_count: one(
            "SELECT COUNT(*) AS count FROM comments WHERE user_id = ?",
            [id],
          ).count,
          danmaku_count: one(
            "SELECT COUNT(*) AS count FROM danmaku WHERE user_id = ?",
            [id],
          ).count,
          chat_count: one(
            "SELECT COUNT(*) AS count FROM chat_messages WHERE user_id = ?",
            [id],
          ).count,
          report_count: one(
            "SELECT COUNT(*) AS count FROM reports WHERE reporter_id = ?",
            [id],
          ).count,
          reported_count: one(
            `SELECT COUNT(*) AS count
             FROM reports
             WHERE target_type = 'user' AND target_id = ?`,
            [String(id)],
          ).count,
        }),
        comments: all(
          `SELECT c.*, u.nickname, u.avatar_url
           FROM comments c
           JOIN users u ON u.id = c.user_id
           WHERE c.user_id = ?
           ORDER BY c.id DESC
           LIMIT 20`,
          [id],
        ).map(commentJson),
        danmaku: all(
          `SELECT d.*, u.nickname, u.avatar_url
           FROM danmaku d
           JOIN users u ON u.id = d.user_id
           WHERE d.user_id = ?
           ORDER BY d.id DESC
           LIMIT 20`,
          [id],
        ).map(danmakuJson),
        chat: all(
          `SELECT m.*, u.nickname, u.avatar_url
           FROM chat_messages m
           JOIN users u ON u.id = m.user_id
           WHERE m.user_id = ?
           ORDER BY m.id DESC
           LIMIT 20`,
          [id],
        ).map(chatJson),
        reports: reportRows({ reporterId: id, limit: 20 }),
      };
    },
  );

  app.get(
    "/admin/growth/rules",
    { preHandler: app.adminRequired },
    async () => ({ levels: levelThresholds }),
  );

  app.get(
    "/admin/settings",
    { preHandler: app.adminRequired },
    async () => adminSettingsPayload(),
  );

  app.patch(
    "/admin/settings",
    { preHandler: app.adminRequired },
    async (request) => {
      const body = request.body || {};
      saveSettingGroup(
        "iflytek_asr",
        normalizeIflytekAsrSettings(body.iflytekAsr || {}),
        [
          "productType",
          "appId",
          "apiKey",
          "secretKey",
          "apiSecret",
          "hostUrl",
          "enabled",
        ],
      );
      saveSettingGroup(
        "iflytek_tts",
        normalizeIflytekTtsSettings(body.iflytekTts || {}),
        ["appId", "apiKey", "apiSecret", "hostUrl", "enabled"],
      );
      const appAnnouncementBody = normalizeAppAnnouncementSettings(
        body.appAnnouncement || {},
      );
      if (appAnnouncementChanged(appAnnouncementBody)) {
        appAnnouncementBody.version = String(Date.now());
      }
      saveSettingGroup("app_announcement", appAnnouncementBody, [
        "enabled",
        "title",
        "content",
        "version",
      ]);
      const rawChatBotBody = {
        ...(body.chatBot || {}),
        skinId: normalizeChatBotSkinId(body.chatBot?.skinId),
      };
      const chatBotBody = resolveChatBotProviderSettings({
        ...rawChatBotBody,
        ...(String(rawChatBotBody.apiKey || "").trim() &&
        rawChatBotBody.enabled === undefined
          ? { enabled: true }
          : {}),
      });
      saveSettingGroup("chat_bot", chatBotBody, [
        "enabled",
        "provider",
        "baseUrl",
        "apiKey",
        "model",
        "botName",
        "avatarUrl",
        "skinId",
        "triggerMode",
        "systemPrompt",
      ]);
      return adminSettingsPayload();
    },
  );

  app.post(
    "/admin/settings/chat-bot/test",
    { preHandler: app.adminRequired },
    async (request) => {
      const body = request.body || {};
      const chatBotBody = body.chatBot || {};
      try {
        const result = await testChatBotReply({
          content: optionalString(body.message, 500) || "你好，小樱",
          overrides: {
            provider: optionalString(chatBotBody.provider, 40) || undefined,
            baseUrl: optionalString(chatBotBody.baseUrl, 800) || undefined,
            apiKey: optionalString(chatBotBody.apiKey, 800) || undefined,
            model: optionalString(chatBotBody.model, 120) || undefined,
            botName: optionalString(chatBotBody.botName, 40) || undefined,
            avatarUrl: optionalString(chatBotBody.avatarUrl, 800) || undefined,
            skinId: normalizeChatBotSkinId(chatBotBody.skinId),
            triggerMode: optionalString(chatBotBody.triggerMode, 20) || undefined,
            systemPrompt:
              optionalString(chatBotBody.systemPrompt, 4000) || undefined,
          },
        });
        return { ok: true, ...result };
      } catch (error) {
        throw badRequest(chatBotTestErrorMessage(error));
      }
    },
  );

  app.patch(
    "/admin/users/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("user id is invalid");
      const body = request.body || {};
      const status = optionalString(request.body?.status, 20);
      const role = optionalString(request.body?.role, 20);
      const nickname = optionalString(body.nickname, 32);
      const signature = optionalString(body.signature, 80);
      const bio = optionalString(body.bio, 140);
      const gender = optionalString(body.gender, 20);
      const points =
        Object.hasOwn(body, "points") && body.points !== ""
          ? Math.max(0, optionalInt(body.points, 0))
          : null;
      const sakuraCoinsDelta =
        Object.hasOwn(body, "sakuraCoinsDelta") && body.sakuraCoinsDelta !== ""
          ? optionalInt(body.sakuraCoinsDelta, 0)
          : null;
      const sakuraCoins =
        Object.hasOwn(body, "sakuraCoins") && body.sakuraCoins !== ""
          ? Math.max(0, optionalInt(body.sakuraCoins, 0))
          : null;
      if (status && !["active", "banned"].includes(status)) {
        throw badRequest("status is invalid");
      }
      if (role && !["user", "admin"].includes(role)) {
        throw badRequest("role is invalid");
      }
      if (gender && !["male", "female", "private"].includes(gender)) {
        throw badRequest("gender is invalid");
      }
      if (id === request.user.id && status === "banned") {
        throw badRequest("cannot ban yourself");
      }
      if (nickname) {
        run(
          `UPDATE users
           SET nickname = ?,
               signature = ?,
               bio = ?,
               gender = COALESCE(NULLIF(?, ''), gender),
               updated_at = datetime('now')
           WHERE id = ?`,
          [nickname, signature, bio, gender, id],
        );
      }
      if (points != null) {
        run(
          `UPDATE users
           SET points = ?,
               level = ?,
               updated_at = datetime('now')
           WHERE id = ?`,
          [points, levelFromPoints(points), id],
        );
      }
      if (sakuraCoins != null) {
        run(
          `UPDATE users
           SET sakura_coins = ?, updated_at = datetime('now')
           WHERE id = ?`,
          [sakuraCoins, id],
        );
      } else if (sakuraCoinsDelta != null && sakuraCoinsDelta !== 0) {
        run(
          `UPDATE users
           SET sakura_coins = MAX(0, sakura_coins + ?),
               updated_at = datetime('now')
           WHERE id = ?`,
          [sakuraCoinsDelta, id],
        );
        run(
          `INSERT INTO user_reward_events
             (user_id, action, coins_delta, description, related_type, related_id)
           VALUES (?, 'admin_adjust_coins', ?, '后台调整樱花币', 'admin', ?)`,
          [id, sakuraCoinsDelta, String(request.user.id)],
        );
      }
      if (status) {
        run(
          `UPDATE users
           SET status = ?,
               banned_until = CASE WHEN ? = 'active' THEN '' ELSE banned_until END,
               ban_reason = CASE WHEN ? = 'active' THEN '' ELSE ban_reason END,
               updated_at = datetime('now')
           WHERE id = ?`,
          [status, status, status, id],
        );
        if (status === "banned") recordKnownUserBanIps(id, "admin_ban");
      }
      if (role) {
        run(
          `UPDATE users
           SET role = ?, updated_at = datetime('now')
           WHERE id = ?`,
          [role, id],
        );
      }
      return { ok: true };
    },
  );

  app.get(
    "/admin/comments",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const keyword = optionalString(request.query?.q, 120);
      const status = optionalString(request.query?.status, 20);
      const targetType = optionalString(request.query?.targetType, 32);
      const where = [];
      const params = [];
      if (keyword) {
        where.push(
          "(c.content LIKE ? OR c.target_id LIKE ? OR c.chapter_id LIKE ? OR c.episode_id LIKE ? OR u.nickname LIKE ?)",
        );
        params.push(
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
        );
      }
      if (status) {
        where.push("c.status = ?");
        params.push(status);
      }
      if (targetType) {
        where.push("c.target_type = ?");
        params.push(targetType);
      }
      const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
      const items = all(
        `SELECT c.*, u.nickname, u.avatar_url
         FROM comments c
         JOIN users u ON u.id = c.user_id
         ${clause}
         ORDER BY c.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(commentJson);
      const total = Number(
        one(
          `SELECT COUNT(*) AS count
           FROM comments c
           JOIN users u ON u.id = c.user_id
           ${clause}`,
          params,
        )?.count || 0,
      );
      return {
        page,
        pageSize,
        total,
        statusCounts: statusCounts("comments", "status"),
        targetCounts: groupedCounts("comments", "target_type"),
        items,
      };
    },
  );

  app.get(
    "/admin/comments/:id/context",
    { preHandler: app.adminRequired },
    async (request) => commentModerationContext(request.params.id),
  );

  app.patch(
    "/admin/comments/:id/status",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = positiveAdminId(request.params.id, "comment id");
      const status = requiredString(request.body?.status, "status", 20);
      if (!["visible", "deleted"].includes(status)) {
        throw badRequest("comment status is invalid");
      }
      const result = run(
        `UPDATE comments
         SET status = ?,
             deleted_at = CASE WHEN ? = 'deleted' THEN datetime('now') ELSE NULL END,
             updated_at = datetime('now')
         WHERE id = ?`,
        [status, status, id],
      );
      if (!result.changes) throw badRequest("comment not found");
      return { item: commentJson(commentModerationRow(id)) };
    },
  );

  app.get(
    "/admin/comments/groups",
    { preHandler: app.adminRequired },
    async (request) => commentGroups(request.query || {}),
  );

  app.get(
    "/admin/comments/target-search",
    { preHandler: app.adminRequired },
    async (request) => commentTargetSearch(request.query || {}),
  );

  app.get(
    "/admin/comments/targets/detail",
    { preHandler: app.adminRequired },
    async (request) =>
      commentTargetGroups(
        requiredString(request.query?.targetType, "targetType", 32),
        requiredString(request.query?.targetId, "targetId", 200),
        request.query || {},
      ),
  );

  app.get(
    "/admin/comments/groups/detail",
    { preHandler: app.adminRequired },
    async (request) => {
      const query = request.query || {};
      const targetType = requiredString(query.targetType, "targetType", 32);
      const targetId = requiredString(query.targetId, "targetId", 200);
      const chapterId = optionalString(query.chapterId, 200);
      const episodeId = optionalString(query.episodeId, 200);
      const keyword = optionalString(query.q, 120);
      const status = optionalString(query.status, 20) || "visible";
      const { page, pageSize, offset } = pageParams(query);
      const whereKeyword = keyword
        ? "AND (c.content LIKE ? OR u.nickname LIKE ?)"
        : "";
      const params = keyword
        ? [
            targetType,
            targetId,
            chapterId,
            episodeId,
            status,
            `%${keyword}%`,
            `%${keyword}%`,
          ]
        : [targetType, targetId, chapterId, episodeId, status];
      const group = one(
        `SELECT
           target_type,
           target_id,
           chapter_id,
           episode_id,
           '' AS target_title,
           '' AS chapter_title,
           '' AS episode_title,
           COUNT(*) AS comment_count,
           SUM(CASE WHEN parent_id IS NULL THEN 1 ELSE 0 END) AS thread_count,
           SUM(CASE WHEN parent_id IS NOT NULL THEN 1 ELSE 0 END) AS reply_count,
           ROUND(AVG(rating), 1) AS rating_avg,
           MAX(created_at) AS last_created_at
         FROM comments
         WHERE target_type = ?
           AND target_id = ?
           AND chapter_id = ?
           AND episode_id = ?
           AND status = ?
         GROUP BY target_type, target_id, chapter_id, episode_id`,
        [targetType, targetId, chapterId, episodeId, status],
      );
      if (!group) throw badRequest("comment group not found");
      const meta = one(
        `SELECT target_title, chapter_title, episode_title
         FROM comment_target_meta
         WHERE target_type = ?
           AND target_id = ?
           AND chapter_id = ?
           AND episode_id = ?`,
        [targetType, targetId, chapterId, episodeId],
      );
      const total = one(
        `SELECT COUNT(*) AS count
         FROM comments c
         JOIN users u ON u.id = c.user_id
         WHERE c.target_type = ?
           AND c.target_id = ?
           AND c.chapter_id = ?
           AND c.episode_id = ?
           AND c.status = ?
           ${whereKeyword}`,
        params,
      ).count;
      const items = all(
        `SELECT c.*, u.nickname, u.avatar_url
         FROM comments c
         JOIN users u ON u.id = c.user_id
         WHERE c.target_type = ?
           AND c.target_id = ?
           AND c.chapter_id = ?
           AND c.episode_id = ?
           AND c.status = ?
           ${whereKeyword}
         ORDER BY COALESCE(c.parent_id, c.id) DESC, c.parent_id IS NOT NULL ASC, c.id ASC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(commentJson);
      return {
        page,
        pageSize,
        total,
        totalPages: Math.max(1, Math.ceil(total / pageSize)),
        group: commentGroupJson({ ...group, ...(meta || {}) }),
        items,
      };
    },
  );

  app.delete(
    "/admin/comments/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("comment id is invalid");
      run(
        `UPDATE comments
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE id = ?`,
        [id],
      );
      return { ok: true };
    },
  );

  app.get(
    "/admin/danmaku",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const keyword = optionalString(request.query?.q, 120);
      const status = optionalString(request.query?.status, 20);
      const animeId = optionalString(request.query?.animeId, 120);
      const episodeId = optionalString(request.query?.episodeId, 200);
      const videoId = optionalString(request.query?.videoId, 300);
      const where = [];
      const params = [];
      if (keyword) {
        where.push(
          "(d.content LIKE ? OR d.video_id LIKE ? OR d.anime_id LIKE ? OR d.episode_id LIKE ? OR u.nickname LIKE ?)",
        );
        params.push(
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
          `%${keyword}%`,
        );
      }
      if (status) {
        where.push("d.status = ?");
        params.push(status);
      }
      if (animeId) {
        where.push("d.anime_id = ?");
        params.push(animeId);
      }
      if (episodeId) {
        where.push("d.episode_id = ?");
        params.push(episodeId);
      }
      if (videoId) {
        where.push("d.video_id = ?");
        params.push(videoId);
      }
      const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
      const items = all(
        `SELECT d.*, u.nickname, u.avatar_url, u.email AS user_email
         FROM danmaku d
         JOIN users u ON u.id = d.user_id
         ${clause}
         ORDER BY d.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(danmakuModerationJson);
      const total = Number(
        one(
          `SELECT COUNT(*) AS count
           FROM danmaku d
           JOIN users u ON u.id = d.user_id
           ${clause}`,
          params,
        )?.count || 0,
      );
      return {
        page,
        pageSize,
        total,
        statusCounts: statusCounts("danmaku", "status"),
        stats: danmakuModerationStats(),
        items,
      };
    },
  );

  app.get(
    "/admin/danmaku/:id/context",
    { preHandler: app.adminRequired },
    async (request) => danmakuModerationContext(request.params.id),
  );

  app.patch(
    "/admin/danmaku/:id/status",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = positiveAdminId(request.params.id, "danmaku id");
      const status = requiredString(request.body?.status, "status", 20);
      if (!["visible", "deleted"].includes(status)) {
        throw badRequest("danmaku status is invalid");
      }
      const result = run(
        `UPDATE danmaku
         SET status = ?,
             deleted_at = CASE WHEN ? = 'deleted' THEN datetime('now') ELSE NULL END
         WHERE id = ?`,
        [status, status, id],
      );
      if (!result.changes) throw badRequest("danmaku not found");
      return { item: danmakuModerationJson(danmakuModerationRow(id)) };
    },
  );

  app.get(
    "/admin/danmaku/groups",
    { preHandler: app.adminRequired },
    async (request) => danmakuGroupsQuery(request.query || {}),
  );

  app.get(
    "/admin/danmaku/anime-search",
    { preHandler: app.adminRequired },
    async (request) => danmakuAnimeSearch(request.query || {}),
  );

  app.get(
    "/admin/danmaku/anime/:animeId/episodes",
    { preHandler: app.adminRequired },
    async (request) =>
      danmakuEpisodeSearch(
        requiredString(request.params.animeId, "animeId", 120),
        request.query || {},
      ),
  );

  app.get(
    "/admin/danmaku/episodes/detail",
    { preHandler: app.adminRequired },
    async (request) =>
      danmakuEpisodeDetail(
        requiredString(request.query?.videoId, "videoId", 300),
        request.query || {},
      ),
  );

  app.get(
    "/admin/danmaku/groups/detail",
    { preHandler: app.adminRequired },
    async (request) =>
      danmakuGroupDetail(
        requiredString(request.query?.videoId, "videoId", 300),
        request.query || {},
      ),
  );

  app.get(
    "/admin/danmaku/groups/:videoId",
    { preHandler: app.adminRequired },
    async (request) =>
      danmakuGroupDetail(
        requiredString(request.params.videoId, "videoId", 300),
        request.query || {},
      ),
  );

  app.get(
    "/admin/danmaku/bilibili/search",
    { preHandler: app.adminRequired },
    async (request) =>
      searchBilibiliBangumi(requiredString(request.query?.q, "q", 120)),
  );

  app.get(
    "/admin/danmaku/bilibili/season/:seasonId",
    { preHandler: app.adminRequired },
    async (request) => fetchBilibiliSeason(request.params.seasonId),
  );

  app.get(
    "/admin/danmaku/bilibili/source/:cid/summary",
    { preHandler: app.adminRequired },
    async (request) => fetchBilibiliDanmakuSummary(request.params.cid),
  );

  app.post(
    "/admin/danmaku/bilibili/sync",
    { preHandler: app.adminRequired },
    async (request) => {
      const body = request.body || {};
      const target = normalizeBilibiliSyncTarget(body);
      const cid = optionalInt(body.cid);
      if (!cid) throw badRequest("bilibili cid is invalid");
      return syncBilibiliDanmakuToTarget({
        cid,
        limit: optionalInt(body.limit, 800),
        replace: body.replace !== false,
        ...target,
      });
    },
  );

  app.post(
    "/admin/danmaku/bilibili/batch-sync",
    { preHandler: app.adminRequired },
    async (request) => {
      const body = request.body || {};
      const season = await fetchBilibiliSeason(body.seasonId);
      const targets = Array.isArray(body.targets) ? body.targets : [];
      if (!targets.length) throw badRequest("targets are required");
      const limit = optionalInt(body.limit, 800);
      const replace = body.replace !== false;
      const skipSynced = body.skipSynced !== false;
      const results = [];
      for (const [index, rawTarget] of targets.entries()) {
        const episode =
          season.episodes.find(
            (item) => item.index === optionalInt(rawTarget.biliEpisodeIndex),
          ) || season.episodes[index];
        if (!episode?.cid) {
          results.push({
            ok: false,
            targetVideoId: rawTarget.targetVideoId || "",
            error: "bilibili episode not found",
          });
          continue;
        }
        try {
          const target = normalizeBilibiliSyncTarget(rawTarget);
          const importedCount = bilibiliImportedCountForTarget(target);
          if (skipSynced && importedCount > 0) {
            results.push({
              ok: true,
              skipped: true,
              targetVideoId: target.targetVideoId,
              canonicalVideoId: canonicalBilibiliTargetVideoId(target),
              inserted: 0,
              deleted: 0,
              bilibiliImportedCount: importedCount,
              biliEpisodeIndex: episode.index,
              biliTitle: episode.displayTitle,
            });
            continue;
          }
          const result = await syncBilibiliDanmakuToTarget({
            cid: episode.cid,
            limit,
            replace,
            ...target,
          });
          results.push({
            ...result,
            biliEpisodeIndex: episode.index,
            biliTitle: episode.displayTitle,
          });
        } catch (error) {
          results.push({
            ok: false,
            targetVideoId: rawTarget.targetVideoId || "",
            error: error.message || "sync failed",
          });
        }
      }
      return {
        ok: true,
        season: {
          seasonId: season.seasonId,
          title: season.title,
          episodes: season.episodes.length,
        },
        results,
      };
    },
  );

  app.delete(
    "/admin/danmaku/groups/:videoId/imported",
    { preHandler: app.adminRequired },
    async (request) => {
      const videoId = requiredString(request.params.videoId, "videoId", 300);
      const importUser = one(
        `SELECT id FROM users WHERE email = 'bilibili-danmaku@import.local'`,
      );
      if (!importUser) return { ok: true, deleted: 0 };
      const result = run(
        `UPDATE danmaku
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE video_id = ? AND user_id = ? AND status = 'visible'`,
        [videoId, importUser.id],
      );
      return { ok: true, deleted: result.changes ?? 0 };
    },
  );

  app.delete(
    "/admin/danmaku/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("danmaku id is invalid");
      run(
        `UPDATE danmaku
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE id = ?`,
        [id],
      );
      return { ok: true };
    },
  );

  app.get("/admin/chat", { preHandler: app.adminRequired }, async (request) => {
    const { page, pageSize, offset } = pageParams(request.query || {});
    const keyword = optionalString(request.query?.q, 120);
    const status = optionalString(request.query?.status, 20);
    const where = [];
    const params = [];
    if (keyword) {
      where.push("(m.content LIKE ? OR m.room_id LIKE ? OR u.nickname LIKE ?)");
      params.push(`%${keyword}%`, `%${keyword}%`, `%${keyword}%`);
    }
    if (status) {
      where.push("m.status = ?");
      params.push(status);
    }
    const items = all(
      `SELECT m.*, u.nickname, u.avatar_url
       FROM chat_messages m
       JOIN users u ON u.id = m.user_id
       ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
       ORDER BY m.id DESC
       LIMIT ? OFFSET ?`,
      [...params, pageSize, offset],
    ).map(chatJson);
    return { page, pageSize, items };
  });

  app.get(
    "/admin/chat/rooms",
    { preHandler: app.adminRequired },
    async (request) => chatRoomsQuery(request.query || {}),
  );

  app.post(
    "/admin/chat/rooms",
    { preHandler: app.adminRequired },
    async (request) => {
      const body = request.body || {};
      const name = requiredString(body.name, "name", 40);
      const roomId =
        normalizeChatRoomId(body.roomId) ||
        normalizeChatRoomId(name) ||
        `room-${Date.now()}`;
      const avatarUrl = optionalString(body.avatarUrl, 800);
      const minLevel = clampLevel(body.minLevel);
      const category = normalizeChatRoomCategory(body.category);
      const isOfficial = body.isOfficial === true ? 1 : 0;
      const botEnabled = body.botEnabled === false ? 0 : 1;
      run(
        `INSERT INTO chat_rooms
           (id, name, avatar_url, min_level, category, is_official, owner_id, bot_enabled)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           avatar_url = excluded.avatar_url,
           min_level = excluded.min_level,
           category = excluded.category,
           is_official = excluded.is_official,
           bot_enabled = excluded.bot_enabled,
           status = 'active',
           updated_at = datetime('now')`,
        [
          roomId,
          name,
          avatarUrl,
          minLevel,
          category,
          isOfficial,
          request.user.id,
          botEnabled,
        ],
      );
      ensureChatBotWelcomeMessage(roomId, name);
      return { ok: true, item: chatRoomAdminDetail(roomId) };
    },
  );

  app.patch(
    "/admin/chat/rooms/:roomId",
    { preHandler: app.adminRequired },
    async (request) => {
      const roomId = normalizeChatRoomId(request.params.roomId);
      const current = one("SELECT * FROM chat_rooms WHERE id = ?", [roomId]);
      if (!current) throw badRequest("chat room not found");
      const body = request.body || {};
      const name = optionalString(body.name, 40) || current.name;
      const avatarUrl = Object.hasOwn(body, "avatarUrl")
        ? optionalString(body.avatarUrl, 800)
        : current.avatar_url;
      const minLevel = Object.hasOwn(body, "minLevel")
        ? clampLevel(body.minLevel)
        : current.min_level;
      const category = Object.hasOwn(body, "category")
        ? normalizeChatRoomCategory(body.category)
        : current.category || "novel";
      const isOfficial = Object.hasOwn(body, "isOfficial")
        ? body.isOfficial === true
          ? 1
          : 0
        : current.is_official || 0;
      const status = optionalString(body.status, 20) || current.status;
      if (!["active", "hidden"].includes(status)) {
        throw badRequest("chat room status is invalid");
      }
      const botEnabled = Object.hasOwn(body, "botEnabled")
        ? body.botEnabled === true
          ? 1
          : 0
        : current.bot_enabled;
      run(
        `UPDATE chat_rooms
         SET name = ?,
             avatar_url = ?,
             min_level = ?,
             category = ?,
             is_official = ?,
             status = ?,
             bot_enabled = ?,
             updated_at = datetime('now')
         WHERE id = ?`,
        [name, avatarUrl, minLevel, category, isOfficial, status, botEnabled, roomId],
      );
      if (botEnabled) ensureChatBotMember(roomId);
      return { ok: true, item: chatRoomAdminDetail(roomId) };
    },
  );

  app.delete(
    "/admin/chat/rooms/:roomId",
    { preHandler: app.adminRequired },
    async (request) => {
      const roomId = normalizeChatRoomId(request.params.roomId);
      const current = one("SELECT * FROM chat_rooms WHERE id = ?", [roomId]);
      if (!current) throw badRequest("chat room not found");
      if (current.status === "deleted") {
        return { ok: true, item: chatRoomAdminDetail(roomId), dissolved: true };
      }
      run(
        `UPDATE chat_rooms
         SET status = 'deleted', updated_at = datetime('now')
         WHERE id = ?`,
        [roomId],
      );
      run("DELETE FROM chat_room_members WHERE room_id = ?", [roomId]);
      run(
        `UPDATE chat_messages
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE room_id = ? AND status = 'visible'`,
        [roomId],
      );
      return { ok: true, item: chatRoomAdminDetail(roomId), dissolved: true };
    },
  );

  app.get(
    "/admin/chat/rooms/detail",
    { preHandler: app.adminRequired },
    async (request) => {
      const roomId = requiredString(request.query?.roomId, "roomId", 120);
      const keyword = optionalString(request.query?.q, 120);
      const status = optionalString(request.query?.status, 20) || "visible";
      const whereKeyword = keyword
        ? "AND (m.content LIKE ? OR u.nickname LIKE ?)"
        : "";
      const params = keyword
        ? [roomId, status, `%${keyword}%`, `%${keyword}%`]
        : [roomId, status];
      const room = one(
        `SELECT
           r.id AS room_id,
           r.name,
           r.avatar_url,
           r.min_level,
           r.category,
           r.is_official,
           r.status AS room_status,
           r.bot_enabled,
           COUNT(m.id) AS message_count,
           COUNT(DISTINCT m.user_id) AS user_count,
           MAX(m.created_at) AS last_created_at,
           (
             SELECT m2.content
             FROM chat_messages m2
             WHERE m2.room_id = r.id
               AND m2.status = 'visible'
             ORDER BY m2.id DESC
             LIMIT 1
           ) AS latest_content
         FROM chat_rooms r
         LEFT JOIN chat_messages m
           ON m.room_id = r.id AND m.status = ?
         WHERE r.id = ?
         GROUP BY r.id`,
        [status, roomId],
      );
      if (!room) throw badRequest("chat room not found");
      const items = all(
        `SELECT m.*, u.nickname, u.avatar_url
         FROM chat_messages m
         JOIN users u ON u.id = m.user_id
         WHERE m.room_id = ?
           AND m.status = ?
           ${whereKeyword}
         ORDER BY m.id DESC
         LIMIT 500`,
        params,
      ).map(chatJson);
      return { room: chatRoomJson(room), items };
    },
  );

  app.delete(
    "/admin/chat/batch",
    { preHandler: app.adminRequired },
    async (request) => {
      const rawIds = Array.isArray(request.body?.ids) ? request.body.ids : [];
      const ids = [
        ...new Set(rawIds.map((id) => optionalInt(id)).filter((id) => id > 0)),
      ].slice(0, 500);
      if (!ids.length) throw badRequest("chat ids are required");
      const placeholders = ids.map(() => "?").join(",");
      const result = run(
        `UPDATE chat_messages
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE id IN (${placeholders})`,
        ids,
      );
      return { ok: true, deleted: result.changes ?? 0 };
    },
  );

  app.delete(
    "/admin/chat/rooms/clear",
    { preHandler: app.adminRequired },
    async (request) => {
      const roomId = requiredString(request.body?.roomId, "roomId", 120);
      const status = optionalString(request.body?.status, 20) || "visible";
      const result = run(
        `UPDATE chat_messages
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE room_id = ? AND status = ?`,
        [roomId, status],
      );
      return { ok: true, deleted: result.changes ?? 0 };
    },
  );

  app.get(
    "/admin/chat/keywords",
    { preHandler: app.adminRequired },
    async (request) => {
      const keyword = optionalString(request.query?.q, 80);
      const status = optionalString(request.query?.status, 20);
      const where = [];
      const params = [];
      if (keyword) {
        where.push("(keyword LIKE ? OR note LIKE ?)");
        params.push(`%${keyword}%`, `%${keyword}%`);
      }
      if (status) {
        where.push("status = ?");
        params.push(status);
      }
      const items = all(
        `SELECT *
         FROM chat_block_keywords
         ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
         ORDER BY status ASC, id DESC
         LIMIT 300`,
        params,
      ).map(chatKeywordJson);
      return { items };
    },
  );

  app.post(
    "/admin/chat/keywords",
    { preHandler: app.adminRequired },
    async (request) => {
      const keyword = requiredString(request.body?.keyword, "keyword", 80);
      const matchType =
        optionalString(request.body?.matchType, 20) || "contains";
      const severity = optionalString(request.body?.severity, 20) || "block";
      const note = optionalString(request.body?.note, 120);
      if (!["contains", "exact"].includes(matchType)) {
        throw badRequest("match type is invalid");
      }
      if (!["block"].includes(severity)) {
        throw badRequest("severity is invalid");
      }
      const result = run(
        `INSERT INTO chat_block_keywords
           (keyword, match_type, severity, status, note)
         VALUES (?, ?, ?, 'active', ?)
         ON CONFLICT(keyword) DO UPDATE SET
           match_type = excluded.match_type,
           severity = excluded.severity,
           status = 'active',
           note = excluded.note,
           updated_at = datetime('now')`,
        [keyword, matchType, severity, note],
      );
      return { ok: true, id: result.lastInsertRowid };
    },
  );

  app.patch(
    "/admin/chat/keywords/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("keyword id is invalid");
      const keyword = optionalString(request.body?.keyword, 80);
      const matchType = optionalString(request.body?.matchType, 20);
      const severity = optionalString(request.body?.severity, 20);
      const status = optionalString(request.body?.status, 20);
      const note = optionalString(request.body?.note, 120);
      if (matchType && !["contains", "exact"].includes(matchType)) {
        throw badRequest("match type is invalid");
      }
      if (severity && !["block"].includes(severity)) {
        throw badRequest("severity is invalid");
      }
      if (status && !["active", "inactive"].includes(status)) {
        throw badRequest("status is invalid");
      }
      const current = one("SELECT * FROM chat_block_keywords WHERE id = ?", [
        id,
      ]);
      if (!current) throw badRequest("keyword not found");
      run(
        `UPDATE chat_block_keywords
         SET keyword = ?,
             match_type = ?,
             severity = ?,
             status = ?,
             note = ?,
             updated_at = datetime('now')
         WHERE id = ?`,
        [
          keyword || current.keyword,
          matchType || current.match_type,
          severity || current.severity,
          status || current.status,
          request.body && Object.hasOwn(request.body, "note")
            ? note
            : current.note,
          id,
        ],
      );
      return { ok: true };
    },
  );

  app.delete(
    "/admin/chat/keywords/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("keyword id is invalid");
      run("DELETE FROM chat_block_keywords WHERE id = ?", [id]);
      return { ok: true };
    },
  );

  app.get(
    "/admin/chat/violations",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const keyword = optionalString(request.query?.q, 120);
      const userId = optionalInt(request.query?.userId);
      const where = [];
      const params = [];
      if (keyword) {
        where.push("(v.content LIKE ? OR v.keyword LIKE ? OR u.nickname LIKE ?)");
        params.push(`%${keyword}%`, `%${keyword}%`, `%${keyword}%`);
      }
      if (userId) {
        where.push("v.user_id = ?");
        params.push(userId);
      }
      const items = all(
        `SELECT v.*, u.nickname, u.email
         FROM chat_violations v
         JOIN users u ON u.id = v.user_id
         ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
         ORDER BY v.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, offset],
      ).map(chatViolationJson);
      return { page, pageSize, items };
    },
  );

  app.get(
    "/admin/blocked-ips",
    { preHandler: app.adminRequired },
    async (request) => {
      const keyword = optionalString(request.query?.q, 80);
      const where = [];
      const params = [];
      if (keyword) {
        where.push("(b.ip LIKE ? OR b.reason LIKE ? OR u.nickname LIKE ?)");
        params.push(`%${keyword}%`, `%${keyword}%`, `%${keyword}%`);
      }
      const items = all(
        `SELECT b.*, u.nickname, u.email
         FROM banned_registration_ips b
         LEFT JOIN users u ON u.id = b.user_id
         ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
         ORDER BY b.created_at DESC
         LIMIT 300`,
        params,
      ).map(blockedIpJson);
      return { items };
    },
  );

  app.post(
    "/admin/blocked-ips",
    { preHandler: app.adminRequired },
    async (request) => {
      const ip = requiredString(request.body?.ip, "ip", 80);
      const reason = optionalString(request.body?.reason, 120);
      const userId = optionalInt(request.body?.userId) || null;
      run(
        `INSERT INTO banned_registration_ips (ip, user_id, reason)
         VALUES (?, ?, ?)
         ON CONFLICT(ip) DO UPDATE SET
           user_id = excluded.user_id,
           reason = excluded.reason`,
        [ip, userId, reason || "admin_block"],
      );
      return { ok: true };
    },
  );

  app.delete(
    "/admin/blocked-ips/:ip",
    { preHandler: app.adminRequired },
    async (request) => {
      const ip = requiredString(request.params.ip, "ip", 80);
      run("DELETE FROM banned_registration_ips WHERE ip = ?", [ip]);
      return { ok: true };
    },
  );

  app.delete(
    "/admin/chat/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("chat id is invalid");
      run(
        `UPDATE chat_messages
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE id = ?`,
        [id],
      );
      return { ok: true };
    },
  );

  app.get(
    "/admin/reports",
    { preHandler: app.adminRequired },
    async (request) => {
      const { page, pageSize, offset } = pageParams(request.query || {});
      const status = optionalString(request.query?.status, 20);
      const targetType = optionalString(request.query?.targetType, 20);
      const keyword = optionalString(request.query?.q, 120);
      const items = reportRows({
        status,
        targetType,
        keyword,
        limit: pageSize,
        offset,
      });
      return {
        page,
        pageSize,
        total: reportCount({ status, targetType, keyword }),
        statusCounts: statusCounts("reports", "status"),
        targetCounts: groupedCounts("reports", "target_type"),
        items,
      };
    },
  );

  app.patch(
    "/admin/reports/:id",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("report id is invalid");
      const status = requiredString(request.body?.status, "status", 20);
      if (!["open", "resolved", "ignored"].includes(status)) {
        throw badRequest("status is invalid");
      }
      const result = run(
        `UPDATE reports
         SET status = ?,
             handled_at = CASE WHEN ? = 'open' THEN NULL ELSE datetime('now') END,
             handled_by = CASE WHEN ? = 'open' THEN NULL ELSE ? END
         WHERE id = ?`,
        [status, status, status, request.user.id, id],
      );
      if (!result.changes) throw badRequest("report not found");
      return { ok: true };
    },
  );

  app.post(
    "/admin/reports/:id/resolve-delete-target",
    { preHandler: app.adminRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("report id is invalid");
      const report = one("SELECT * FROM reports WHERE id = ?", [id]);
      if (!report) throw badRequest("report not found");
      if (!manageableTargets.has(report.target_type)) {
        throw badRequest("target type is invalid");
      }
      db.exec("BEGIN IMMEDIATE");
      try {
        const deleted = deleteReportTarget(report);
        run(
          `UPDATE reports
           SET status = 'resolved', handled_at = datetime('now'), handled_by = ?
           WHERE id = ?`,
          [request.user.id, id],
        );
        db.exec("COMMIT");
        return { ok: true, deleted };
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },
  );
}

function commentModerationContext(rawId) {
  const id = positiveAdminId(rawId, "comment id");
  const item = commentModerationRow(id);
  if (!item) throw badRequest("comment not found");
  const parent = item.parent_id ? commentModerationRow(item.parent_id) : null;
  const replies = all(
    `SELECT c.*, u.nickname, u.avatar_url
     FROM comments c
     JOIN users u ON u.id = c.user_id
     WHERE c.parent_id = ?
     ORDER BY c.id`,
    [id],
  ).map(commentJson);
  const meta = one(
    `SELECT target_title, chapter_title, episode_title
     FROM comment_target_meta
     WHERE target_type = ? AND target_id = ?
       AND chapter_id = ? AND episode_id = ?`,
    [item.target_type, item.target_id, item.chapter_id, item.episode_id],
  );
  const reports = all(
    `SELECT r.*, u.nickname AS reporter_nickname, h.nickname AS handler_nickname
     FROM reports r
     LEFT JOIN users u ON u.id = r.reporter_id
     LEFT JOIN users h ON h.id = r.handled_by
     WHERE r.target_type = 'comment' AND r.target_id = ?
     ORDER BY CASE r.status WHEN 'open' THEN 0 ELSE 1 END, r.id DESC`,
    [String(id)],
  ).map(reportJson);
  return {
    item: commentJson(item),
    parent: parent ? commentJson(parent) : null,
    replies,
    reports,
    target: {
      type: item.target_type,
      id: item.target_id,
      title: meta?.target_title || "",
      chapterId: item.chapter_id || "",
      chapterTitle: meta?.chapter_title || "",
      episodeId: item.episode_id || "",
      episodeTitle: meta?.episode_title || "",
    },
  };
}

function commentModerationRow(id) {
  return one(
    `SELECT c.*, u.nickname, u.avatar_url
     FROM comments c
     JOIN users u ON u.id = c.user_id
     WHERE c.id = ?`,
    [id],
  );
}

function positiveAdminId(value, label) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw badRequest(`${label} is invalid`);
  return id;
}

function danmakuModerationStats() {
  const row = one(
    `SELECT
       COUNT(DISTINCT CASE WHEN status = 'visible' THEN video_id END) AS video_count,
       COUNT(DISTINCT CASE WHEN status = 'visible' AND anime_id != '' THEN anime_id END) AS anime_count,
       COUNT(DISTINCT CASE WHEN status = 'visible' THEN user_id END) AS user_count
     FROM danmaku`,
  );
  const importedCount = Number(
    one(
      `SELECT COUNT(*) AS count
       FROM danmaku d
       JOIN users u ON u.id = d.user_id
       WHERE d.status = 'visible' AND u.email = ?`,
      [bilibiliImportEmail],
    )?.count || 0,
  );
  return {
    animeCount: Number(row?.anime_count || 0),
    videoCount: Number(row?.video_count || 0),
    userCount: Number(row?.user_count || 0),
    importedCount,
  };
}

function danmakuModerationContext(rawId) {
  const id = positiveAdminId(rawId, "danmaku id");
  const item = danmakuModerationRow(id);
  if (!item) throw badRequest("danmaku not found");
  const meta = one(
    `SELECT anime_title, episode_title
     FROM danmaku_episode_meta
     WHERE canonical_video_id = ?`,
    [item.video_id],
  );
  const aliases = all(
    `SELECT alias_video_id, canonical_video_id, anime_id, episode_id, source_name, created_at
     FROM danmaku_video_aliases
     WHERE canonical_video_id = ?
     ORDER BY source_name, id`,
    [item.video_id],
  ).map((row) => ({
    aliasVideoId: row.alias_video_id,
    canonicalVideoId: row.canonical_video_id,
    animeId: row.anime_id,
    episodeId: row.episode_id,
    sourceName: row.source_name,
    createdAt: row.created_at,
  }));
  const nearby = all(
    `SELECT d.*, u.nickname, u.avatar_url, u.email AS user_email
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     WHERE d.video_id = ?
       AND d.time_ms BETWEEN ? AND ?
       AND d.id != ?
     ORDER BY ABS(d.time_ms - ?), d.id
     LIMIT 30`,
    [
      item.video_id,
      Math.max(0, item.time_ms - 15000),
      item.time_ms + 15000,
      id,
      item.time_ms,
    ],
  ).map(danmakuModerationJson);
  const reports = all(
    `SELECT r.*, u.nickname AS reporter_nickname, h.nickname AS handler_nickname
     FROM reports r
     LEFT JOIN users u ON u.id = r.reporter_id
     LEFT JOIN users h ON h.id = r.handled_by
     WHERE r.target_type = 'danmaku' AND r.target_id = ?
     ORDER BY CASE r.status WHEN 'open' THEN 0 ELSE 1 END, r.id DESC`,
    [String(id)],
  ).map(reportJson);
  return {
    item: danmakuModerationJson(item),
    group: {
      videoId: item.video_id,
      animeId: item.anime_id || "unknown",
      animeTitle:
        cleanAdminTitle(meta?.anime_title) ||
        danmakuAnimeFallbackTitle(item.anime_id || "unknown"),
      episodeId: item.episode_id || item.video_id,
      episodeTitle: meta?.episode_title || item.episode_id || item.video_id,
      aliasCount: aliases.length,
      bilibiliImportedCount: bilibiliImportedCountForTarget({
        targetVideoId: item.video_id,
        animeId: item.anime_id,
        episodeId: item.episode_id,
      }),
    },
    aliases,
    nearby,
    reports,
  };
}

function danmakuModerationRow(id) {
  return one(
    `SELECT d.*, u.nickname, u.avatar_url, u.email AS user_email
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     WHERE d.id = ?`,
    [id],
  );
}

function danmakuModerationJson(row) {
  return {
    ...danmakuJson(row),
    isImported: row.user_email === bilibiliImportEmail,
  };
}

function commentGroups(query = {}) {
  const keyword = optionalString(query.q, 120);
  const limit = Math.max(1, Math.min(100, optionalInt(query.limit, 100)));
  const status = optionalString(query.status, 20) || "visible";
  const where = ["c.status = ?"];
  const params = [status];
  if (keyword) {
    where.push(
      `(c.target_type LIKE ?
        OR c.target_id LIKE ?
        OR c.chapter_id LIKE ?
        OR c.episode_id LIKE ?
        OR c.content LIKE ?
        OR u.nickname LIKE ?
        OR m.target_title LIKE ?
        OR m.chapter_title LIKE ?
        OR m.episode_title LIKE ?)`,
    );
    params.push(
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
    );
  }
  const items = all(
    `SELECT
       c.target_type,
       c.target_id,
       c.chapter_id,
       c.episode_id,
       COALESCE(NULLIF(m.target_title, ''), '') AS target_title,
       COALESCE(NULLIF(m.chapter_title, ''), '') AS chapter_title,
       COALESCE(NULLIF(m.episode_title, ''), '') AS episode_title,
       COUNT(*) AS comment_count,
       COUNT(DISTINCT c.user_id) AS user_count,
       SUM(CASE WHEN c.parent_id IS NULL THEN 1 ELSE 0 END) AS thread_count,
       SUM(CASE WHEN c.parent_id IS NOT NULL THEN 1 ELSE 0 END) AS reply_count,
       ROUND(AVG(c.rating), 1) AS rating_avg,
       MAX(c.created_at) AS last_created_at,
       (
         SELECT c2.content
         FROM comments c2
         WHERE c2.target_type = c.target_type
           AND c2.target_id = c.target_id
           AND c2.chapter_id = c.chapter_id
           AND c2.episode_id = c.episode_id
           AND c2.status = c.status
         ORDER BY c2.created_at DESC
         LIMIT 1
       ) AS latest_content
     FROM comments c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN comment_target_meta m
       ON m.target_type = c.target_type
      AND m.target_id = c.target_id
      AND m.chapter_id = c.chapter_id
      AND m.episode_id = c.episode_id
     WHERE ${where.join(" AND ")}
     GROUP BY c.target_type, c.target_id, c.chapter_id, c.episode_id,
       COALESCE(NULLIF(m.target_title, ''), ''),
       COALESCE(NULLIF(m.chapter_title, ''), ''),
       COALESCE(NULLIF(m.episode_title, ''), '')
     ORDER BY last_created_at DESC
     LIMIT ?`,
    [...params, limit],
  ).map(commentGroupJson);
  return { items };
}

function commentTargetSearch(query = {}) {
  const keyword = optionalString(query.q, 120);
  const limit = Math.max(1, Math.min(50, optionalInt(query.limit, 30)));
  const status = optionalString(query.status, 20) || "visible";
  if (!keyword) return { items: [], hint: "search_required" };
  const like = `%${keyword}%`;
  const items = all(
    `SELECT
       c.target_type,
       c.target_id,
       COALESCE(MAX(NULLIF(m.target_title, '')), '') AS target_title,
       COUNT(DISTINCT c.id) AS comment_count,
       COUNT(DISTINCT c.user_id) AS user_count,
       SUM(CASE WHEN c.parent_id IS NULL THEN 1 ELSE 0 END) AS thread_count,
       SUM(CASE WHEN c.parent_id IS NOT NULL THEN 1 ELSE 0 END) AS reply_count,
       ROUND(AVG(c.rating), 1) AS rating_avg,
       MAX(c.created_at) AS last_created_at,
       (
         SELECT c2.content
         FROM comments c2
         WHERE c2.target_type = c.target_type
           AND c2.target_id = c.target_id
           AND c2.status = c.status
         ORDER BY c2.created_at DESC
         LIMIT 1
       ) AS latest_content
     FROM comments c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN comment_target_meta m
       ON m.target_type = c.target_type
      AND m.target_id = c.target_id
      AND m.chapter_id = c.chapter_id
      AND m.episode_id = c.episode_id
     WHERE c.status = ?
       AND (
         c.target_type LIKE ?
         OR c.target_id LIKE ?
         OR c.chapter_id LIKE ?
         OR c.episode_id LIKE ?
         OR c.content LIKE ?
         OR u.nickname LIKE ?
         OR m.target_title LIKE ?
         OR m.chapter_title LIKE ?
         OR m.episode_title LIKE ?
       )
     GROUP BY c.target_type, c.target_id
     ORDER BY last_created_at DESC, comment_count DESC
     LIMIT ?`,
    [status, like, like, like, like, like, like, like, like, like, limit],
  ).map(commentTargetJson);
  return { items };
}

function commentTargetGroups(targetType, targetId, query = {}) {
  const keyword = optionalString(query.q, 120);
  const status = optionalString(query.status, 20) || "visible";
  const where = [
    "c.status = ?",
    "c.target_type = ?",
    "c.target_id = ?",
  ];
  const params = [status, targetType, targetId];
  if (keyword) {
    where.push(
      `(c.chapter_id LIKE ?
        OR c.episode_id LIKE ?
        OR c.content LIKE ?
        OR u.nickname LIKE ?
        OR m.chapter_title LIKE ?
        OR m.episode_title LIKE ?)`,
    );
    params.push(
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
    );
  }
  const items = all(
    `SELECT
       c.target_type,
       c.target_id,
       c.chapter_id,
       c.episode_id,
       COALESCE(MAX(NULLIF(m.target_title, '')), '') AS target_title,
       COALESCE(MAX(NULLIF(m.chapter_title, '')), '') AS chapter_title,
       COALESCE(MAX(NULLIF(m.episode_title, '')), '') AS episode_title,
       COUNT(*) AS comment_count,
       COUNT(DISTINCT c.user_id) AS user_count,
       SUM(CASE WHEN c.parent_id IS NULL THEN 1 ELSE 0 END) AS thread_count,
       SUM(CASE WHEN c.parent_id IS NOT NULL THEN 1 ELSE 0 END) AS reply_count,
       ROUND(AVG(c.rating), 1) AS rating_avg,
       MAX(c.created_at) AS last_created_at,
       (
         SELECT c2.content
         FROM comments c2
         WHERE c2.target_type = c.target_type
           AND c2.target_id = c.target_id
           AND c2.chapter_id = c.chapter_id
           AND c2.episode_id = c.episode_id
           AND c2.status = c.status
         ORDER BY c2.created_at DESC
         LIMIT 1
       ) AS latest_content
     FROM comments c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN comment_target_meta m
       ON m.target_type = c.target_type
      AND m.target_id = c.target_id
      AND m.chapter_id = c.chapter_id
      AND m.episode_id = c.episode_id
     WHERE ${where.join(" AND ")}
     GROUP BY c.target_type, c.target_id, c.chapter_id, c.episode_id
     ORDER BY last_created_at DESC
     LIMIT 200`,
    params,
  ).map(commentGroupJson);
  const target = items[0] || {
    targetType,
    targetId,
    targetTitle: "",
    commentCount: 0,
    userCount: 0,
    threadCount: 0,
    replyCount: 0,
    ratingAvg: null,
    lastCreatedAt: "",
    latestContent: "",
  };
  return { target, items };
}

function danmakuGroupsQuery(query = {}) {
  const keyword = optionalString(query.q, 120);
  const limit = Math.max(1, Math.min(100, optionalInt(query.limit, 100)));
  const status = optionalString(query.status, 20) || "visible";
  const where = ["d.status = ?"];
  const params = [status];
  if (keyword) {
    where.push(
      `(d.video_id LIKE ?
        OR d.anime_id LIKE ?
        OR d.episode_id LIKE ?
        OR d.content LIKE ?
        OR a.alias_video_id LIKE ?
        OR a.source_name LIKE ?)`,
    );
    params.push(
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
    );
  }
  const items = all(
    `SELECT
       d.video_id,
       d.anime_id,
       d.episode_id,
       COUNT(DISTINCT d.id) AS danmaku_count,
       COUNT(DISTINCT d.user_id) AS user_count,
       COUNT(DISTINCT a.id) AS alias_count,
       MIN(d.time_ms) AS min_time_ms,
       MAX(d.time_ms) AS max_time_ms,
       MAX(d.created_at) AS last_created_at,
       (
         SELECT d2.content
         FROM danmaku d2
         WHERE d2.video_id = d.video_id
           AND d2.status = d.status
         ORDER BY d2.created_at DESC
         LIMIT 1
       ) AS latest_content
     FROM danmaku d
     LEFT JOIN danmaku_video_aliases a
       ON a.canonical_video_id = d.video_id
     WHERE ${where.join(" AND ")}
     GROUP BY d.video_id, d.anime_id, d.episode_id
     ORDER BY last_created_at DESC, d.video_id ASC
     LIMIT ?`,
    [...params, limit],
  ).map(danmakuGroupJson);
  return { items };
}

async function danmakuAnimeSearch(query = {}) {
  const keyword = optionalString(query.q, 120);
  const limit = Math.max(1, Math.min(50, optionalInt(query.limit, 30)));
  const status = optionalString(query.status, 20) || "visible";
  const like = `%${keyword}%`;
  const searchClause = keyword
    ? `AND (
         d.anime_id LIKE ?
         OR d.episode_id LIKE ?
         OR d.video_id LIKE ?
         OR d.content LIKE ?
         OR m.anime_title LIKE ?
         OR m.episode_title LIKE ?
         OR a.alias_video_id LIKE ?
         OR a.source_name LIKE ?
       )`
    : "";
  const searchParams = keyword
    ? [like, like, like, like, like, like, like, like]
    : [];
  const danmakuItems = all(
    `SELECT
       COALESCE(NULLIF(d.anime_id, ''), 'unknown') AS anime_id,
       COALESCE(MAX(NULLIF(m.anime_title, '')), '') AS anime_title,
       COUNT(DISTINCT d.video_id) AS episode_count,
       COUNT(DISTINCT d.id) AS danmaku_count,
       COUNT(DISTINCT d.user_id) AS user_count,
       COUNT(DISTINCT a.id) AS alias_count,
       MAX(d.created_at) AS last_created_at
     FROM danmaku d
     LEFT JOIN danmaku_episode_meta m
       ON m.canonical_video_id = d.video_id
     LEFT JOIN danmaku_video_aliases a
       ON a.canonical_video_id = d.video_id
     WHERE d.status = ?
       ${searchClause}
     GROUP BY
       COALESCE(NULLIF(d.anime_id, ''), 'unknown')
     ORDER BY last_created_at DESC, danmaku_count DESC
     LIMIT ?`,
    [status, ...searchParams, limit],
  ).map((row) => {
    const animeTitle = cleanAdminTitle(row.anime_title);
    return {
      animeId: row.anime_id,
      animeTitle: animeTitle || danmakuAnimeFallbackTitle(row.anime_id),
      titleMissing: !animeTitle,
      episodeCount: row.episode_count || 0,
      danmakuCount: row.danmaku_count || 0,
      userCount: row.user_count || 0,
      aliasCount: row.alias_count || 0,
      lastCreatedAt: row.last_created_at,
    };
  });
  let sourceItems = [];
  if (keyword) {
    try {
      sourceItems = await searchAnimeSource(keyword, { limit });
    } catch {
      sourceItems = [];
    }
  }
  const items = mergeDanmakuAnimeCandidates(danmakuItems, sourceItems).slice(
    0,
    limit,
  );
  return { items };
}

async function danmakuEpisodeSearch(animeId, query = {}) {
  const keyword = optionalString(query.q, 120);
  const status = optionalString(query.status, 20) || "visible";
  const syncStatus = normalizeBilibiliSyncStatus(query.biliSyncStatus);
  const where = [
    "d.status = ?",
    "COALESCE(NULLIF(d.anime_id, ''), 'unknown') = ?",
  ];
  const params = [status, animeId];
  if (keyword) {
    where.push(
      `(d.episode_id LIKE ?
        OR d.video_id LIKE ?
        OR d.content LIKE ?
        OR m.episode_title LIKE ?
        OR a.alias_video_id LIKE ?
        OR a.source_name LIKE ?)`,
    );
    params.push(
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
      `%${keyword}%`,
    );
  }
  const danmakuItems = all(
    `SELECT
       d.video_id,
       COALESCE(NULLIF(d.anime_id, ''), 'unknown') AS anime_id,
       COALESCE(MAX(NULLIF(m.anime_title, '')), '') AS anime_title,
       COALESCE(NULLIF(d.episode_id, ''), d.video_id) AS episode_id,
       COALESCE(MAX(NULLIF(m.episode_title, '')), NULLIF(d.episode_id, ''), d.video_id) AS episode_title,
       COUNT(DISTINCT d.id) AS danmaku_count,
       COUNT(DISTINCT d.user_id) AS user_count,
       COUNT(DISTINCT a.id) AS alias_count,
       (
         SELECT COUNT(*)
         FROM danmaku imported
         JOIN users import_user ON import_user.id = imported.user_id
         WHERE imported.video_id = d.video_id
           AND imported.status = 'visible'
           AND import_user.email = ?
       ) AS bilibili_imported_count,
       MIN(d.time_ms) AS min_time_ms,
       MAX(d.time_ms) AS max_time_ms,
       MAX(d.created_at) AS last_created_at,
       (
         SELECT d2.content
         FROM danmaku d2
         WHERE d2.video_id = d.video_id
           AND d2.status = d.status
         ORDER BY d2.created_at DESC
         LIMIT 1
       ) AS latest_content
     FROM danmaku d
     LEFT JOIN danmaku_episode_meta m
       ON m.canonical_video_id = d.video_id
     LEFT JOIN danmaku_video_aliases a
       ON a.canonical_video_id = d.video_id
     WHERE ${where.join(" AND ")}
     GROUP BY
       d.video_id,
       COALESCE(NULLIF(d.anime_id, ''), 'unknown'),
       COALESCE(NULLIF(d.episode_id, ''), d.video_id)
     ${bilibiliSyncHavingClause(syncStatus)}
     ORDER BY episode_title ASC, last_created_at DESC
     LIMIT 200`,
    [bilibiliImportEmail, ...params],
  ).map((row) => {
    const animeTitle = cleanAdminTitle(row.anime_title);
    return {
      videoId: row.video_id,
      animeId: row.anime_id,
      animeTitle: animeTitle || danmakuAnimeFallbackTitle(row.anime_id),
      titleMissing: !animeTitle,
      episodeId: row.episode_id,
      episodeTitle: row.episode_title,
      danmakuCount: row.danmaku_count || 0,
      userCount: row.user_count || 0,
      aliasCount: row.alias_count || 0,
      bilibiliImportedCount: row.bilibili_imported_count || 0,
      bilibiliSyncStatus: danmakuBilibiliSyncStatus(
        row.bilibili_imported_count || 0,
      ),
      minTimeMs: row.min_time_ms,
      maxTimeMs: row.max_time_ms,
      lastCreatedAt: row.last_created_at,
      latestContent: row.latest_content || "",
    };
  });
  const detail = await fetchAnimeSourceDetail(animeId).catch(() => null);
  const items = mergeDanmakuEpisodeCandidates(
    danmakuItems,
    detail?.episodes || [],
    syncStatus,
  );
  return { items };
}

function mergeDanmakuAnimeCandidates(danmakuItems, sourceItems) {
  const byId = new Map();
  for (const item of sourceItems || []) {
    if (!item?.animeId) continue;
    byId.set(String(item.animeId), { ...item });
  }
  for (const item of danmakuItems || []) {
    if (!item?.animeId) continue;
    const key = String(item.animeId);
    const existing = byId.get(key);
    byId.set(key, {
      ...(existing || {}),
      ...item,
      animeTitle:
        cleanAdminTitle(item.animeTitle) ||
        existing?.animeTitle ||
        danmakuAnimeFallbackTitle(item.animeId),
      episodeCount: Math.max(item.episodeCount || 0, existing?.episodeCount || 0),
      danmakuCount: item.danmakuCount || 0,
      aliasCount: Math.max(item.aliasCount || 0, existing?.aliasCount || 0),
      source: existing?.source === "anime_source" ? "mixed" : item.source,
      sourceLabel: existing ? "本地动漫源 + 已有弹幕" : item.sourceLabel,
    });
  }
  return [...byId.values()].sort((a, b) => {
    const aDanmaku = Number(a.danmakuCount || 0);
    const bDanmaku = Number(b.danmakuCount || 0);
    if (aDanmaku !== bDanmaku) return bDanmaku - aDanmaku;
    return Number(b.episodeCount || 0) - Number(a.episodeCount || 0);
  });
}

function mergeDanmakuEpisodeCandidates(danmakuItems, sourceEpisodes, syncStatus) {
  const byVideoId = new Map();
  for (const item of sourceEpisodes || []) {
    const target = {
      ...item,
      bilibiliImportedCount: bilibiliImportedCountForTarget({
        targetVideoId: item.videoId,
        animeId: item.animeId,
        episodeId: item.episodeId,
        episodeTitle: item.episodeTitle,
      }),
    };
    target.bilibiliSyncStatus = danmakuBilibiliSyncStatus(
      target.bilibiliImportedCount,
    );
    byVideoId.set(item.videoId, target);
  }
  for (const item of danmakuItems || []) {
    byVideoId.set(item.videoId, {
      ...(byVideoId.get(item.videoId) || {}),
      ...item,
      targetAliases: byVideoId.get(item.videoId)?.targetAliases || [],
    });
  }
  return [...byVideoId.values()].filter((item) => {
    if (!syncStatus) return true;
    return (item.bilibiliSyncStatus || "unsynced") === syncStatus;
  });
}

function danmakuEpisodeDetail(videoId, query = {}) {
  const keyword = optionalString(query.q, 120);
  const status = optionalString(query.status, 20) || "visible";
  const { page, pageSize, offset } = pageParams(query);
  const fromMs = optionalInt(query.fromMs, 0);
  const toMs = optionalInt(query.toMs, 24 * 60 * 60 * 1000);
  const whereKeyword = keyword
    ? "AND (d.content LIKE ? OR u.nickname LIKE ?)"
    : "";
  const params = keyword
    ? [videoId, fromMs, toMs, status, `%${keyword}%`, `%${keyword}%`]
    : [videoId, fromMs, toMs, status];

  const group = one(
    `SELECT
       d.video_id,
       COALESCE(NULLIF(d.anime_id, ''), 'unknown') AS anime_id,
       COALESCE(MAX(NULLIF(m.anime_title, '')), '') AS anime_title,
       COALESCE(NULLIF(d.episode_id, ''), d.video_id) AS episode_id,
       COALESCE(MAX(NULLIF(m.episode_title, '')), NULLIF(d.episode_id, ''), d.video_id) AS episode_title,
       COUNT(*) AS danmaku_count,
       COUNT(DISTINCT d.user_id) AS user_count,
       (
         SELECT COUNT(*)
         FROM danmaku imported
         JOIN users import_user ON import_user.id = imported.user_id
         WHERE imported.video_id = d.video_id
           AND imported.status = 'visible'
           AND import_user.email = ?
       ) AS bilibili_imported_count,
       MIN(d.time_ms) AS min_time_ms,
       MAX(d.time_ms) AS max_time_ms,
       MAX(d.created_at) AS last_created_at
     FROM danmaku d
     LEFT JOIN danmaku_episode_meta m
       ON m.canonical_video_id = d.video_id
     WHERE d.video_id = ? AND d.status = ?
    GROUP BY
       d.video_id,
       COALESCE(NULLIF(d.anime_id, ''), 'unknown'),
       COALESCE(NULLIF(d.episode_id, ''), d.video_id)`,
    [bilibiliImportEmail, videoId, status],
  );
  if (!group) throw badRequest("danmaku group not found");

  const total = one(
    `SELECT COUNT(*) AS count
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     WHERE d.video_id = ?
       AND d.time_ms BETWEEN ? AND ?
       AND d.status = ?
       ${whereKeyword}`,
    params,
  ).count;
  const aliases = all(
    `SELECT alias_video_id, canonical_video_id, anime_id, episode_id, source_name, created_at
     FROM danmaku_video_aliases
     WHERE canonical_video_id = ?
     ORDER BY source_name ASC, id ASC`,
    [videoId],
  ).map((row) => ({
    aliasVideoId: row.alias_video_id,
    canonicalVideoId: row.canonical_video_id,
    animeId: row.anime_id,
    episodeId: row.episode_id,
    sourceName: row.source_name,
    createdAt: row.created_at,
  }));
  const buckets = all(
    `SELECT
       CAST(time_ms / 60000 AS INTEGER) AS minute,
       COUNT(*) AS count
     FROM danmaku
     WHERE video_id = ? AND status = ?
     GROUP BY CAST(time_ms / 60000 AS INTEGER)
     ORDER BY minute ASC`,
    [videoId, status],
  ).map((row) => ({
    minute: row.minute,
    count: row.count,
  }));
  const items = all(
    `SELECT d.*, u.nickname, u.avatar_url, u.email AS user_email
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     WHERE d.video_id = ?
       AND d.time_ms BETWEEN ? AND ?
       AND d.status = ?
       ${whereKeyword}
     ORDER BY d.time_ms ASC, d.id ASC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(danmakuModerationJson);
  return {
    page,
    pageSize,
    total,
    totalPages: Math.max(1, Math.ceil(total / pageSize)),
    group: {
      videoId: group.video_id,
      animeId: group.anime_id,
      animeTitle:
        cleanAdminTitle(group.anime_title) ||
        danmakuAnimeFallbackTitle(group.anime_id),
      titleMissing: !cleanAdminTitle(group.anime_title),
      episodeId: group.episode_id,
      episodeTitle: group.episode_title,
      danmakuCount: group.danmaku_count || 0,
      userCount: group.user_count || 0,
      aliasCount: aliases.length,
      minTimeMs: group.min_time_ms,
      maxTimeMs: group.max_time_ms,
      lastCreatedAt: group.last_created_at,
    },
    aliases,
    buckets,
    items,
  };
}

function danmakuGroupDetail(videoId, query = {}) {
  const keyword = optionalString(query.q, 120);
  const fromMs = optionalInt(query.fromMs, 0);
  const toMs = optionalInt(query.toMs, 24 * 60 * 60 * 1000);
  const status = optionalString(query.status, 20) || "visible";
  const whereKeyword = keyword
    ? "AND (d.content LIKE ? OR u.nickname LIKE ?)"
    : "";
  const params = keyword
    ? [videoId, fromMs, toMs, status, `%${keyword}%`, `%${keyword}%`]
    : [videoId, fromMs, toMs, status];
  const group = one(
    `SELECT
       video_id,
       anime_id,
       episode_id,
       COUNT(*) AS danmaku_count,
       COUNT(DISTINCT user_id) AS user_count,
       MIN(time_ms) AS min_time_ms,
       MAX(time_ms) AS max_time_ms,
       MAX(created_at) AS last_created_at
     FROM danmaku
     WHERE video_id = ? AND status = ?
     GROUP BY video_id, anime_id, episode_id`,
    [videoId, status],
  );
  if (!group) throw badRequest("danmaku group not found");

  const aliases = all(
    `SELECT alias_video_id, canonical_video_id, anime_id, episode_id, source_name, created_at
     FROM danmaku_video_aliases
     WHERE canonical_video_id = ?
     ORDER BY source_name ASC, id ASC`,
    [videoId],
  ).map((row) => ({
    aliasVideoId: row.alias_video_id,
    canonicalVideoId: row.canonical_video_id,
    animeId: row.anime_id,
    episodeId: row.episode_id,
    sourceName: row.source_name,
    createdAt: row.created_at,
  }));
  const buckets = all(
    `SELECT
       CAST(time_ms / 60000 AS INTEGER) AS minute,
       COUNT(*) AS count
     FROM danmaku
     WHERE video_id = ? AND status = ?
     GROUP BY CAST(time_ms / 60000 AS INTEGER)
     ORDER BY minute ASC`,
    [videoId, status],
  ).map((row) => ({
    minute: row.minute,
    count: row.count,
  }));
  const items = all(
    `SELECT d.*, u.nickname, u.avatar_url, u.email AS user_email
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     WHERE d.video_id = ?
       AND d.time_ms BETWEEN ? AND ?
       AND d.status = ?
       ${whereKeyword}
     ORDER BY d.time_ms ASC, d.id ASC
     LIMIT 5000`,
    params,
  ).map(danmakuModerationJson);
  return {
    group: danmakuGroupJson({
      ...group,
      alias_count: aliases.length,
    }),
    aliases,
    buckets,
    items,
  };
}

function normalizeBilibiliSyncTarget(raw = {}) {
  const targetVideoId = requiredString(raw.targetVideoId, "targetVideoId", 300);
  const animeId = optionalString(raw.animeId, 120);
  const animeTitle = optionalString(raw.animeTitle, 200);
  const episodeId = optionalString(raw.episodeId, 200);
  const episodeTitle = optionalString(raw.episodeTitle, 200) || episodeId;
  const sourceName = optionalString(raw.sourceName, 80) || "Bilibili";
  const targetAliases = Array.isArray(raw.targetAliases)
    ? raw.targetAliases
        .map((item) =>
          typeof item === "string" ? item : optionalString(item?.url, 300),
        )
        .filter(Boolean)
        .slice(0, 30)
    : [];
  return {
    targetVideoId,
    targetAliases,
    animeId,
    animeTitle,
    episodeId,
    episodeTitle,
    sourceName,
  };
}

function canonicalBilibiliTargetVideoId(target) {
  return canonicalDanmakuVideoId({
    animeId: target.animeId,
    episodeId: target.episodeId || target.episodeTitle,
    fallback: target.targetVideoId,
  });
}

function bilibiliImportedCountForTarget(target) {
  const canonicalVideoId = canonicalBilibiliTargetVideoId(target);
  if (!canonicalVideoId) return 0;
  return (
    one(
      `SELECT COUNT(*) AS count
       FROM danmaku d
       JOIN users u ON u.id = d.user_id
       WHERE d.video_id = ?
         AND d.status = 'visible'
         AND u.email = ?`,
      [canonicalVideoId, bilibiliImportEmail],
    )?.count || 0
  );
}

function normalizeBilibiliSyncStatus(value) {
  const text = optionalString(value, 20);
  return ["unsynced", "partial", "synced"].includes(text) ? text : "";
}

function bilibiliSyncHavingClause(status) {
  if (status === "unsynced") return "HAVING bilibili_imported_count = 0";
  if (status === "partial") {
    return "HAVING bilibili_imported_count > 0 AND bilibili_imported_count < 50";
  }
  if (status === "synced") return "HAVING bilibili_imported_count >= 50";
  return "";
}

function danmakuBilibiliSyncStatus(importedCount) {
  const count = Number(importedCount || 0);
  if (count <= 0) return "unsynced";
  return count >= 50 ? "synced" : "partial";
}

function chatBotTestErrorMessage(error) {
  const message = String(error?.message || error || "").trim();
  if (!message || message === "chat_bot_config_missing") {
    return "请先填写 NVIDIA API Key；接口地址和模型会自动配置";
  }
  if (/401|403|unauthorized|forbidden/i.test(message)) {
    return "机器人接口鉴权失败，请检查 API Key";
  }
  if (/429|rate.?limit|too many requests/i.test(message)) {
    return "机器人接口当前已限流或试用额度不足，请稍后重试并检查 NVIDIA 额度";
  }
  if (/404|not found/i.test(message)) {
    return "机器人接口地址不正确，请检查 URL 是否包含正确的 /v1 路径";
  }
  if (/timeout|ECONN|ENOTFOUND|fetch failed|network/i.test(message)) {
    return "无法连接机器人接口，请检查第三方站 URL 和网络";
  }
  if (/invalid json|provider returned invalid json/i.test(message)) {
    return "机器人接口返回格式异常，请确认 NVIDIA、OpenAI 或 Claude 服务状态";
  }
  return `机器人测试失败：${message.slice(0, 160)}`;
}

function normalizeIflytekAsrSettings(values) {
  const rawProductType = optionalString(values.productType, 20);
  const productType = Object.hasOwn(
    iflytekSpeechDefaults.asrHostUrls,
    rawProductType,
  )
    ? rawProductType
    : iflytekSpeechDefaults.asrProductType;
  return {
    ...values,
    productType,
    hostUrl:
      optionalString(values.hostUrl, 240) || defaultAsrHostUrl(productType),
  };
}

function normalizeIflytekTtsSettings(values) {
  const rest = { ...values };
  delete rest.voiceName;
  return {
    ...rest,
    hostUrl:
      optionalString(values.hostUrl, 240) || iflytekSpeechDefaults.ttsHostUrl,
  };
}

function adminSettingsPayload() {
  const appAnnouncement = appAnnouncementSettings();
  const chatBot = settingGroup("chat_bot", [
    ["enabled", false],
    ["provider", false],
    ["baseUrl", false],
    ["apiKey", true],
    ["model", false],
    ["botName", false],
    ["avatarUrl", false],
    ["skinId", false],
    ["triggerMode", false],
    ["systemPrompt", false],
  ]);
  const normalizedChatBot = resolveChatBotProviderSettings(chatBot);
  const iflytekAsr = settingGroup("iflytek_asr", [
    ["productType", false],
    ["appId", false],
    ["apiKey", true],
    ["secretKey", true],
    ["apiSecret", true],
    ["hostUrl", false],
    ["enabled", false],
  ]);
  const asrProductType = Object.hasOwn(
    iflytekSpeechDefaults.asrHostUrls,
    iflytekAsr.productType,
  )
    ? iflytekAsr.productType
    : iflytekSpeechDefaults.asrProductType;
  const iflytekTts = settingGroup("iflytek_tts", [
    ["appId", false],
    ["apiKey", true],
    ["apiSecret", true],
    ["hostUrl", false],
    ["enabled", false],
  ]);
  return {
    appAnnouncement: {
      enabled: appAnnouncement.enabled ? "true" : "false",
      title: appAnnouncement.title || "公告",
      content: appAnnouncement.content || "",
      version: appAnnouncement.version || "",
    },
    iflytekAsr: {
      ...iflytekAsr,
      productType: asrProductType,
      hostUrl: iflytekAsr.hostUrl || defaultAsrHostUrl(asrProductType),
      enabled: iflytekAsr.enabled || "false",
    },
    iflytekTts: {
      ...iflytekTts,
      hostUrl: iflytekTts.hostUrl || iflytekSpeechDefaults.ttsHostUrl,
      enabled: iflytekTts.enabled || "false",
    },
    speechDefaults: iflytekSpeechDefaults,
    chatBot: {
      ...normalizedChatBot,
      enabled: normalizedChatBot.enabled || "false",
      botName: normalizedChatBot.botName || "小樱",
      skinId: normalizeChatBotSkinId(normalizedChatBot.skinId || "sakura"),
      triggerMode: normalizedChatBot.triggerMode || "mention",
    },
    chatBotProviderPresets,
    chatBotSkins,
  };
}

function settingGroup(prefix, fields) {
  const rows = all(
    `SELECT key, value, is_secret, updated_at
     FROM app_settings
     WHERE key LIKE ?`,
    [`${prefix}.%`],
  );
  const map = new Map(rows.map((row) => [row.key, row]));
  const result = {};
  for (const [field, isSecret] of fields) {
    const key = `${prefix}.${field}`;
    const row = map.get(key);
    if (isSecret) {
      result[field] = {
        configured: Boolean(row?.value),
        updatedAt: row?.updated_at || "",
      };
    } else {
      result[field] = row?.value || "";
    }
  }
  return result;
}

function saveSettingGroup(prefix, values, allowedFields) {
  const secretFields = new Set(["apiKey", "apiSecret", "secretKey"]);
  for (const field of allowedFields) {
    if (!Object.hasOwn(values, field)) continue;
    const raw = values[field];
    if (raw == null) continue;
    const plainValue =
      field === "enabled" ? (raw === true || raw === "true" ? "true" : "false") : String(raw).trim();
    if (secretFields.has(field) && !plainValue) continue;
    const value = secretFields.has(field)
      ? encryptSettingSecret(plainValue)
      : plainValue;
    run(
      `INSERT INTO app_settings (key, value, is_secret)
       VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET
         value = excluded.value,
         is_secret = excluded.is_secret,
         updated_at = datetime('now')`,
      [`${prefix}.${field}`, value, secretFields.has(field) ? 1 : 0],
    );
  }
}

function chatRoomsQuery(query = {}) {
  const keyword = optionalString(query.q, 120);
  const limit = Math.max(1, Math.min(100, optionalInt(query.limit, 100)));
  const status = optionalString(query.status, 20) || "active";
  const where = ["r.status = ?"];
  const params = [status];
  const category = optionalString(query.category, 20);
  if (category) {
    where.push("r.category = ?");
    params.push(normalizeChatRoomCategory(category));
  }
  if (keyword) {
    where.push("(r.id LIKE ? OR r.name LIKE ? OR latest.content LIKE ?)");
    params.push(`%${keyword}%`, `%${keyword}%`, `%${keyword}%`);
  }
  const items = all(
    `SELECT
       r.id AS room_id,
       r.name,
       r.avatar_url,
       r.min_level,
       r.category,
       r.is_official,
       r.status AS room_status,
       r.bot_enabled,
       COUNT(latest.id) AS message_count,
       COUNT(DISTINCT latest.user_id) AS user_count,
       MAX(latest.created_at) AS last_created_at,
       (
         SELECT m2.content
         FROM chat_messages m2
         WHERE m2.room_id = r.id
           AND m2.status = 'visible'
         ORDER BY m2.id DESC
         LIMIT 1
       ) AS latest_content
     FROM chat_rooms r
     LEFT JOIN chat_messages latest
       ON latest.room_id = r.id AND latest.status = 'visible'
     WHERE ${where.join(" AND ")}
     GROUP BY r.id
     ORDER BY
       CASE r.category
         WHEN 'novel' THEN 1
         WHEN 'anime' THEN 2
         WHEN 'manga' THEN 3
         ELSE 9
       END,
       r.is_official DESC,
       last_created_at DESC
     LIMIT ?`,
    [...params, limit],
  ).map(chatRoomJson);
  return {
    items,
    categories: chatRoomCategories.map((item) => ({
      ...item,
      count: items.filter((room) => room.category === item.key).length,
      hot: isHotChatCategory(item.key, items),
    })),
  };
}

function chatRoomAdminDetail(roomId) {
  const row = one(
    `SELECT r.*,
            COUNT(DISTINCT m.user_id) AS active_user_count,
            COUNT(m.id) AS recent_message_count,
            MAX(m.created_at) AS last_message_at,
            (
              SELECT content
              FROM chat_messages latest
              WHERE latest.room_id = r.id AND latest.status = 'visible'
              ORDER BY latest.id DESC
              LIMIT 1
            ) AS latest_content
     FROM chat_rooms r
     LEFT JOIN chat_messages m
       ON m.room_id = r.id
      AND m.status = 'visible'
      AND m.created_at >= datetime('now', '-10 minutes')
     WHERE r.id = ?
     GROUP BY r.id`,
    [roomId],
  );
  return row ? chatRoomAdminJson(row) : null;
}

function chatRoomAdminJson(row) {
  const category = chatRoomCategory(row.category);
  return {
    roomId: row.id,
    id: row.id,
    name: row.name || row.id,
    avatarUrl: row.avatar_url || "",
    minLevel: row.min_level || 1,
    category: category.key,
    categoryLabel: category.label,
    isOfficial: Boolean(row.is_official),
    status: row.status || "active",
    botEnabled: Boolean(row.bot_enabled),
    activeUserCount: row.active_user_count || 0,
    recentMessageCount: row.recent_message_count || 0,
    lastMessageAt: row.last_message_at || "",
    latestContent: row.latest_content || "",
  };
}

function normalizeChatRoomId(value) {
  return String(value || "")
    .trim()
    .replace(/[^\w:.-]/g, "-")
    .replace(/-+/g, "-")
    .slice(0, 80);
}

function clampLevel(value) {
  return Math.max(1, Math.min(7, optionalInt(value, 1)));
}

function normalizeChatRoomCategory(value) {
  const raw = optionalString(value, 20) || "novel";
  return chatRoomCategories.some((item) => item.key === raw) ? raw : "novel";
}

function chatRoomCategory(value) {
  return (
    chatRoomCategories.find((item) => item.key === value) ||
    chatRoomCategories[0]
  );
}

function isHotChatCategory(category, rooms) {
  let hotCategory = "";
  let hotScore = 0;
  const scores = new Map(chatRoomCategories.map((item) => [item.key, 0]));
  for (const room of rooms) {
    const score =
      Number(room.messageCount || 0) * 2 + Number(room.userCount || 0);
    scores.set(room.category, (scores.get(room.category) || 0) + score);
  }
  for (const [key, score] of scores) {
    if (score > hotScore) {
      hotScore = score;
      hotCategory = key;
    }
  }
  return hotScore > 0 && hotCategory === category;
}

function reportRows({
  status = "",
  targetType = "",
  keyword = "",
  reporterId = 0,
  limit = 20,
  offset = 0,
} = {}) {
  const { clause, params } = reportFilter({
    status,
    targetType,
    keyword,
    reporterId,
  });
  return all(
    `SELECT r.*, u.nickname AS reporter_nickname, h.nickname AS handler_nickname
     FROM reports r
     LEFT JOIN users u ON u.id = r.reporter_id
     LEFT JOIN users h ON h.id = r.handled_by
     ${clause}
     ORDER BY
       CASE r.status WHEN 'open' THEN 0 WHEN 'resolved' THEN 1 ELSE 2 END,
       r.id DESC
     LIMIT ? OFFSET ?`,
    [...params, limit, offset],
  ).map(reportJson);
}

function reportCount(filters = {}) {
  const { clause, params } = reportFilter(filters);
  return Number(
    one(
      `SELECT COUNT(*) AS count
       FROM reports r
       LEFT JOIN users u ON u.id = r.reporter_id
       ${clause}`,
      params,
    )?.count || 0,
  );
}

function reportFilter({
  status = "",
  targetType = "",
  keyword = "",
  reporterId = 0,
} = {}) {
  const where = [];
  const params = [];
  if (status) {
    where.push("r.status = ?");
    params.push(status);
  }
  if (targetType) {
    where.push("r.target_type = ?");
    params.push(targetType);
  }
  if (reporterId) {
    where.push("r.reporter_id = ?");
    params.push(reporterId);
  }
  if (keyword) {
    where.push("(r.reason LIKE ? OR r.target_id LIKE ? OR u.nickname LIKE ?)");
    params.push(`%${keyword}%`, `%${keyword}%`, `%${keyword}%`);
  }
  return {
    clause: where.length ? `WHERE ${where.join(" AND ")}` : "",
    params,
  };
}

function reportJson(row) {
  const preview = targetPreview(row.target_type, row.target_id);
  return {
    id: row.id,
    targetType: row.target_type,
    targetId: row.target_id,
    reason: row.reason,
    status: row.status,
    createdAt: row.created_at,
    handledAt: row.handled_at,
    reporter: row.reporter_id
      ? { id: row.reporter_id, nickname: row.reporter_nickname || "" }
      : null,
    handler: row.handled_by
      ? { id: row.handled_by, nickname: row.handler_nickname || "" }
      : null,
    preview,
  };
}

function targetPreview(targetType, targetId) {
  if (targetType === "comment") {
    const row = one(
      `SELECT c.*, u.nickname, u.avatar_url
       FROM comments c
       LEFT JOIN users u ON u.id = c.user_id
       WHERE c.id = ?`,
      [targetId],
    );
    return row
      ? {
          type: "comment",
          status: row.status,
          content: row.content,
          targetType: row.target_type,
          targetId: row.target_id,
          chapterId: row.chapter_id,
          episodeId: row.episode_id,
          user: { id: row.user_id, nickname: row.nickname || "" },
          createdAt: row.created_at,
        }
      : null;
  }
  if (targetType === "danmaku") {
    const row = one(
      `SELECT d.*, u.nickname, u.avatar_url
       FROM danmaku d
       LEFT JOIN users u ON u.id = d.user_id
       WHERE d.id = ?`,
      [targetId],
    );
    return row
      ? {
          type: "danmaku",
          status: row.status,
          content: row.content,
          videoId: row.video_id,
          animeId: row.anime_id,
          episodeId: row.episode_id,
          timeMs: row.time_ms,
          user: { id: row.user_id, nickname: row.nickname || "" },
          createdAt: row.created_at,
        }
      : null;
  }
  if (targetType === "chat") {
    const row = one(
      `SELECT m.*, u.nickname, u.avatar_url
       FROM chat_messages m
       LEFT JOIN users u ON u.id = m.user_id
       WHERE m.id = ?`,
      [targetId],
    );
    return row
      ? {
          type: "chat",
          status: row.status,
          content: row.content,
          roomId: row.room_id,
          user: { id: row.user_id, nickname: row.nickname || "" },
          createdAt: row.created_at,
        }
      : null;
  }
  if (targetType === "user") {
    const row = one(
      `SELECT id, email, nickname, avatar_url, role, status, created_at, last_login_at
       FROM users
       WHERE id = ?`,
      [targetId],
    );
    return row
      ? {
          type: "user",
          id: row.id,
          email: row.email,
          nickname: row.nickname,
          role: row.role,
          status: row.status,
          createdAt: row.created_at,
          lastLoginAt: row.last_login_at,
        }
      : null;
  }
  return null;
}

function deleteReportTarget(report) {
  const targetId = optionalInt(report.target_id);
  if (!targetId) return 0;
  if (report.target_type === "comment") {
    return (
      run(
        `UPDATE comments
       SET status = 'deleted', deleted_at = datetime('now')
       WHERE id = ?`,
        [targetId],
      ).changes ?? 0
    );
  }
  if (report.target_type === "danmaku") {
    return (
      run(
        `UPDATE danmaku
       SET status = 'deleted', deleted_at = datetime('now')
       WHERE id = ?`,
        [targetId],
      ).changes ?? 0
    );
  }
  if (report.target_type === "chat") {
    return (
      run(
        `UPDATE chat_messages
       SET status = 'deleted', deleted_at = datetime('now')
       WHERE id = ?`,
        [targetId],
      ).changes ?? 0
    );
  }
  if (report.target_type === "user") {
    return (
      run(
        `UPDATE users
       SET status = 'banned', updated_at = datetime('now')
       WHERE id = ?`,
        [targetId],
      ).changes ?? 0
    );
  }
  return 0;
}

function userAdminJson(row) {
  return {
    id: row.id,
    email: row.email,
    nickname: row.nickname,
    avatarUrl: row.avatar_url || "",
    gender: row.gender || "private",
    bio: row.bio || "",
    signature: row.signature || "",
    spaceTitle: row.space_title || "",
    profileBannerUrl: row.profile_banner_url || "",
    dynamicAvatarUrl: row.dynamic_avatar_url || "",
    profileTheme: row.profile_theme || "sakura",
    growth: growthFromUser(row),
    role: row.role,
    status: row.status,
    registerIp: row.register_ip || "",
    lastLoginIp: row.last_login_ip || "",
    bannedUntil: row.banned_until || "",
    banReason: row.ban_reason || "",
    chatViolationTotal: row.chat_violation_total || 0,
    chatTempBanCount: row.chat_temp_ban_count || 0,
    createdAt: row.created_at,
    lastLoginAt: row.last_login_at,
    appInstall: row.app_version_name
      ? {
          versionName: row.app_version_name,
          versionCode: Number(row.app_version_code || 0),
          platform: row.app_platform || "",
          deviceModel: row.app_device_model || "",
          osVersion: row.app_os_version || "",
          lastSeenAt: row.app_last_seen_at || "",
        }
      : null,
    stats: {
      comments: row.comment_count || 0,
      danmaku: row.danmaku_count || 0,
      chat: row.chat_count || 0,
      reports: row.report_count || 0,
      reported: row.reported_count || 0,
    },
  };
}

function commentGroupJson(row) {
  const targetTitle = cleanAdminTitle(row.target_title);
  const chapterTitle = cleanAdminTitle(row.chapter_title);
  const episodeTitle = cleanAdminTitle(row.episode_title);
  return {
    key: [
      row.target_type,
      row.target_id,
      row.chapter_id || "",
      row.episode_id || "",
    ].join("|"),
    targetType: row.target_type,
    targetId: row.target_id,
    targetTitle,
    chapterId: row.chapter_id || "",
    chapterTitle,
    episodeId: row.episode_id || "",
    episodeTitle,
    commentCount: row.comment_count || 0,
    userCount: row.user_count || 0,
    threadCount: row.thread_count || 0,
    replyCount: row.reply_count || 0,
    ratingAvg: row.rating_avg,
    lastCreatedAt: row.last_created_at,
    latestContent: row.latest_content || "",
  };
}

function commentTargetJson(row) {
  const targetTitle = cleanAdminTitle(row.target_title);
  return {
    key: [row.target_type, row.target_id].join("|"),
    targetType: row.target_type,
    targetId: row.target_id,
    targetTitle,
    displayTitle:
      targetTitle || `${labelTargetTypeForAdmin(row.target_type)} ${row.target_id}`,
    commentCount: row.comment_count || 0,
    userCount: row.user_count || 0,
    threadCount: row.thread_count || 0,
    replyCount: row.reply_count || 0,
    ratingAvg: row.rating_avg,
    lastCreatedAt: row.last_created_at,
    latestContent: row.latest_content || "",
  };
}

function danmakuGroupJson(row) {
  const importedCount = row.bilibili_imported_count || 0;
  return {
    videoId: row.video_id,
    animeId: row.anime_id || "",
    episodeId: row.episode_id || "",
    danmakuCount: row.danmaku_count || 0,
    userCount: row.user_count || 0,
    aliasCount: row.alias_count || 0,
    bilibiliImportedCount: importedCount,
    bilibiliSyncStatus: danmakuBilibiliSyncStatus(importedCount),
    minTimeMs: row.min_time_ms,
    maxTimeMs: row.max_time_ms,
    lastCreatedAt: row.last_created_at,
    latestContent: row.latest_content || "",
  };
}

function cleanAdminTitle(value) {
  const title = String(value || "").trim();
  if (!title) return "";
  if (/^(动漫|小说|漫画)\s*\d+$/.test(title)) return "";
  return title;
}

function danmakuAnimeFallbackTitle(animeId) {
  return `动漫 ID ${animeId || "unknown"}（标题待补全）`;
}

function labelTargetTypeForAdmin(value) {
  return (
    {
      novel: "小说",
      manga: "漫画",
      anime: "动漫",
      chapter: "章节",
      episode: "剧集",
    }[value] || value
  );
}

function chatRoomJson(row) {
  const category = chatRoomCategory(row.category);
  return {
    roomId: row.room_id,
    id: row.room_id,
    name: row.name || row.room_id,
    avatarUrl: row.avatar_url || "",
    minLevel: row.min_level || 1,
    category: category.key,
    categoryLabel: category.label,
    isOfficial: Boolean(row.is_official),
    status: row.room_status || "active",
    botEnabled: Boolean(row.bot_enabled),
    messageCount: row.message_count || 0,
    userCount: row.user_count || 0,
    lastCreatedAt: row.last_created_at,
    latestContent: row.latest_content || "",
  };
}

function chatKeywordJson(row) {
  return {
    id: row.id,
    keyword: row.keyword || "",
    matchType: row.match_type || "contains",
    severity: row.severity || "block",
    status: row.status || "active",
    note: row.note || "",
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function chatViolationJson(row) {
  return {
    id: row.id,
    roomId: row.room_id || "",
    content: row.content || "",
    keywordId: row.keyword_id,
    keyword: row.keyword || "",
    action: row.action || "blocked",
    ip: row.ip || "",
    createdAt: row.created_at,
    user: {
      id: row.user_id,
      nickname: row.nickname || "",
      email: row.email || "",
    },
  };
}

function blockedIpJson(row) {
  return {
    ip: row.ip || "",
    reason: row.reason || "",
    createdAt: row.created_at,
    user: row.user_id
      ? {
          id: row.user_id,
          nickname: row.nickname || "",
          email: row.email || "",
        }
      : null,
  };
}

function statusCounts(table, column) {
  return groupedCounts(table, column).reduce(
    (acc, item) => ({ ...acc, [item.key]: item.count }),
    {},
  );
}

function groupedCounts(table, column) {
  return all(
    `SELECT ${column} AS key, COUNT(*) AS count
     FROM ${table}
     GROUP BY ${column}
     ORDER BY count DESC`,
  ).map((row) => ({
    key: row.key,
    count: row.count,
  }));
}
