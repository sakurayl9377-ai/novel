import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";

import { config } from "./config.js";
import { publicAppAnnouncement } from "./app-announcement.js";
import {
  buildChatBotContentShare,
  buildChatBotReply,
  chatBotRoomAvatarAsset,
  chatBotRoomSkinId,
  chatBotSettings,
  ensureChatBotWelcomeMessage,
} from "./chat-bot.js";
import { commentJson, danmakuJson } from "./routes-content.js";
import { findUserByBearer } from "./auth.js";
import { all, db, one, run } from "./db.js";
import { levelFromPoints } from "./growth.js";
import { privateUser, publicUser } from "./security.js";
import { activeChatUserIds, chatJson } from "./websocket.js";
import { dailyRewardCaps, grantReward, publicRewardRules } from "./rewards.js";
import { enforceRateLimits } from "./rate-limit.js";
import {
  deleteRetiredManagedUploadKeys,
  isManagedUploadRetired,
  markManagedUploadUrlsRetired,
  referencedUploadUrls,
  retireManagedUploadKey,
  retireManagedUploadUrls,
  scheduleManagedUploadRetirement,
  scheduleRetiredUploadDeleteRetry,
} from "./upload-lifecycle.js";
import {
  inspectUserUploadUsage,
  pruneOrphanedUserUploads,
  validateUploadBytes,
  withUploadLock,
  writeUploadAtomically,
} from "./upload-security.js";
import {
  badRequest,
  forbidden,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const imageUploadMimes = new Set([
  "image/jpeg",
  "image/jpg",
  "image/png",
  "image/webp",
  "image/gif",
]);
const audioUploadMimes = new Set([
  "audio/aac",
  "audio/mp4",
  "audio/mpeg",
  "audio/ogg",
  "audio/wav",
  "audio/webm",
]);
const fileUploadMimes = new Set([
  "application/pdf",
  "application/zip",
  "text/plain",
]);
const profileImageUploadKinds = {
  avatar: { folder: "avatars", errorPrefix: "avatar", mimes: imageUploadMimes },
  banner: { folder: "banners", errorPrefix: "profile_banner", mimes: imageUploadMimes },
  dynamicAvatar: { folder: "dynamic-avatars", errorPrefix: "dynamic_avatar", mimes: imageUploadMimes },
  photo: { folder: "photos", errorPrefix: "profile_photo", mimes: imageUploadMimes },
  chatImage: { folder: "chat-images", errorPrefix: "chat_image", mimes: imageUploadMimes },
  chatAudio: { folder: "chat-audio", errorPrefix: "chat_audio", mimes: audioUploadMimes },
  chatFile: { folder: "chat-files", errorPrefix: "chat_file", mimes: fileUploadMimes },
};

const chatRoomCategories = [
  { key: "novel", label: "小说" },
  { key: "anime", label: "动漫" },
  { key: "manga", label: "漫画" },
];

const profileImageFolders = new Set(
  Object.values(profileImageUploadKinds).map((kind) => kind.folder),
);

const profileImageExtensionsByMime = {
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/gif": "gif",
  "audio/aac": "aac",
  "audio/mp4": "m4a",
  "audio/mpeg": "mp3",
  "audio/ogg": "ogg",
  "audio/wav": "wav",
  "audio/webm": "webm",
  "application/pdf": "pdf",
  "application/zip": "zip",
  "text/plain": "txt",
};

const progressContentTypes = new Set(["novel", "manga", "anime"]);
const progressSyncMaxItems = 200;
const progressDefaultLimit = 100;
const progressMaxFutureMs = 5 * 60 * 1000;
const progressMaxPastMs = 10 * 365 * 24 * 60 * 60 * 1000;
const progressPayloadMaxBytes = 16 * 1024;
const progressMetadataMaxBytes = 8 * 1024;

export async function userRoutes(app) {
  app.get("/app/announcement", async () => ({
    item: publicAppAnnouncement(),
  }));

  app.post(
    "/users/me/app-install",
    { preHandler: app.authRequired },
    async (request) => {
      const body = request.body || {};
      const installId = requiredString(body.installId, "installId", 80);
      const versionName = requiredString(body.versionName, "versionName", 40);
      const versionCode = optionalInt(body.versionCode, 0);
      const platform = requiredString(body.platform, "platform", 30);
      const osVersion = optionalString(body.osVersion, 200);
      const deviceModel = optionalString(body.deviceModel, 120);
      if (versionCode <= 0) throw badRequest("versionCode is invalid");
      run(
        `INSERT INTO user_app_installs
         (user_id, install_id, version_name, version_code, platform,
          os_version, device_model, last_ip)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(user_id, install_id) DO UPDATE SET
           version_name = excluded.version_name,
           version_code = excluded.version_code,
           platform = excluded.platform,
           os_version = excluded.os_version,
           device_model = excluded.device_model,
           last_seen_at = datetime('now'),
           last_ip = excluded.last_ip`,
        [
          request.user.id,
          installId,
          versionName,
          versionCode,
          platform,
          osVersion,
          deviceModel,
          String(request.ip || "").slice(0, 80),
        ],
      );
      return { ok: true };
    },
  );

  app.get(
    "/users/me/progress",
    { preHandler: app.authRequired },
    async (request) => {
      const cursor = progressCursor(request.query?.cursor);
      const limit = progressLimit(request.query?.limit);
      return progressChanges(request.user.id, cursor, limit);
    },
  );

  app.post(
    "/users/me/progress/sync",
    {
      preHandler: app.authRequired,
      bodyLimit: 4 * 1024 * 1024,
    },
    async (request) => {
      const body = request.body || {};
      const deviceId = requiredString(body.deviceId, "deviceId", 120);
      const cursor = progressCursor(body.cursor);
      if (!Array.isArray(body.items)) throw badRequest("items must be an array");
      if (body.items.length > progressSyncMaxItems) {
        throw badRequest(`items cannot contain more than ${progressSyncMaxItems} entries`);
      }

      const nowMs = Date.now();
      const items = body.items.map((item, index) =>
        normalizeProgressItem(item, index, deviceId, nowMs),
      );

      run("BEGIN IMMEDIATE");
      const writeOutcomes = [];
      try {
        let nextRevision = Number(
          one(
            `SELECT COALESCE(MAX(revision), 0) AS revision
             FROM user_content_progress
             WHERE user_id = ?`,
            [request.user.id],
          )?.revision || 0,
        );
        for (const item of items) {
          let accepted = false;
          const existing = one(
            `SELECT *
             FROM user_content_progress
             WHERE user_id = ? AND content_type = ? AND content_key = ?`,
            [request.user.id, item.contentType, item.contentKey],
          );
          if (existing) {
            const existingClientTime = Number(existing.client_updated_at_ms);
            const existingDeviceId = String(existing.device_id || "");
            const isOlder = item.clientUpdatedAtMs < existingClientTime;
            const losesDeterministicTie =
              item.clientUpdatedAtMs === existingClientTime &&
              deviceId <= existingDeviceId;
            if (isOlder || losesDeterministicTie) {
              writeOutcomes.push({
                contentType: item.contentType,
                contentKey: item.contentKey,
                accepted,
              });
              continue;
            }
          }

          nextRevision += 1;
          accepted = true;
          const deletedAtSql = item.deleted ? "datetime('now')" : "NULL";
          if (existing) {
            run(
              `UPDATE user_content_progress
               SET source_key = ?, item_id = ?, sub_item_id = ?,
                   payload_json = ?, metadata_json = ?, device_id = ?,
                   client_updated_at_ms = ?, revision = ?,
                   deleted_at = ${deletedAtSql}, updated_at = datetime('now')
               WHERE id = ?`,
              [
                item.sourceKey,
                item.itemId,
                item.subItemId,
                item.payloadJson,
                item.metadataJson,
                deviceId,
                item.clientUpdatedAtMs,
                nextRevision,
                existing.id,
              ],
            );
          } else {
            run(
              `INSERT INTO user_content_progress
               (user_id, content_type, content_key, source_key, item_id,
                sub_item_id, payload_json, metadata_json, device_id,
                client_updated_at_ms, revision, deleted_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ${deletedAtSql})`,
              [
                request.user.id,
                item.contentType,
                item.contentKey,
                item.sourceKey,
                item.itemId,
                item.subItemId,
                item.payloadJson,
                item.metadataJson,
                deviceId,
                item.clientUpdatedAtMs,
                nextRevision,
              ],
            );
          }
          writeOutcomes.push({
            contentType: item.contentType,
            contentKey: item.contentKey,
            accepted,
          });
        }
        db.exec("COMMIT");
      } catch (error) {
        try {
          db.exec("ROLLBACK");
        } catch {
          // Preserve the original transaction error.
        }
        throw error;
      }

      const response = progressChanges(
        request.user.id,
        cursor,
        progressSyncMaxItems,
      );
      return {
        ...response,
        writeResults: writeOutcomes.map((outcome) => {
          const winner = one(
            `SELECT *
             FROM user_content_progress
             WHERE user_id = ? AND content_type = ? AND content_key = ?`,
            [request.user.id, outcome.contentType, outcome.contentKey],
          );
          return {
            contentKey: outcome.contentKey,
            accepted: outcome.accepted,
            winner: winner ? progressJson(winner) : null,
          };
        }),
      };
    },
  );

  app.get("/chat/rooms/default-avatar.svg", async (_request, reply) => {
    reply.type("image/svg+xml");
    return `<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160">
      <defs><linearGradient id="g" x1="0" x2="1" y1="0" y2="1"><stop stop-color="#7dd3fc"/><stop offset="1" stop-color="#f9a8d4"/></linearGradient></defs>
      <rect width="160" height="160" rx="38" fill="url(#g)"/>
      <circle cx="80" cy="70" r="34" fill="white" opacity=".9"/>
      <path d="M42 124c10-24 66-24 76 0" fill="white" opacity=".9"/>
      <path d="M62 69h36M55 88h50" stroke="#237CFF" stroke-width="8" stroke-linecap="round"/>
    </svg>`;
  });

  app.get("/chat/bot", async () => {
    const settings = chatBotSettings();
    return {
      botName: settings.botName,
      skinId: settings.skinId,
      enabled: settings.enabled,
      skin: settings.skin,
    };
  });

  app.post(
    "/chat/bot/direct",
    { preHandler: app.authRequired },
    async (request) => {
      const content = requiredString(request.body?.content, "content", 500);
      const userMessage = insertChatBotDirectMessage({
        userId: request.user.id,
        sender: "user",
        content,
      });
      const share = buildChatBotContentShare(content, {
        sessionKey: `profile:${request.user.id}`,
      });
      const reply = share
        ? share.content
        : await buildChatBotReply({
            roomId: "profile",
            roomName: "我的页面",
            userName: request.user.nickname || "用户",
            content,
            history: recentChatBotDirectMessages(request.user.id, userMessage.id),
          });
      const botMessage = insertChatBotDirectMessage({
        userId: request.user.id,
        sender: "bot",
        content: reply,
        metadata: share?.share ? { share: share.share } : {},
      });
      return {
        ok: true,
        reply,
        share: share?.share || {},
        message: chatBotDirectMessageJson(botMessage),
      };
    },
  );

  app.get(
    "/chat/bot/direct/messages",
    { preHandler: app.authRequired },
    async (request) => {
      const limit = Math.max(
        1,
        Math.min(50, optionalInt(request.query?.limit, 20)),
      );
      const beforeId = optionalInt(request.query?.beforeId, 0);
      const beforeSql = beforeId > 0 ? "AND id < ?" : "";
      const params = beforeId > 0
        ? [request.user.id, beforeId, limit]
        : [request.user.id, limit];
      const items = all(
        `SELECT *
         FROM chat_bot_direct_messages
         WHERE user_id = ?
           ${beforeSql}
         ORDER BY id DESC
         LIMIT ?`,
        params,
      )
        .reverse()
        .map(chatBotDirectMessageJson);
      return { items };
    },
  );

  app.get("/uploads/avatars/:file", async (request, reply) => {
    return serveProfileImage("avatars", request.params.file, reply);
  });

  app.get("/uploads/profile/:kind/:file", async (request, reply) => {
    const kind = String(request.params.kind || "");
    if (!profileImageFolders.has(kind)) {
      throw badRequest("upload kind is invalid");
    }
    return serveProfileImage(kind, request.params.file, reply);
  });

  app.get(
    "/users/me/profile",
    { preHandler: app.authRequired },
    async (request) => profilePayload(request.user.id, request.user.id),
  );

  app.post(
    "/users/me/avatar",
    { preHandler: app.authRequired, bodyLimit: 7 * 1024 * 1024 },
    async (request, reply) => {
      const limited = enforceUploadRateLimit(request, reply);
      if (limited) return limited;
      return handleProfileImageUpload(request, "avatar");
    },
  );

  app.post(
    "/users/me/profile-image",
    { preHandler: app.authRequired, bodyLimit: 7 * 1024 * 1024 },
    async (request, reply) => {
      const limited = enforceUploadRateLimit(request, reply);
      if (limited) return limited;
      return handleProfileImageUpload(request);
    },
  );

  app.patch(
    "/users/me/profile",
    { preHandler: app.authRequired },
    async (request) => {
      const body = request.body || {};
      const nickname = optionalString(body.nickname, 32);
      const avatarUrl = optionalString(body.avatarUrl, 800);
      const gender = normalizeGender(body.gender);
      const bio = optionalString(body.bio, 140);
      const signature = optionalString(body.signature, 80);
      const spaceTitle = optionalString(body.spaceTitle, 60);
      const profileBannerUrl = optionalString(body.profileBannerUrl, 800);
      const dynamicAvatarUrl = optionalString(body.dynamicAvatarUrl, 800);
      const profileTheme = optionalString(body.profileTheme, 40) || "sakura";
      const privacyMode = body.privacyMode === true ? 1 : 0;
      const level = levelFromPoints(request.user.points || 0);

      if (!nickname) throw badRequest("nickname is required");
      if (dynamicAvatarUrl && level < 5) {
        throw badRequest("level_required_dynamic_avatar");
      }
      if (profileTheme !== "sakura" && level < 2) {
        throw badRequest("level_required_profile_skin");
      }

      let photoWall = null;
      if (Array.isArray(body.photoWall)) {
        const maxPhotos = photoWallLimit(level);
        if (body.photoWall.length > maxPhotos) {
          throw badRequest("photo_wall_limit");
        }
        photoWall = body.photoWall.flatMap((raw, index) => {
          const item = raw && typeof raw === "object" ? raw : {};
          const imageUrl = optionalString(item.imageUrl, 800);
          if (!imageUrl) return [];
          return [{
            imageUrl,
            caption: optionalString(item.caption, 80),
            sortOrder: index,
          }];
        });
      }

      const replacementUrls = [
        avatarUrl,
        profileBannerUrl,
        dynamicAvatarUrl,
        ...(photoWall || []).map((item) => item.imageUrl),
      ];

      return withUploadLock(request.user.id, async () => {
        const previousUrls = currentProfileResourceUrls(request.user.id);
        let retiredPreviousKeys = [];
        let transactionStarted = false;
        try {
          db.exec("BEGIN IMMEDIATE");
          transactionStarted = true;
          run(
            `UPDATE users
             SET nickname = ?,
                 avatar_url = ?,
                 gender = ?,
                 bio = ?,
                 signature = ?,
                 space_title = ?,
                 profile_banner_url = ?,
                 dynamic_avatar_url = ?,
                 profile_theme = ?,
                 privacy_mode = ?,
                 updated_at = datetime('now')
             WHERE id = ?`,
            [
              nickname,
              avatarUrl,
              gender,
              bio,
              signature,
              spaceTitle,
              profileBannerUrl,
              dynamicAvatarUrl,
              profileTheme,
              privacyMode,
              request.user.id,
            ],
          );

          if (photoWall) {
            run("DELETE FROM profile_photos WHERE user_id = ?", [request.user.id]);
            for (const item of photoWall) {
              run(
                `INSERT INTO profile_photos
                 (user_id, image_url, caption, sort_order)
                 VALUES (?, ?, ?, ?)`,
                [
                  request.user.id,
                  item.imageUrl,
                  item.caption,
                  item.sortOrder,
                ],
              );
            }
          }

          if (avatarUrl && signature && bio) {
            grantReward(request.user.id, "profile_complete", {
              type: "profile",
              id: String(request.user.id),
            });
          }
          retiredPreviousKeys = markManagedUploadUrlsRetired({
            userId: request.user.id,
            urls: previousUrls,
          });
          db.exec("COMMIT");
          transactionStarted = false;
        } catch (error) {
          if (transactionStarted) {
            try {
              db.exec("ROLLBACK");
            } catch {
              // Preserve the original profile update error.
            }
          }
          await cleanupProfileUploadUrls(request, replacementUrls, {
            phase: "profile_update_rollback",
          });
          throw error;
        }

        await deleteRetiredProfileUploadKeys(request, retiredPreviousKeys, {
          phase: "profile_resource_replaced",
        });
        return profilePayload(request.user.id, request.user.id);
      });
    },
  );

  app.post(
    "/users/me/signin",
    { preHandler: app.authRequired },
    async (request) => {
      const reward = grantReward(request.user.id, "daily_signin", {
        type: "user",
        id: String(request.user.id),
      });
      return {
        ok: true,
        reward,
        alreadySigned: reward == null,
        ...(await profilePayload(request.user.id, request.user.id)),
      };
    },
  );

  app.get("/users/reward-rules", async () => publicRewardRules());

  app.get("/chat/rooms", async (request) => {
    const currentUser = findUserByBearer(request);
    return chatRoomsData(currentUser);
  });

  app.get("/chat/rooms/:roomId", async (request) => {
    const roomId = normalizeChatRoomId(request.params.roomId);
    const currentUser = findUserByBearer(request);
    markChatRoomRead(roomId, currentUser?.id);
    const room = chatRoomPayload(roomId, currentUser, { includeMembers: true });
    if (!room) throw badRequest("chat room not found");
    return { item: room };
  });

  app.post(
    "/chat/rooms/:roomId/join",
    { preHandler: app.authRequired },
    async (request) => {
      const roomId = normalizeChatRoomId(request.params.roomId);
      const room = one("SELECT * FROM chat_rooms WHERE id = ?", [roomId]);
      if (!room || room.status !== "active") {
        throw badRequest("chat room not found");
      }
      if (levelFromPoints(request.user.points || 0) < (room.min_level || 1)) {
        throw badRequest("chat room level required");
      }
      run(
        `INSERT INTO chat_room_members (room_id, user_id, role, joined_at)
         VALUES (?, ?, 'member', datetime('now'))
         ON CONFLICT(room_id, user_id) DO UPDATE SET
           role = CASE
             WHEN chat_room_members.role = 'manager' THEN 'manager'
             ELSE 'member'
           END`,
        [roomId, request.user.id],
      );
      markChatRoomRead(roomId, request.user.id);
      if (room.bot_enabled) ensureChatBotWelcomeMessage(roomId, room.name || "");
      return {
        ok: true,
        item: chatRoomPayload(roomId, request.user, { includeMembers: true }),
      };
    },
  );

  app.delete(
    "/chat/rooms/:roomId/join",
    { preHandler: app.authRequired },
    async (request) => {
      const roomId = normalizeChatRoomId(request.params.roomId);
      run(
        `DELETE FROM chat_room_members
         WHERE room_id = ? AND user_id = ? AND role != 'manager'`,
        [roomId, request.user.id],
      );
      if (!chatRoomIsJoined(roomId, request.user.id)) {
        request.server.disconnectChatRoomUser?.(
          roomId,
          request.user.id,
          "chat_room_left",
        );
      }
      return {
        ok: true,
        item: chatRoomPayload(roomId, request.user, { includeMembers: true }),
      };
    },
  );

  app.get(
    "/chat/rooms/:roomId/messages",
    { preHandler: app.authRequired },
    async (request) => {
      const roomId = normalizeChatRoomId(request.params.roomId);
      const room = one(
        "SELECT id, min_level FROM chat_rooms WHERE id = ? AND status = 'active'",
        [roomId],
      );
      if (!room) throw badRequest("chat room not found");
      if (levelFromPoints(request.user.points || 0) < (room.min_level || 1)) {
        throw forbidden("chat_room_level_required");
      }
      if (!chatRoomIsJoined(roomId, request.user.id)) {
        throw forbidden("chat_room_join_required");
      }
      const keyword = optionalString(request.query?.q, 120);
      const { page, pageSize } = pageParams(request.query || {}, {
        defaultPageSize: 30,
        maxPageSize: 80,
      });
      const beforeId = optionalInt(request.query?.beforeId, 0);
      const whereKeyword = keyword ? "AND (m.content LIKE ? OR u.nickname LIKE ?)" : "";
      const whereBefore = !keyword && beforeId > 0 ? "AND m.id < ?" : "";
      const params = [roomId];
      if (keyword) params.push(`%${keyword}%`, `%${keyword}%`);
      if (!keyword && beforeId > 0) params.push(beforeId);
      params.push(pageSize);
      if (keyword) params.push((page - 1) * pageSize);
      const rows = all(
        `SELECT m.*, u.nickname, u.avatar_url
           FROM chat_messages m
           JOIN users u ON u.id = m.user_id
          WHERE m.room_id = ?
            AND m.status = 'visible'
            ${whereKeyword}
            ${whereBefore}
          ORDER BY m.id DESC
          LIMIT ?
          ${keyword ? "OFFSET ?" : ""}`,
        params,
      );
      const items = (keyword ? rows : rows.reverse()).map(chatJson);
      return { items };
    },
  );

  app.get(
    "/users/me/interactions/comments",
    { preHandler: app.authRequired },
    async (request) => userCommentsPayload(request.user.id, request.query || {}),
  );

  app.get(
    "/users/me/interactions/danmaku",
    { preHandler: app.authRequired },
    async (request) => userDanmakuPayload(request.user.id, request.query || {}),
  );

  app.get(
    "/messages/unread-summary",
    { preHandler: app.authRequired },
    async (request) => messageUnreadSummaryPayload(request.user.id),
  );

  app.get(
    "/messages/conversations",
    { preHandler: app.authRequired },
    async (request) => privateConversationPayload(request.user.id, request.query || {}),
  );

  app.get(
    "/messages/system",
    { preHandler: app.authRequired },
    async (request) => systemNotificationPayload(request.user.id, request.query || {}),
  );

  app.post(
    "/messages/system/:id/read",
    { preHandler: app.authRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("notification id is invalid");
      run(
        `UPDATE system_notifications
         SET read_at = datetime('now')
         WHERE id = ? AND user_id = ? AND read_at = ''`,
        [id, request.user.id],
      );
      return { ok: true, unread: messageUnreadSummaryPayload(request.user.id) };
    },
  );

  app.get(
    "/messages/private/:userId",
    { preHandler: app.authRequired },
    async (request) => {
      const peerId = Number(request.params.userId);
      if (!Number.isInteger(peerId) || peerId <= 0) {
        throw badRequest("user id is invalid");
      }
      run(
        `UPDATE private_messages
         SET read_at = datetime('now')
         WHERE sender_id = ? AND receiver_id = ? AND read_at = ''`,
        [peerId, request.user.id],
      );
      return privateMessagePayload(request.user.id, peerId, request.query || {});
    },
  );

  app.post(
    "/messages/private/:userId",
    { preHandler: app.authRequired },
    async (request) => {
      const peerId = Number(request.params.userId);
      if (!Number.isInteger(peerId) || peerId <= 0) {
        throw badRequest("user id is invalid");
      }
      if (peerId === request.user.id) throw badRequest("cannot message self");
      const peer = one("SELECT id FROM users WHERE id = ? AND status = 'active'", [
        peerId,
      ]);
      if (!peer) throw badRequest("user not found");
      const content = optionalString(request.body?.content, 800);
      if (!content) throw badRequest("message content is required");
      const result = run(
        `INSERT INTO private_messages (sender_id, receiver_id, content)
         VALUES (?, ?, ?)`,
        [request.user.id, peerId, content],
      );
      const item = one(
        `SELECT pm.*,
                sender.nickname AS sender_nickname,
                sender.avatar_url AS sender_avatar_url,
                receiver.nickname AS receiver_nickname,
                receiver.avatar_url AS receiver_avatar_url
         FROM private_messages pm
         JOIN users sender ON sender.id = pm.sender_id
         JOIN users receiver ON receiver.id = pm.receiver_id
         WHERE pm.id = ?`,
        [Number(result.lastInsertRowid)],
      );
      return { ok: true, item: privateMessageJson(item, request.user.id) };
    },
  );

  app.get("/users/:id/profile", async (request) => {
    const id = Number(request.params.id);
    if (!Number.isInteger(id) || id <= 0)
      throw badRequest("user id is invalid");
    const currentUser = findUserByBearer(request);
    return profilePayload(id, currentUser?.id || null);
  });

  app.get("/users/:id/followers", async (request) => {
    const id = Number(request.params.id);
    if (!Number.isInteger(id) || id <= 0)
      throw badRequest("user id is invalid");
    const currentUser = findUserByBearer(request);
    return userFollowListPayload(
      id,
      currentUser?.id || null,
      "followers",
      request.query || {},
    );
  });

  app.get("/users/:id/following", async (request) => {
    const id = Number(request.params.id);
    if (!Number.isInteger(id) || id <= 0)
      throw badRequest("user id is invalid");
    const currentUser = findUserByBearer(request);
    return userFollowListPayload(
      id,
      currentUser?.id || null,
      "following",
      request.query || {},
    );
  });

  app.post(
    "/users/:id/follow",
    { preHandler: app.authRequired },
    async (request) => {
      const targetId = Number(request.params.id);
      if (!Number.isInteger(targetId) || targetId <= 0) {
        throw badRequest("user id is invalid");
      }
      if (targetId === request.user.id) throw badRequest("cannot follow self");
      const target = one("SELECT id, privacy_mode FROM users WHERE id = ?", [
        targetId,
      ]);
      if (!target) throw badRequest("user not found");
      if (target.privacy_mode) throw badRequest("profile_private");

      db.exec("BEGIN IMMEDIATE");
      try {
        const inserted = run(
          `INSERT OR IGNORE INTO user_follows (follower_id, following_id)
           VALUES (?, ?)`,
          [request.user.id, targetId],
        );
        if ((inserted.changes ?? 0) > 0) {
          const claimed = run(
            `INSERT OR IGNORE INTO user_follow_reward_claims
               (follower_id, following_id)
             VALUES (?, ?)`,
            [request.user.id, targetId],
          );
          if ((claimed.changes ?? 0) > 0) {
            grantReward(request.user.id, "follow_user", {
              type: "user",
              id: String(targetId),
            });
          }
        }
        db.exec("COMMIT");
      } catch (error) {
        try {
          db.exec("ROLLBACK");
        } catch {
          // Preserve the original transaction error.
        }
        throw error;
      }
      return profilePayload(targetId, request.user.id);
    },
  );

  app.delete(
    "/users/:id/follow",
    { preHandler: app.authRequired },
    async (request) => {
      const targetId = Number(request.params.id);
      if (!Number.isInteger(targetId) || targetId <= 0) {
        throw badRequest("user id is invalid");
      }
      run(
        `DELETE FROM user_follows
         WHERE follower_id = ? AND following_id = ?`,
        [request.user.id, targetId],
      );
      return profilePayload(targetId, request.user.id);
    },
  );

  app.get("/shop/items", async () => ({
    items: all(
      `SELECT *
       FROM shop_items
       WHERE status = 'active'
       ORDER BY sort_order ASC, min_level ASC, price_coins ASC, id ASC`,
    ).map(shopItemJson),
  }));

  app.post(
    "/shop/items/:id/redeem",
    { preHandler: app.authRequired },
    async (request) => {
      const itemId = String(request.params.id || "").trim();
      let item;
      let alreadyOwned = false;
      db.exec("BEGIN IMMEDIATE");
      try {
        item = one("SELECT * FROM shop_items WHERE id = ?", [itemId]);
        if (!item || item.status !== "active") {
          throw badRequest("item not found");
        }
        const user = one("SELECT * FROM users WHERE id = ?", [request.user.id]);
        if (!user) throw badRequest("user not found");
        if (levelFromPoints(user.points || 0) < item.min_level) {
          throw badRequest("level_required");
        }

        const inventoryInsert = run(
          `INSERT OR IGNORE INTO user_inventory (user_id, item_id)
           VALUES (?, ?)`,
          [request.user.id, item.id],
        );
        alreadyOwned = (inventoryInsert.changes ?? 0) === 0;
        if (!alreadyOwned) {
          const debit = run(
            `UPDATE users
             SET sakura_coins = sakura_coins - ?,
                 updated_at = datetime('now')
             WHERE id = ? AND sakura_coins >= ?`,
            [item.price_coins, request.user.id, item.price_coins],
          );
          if ((debit.changes ?? 0) !== 1) {
            throw badRequest("coins_not_enough");
          }
          run(
            `INSERT INTO user_reward_events
               (user_id, action, coins_delta, description, related_type, related_id)
             VALUES (?, 'shop_redeem', ?, ?, 'shop_item', ?)`,
            [
              request.user.id,
              -Number(item.price_coins || 0),
              `兑换商品：${item.name}`,
              item.id,
            ],
          );
        }
        db.exec("COMMIT");
      } catch (error) {
        try {
          db.exec("ROLLBACK");
        } catch {
          // Preserve the original transaction error.
        }
        throw error;
      }
      return {
        ok: true,
        alreadyOwned,
        item: shopItemJson(item),
        ...(await profilePayload(request.user.id, request.user.id)),
      };
    },
  );

  app.put(
    "/users/me/equipment/:slot",
    { preHandler: app.authRequired },
    async (request) => {
      const slot = normalizeEquipmentSlot(request.params.slot);
      const itemId = optionalString(request.body?.itemId, 120);
      if (!slot) throw badRequest("equipment_slot_invalid");
      if (!itemId) {
        run("DELETE FROM user_equipment WHERE user_id = ? AND slot = ?", [
          request.user.id,
          slot,
        ]);
        return profilePayload(request.user.id, request.user.id);
      }

      const item = one(
        `SELECT s.*
         FROM user_inventory i
         JOIN shop_items s ON s.id = i.item_id
         WHERE i.user_id = ? AND i.item_id = ?`,
        [request.user.id, itemId],
      );
      if (!item) throw badRequest("item_not_owned");
      if (equipmentSlotForItem(item.item_type) !== slot) {
        throw badRequest("equipment_slot_invalid");
      }

      run(
        `INSERT INTO user_equipment (user_id, slot, item_id, updated_at)
         VALUES (?, ?, ?, datetime('now'))
         ON CONFLICT(user_id, slot) DO UPDATE SET
           item_id = excluded.item_id,
           updated_at = datetime('now')`,
        [request.user.id, slot, itemId],
      );
      if (slot === "profile_skin" && item.asset_value) {
        run(
          `UPDATE users
           SET profile_theme = ?, updated_at = datetime('now')
           WHERE id = ?`,
          [item.asset_value, request.user.id],
        );
      }
      return profilePayload(request.user.id, request.user.id);
    },
  );
}

function userCommentsPayload(userId, query) {
  const { page, pageSize, offset } = pageParams(query);
  const total = count(
    "SELECT COUNT(*) AS count FROM comments WHERE user_id = ? AND status = 'visible'",
    [userId],
  );
  const items = all(
    `SELECT c.*,
            u.nickname,
            u.avatar_url,
            m.target_title,
            m.chapter_title,
            m.episode_title
     FROM comments c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN comment_target_meta m
       ON m.target_type = c.target_type
      AND m.target_id = c.target_id
      AND m.chapter_id = c.chapter_id
      AND m.episode_id = c.episode_id
     WHERE c.user_id = ?
       AND c.status = 'visible'
     ORDER BY c.created_at DESC, c.id DESC
     LIMIT ? OFFSET ?`,
    [userId, pageSize, offset],
  ).map((row) => ({
    ...commentJson(row),
    targetTitle: row.target_title || "",
    chapterTitle: row.chapter_title || "",
    episodeTitle: row.episode_title || "",
  }));
  return { page, pageSize, total, items };
}

function userDanmakuPayload(userId, query) {
  const { page, pageSize, offset } = pageParams(query);
  const total = count(
    "SELECT COUNT(*) AS count FROM danmaku WHERE user_id = ? AND status = 'visible'",
    [userId],
  );
  const items = all(
    `SELECT d.*,
            u.nickname,
            u.avatar_url,
            m.anime_title,
            m.episode_title
     FROM danmaku d
     JOIN users u ON u.id = d.user_id
     LEFT JOIN danmaku_episode_meta m
       ON m.canonical_video_id = d.video_id
     WHERE d.user_id = ?
       AND d.status = 'visible'
     ORDER BY d.created_at DESC, d.id DESC
     LIMIT ? OFFSET ?`,
    [userId, pageSize, offset],
  ).map((row) => ({
    ...danmakuJson(row),
    animeTitle: row.anime_title || "",
    episodeTitle: row.episode_title || "",
  }));
  return { page, pageSize, total, items };
}

function userFollowListPayload(userId, currentUserId, kind, query) {
  const user = one("SELECT id, privacy_mode FROM users WHERE id = ?", [userId]);
  if (!user) throw badRequest("user not found");
  if (user.privacy_mode && currentUserId !== userId) {
    throw badRequest("profile_private");
  }

  const { page, pageSize, offset } = pageParams(query);
  const isFollowers = kind === "followers";
  const relationWhere = isFollowers
    ? "f.following_id = ?"
    : "f.follower_id = ?";
  const userJoin = isFollowers ? "u.id = f.follower_id" : "u.id = f.following_id";
  const total = count(
    `SELECT COUNT(*) AS count FROM user_follows f WHERE ${relationWhere}`,
    [userId],
  );
  const items = all(
    `SELECT u.*, f.created_at AS followed_at
     FROM user_follows f
     JOIN users u ON ${userJoin}
     WHERE ${relationWhere}
     ORDER BY f.created_at DESC, f.id DESC
     LIMIT ? OFFSET ?`,
    [userId, pageSize, offset],
  ).map((row) => ({
    ...publicUser(row),
    followedAt: row.followed_at,
  }));
  return { page, pageSize, total, items };
}

async function profilePayload(userId, currentUserId) {
  const user = one("SELECT * FROM users WHERE id = ?", [userId]);
  if (!user) throw badRequest("user not found");
  const isSelf = currentUserId === userId;
  if (user.privacy_mode && !isSelf) {
    throw badRequest("profile_private");
  }
  const stats = {
    following: count(
      "SELECT COUNT(*) AS count FROM user_follows WHERE follower_id = ?",
      userId,
    ),
    followers: count(
      "SELECT COUNT(*) AS count FROM user_follows WHERE following_id = ?",
      userId,
    ),
    comments: count(
      "SELECT COUNT(*) AS count FROM comments WHERE user_id = ?",
      [userId],
    ),
    danmaku: count("SELECT COUNT(*) AS count FROM danmaku WHERE user_id = ?", [
      userId,
    ]),
    chat: count(
      "SELECT COUNT(*) AS count FROM chat_messages WHERE user_id = ?",
      [userId],
    ),
  };
  const photos = all(
    `SELECT id, image_url, caption, sort_order, created_at
     FROM profile_photos
     WHERE user_id = ?
     ORDER BY sort_order ASC, id ASC`,
    [userId],
  ).map((row) => ({
    id: row.id,
    imageUrl: row.image_url,
    caption: row.caption || "",
    sortOrder: row.sort_order || 0,
    createdAt: row.created_at,
  }));
  const inventory = isSelf
    ? all(
        `SELECT i.acquired_at, s.*
         FROM user_inventory i
         JOIN shop_items s ON s.id = i.item_id
         WHERE i.user_id = ?
         ORDER BY i.acquired_at DESC`,
        [userId],
      ).map((row) => ({ ...shopItemJson(row), acquiredAt: row.acquired_at }))
    : [];
  const equipment = all(
    `SELECT e.slot, e.updated_at, s.*
     FROM user_equipment e
     JOIN shop_items s ON s.id = e.item_id
     WHERE e.user_id = ?
     ORDER BY e.slot ASC`,
    [userId],
  ).map((row) => ({
    slot: row.slot,
    updatedAt: row.updated_at,
    item: shopItemJson(row),
  }));
  const recentRewards = isSelf
    ? all(
        `SELECT action, points_delta, coins_delta, description, created_at
         FROM user_reward_events
         WHERE user_id = ?
         ORDER BY id DESC
         LIMIT 10`,
        [userId],
      ).map((row) => ({
        action: row.action,
        points: row.points_delta,
        coins: row.coins_delta,
        description: row.description,
        createdAt: row.created_at,
      }))
    : [];
  const todayRewardRows = isSelf
    ? all(
        `SELECT
           action,
           COUNT(*) AS count,
           COALESCE(SUM(points_delta), 0) AS points,
           COALESCE(SUM(coins_delta), 0) AS coins
         FROM user_reward_events
         WHERE user_id = ?
           AND date(created_at) = date('now')
         GROUP BY action`,
        [userId],
      )
    : [];
  const todayRewardByAction = new Map(
    todayRewardRows.map((row) => [row.action, row]),
  );
  const lifetimeRewardRows = isSelf
    ? all(
        `SELECT
           action,
           COUNT(*) AS count,
           COALESCE(SUM(points_delta), 0) AS points,
           COALESCE(SUM(coins_delta), 0) AS coins
         FROM user_reward_events
         WHERE user_id = ?
         GROUP BY action`,
        [userId],
      )
    : [];
  const lifetimeRewardByAction = new Map(
    lifetimeRewardRows.map((row) => [row.action, row]),
  );
  const followedByMe = currentUserId
    ? Boolean(
        one(
          `SELECT id FROM user_follows
           WHERE follower_id = ? AND following_id = ?`,
          [currentUserId, userId],
        ),
      )
    : false;
  const todayGrowth = isSelf
    ? one(
        `SELECT
           COALESCE(SUM(points_delta), 0) AS points,
           COALESCE(SUM(coins_delta), 0) AS coins
         FROM user_reward_events
         WHERE user_id = ?
           AND date(created_at) = date('now')`,
        [userId],
      )
    : null;
  const signInStreakDays = isSelf ? countSignInStreakDays(userId) : 0;
  const payload = {
    user: (isSelf ? privateUser : publicUser)(user, {
      dailyGrowth: { ...(todayGrowth || {}), signInStreakDays },
    }),
    stats,
    photos,
    equipment,
    followedByMe,
  };
  if (!isSelf) return payload;
  return {
    ...payload,
    inventory,
    recentRewards,
    dailyRewards: publicRewardRules().actions.map((rule) => {
      const row = rule.once
        ? lifetimeRewardByAction.get(rule.action) || {}
        : todayRewardByAction.get(rule.action) || {};
      const countValue = row.count || 0;
      const limit = rule.dailyLimit ?? (rule.once ? 1 : null);
      return {
        ...rule,
        count: countValue,
        pointsEarned: row.points || 0,
        coinsEarned: row.coins || 0,
        completed: limit == null ? countValue > 0 : countValue >= limit,
      };
    }),
    dailyCaps: {
      coins: dailyRewardCaps.coins,
      coinsEarned: todayGrowth?.coins || 0,
      coinsRemaining: Math.max(
        0,
        dailyRewardCaps.coins - (todayGrowth?.coins || 0),
      ),
    },
  };
}

function count(sql, params) {
  return one(sql, Array.isArray(params) ? params : [params])?.count || 0;
}

function progressCursor(value) {
  if (value == null || value === "") return 0;
  const cursor = Number(value);
  if (!Number.isSafeInteger(cursor) || cursor < 0) {
    throw badRequest("cursor is invalid");
  }
  return cursor;
}

function progressLimit(value) {
  if (value == null || value === "") return progressDefaultLimit;
  const limit = Number(value);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > progressSyncMaxItems) {
    throw badRequest(`limit must be between 1 and ${progressSyncMaxItems}`);
  }
  return limit;
}

