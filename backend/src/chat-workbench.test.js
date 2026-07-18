import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-chat-workbench-"));
process.env.DB_PATH = path.join(tempDir, "chat.sqlite");
process.env.TOKEN_SECRET = "chat-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "chat-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");
const { recordChatViolation } = await import("./chat-moderation.js");

test("chat workbench supports rooms, recoverable moderation and risk controls", async () => {
  const app = await buildServer();
  try {
    const memberId = insertUser("chat-member@example.com", "聊天室成员");
    const reporterId = insertUser("chat-reporter@example.com", "举报人");
    const admin = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = admin.token;

    const generatedRoom = await request(
      app,
      "POST",
      "/admin/chat/rooms",
      {
        name: "中文小说讨论室",
        category: "novel",
        minLevel: 2,
        isOfficial: true,
        botEnabled: false,
      },
      token,
    );
    const roomId = generatedRoom.item.roomId;
    assert.match(roomId, /^room-[a-z0-9]+$/);
    assert.equal(
      one("SELECT COUNT(*) AS count FROM chat_messages WHERE room_id = ?", [roomId])
        .count,
      0,
      "disabled bot must not create a welcome message",
    );

    await request(
      app,
      "POST",
      "/admin/chat/rooms",
      {
        roomId: "custom-room",
        name: "自定义房间",
        category: "anime",
        botEnabled: false,
      },
      token,
    );
    const duplicateRoom = await rawRequest(
      app,
      "POST",
      "/admin/chat/rooms",
      { roomId: "custom-room", name: "不能覆盖", botEnabled: false },
      token,
    );
    assert.equal(duplicateRoom.statusCode, 400);
    assert.equal(duplicateRoom.json().error, "chat_room_exists");
    const invalidRoom = await rawRequest(
      app,
      "POST",
      "/admin/chat/rooms",
      { roomId: "中文房间", name: "非法 ID", botEnabled: false },
      token,
    );
    assert.equal(invalidRoom.statusCode, 400);
    assert.equal(invalidRoom.json().error, "chat_room_id_invalid");

    run(
      `INSERT INTO chat_room_members (room_id, user_id, role)
       VALUES (?, ?, 'member')`,
      [roomId, memberId],
    );
    const members = await request(
      app,
      "GET",
      `/admin/chat/rooms/${encodeURIComponent(roomId)}/members?page=1&pageSize=20`,
      undefined,
      token,
    );
    assert.equal(members.total, 1);
    assert.equal(members.items[0].role, "member");
    const promoted = await request(
      app,
      "PATCH",
      `/admin/chat/rooms/${encodeURIComponent(roomId)}/members/${memberId}`,
      { role: "manager" },
      token,
    );
    assert.equal(promoted.item.role, "manager");

    const firstMessage = run(
      `INSERT INTO chat_messages (room_id, user_id, type, content)
       VALUES (?, ?, 'text', '第一条测试消息')`,
      [roomId, memberId],
    );
    const firstMessageId = Number(firstMessage.lastInsertRowid);
    const secondMessage = run(
      `INSERT INTO chat_messages (room_id, user_id, type, content, media_url)
       VALUES (?, ?, 'image', '图片说明', 'https://example.com/test.png')`,
      [roomId, memberId],
    );
    const secondMessageId = Number(secondMessage.lastInsertRowid);
    run(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason)
       VALUES (?, 'chat', ?, '疑似违规内容')`,
      [reporterId, String(firstMessageId)],
    );

    const rooms = await request(
      app,
      "GET",
      `/admin/chat/rooms?status=active&q=${encodeURIComponent("第一条")}&page=1&pageSize=10`,
      undefined,
      token,
    );
    assert.ok(rooms.total >= 1);
    assert.equal(rooms.items[0].roomId, roomId);
    assert.equal(rooms.items[0].messageCount, 2);
    assert.ok(rooms.stats.activeRooms >= 2);
    assert.equal(typeof rooms.stats.activeKeywords, "number");

    const detail = await request(
      app,
      "GET",
      `/admin/chat/rooms/detail?roomId=${encodeURIComponent(roomId)}&status=visible&page=1&pageSize=1`,
      undefined,
      token,
    );
    assert.equal(detail.total, 2);
    assert.equal(detail.items.length, 1);
    assert.equal(detail.statusCounts.visible, 2);
    assert.equal(detail.room.memberCount, 1);

    const context = await request(
      app,
      "GET",
      `/admin/chat/messages/${firstMessageId}/context`,
      undefined,
      token,
    );
    assert.equal(context.item.content, "第一条测试消息");
    assert.equal(context.room.roomId, roomId);
    assert.equal(context.nearby[0].id, secondMessageId);
    assert.equal(context.reports.length, 1);

    await request(
      app,
      "PATCH",
      `/admin/chat/messages/${firstMessageId}/status`,
      { status: "deleted" },
      token,
    );
    assert.equal(one("SELECT status FROM chat_messages WHERE id = ?", [firstMessageId]).status, "deleted");
    await request(
      app,
      "PATCH",
      "/admin/chat/messages/batch/status",
      { ids: [firstMessageId, secondMessageId], status: "visible" },
      token,
    );
    assert.equal(
      one("SELECT COUNT(*) AS count FROM chat_messages WHERE room_id = ? AND status = 'visible'", [roomId]).count,
      2,
    );

    const createdRule = await request(
      app,
      "POST",
      "/admin/chat/keywords",
      { keyword: "违禁词", matchType: "contains", note: "自动化测试" },
      token,
    );
    const ruleId = Number(createdRule.id);
    const duplicateRule = await rawRequest(
      app,
      "POST",
      "/admin/chat/keywords",
      { keyword: "违禁词", matchType: "exact" },
      token,
    );
    assert.equal(duplicateRule.statusCode, 400);
    assert.equal(duplicateRule.json().error, "chat_keyword_exists");
    const testedRule = await request(
      app,
      "POST",
      "/admin/chat/keywords/test",
      { content: "这句话包含违禁词" },
      token,
    );
    assert.equal(testedRule.matched, true);
    assert.equal(testedRule.item.id, ruleId);

    const rule = one("SELECT * FROM chat_block_keywords WHERE id = ?", [ruleId]);
    let moderation;
    for (let index = 0; index < 6; index += 1) {
      moderation = recordChatViolation({
        userId: memberId,
        roomId,
        content: `违规消息 ${index + 1}`,
        keyword: rule,
        ip: "203.0.113.9",
      });
    }
    assert.equal(moderation.action, "temp_ban");
    assert.equal(
      one("SELECT action FROM chat_violations WHERE id = ?", [moderation.violationId]).action,
      "temp_ban",
    );

    const rules = await request(
      app,
      "GET",
      "/admin/chat/keywords?status=active",
      undefined,
      token,
    );
    assert.equal(rules.items.find((item) => item.id === ruleId).hitCount, 6);
    const violations = await request(
      app,
      "GET",
      `/admin/chat/violations?action=temp_ban&roomId=${encodeURIComponent(roomId)}&page=1&pageSize=20`,
      undefined,
      token,
    );
    assert.equal(violations.total, 1);
    assert.equal(violations.items[0].action, "temp_ban");
    assert.equal(violations.actionCounts.blocked, 5);

    const blockedIps = await request(
      app,
      "GET",
      "/admin/blocked-ips?page=1&pageSize=10",
      undefined,
      token,
    );
    assert.ok(blockedIps.items.some((item) => item.ip === "203.0.113.9"));
    assert.ok(blockedIps.total >= 1);
    const invalidIp = await rawRequest(
      app,
      "POST",
      "/admin/blocked-ips",
      { ip: "not-an-ip", reason: "admin_block" },
      token,
    );
    assert.equal(invalidIp.statusCode, 400);
    assert.equal(invalidIp.json().error, "blocked_ip_invalid");

    await request(
      app,
      "DELETE",
      `/admin/chat/rooms/${encodeURIComponent(roomId)}/members/${memberId}`,
      undefined,
      token,
    );
    assert.equal(
      one("SELECT COUNT(*) AS count FROM chat_room_members WHERE room_id = ? AND user_id = ?", [roomId, memberId]).count,
      0,
    );
    await request(
      app,
      "DELETE",
      `/admin/chat/rooms/${encodeURIComponent(roomId)}`,
      undefined,
      token,
    );
    const editDissolved = await rawRequest(
      app,
      "PATCH",
      `/admin/chat/rooms/${encodeURIComponent(roomId)}`,
      { name: "不可恢复" },
      token,
    );
    assert.equal(editDissolved.statusCode, 400);
    assert.equal(editDissolved.json().error, "chat_room_dissolved");
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
  const response = await rawRequest(app, method, route, body, token);
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}

function rawRequest(app, method, route, body, token = "") {
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
