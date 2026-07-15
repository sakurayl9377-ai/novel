import { findUserByToken } from "./auth.js";
import {
  buildChatBotContentShare,
  buildChatBotReply,
  chatBotRoomAvatarAsset,
  chatBotRoomSkinId,
  chatBotSettings,
  ensureChatBotMember,
  ensureChatBotUser,
  hasPendingChatBotContentSuggestion,
  shouldChatBotReply,
} from "./chat-bot.js";
import {
  findActiveChatKeyword,
  recordChatViolation,
  refreshExpiredBan,
} from "./chat-moderation.js";
import { all, one, run } from "./db.js";
import { levelFromPoints } from "./growth.js";
import {
  horseRaceStateJson,
  horseRaceStatesJson,
  saveHorseRaceChat,
} from "./horse-race.js";
import { grantReward } from "./rewards.js";
import { danmakuJson } from "./routes-content.js";

export function registerWebSockets(app, config) {
  const chatRooms = new Map();
  const chatPresence = new Map();
  const gameSockets = new Set();
  const danmakuRooms = new Map();

  app.decorate("broadcastHorseRace", () => {
    broadcastHorseRaceState(gameSockets);
  });

  const gameTicker = setInterval(() => {
    if (gameSockets.size) broadcastHorseRaceState(gameSockets);
  }, 1000);
  gameTicker.unref?.();

  app.addHook("onClose", async () => {
    clearInterval(gameTicker);
  });

  app.decorate("broadcastDanmaku", (videoId, item) => {
    broadcast(danmakuRooms.get(videoId), {
      type: "danmaku",
      videoId,
      item,
    });
  });

  app.decorate(
    "disconnectChatRoomUser",
    (roomId, userId, reason = "chat_room_membership_revoked") => {
      let disconnected = 0;
      for (const socket of chatRooms.get(roomId) || []) {
        const session = socket.__novelChatSession;
        if (Number(session?.userId || 0) !== Number(userId)) continue;
        disconnected += 1;
        closeSocket(socket, 1008, reason);
      }
      return disconnected;
    },
  );

  app.get(config.wsChatPath, { websocket: true }, (socket, request) => {
    const query = new URL(request.url, "http://local").searchParams;
    const token = websocketToken(request, query, config);
    const user = refreshExpiredBan(findUserByToken(token));
    if (!user || user.status !== "active") {
      socket.close(1008, "unauthorized");
      return;
    }
    const roomId = normalizeRoomId(query.get("roomId") || "global");
    const room = one("SELECT * FROM chat_rooms WHERE id = ?", [roomId]);
    if (!room || room.status !== "active") {
      socket.close(1008, "room_not_found");
      return;
    }
    if (levelFromPoints(user.points || 0) < (room.min_level || 1)) {
      socket.close(1008, "room_level_required");
      return;
    }
    if (!isChatRoomMember(roomId, user.id)) {
      socket.close(1008, "chat_room_join_required");
      return;
    }
    socket.__novelChatSession = { roomId, userId: user.id, token };
    const announceEntrance = query.get("entrance") === "1";
    join(chatRooms, roomId, socket);
    markChatOnline(chatPresence, roomId, user.id);
    markChatRead(roomId, user.id);
    if (room.bot_enabled) ensureChatBotMember(roomId);
    const userEquipment = chatEquipmentForUser(user.id);
    const botUser = room.bot_enabled ? ensureChatBotUser() : null;

    send(socket, {
      type: "ready",
      roomId,
      user: {
        id: user.id,
        nickname: user.nickname,
        avatarUrl: user.avatar_url || "",
        equipment: userEquipment,
        isJoined: isChatRoomMember(roomId, user.id),
      },
    });
    if (announceEntrance && levelFromPoints(user.points || 0) >= 7) {
      broadcastChat(chatRooms.get(roomId), {
        type: "entrance",
        roomId,
        effect: "lv7",
        user: {
          id: user.id,
          nickname: user.nickname,
          avatarUrl: user.avatar_url || "",
        },
      });
    }

    const history = all(
      `SELECT m.*, u.nickname, u.avatar_url
       FROM chat_messages m
       JOIN users u ON u.id = m.user_id
       WHERE m.room_id = ? AND m.status = 'visible'
       ORDER BY m.id DESC
       LIMIT 50`,
      [roomId],
    )
      .reverse()
      .map(chatJson);
    send(socket, { type: "history", items: history });

    onSocketMessage(socket, request, config, (payload) => {
      const currentUser = currentChatSocketUser(socket);
      if (!currentUser) {
        closeSocket(socket, 1008, "chat_authorization_revoked");
        return;
      }
      if (payload.type === "ping") {
        markChatRead(roomId, currentUser.id);
        send(socket, { type: "pong", ts: Date.now() });
        return;
      }
      const type = normalizeMessageType(payload.type);
      const content = String(payload.content || "").trim();
      const mediaUrl = String(payload.mediaUrl || "").trim();
      const metadataObject =
        payload.metadata && typeof payload.metadata === "object"
          ? { ...payload.metadata }
          : {};
      const latestEquipment = chatEquipmentForUser(currentUser.id);
      if (latestEquipment.chatBubble) {
        metadataObject.chatBubble = latestEquipment.chatBubble;
      }
      if (!hasCompleteChatProfile(currentUser)) {
        send(socket, { type: "error", error: "profile_required" });
        return;
      }
      if (!content || content.length > 800) {
        send(socket, { type: "error", error: "content_invalid" });
        return;
      }
      if (!isChatRoomMember(roomId, currentUser.id)) {
        send(socket, { type: "error", error: "chat_room_join_required" });
        return;
      }
      const mentions = extractMentions(content, roomId);
      if (mentions.length) metadataObject.mentions = mentions;
      const metadata = JSON.stringify(metadataObject).slice(0, 1600);
      const blockedKeyword = findActiveChatKeyword(content);
      if (blockedKeyword) {
        const moderation = recordChatViolation({
          userId: currentUser.id,
          roomId,
          content,
          keyword: blockedKeyword,
          ip: request.ip,
        });
        send(socket, {
          type: "error",
          error:
            moderation.action === "permanent_ban"
              ? "chat_keyword_permanent_ban"
              : moderation.action === "temp_ban"
                ? "chat_keyword_temp_ban"
                : "chat_keyword_blocked",
        });
        if (moderation.action !== "blocked") {
          socket.close(1008, moderation.action);
        }
        return;
      }
      if ((type === "image" || type === "audio") && !/^https?:\/\//i.test(mediaUrl)) {
        send(socket, { type: "error", error: "media_url_invalid" });
        return;
      }
      const level = levelFromPoints(currentUser.points || 0);
      if (type === "image" && level < 3) {
        send(socket, { type: "error", error: "level_required_chat_image" });
        return;
      }
      if (type === "sticker" && level < 4) {
        send(socket, { type: "error", error: "level_required_chat_sticker" });
        return;
      }
      const result = run(
        `INSERT INTO chat_messages (room_id, user_id, type, content, media_url, metadata)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [roomId, currentUser.id, type, content, mediaUrl, metadata],
      );
      const row = one(
        `SELECT m.*, u.nickname, u.avatar_url
         FROM chat_messages m
         JOIN users u ON u.id = m.user_id
         WHERE m.id = ?`,
        [Number(result.lastInsertRowid)],
      );
      grantReward(currentUser.id, "chat_message", {
        type: "chat",
        id: String(result.lastInsertRowid),
      });
      broadcastChat(chatRooms.get(roomId), {
        type: "message",
        item: chatJson(row),
      });
      const botSessionKey = `chat:${roomId}:${currentUser.id}`;
      if (
        room.bot_enabled &&
        type === "text" &&
        botUser &&
        (shouldBotAnswer(content, mentions, botUser) ||
          hasPendingChatBotContentSuggestion(botSessionKey))
      ) {
        return replyAsChatBot({
          sockets: chatRooms.get(roomId),
          roomId,
          roomName: room.name || roomId,
          userId: currentUser.id,
          userName: currentUser.nickname,
          content,
        });
      }
    });

    socket.on("close", () => {
      leave(chatRooms, roomId, socket);
      try {
        markChatOffline(chatPresence, roomId, user.id);
      } catch (error) {
        if (error?.code !== "ERR_INVALID_STATE") throw error;
      }
    });
  });

  app.get(config.wsGamePath, { websocket: true }, (socket, request) => {
    const query = new URL(request.url, "http://local").searchParams;
    const user = refreshExpiredBan(
      findUserByToken(websocketToken(request, query, config)),
    );
    if (!user || user.status !== "active") {
      socket.close(1008, "unauthorized");
      return;
    }
    socket.__novelGameUserId = user.id;
    gameSockets.add(socket);
    send(socket, { type: "ready", user: publicGameUser(user) });
    send(socket, { type: "horse_race_state", item: horseRaceStateJson(user.id) });

    onSocketMessage(socket, request, config, (payload) => {
      if (payload.type === "ping") {
        send(socket, { type: "pong", ts: Date.now() });
        send(socket, { type: "horse_race_state", item: horseRaceStateJson(user.id) });
        return;
      }
      if (payload.type !== "chat") return;
      try {
        const currentUser = refreshExpiredBan(
          one("SELECT * FROM users WHERE id = ?", [user.id]),
        );
        if (!currentUser || currentUser.status !== "active") {
          send(socket, { type: "error", error: "account_banned" });
          socket.close(1008, "account_banned");
          return;
        }
        const item = saveHorseRaceChat({
          user: currentUser,
          content: payload.content,
        });
        broadcast(gameSockets, { type: "game_chat", item });
      } catch (error) {
        if (Number(error?.statusCode) >= 400 && Number(error?.statusCode) < 500) {
          send(socket, { type: "error", error: error.message || "chat_failed" });
          return;
        }
        throw error;
      }
    });

    socket.on("close", () => {
      gameSockets.delete(socket);
    });
  });

  app.get(config.wsDanmakuPath, { websocket: true }, (socket, request) => {
    const query = new URL(request.url, "http://local").searchParams;
    const videoId = String(query.get("videoId") || "").trim();
    if (!videoId) {
      socket.close(1008, "videoId required");
      return;
    }
    join(danmakuRooms, videoId, socket);
    send(socket, { type: "ready", videoId });

    onSocketMessage(socket, request, config, (payload) => {
      if (payload.type !== "ping") return;
      send(socket, { type: "pong", ts: Date.now() });
    });

    socket.on("close", () => leave(danmakuRooms, videoId, socket));
  });
}

function join(map, key, socket) {
  if (!map.has(key)) map.set(key, new Set());
  map.get(key).add(socket);
}

function broadcastHorseRaceState(sockets) {
  if (!sockets?.size) return;
  const userIds = [...sockets]
    .map((socket) => Number(socket.__novelGameUserId || 0))
    .filter((userId) => userId > 0);
  const states = horseRaceStatesJson(userIds);
  for (const socket of sockets) {
    const userId = Number(socket.__novelGameUserId || 0);
    send(socket, {
      type: "horse_race_state",
      item: states.get(userId) || horseRaceStateJson(userId),
    });
  }
}

function publicGameUser(user) {
  return {
    id: user.id,
    nickname: user.nickname || "",
    avatarUrl: user.avatar_url || "",
    role: user.role || "user",
  };
}

export function activeChatUserIds(roomId) {
  const users = globalThis.__novelChatPresence?.get(roomId);
  return users ? [...users.keys()] : [];
}

function markChatOnline(map, roomId, userId) {
  globalThis.__novelChatPresence = map;
  if (!map.has(roomId)) map.set(roomId, new Map());
  const users = map.get(roomId);
  users.set(userId, (users.get(userId) || 0) + 1);
}

function markChatOffline(map, roomId, userId) {
  const users = map.get(roomId);
  if (!users) return;
  const nextCount = (users.get(userId) || 0) - 1;
  if (nextCount > 0) {
    users.set(userId, nextCount);
    return;
  }
  users.delete(userId);
  run(
    `UPDATE chat_room_members
     SET last_seen_at = datetime('now'),
         last_read_at = datetime('now'),
         last_read_message_id = COALESCE(
           (SELECT MAX(id)
            FROM chat_messages
            WHERE room_id = ? AND status = 'visible'),
           last_read_message_id
         )
     WHERE room_id = ? AND user_id = ?`,
    [roomId, roomId, userId],
  );
  if (!users.size) map.delete(roomId);
}

function markChatRead(roomId, userId) {
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

function leave(map, key, socket) {
  const sockets = map.get(key);
  if (!sockets) return;
  sockets.delete(socket);
  if (sockets.size === 0) map.delete(key);
}

function broadcast(sockets, payload) {
  if (!sockets) return;
  for (const socket of sockets) send(socket, payload);
}

function broadcastChat(sockets, payload) {
  if (!sockets) return;
  for (const socket of sockets) {
    if (!currentChatSocketUser(socket)) {
      closeSocket(socket, 1008, "chat_authorization_revoked");
      continue;
    }
    send(socket, payload);
  }
}

function currentChatSocketUser(socket) {
  if (socket.__novelClosing) return null;
  const session = socket.__novelChatSession;
  if (!session?.token || !session.roomId || !session.userId) return null;
  const user = refreshExpiredBan(findUserByToken(session.token));
  if (!user || user.status !== "active" || user.id !== session.userId) {
    return null;
  }
  const membership = one(
    `SELECT room.min_level
     FROM chat_room_members member
     JOIN chat_rooms room ON room.id = member.room_id
     WHERE member.room_id = ?
       AND member.user_id = ?
       AND room.status = 'active'`,
    [session.roomId, user.id],
  );
  if (
    !membership ||
    levelFromPoints(user.points || 0) < (membership.min_level || 1)
  ) {
    return null;
  }
  return user;
}

function websocketToken(request, query, settings = {}) {
  const header = String(request.headers.authorization || "");
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (match?.[1]?.trim()) return match[1].trim();
  // A malformed Authorization header must never downgrade to the legacy
  // query-string path. Query tokens are opt-in only for a time-bounded client
  // migration because reverse proxies commonly retain request URLs.
  if (header.trim() || settings.allowLegacyWebSocketQueryToken !== true) {
    return "";
  }
  const legacyToken = String(query.get("token") || "").trim();
  if (legacyToken) {
    request.log?.warn?.(
      { authTransport: "legacy_query" },
      "deprecated websocket query-token authentication used",
    );
  }
  return legacyToken;
}

function onSocketMessage(socket, request, settings, handler) {
  const maximumBytes = Math.max(
    1024,
    Math.min(1024 * 1024, Number(settings.websocketMaxPayloadBytes) || 65536),
  );
  socket.on("message", (raw, isBinary = false) => {
    if (socket.__novelClosing) return;
    const decoded = decodeSocketPayload(raw, isBinary, maximumBytes);
    if (!decoded.ok) {
      closeSocket(socket, decoded.code, decoded.reason);
      return;
    }
    try {
      const result = handler(decoded.payload);
      if (result && typeof result.catch === "function") {
        result.catch((error) => handleSocketFailure(socket, request, error));
      }
    } catch (error) {
      handleSocketFailure(socket, request, error);
    }
  });
}

function decodeSocketPayload(raw, isBinary, maximumBytes) {
  if (isBinary) {
    return { ok: false, code: 1003, reason: "binary_not_supported" };
  }
  const bytes = Buffer.isBuffer(raw)
    ? raw.length
    : Buffer.byteLength(String(raw || ""), "utf8");
  if (bytes > maximumBytes) {
    return { ok: false, code: 1009, reason: "message_too_large" };
  }
  let payload;
  try {
    payload = JSON.parse(raw.toString());
  } catch {
    return { ok: false, code: 1007, reason: "invalid_json" };
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, code: 1007, reason: "invalid_payload" };
  }
  return { ok: true, payload };
}

function handleSocketFailure(socket, request, error) {
  request.log?.error?.(
    {
      websocketError: {
        type: error?.name || "Error",
        code: error?.code || "websocket_handler_failed",
      },
    },
    "websocket message handler failed",
  );
  closeSocket(socket, 1011, "internal_error");
}

function closeSocket(socket, code, reason) {
  if (socket.__novelClosing) return;
  socket.__novelClosing = true;
  if (socket.readyState === 0 || socket.readyState === 1) {
    socket.close(code, reason);
    return;
  }
  socket.terminate?.();
}

function send(socket, payload) {
  if (socket.readyState !== 1) return;
  socket.send(JSON.stringify(payload));
}

export const websocketSecurityInternals = {
  closeSocket,
  decodeSocketPayload,
  onSocketMessage,
  websocketToken,
};

function hasCompleteChatProfile(user) {
  const nickname = String(user.nickname || "").trim();
  const defaultNickname = String(user.email || "").split("@")[0].trim();
  return (
    nickname.length > 0 &&
    nickname !== "用户" &&
    nickname !== defaultNickname
  );
}

function normalizeRoomId(value) {
  return (
    String(value)
      .trim()
      .replace(/[^\w:.-]/g, "")
      .slice(0, 80) || "global"
  );
}

function normalizeMessageType(value) {
  const type = String(value || "text").trim();
  return ["text", "image", "audio", "file", "sticker", "share"].includes(type)
    ? type
    : "text";
}

function isChatRoomMember(roomId, userId) {
  return Boolean(
    one("SELECT 1 FROM chat_room_members WHERE room_id = ? AND user_id = ?", [
      roomId,
      userId,
    ]),
  );
}

function chatEquipmentForUser(userId) {
  const rows = all(
    `SELECT e.slot, s.asset_value
     FROM user_equipment e
     JOIN shop_items s ON s.id = e.item_id
     WHERE e.user_id = ?`,
    [userId],
  );
  const equipment = {};
  for (const row of rows) {
    if (row.slot === "chat_bubble") equipment.chatBubble = row.asset_value;
    if (row.slot === "chat_room_theme") equipment.chatRoomTheme = row.asset_value;
    if (row.slot === "avatar_frame") equipment.avatarFrame = row.asset_value;
  }
  return equipment;
}

function extractMentionNames(content) {
  const names = new Set();
  const matcher = /@([^\s@，。,.!?！？:：;；()[\]{}<>《》"'“”‘’]{1,32})/gu;
  let match;
  while ((match = matcher.exec(String(content || "")))) {
    const name = match[1]?.trim();
    if (name) names.add(name);
  }
  return [...names].slice(0, 10);
}

function extractMentions(content, roomId) {
  const names = extractMentionNames(content);
  if (!names.length) return [];
  const mentions = [];
  for (const name of names) {
    const user = one(
      `SELECT u.id, u.nickname, u.avatar_url, u.role, u.email
       FROM users u
       LEFT JOIN chat_room_members member
         ON member.user_id = u.id AND member.room_id = ?
       WHERE u.status = 'active'
         AND u.nickname = ?
       ORDER BY CASE WHEN member.room_id IS NULL THEN 1 ELSE 0 END
       LIMIT 1`,
      [roomId, name],
    );
    if (user) {
      mentions.push({
        id: user.id,
        nickname: user.nickname,
        avatarUrl: user.avatar_url || "",
        isBot: isChatBotUser(user),
      });
    } else if (name === "小樱" || name === "小樱助手") {
      const bot = ensureChatBotUser();
      mentions.push({
        id: bot.id,
        nickname: bot.nickname,
        avatarUrl: bot.avatar_url || "",
        isBot: true,
      });
    }
  }
  return mentions;
}

function shouldBotAnswer(content, mentions, botUser) {
  if (mentions.some((item) => item.id === botUser.id || item.isBot)) {
    return true;
  }
  return shouldChatBotReply(content, chatBotSettings().triggerMode);
}

async function replyAsChatBot({
  sockets,
  roomId,
  roomName,
  userId,
  userName,
  content,
}) {
  const bot = ensureChatBotMember(roomId);
  const contentShare = buildChatBotContentShare(content, {
    sessionKey: `chat:${roomId}:${userId || userName || "guest"}`,
  });
  if (contentShare) {
    const hasShare = Boolean(contentShare.share);
    const metadata = JSON.stringify({
      bot: true,
      botSkinId: chatBotRoomSkinId,
      botAvatarAsset: chatBotRoomAvatarAsset,
      replyTo: userName || "",
      ...(hasShare ? { share: contentShare.share } : {}),
    });
    const result = run(
      `INSERT INTO chat_messages (room_id, user_id, type, content, metadata)
       VALUES (?, ?, ?, ?, ?)`,
      [roomId, bot.id, hasShare ? "share" : "text", contentShare.content, metadata],
    );
    const row = one(
      `SELECT m.*, u.nickname, u.avatar_url
       FROM chat_messages m
       JOIN users u ON u.id = m.user_id
       WHERE m.id = ?`,
      [Number(result.lastInsertRowid)],
    );
    broadcastChat(sockets, {
      type: "message",
      item: chatJson(row),
    });
    return;
  }
  const reply = await buildChatBotReply({
    roomId,
    roomName,
    userName,
    content,
    activeUserIds: activeChatUserIds(roomId),
  });
  const metadata = JSON.stringify({
    bot: true,
    botSkinId: chatBotRoomSkinId,
    botAvatarAsset: chatBotRoomAvatarAsset,
    replyTo: userName || "",
  });
  const result = run(
    `INSERT INTO chat_messages (room_id, user_id, type, content, metadata)
     VALUES (?, ?, 'text', ?, ?)`,
    [roomId, bot.id, reply, metadata],
  );
  const row = one(
    `SELECT m.*, u.nickname, u.avatar_url
     FROM chat_messages m
     JOIN users u ON u.id = m.user_id
     WHERE m.id = ?`,
    [Number(result.lastInsertRowid)],
  );
  broadcastChat(sockets, {
    type: "message",
    item: chatJson(row),
  });
}

function chatUserBadges(row, metadata = {}) {
  const user = userRoleSnapshot(row);
  if (user.role === "admin" || isChatBotUser(user) || metadata.bot) {
    return [
      {
        key: "admin",
        label: "admin",
        style: "rainbow",
      },
    ];
  }
  return [];
}

function chatUserSkin(row, metadata = {}) {
  const user = userRoleSnapshot(row);
  if (!isChatBotUser(user) && !metadata.bot) return {};
  return {
    skinId: chatBotRoomSkinId,
    avatarAsset: chatBotRoomAvatarAsset,
  };
}

function userRoleSnapshot(row) {
  if (row.user_role || row.user_email) {
    return {
      id: row.user_id,
      role: row.user_role || "",
      email: row.user_email || "",
      nickname: row.nickname || "",
    };
  }
  return (
    one("SELECT id, role, email, nickname FROM users WHERE id = ?", [row.user_id]) ||
    { id: row.user_id, role: "", email: "", nickname: row.nickname || "" }
  );
}

function isChatBotUser(user) {
  return (
    user?.email === "chatbot@system.local" ||
    user?.email === "chat-bot@system.local" ||
    user?.nickname === "小樱" ||
    user?.nickname === "小樱助手"
  );
}

export function chatJson(row) {
  let metadata = {};
  try {
    metadata = JSON.parse(row.metadata || "{}");
  } catch {
    metadata = {};
  }
  const skin = chatUserSkin(row, metadata);
  return {
    id: row.id,
    roomId: row.room_id,
    type: row.type || "text",
    content: row.content,
    mediaUrl: row.media_url || "",
    metadata,
    status: row.status,
    createdAt: row.created_at,
    user: {
      id: row.user_id,
      nickname: row.nickname,
      avatarUrl: row.avatar_url || "",
      badges: chatUserBadges(row, metadata),
      ...skin,
    },
  };
}