function normalizeProgressItem(value, index, deviceId, nowMs) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw badRequest(`items[${index}] is invalid`);
  }
  const contentType = requiredString(
    value.contentType,
    `items[${index}].contentType`,
    16,
  );
  if (!progressContentTypes.has(contentType)) {
    throw badRequest(`items[${index}].contentType is invalid`);
  }
  const contentKey = requiredString(
    value.contentKey,
    `items[${index}].contentKey`,
    500,
  );
  const sourceKey = optionalString(value.sourceKey, 240);
  const itemId = optionalString(value.itemId, 240);
  const subItemId = optionalString(value.subItemId, 240);
  const clientTime = Number(value.clientUpdatedAtMs);
  if (!Number.isSafeInteger(clientTime) || clientTime <= 0) {
    throw badRequest(`items[${index}].clientUpdatedAtMs is invalid`);
  }
  if (clientTime < nowMs - progressMaxPastMs) {
    throw badRequest(`items[${index}].clientUpdatedAtMs is too old`);
  }
  const clientUpdatedAtMs = Math.min(
    clientTime,
    nowMs + progressMaxFutureMs,
  );
  if (value.deleted != null && typeof value.deleted !== "boolean") {
    throw badRequest(`items[${index}].deleted must be a boolean`);
  }

  return {
    contentType,
    contentKey,
    sourceKey,
    itemId,
    subItemId,
    payloadJson: serializeProgressJson(
      value.payload,
      `items[${index}].payload`,
      progressPayloadMaxBytes,
    ),
    metadataJson: serializeProgressJson(
      value.metadata,
      `items[${index}].metadata`,
      progressMetadataMaxBytes,
    ),
    clientUpdatedAtMs,
    deleted: value.deleted === true,
    deviceId,
  };
}

function serializeProgressJson(value, name, maxBytes) {
  let json;
  try {
    json = JSON.stringify(value ?? {});
  } catch {
    throw badRequest(`${name} is invalid JSON`);
  }
  if (json === undefined) throw badRequest(`${name} is invalid JSON`);
  if (Buffer.byteLength(json, "utf8") > maxBytes) {
    throw badRequest(`${name} is too large`);
  }
  return json;
}

function progressChanges(userId, cursor, limit) {
  const rows = all(
    `SELECT *
     FROM user_content_progress
     WHERE user_id = ? AND revision > ?
     ORDER BY revision ASC
     LIMIT ?`,
    [userId, cursor, limit + 1],
  );
  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  return {
    cursor: page.length ? Number(page[page.length - 1].revision) : cursor,
    items: page.map(progressJson),
    hasMore,
  };
}

function progressJson(row) {
  return {
    contentType: row.content_type,
    contentKey: row.content_key,
    sourceKey: row.source_key,
    itemId: row.item_id,
    subItemId: row.sub_item_id,
    payload: parseProgressJson(row.payload_json),
    metadata: parseProgressJson(row.metadata_json),
    deviceId: row.device_id,
    clientUpdatedAtMs: Number(row.client_updated_at_ms),
    revision: Number(row.revision),
    deleted: Boolean(row.deleted_at),
    deletedAt: row.deleted_at || null,
    updatedAt: row.updated_at,
  };
}

function parseProgressJson(value) {
  try {
    return JSON.parse(value || "{}");
  } catch {
    return {};
  }
}

function messageUnreadSummaryPayload(userId) {
  const system = count(
    `SELECT COUNT(*) AS count
     FROM system_notifications
     WHERE user_id = ? AND read_at = ''`,
    [userId],
  );
  const privateMessages = count(
    `SELECT COUNT(*) AS count
     FROM private_messages
     WHERE receiver_id = ?
       AND read_at = ''
       AND status = 'visible'`,
    [userId],
  );
  const chatMessages = count(
    `SELECT COUNT(*) AS count
     FROM chat_messages unread
     JOIN chat_room_members reader
       ON reader.room_id = unread.room_id
      AND reader.user_id = ?
     WHERE unread.status = 'visible'
       AND unread.user_id != ?
       AND unread.created_at >= reader.joined_at
       AND unread.id > COALESCE(reader.last_read_message_id, 0)`,
    [userId, userId],
  );
  return {
    total: system + privateMessages + chatMessages,
    system,
    private: privateMessages,
    privateMessages,
    chat: chatMessages,
    chatMessages,
  };
}

function privateConversationPayload(userId, query = {}) {
  const limit = Math.max(1, Math.min(80, Number(query.limit) || 50));
  const rows = all(
    `WITH pairs AS (
       SELECT
         CASE WHEN sender_id = ? THEN receiver_id ELSE sender_id END AS peer_id,
         MAX(id) AS last_id
       FROM private_messages
       WHERE sender_id = ? OR receiver_id = ?
       GROUP BY peer_id
     )
     SELECT
       pairs.peer_id,
       peer.nickname,
       peer.avatar_url,
       pm.content,
       pm.created_at,
       pm.sender_id,
       (
         SELECT COUNT(*)
         FROM private_messages unread
         WHERE unread.sender_id = pairs.peer_id
           AND unread.receiver_id = ?
           AND unread.read_at = ''
           AND unread.status = 'visible'
       ) AS unread_count
     FROM pairs
     JOIN private_messages pm ON pm.id = pairs.last_id
     JOIN users peer ON peer.id = pairs.peer_id
     ORDER BY pm.id DESC
     LIMIT ?`,
    [userId, userId, userId, userId, limit],
  );
  return { items: rows.map((row) => privateConversationJson(row, userId)) };
}

function privateMessagePayload(userId, peerId, query = {}) {
  const limit = Math.max(1, Math.min(100, Number(query.limit) || 50));
  const rows = all(
    `SELECT pm.*,
            sender.nickname AS sender_nickname,
            sender.avatar_url AS sender_avatar_url,
            receiver.nickname AS receiver_nickname,
            receiver.avatar_url AS receiver_avatar_url
     FROM private_messages pm
     JOIN users sender ON sender.id = pm.sender_id
     JOIN users receiver ON receiver.id = pm.receiver_id
     WHERE pm.status = 'visible'
       AND (
         (pm.sender_id = ? AND pm.receiver_id = ?)
         OR (pm.sender_id = ? AND pm.receiver_id = ?)
       )
     ORDER BY pm.id DESC
     LIMIT ?`,
    [userId, peerId, peerId, userId, limit],
  ).reverse();
  const peer = one("SELECT id, nickname, avatar_url FROM users WHERE id = ?", [
    peerId,
  ]);
  return {
    peer: peer
      ? {
          id: peer.id,
          nickname: peer.nickname || "",
          avatarUrl: peer.avatar_url || "",
        }
      : null,
    items: rows.map((row) => privateMessageJson(row, userId)),
  };
}

function systemNotificationPayload(userId, query = {}) {
  const limit = Math.max(1, Math.min(100, Number(query.limit) || 50));
  const rows = all(
    `SELECT id, title, content, category, read_at, created_at
     FROM system_notifications
     WHERE user_id = ?
     ORDER BY id DESC
     LIMIT ?`,
    [userId, limit],
  );
  return { items: rows.map(systemNotificationJson) };
}

function systemNotificationJson(row) {
  return {
    id: row.id,
    title: row.title || "",
    content: row.content || "",
    category: row.category || "system",
    readAt: row.read_at || "",
    createdAt: row.created_at || "",
  };
}

function privateConversationJson(row, userId) {
  return {
    peer: {
      id: row.peer_id,
      nickname: row.nickname || "",
      avatarUrl: row.avatar_url || "",
    },
    latestContent: row.content || "",
    latestAt: row.created_at || "",
    unreadCount: row.unread_count || 0,
    fromMe: row.sender_id === userId,
  };
}

function privateMessageJson(row, currentUserId) {
  return {
    id: row.id,
    content: row.content || "",
    createdAt: row.created_at || "",
    readAt: row.read_at || "",
    fromMe: row.sender_id === currentUserId,
    sender: {
      id: row.sender_id,
      nickname: row.sender_nickname || "",
      avatarUrl: row.sender_avatar_url || "",
    },
    receiver: {
      id: row.receiver_id,
      nickname: row.receiver_nickname || "",
      avatarUrl: row.receiver_avatar_url || "",
    },
  };
}

function chatRoomsData(currentUser) {
  const items = chatRoomsPayload(currentUser);
  const scores = new Map(chatRoomCategories.map((item) => [item.key, 0]));
  for (const room of items) {
    const score = chatRoomActivityScore(room.roomId, room.activeUserCount);
    scores.set(room.category, (scores.get(room.category) || 0) + score);
  }
  let hotCategoryKey = "";
  let hotScore = 0;
  for (const [key, score] of scores) {
    if (score > hotScore) {
      hotCategoryKey = key;
      hotScore = score;
    }
  }
  const categories = chatRoomCategories.map((category) => ({
    ...category,
    hot: hotScore > 0 && category.key === hotCategoryKey,
    rooms: items.filter((room) => room.category === category.key),
  }));
  return {
    items,
    categories,
    hotCategory: hotScore > 0 ? hotCategoryKey : "",
  };
}

function chatRoomsPayload(currentUser) {
  const currentUserId = currentUser?.id || 0;
  const rows = all(
    `SELECT r.*,
            (
              SELECT COUNT(*)
              FROM chat_messages unread
              JOIN chat_room_members reader
                ON reader.room_id = unread.room_id
               AND reader.user_id = ?
              WHERE unread.room_id = r.id
                AND unread.status = 'visible'
                AND unread.user_id != ?
                AND unread.created_at >= reader.joined_at
                AND unread.id > COALESCE(reader.last_read_message_id, 0)
            ) AS recent_message_count,
            (
              SELECT MAX(m3.created_at)
              FROM chat_messages m3
              WHERE m3.room_id = r.id AND m3.status = 'visible'
            ) AS last_message_at,
            (
              SELECT content
              FROM chat_messages latest
              WHERE latest.room_id = r.id AND latest.status = 'visible'
              ORDER BY latest.id DESC
              LIMIT 1
            ) AS latest_content
     FROM chat_rooms r
     WHERE r.status = 'active'
     ORDER BY
       CASE r.category
         WHEN 'novel' THEN 1
         WHEN 'anime' THEN 2
         WHEN 'manga' THEN 3
         ELSE 9
       END,
       r.is_official DESC,
       last_message_at DESC,
       r.created_at ASC`,
    [currentUserId, currentUserId],
  );
  return rows.map((row) => chatRoomJson(row, currentUser));
}

function chatRoomPayload(roomId, currentUser, { includeMembers = false } = {}) {
  const currentUserId = currentUser?.id || 0;
  const row = one(
    `SELECT r.*,
            (
              SELECT COUNT(*)
              FROM chat_messages unread
              JOIN chat_room_members reader
                ON reader.room_id = unread.room_id
               AND reader.user_id = ?
              WHERE unread.room_id = r.id
                AND unread.status = 'visible'
                AND unread.user_id != ?
                AND unread.created_at >= reader.joined_at
                AND unread.id > COALESCE(reader.last_read_message_id, 0)
            ) AS recent_message_count,
            (
              SELECT MAX(m3.created_at)
              FROM chat_messages m3
              WHERE m3.room_id = r.id AND m3.status = 'visible'
            ) AS last_message_at,
            (
              SELECT content
              FROM chat_messages latest
              WHERE latest.room_id = r.id AND latest.status = 'visible'
              ORDER BY latest.id DESC
              LIMIT 1
            ) AS latest_content
     FROM chat_rooms r
     WHERE r.id = ? AND r.status = 'active'`,
    [currentUserId, currentUserId, roomId],
  );
  if (!row) return null;
  const room = chatRoomJson(row, currentUser);
  if (includeMembers) room.members = chatRoomMembers(roomId);
  return room;
}

function chatRoomJson(row, currentUser) {
  const userLevel = levelFromPoints(currentUser?.points || 0);
  const category = chatCategory(row.category);
  return {
    id: row.id,
    roomId: row.id,
    name: row.name || row.id,
    avatarUrl: row.avatar_url || defaultChatRoomAvatar(row.id),
    minLevel: row.min_level || 1,
    category: category.key,
    categoryLabel: category.label,
    isOfficial: Boolean(row.is_official),
    activeUserCount: chatRoomActiveUserCount(row.id, row.bot_enabled),
    recentMessageCount: row.recent_message_count || 0,
    lastMessageAt: row.last_message_at || "",
    latestContent: row.latest_content || "",
    botEnabled: Boolean(row.bot_enabled),
    isJoined: chatRoomIsJoined(row.id, currentUser?.id),
    canEnter: userLevel >= (row.min_level || 1),
  };
}

function chatCategory(value) {
  return (
    chatRoomCategories.find((category) => category.key === value) ||
    chatRoomCategories[0]
  );
}

function chatRoomMembers(roomId) {
  const onlineIds = new Set(activeChatUserIds(roomId));
  return all(
    `SELECT
       member.role AS room_role,
       member.joined_at,
       member.last_seen_at,
       u.id,
       u.nickname,
       u.avatar_url,
       u.role AS user_role,
       u.email
     FROM chat_room_members member
     JOIN users u ON u.id = member.user_id
     WHERE member.room_id = ?
     ORDER BY
       CASE WHEN member.role = 'manager' THEN 0 ELSE 1 END,
       member.joined_at ASC`,
    [roomId],
  ).map((row) => {
    const isBot = isChatBotEmail(row.email) || row.nickname === "小樱";
    const online = isBot || onlineIds.has(row.id);
    return {
      id: row.id,
      nickname: row.nickname || "",
      avatarUrl: row.avatar_url || "",
      avatarAsset: isBot ? chatBotRoomAvatarAsset : "",
      skinId: isBot ? chatBotRoomSkinId : "",
      role: row.room_role || "member",
      isAdmin: row.user_role === "admin" || isBot,
      isBot,
      online,
      joinedAt: row.joined_at || "",
      lastSeenAt: online ? "" : row.last_seen_at || "",
    };
  });
}

function chatRoomActiveUserCount(roomId, botEnabled) {
  const ids = new Set(activeChatUserIds(roomId));
  return ids.size + (botEnabled ? 1 : 0);
}

function chatRoomActivityScore(roomId, activeUserCount) {
  const recent = one(
    `SELECT COUNT(*) AS count
     FROM chat_messages
     WHERE room_id = ?
       AND status = 'visible'
       AND created_at >= datetime('now', '-10 minutes')`,
    [roomId],
  )?.count || 0;
  return Number(activeUserCount || 0) + Number(recent || 0) * 2;
}

function markChatRoomRead(roomId, userId) {
  if (!roomId || !userId) return;
  run(
    `UPDATE chat_room_members
     SET last_read_at = datetime('now'),
         last_read_message_id = COALESCE(
           (SELECT MAX(id)
            FROM chat_messages
            WHERE room_id = ? AND status = 'visible'),
           last_read_message_id
         )
     WHERE room_id = ? AND user_id = ?`,
    [roomId, roomId, userId],
  );
}

function isChatBotEmail(email) {
  return email === "chatbot@system.local" || email === "chat-bot@system.local";
}

function chatRoomIsJoined(roomId, userId) {
  if (!userId) return false;
  return Boolean(
    one("SELECT 1 FROM chat_room_members WHERE room_id = ? AND user_id = ?", [
      roomId,
      userId,
    ]),
  );
}

function defaultChatRoomAvatar(roomId) {
  return `${config.apiPrefix}/chat/rooms/default-avatar.svg`;
}

function normalizeChatRoomId(value) {
  return (
    String(value || "")
      .trim()
      .replace(/[^\w:.-]/g, "")
      .slice(0, 80) || "global"
  );
}

function insertChatBotDirectMessage({
  userId,
  sender,
  content,
  metadata = {},
}) {
  const result = run(
    `INSERT INTO chat_bot_direct_messages
       (user_id, sender, content, metadata)
     VALUES (?, ?, ?, ?)`,
    [
      userId,
      sender === "user" ? "user" : "bot",
      String(content || "").trim(),
      JSON.stringify(metadata || {}),
    ],
  );
  return one("SELECT * FROM chat_bot_direct_messages WHERE id = ?", [
    Number(result.lastInsertRowid),
  ]);
}

function recentChatBotDirectMessages(userId, beforeId, limit = 12) {
  return all(
    `SELECT sender, content
     FROM chat_bot_direct_messages
     WHERE user_id = ?
       AND id < ?
     ORDER BY id DESC
     LIMIT ?`,
    [userId, beforeId, limit],
  ).reverse();
}

function chatBotDirectMessageJson(row) {
  let metadata = {};
  try {
    metadata = JSON.parse(row?.metadata || "{}");
  } catch {
    metadata = {};
  }
  return {
    id: row.id,
    sender: row.sender || "bot",
    content: row.content || "",
    share: metadata.share || {},
    createdAt: row.created_at || "",
  };
}

async function serveProfileImage(folder, rawFile, reply) {
  const file = String(rawFile || "");
  if (!/^[a-z0-9-]+\.(aac|gif|jpg|jpeg|m4a|mp3|ogg|pdf|png|txt|wav|webm|webp|zip)$/i.test(file)) {
    throw badRequest("file is invalid");
  }
  const filePath = path.join(config.rootDir, "data", "uploads", folder, file);
  if (isManagedUploadRetired(folder, file)) {
    const retired = new Error("file not found");
    retired.statusCode = 404;
    throw retired;
  }
  try {
    await stat(filePath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    const notFound = new Error("file not found");
    notFound.statusCode = 404;
    throw notFound;
  }
  return reply
    .header("Cache-Control", "no-store")
    .header("X-Content-Type-Options", "nosniff")
    .type(contentTypeForUpload(file))
    .send(createReadStream(filePath));
}

function currentProfileResourceUrls(userId) {
  const user = one(
    `SELECT avatar_url, profile_banner_url, dynamic_avatar_url
     FROM users
     WHERE id = ?`,
    [userId],
  );
  if (!user) throw badRequest("user not found");
  return [
    user.avatar_url,
    user.profile_banner_url,
    user.dynamic_avatar_url,
    ...all(
      `SELECT image_url
       FROM profile_photos
       WHERE user_id = ?`,
      [userId],
    ).map((row) => row.image_url),
  ].filter(Boolean);
}

async function cleanupProfileUploadUrls(request, urls, { phase }) {
  try {
    const result = retireManagedUploadUrls({
      userId: request.user.id,
      urls,
    });
    if (result.failedCount > 0) {
      warnUploadLifecycleFailure(request, phase, {
        code: "upload_delete_deferred",
      });
      scheduleRetiredUploadDeleteRetry(request.log);
    }
  } catch (error) {
    warnUploadLifecycleFailure(request, phase, error);
    scheduleManagedUploadRetirement({
      userId: request.user.id,
      urls,
      logger: request.log,
    });
  }
}

async function deleteRetiredProfileUploadKeys(request, keys, { phase }) {
  try {
    const result = deleteRetiredManagedUploadKeys(keys);
    if (result.failedCount > 0) {
      warnUploadLifecycleFailure(request, phase, {
        code: "upload_delete_deferred",
      });
      scheduleRetiredUploadDeleteRetry(request.log);
    }
  } catch (error) {
    warnUploadLifecycleFailure(request, phase, error);
    scheduleRetiredUploadDeleteRetry(request.log);
  }
}

function warnUploadLifecycleFailure(request, phase, error) {
  request.log?.warn?.(
    {
      uploadLifecycle: {
        phase,
        errorCode: error?.code || "upload_cleanup_failed",
      },
    },
    "profile upload lifecycle cleanup failed",
  );
}

async function handleProfileImageUpload(request, forcedKind) {
  const body = request.body || {};
  const uploadKind =
    profileImageUploadKinds[forcedKind || optionalString(body.kind, 40)];
  if (!uploadKind) throw badRequest("upload_kind_invalid");

  const mimeType = optionalString(body.mimeType, 80).toLowerCase();
  const dataBase64 = optionalString(body.dataBase64, 7 * 1024 * 1024);
  const extension = profileImageExtensionsByMime[mimeType];
  if (!extension || !uploadKind.mimes.has(mimeType)) {
    throw badRequest(`${uploadKind.errorPrefix}_type_invalid`);
  }
  if (!dataBase64) throw badRequest(`${uploadKind.errorPrefix}_file_required`);

  const bytes = Buffer.from(dataBase64, "base64");
  if (bytes.length <= 0 || bytes.length > 5 * 1024 * 1024) {
    throw badRequest(`${uploadKind.errorPrefix}_file_too_large`);
  }
  if (!validateUploadBytes(mimeType, bytes)) {
    throw badRequest(`${uploadKind.errorPrefix}_content_invalid`);
  }

  const fileName = await withUploadLock(request.user.id, async () => {
    try {
      await pruneOrphanedUserUploads({
        rootDir: config.rootDir,
        apiPrefix: config.apiPrefix,
        folders: profileImageFolders,
        userId: request.user.id,
        referencedUrls: referencedUploadUrls(),
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: config.uploadOrphanGraceMs,
      });
    } catch (error) {
      warnUploadLifecycleFailure(request, "stale_orphan_prune", error);
    }

    const usage = await inspectUserUploadUsage({
      rootDir: config.rootDir,
      folders: profileImageFolders,
      userId: request.user.id,
    });
    const maxFiles = Math.max(1, config.uploadMaxFilesPerUser);
    const maxBytes = Math.max(5 * 1024 * 1024, config.uploadMaxBytesPerUser);
    if (usage.files >= maxFiles) {
      throw badRequest("upload_file_quota_exceeded");
    }
    if (usage.bytes + bytes.length > maxBytes) {
      throw badRequest("upload_storage_quota_exceeded");
    }
    const uploadDir = path.join(
      config.rootDir,
      "data",
      "uploads",
      uploadKind.folder,
    );
    const generated = `${request.user.id}-${Date.now()}-${randomUUID()}.${extension}`;
    await writeUploadAtomically({
      directory: uploadDir,
      fileName: generated,
      bytes,
    });
    return generated;
  });

  const host = String(request.headers.host || request.hostname || "").replace(
    /\/+$/g,
    "",
  );
  const baseUrl = `${request.protocol}://${host}${config.apiPrefix}`;
  return { url: `${baseUrl}/uploads/profile/${uploadKind.folder}/${fileName}` };
}

function enforceUploadRateLimit(request, reply) {
  return enforceRateLimits(request, reply, [
    {
      scope: "profile_upload_user",
      key: request.user?.id || request.ip || "unknown",
      limit: 30,
      windowMs: 60 * 60 * 1000,
      error: "upload_rate_limited",
    },
  ]);
}

function contentTypeForUpload(file) {
  const ext = path.extname(file).toLowerCase();
  if (ext === ".aac") return "audio/aac";
  if (ext === ".gif") return "image/gif";
  if (ext === ".m4a") return "audio/mp4";
  if (ext === ".mp3") return "audio/mpeg";
  if (ext === ".ogg") return "audio/ogg";
  if (ext === ".pdf") return "application/pdf";
  if (ext === ".txt") return "text/plain";
  if (ext === ".png") return "image/png";
  if (ext === ".wav") return "audio/wav";
  if (ext === ".webm") return "audio/webm";
  if (ext === ".webp") return "image/webp";
  if (ext === ".zip") return "application/zip";
  return "image/jpeg";
}

function countSignInStreakDays(userId) {
  const rows = all(
    `SELECT date(created_at) AS sign_date
     FROM user_reward_events
     WHERE user_id = ?
       AND action = 'daily_signin'
     GROUP BY date(created_at)
     ORDER BY sign_date DESC`,
    [userId],
  );
  const dates = new Set(rows.map((row) => row.sign_date).filter(Boolean));
  if (dates.size === 0) return 0;

  const cursor = new Date();
  const today = isoDate(cursor);
  if (!dates.has(today)) {
    cursor.setDate(cursor.getDate() - 1);
  }

  let streak = 0;
  while (dates.has(isoDate(cursor))) {
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }
  return streak;
}

function isoDate(value) {
  return value.toISOString().slice(0, 10);
}

function shopItemJson(row) {
  return {
    id: row.id,
    name: row.name,
    description: row.description || "",
    priceCoins: row.price_coins || 0,
    itemType: row.item_type || "cosmetic",
    minLevel: row.min_level || 0,
    assetValue: row.asset_value || "",
    previewUrl: row.preview_url || "",
    sortOrder: Number(row.sort_order || 0),
    status: row.status || "active",
    revision: Number(row.revision || 1),
    createdAt: row.created_at,
    updatedAt: row.updated_at || row.created_at,
  };
}

function normalizeEquipmentSlot(value) {
  const slot = optionalString(value, 40);
  return [
    "avatar_frame",
    "chat_bubble",
    "chat_room_theme",
    "profile_skin",
    "sticker_pack",
  ].includes(slot)
    ? slot
    : "";
}

function normalizeGender(value) {
  const gender = optionalString(value, 20);
  return ["male", "female", "private"].includes(gender) ? gender : "private";
}

function equipmentSlotForItem(type) {
  return normalizeEquipmentSlot(type);
}

function photoWallLimit(level) {
  if (level >= 6) return 9;
  if (level >= 4) return 6;
  if (level >= 2) return 3;
  return 1;
}
