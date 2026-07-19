import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-settings-workbench-"));
process.env.DB_PATH = path.join(tempDir, "settings.sqlite");
process.env.TOKEN_SECRET = "settings-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "settings-workbench-encryption-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { chatBotSettings } = await import("./chat-bot.js");

const pngBytes = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

test("settings workbench validates independent groups and local bot avatars", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const login = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = login.token;

    const initial = await jsonRequest(app, "GET", "/admin/settings/workbench", undefined, token);
    assert.equal(initial.health.enabledCount, 0);
    assert.equal(initial.chatBot.apiKey.configured, false);
    assert.equal(JSON.stringify(initial).includes("bot-secret-value"), false);

    const missingAnnouncement = await rawJsonRequest(
      app,
      "PATCH",
      "/admin/settings/app-announcement",
      { enabled: true, title: "维护" },
      token,
    );
    assert.equal(missingAnnouncement.statusCode, 400);
    assert.equal(missingAnnouncement.json().error, "app_announcement_content_required");

    await jsonRequest(
      app,
      "PATCH",
      "/admin/settings/app-announcement",
      { enabled: true, title: "维护公告", content: "今晚维护" },
      token,
    );
    await jsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      {
        enabled: false,
        provider: "nvidia",
        botName: "小樱",
        skinId: "sakura",
        triggerMode: "mention",
        systemPrompt: "请简短回答",
      },
      token,
    );
    await jsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      { enabled: false, provider: "openai", baseUrl: "", model: "" },
      token,
    );
    const customDisabled = await jsonRequest(
      app,
      "GET",
      "/admin/settings/workbench",
      undefined,
      token,
    );
    assert.equal(customDisabled.chatBot.provider, "openai");
    assert.equal(customDisabled.chatBot.baseUrl, "");
    const afterIndependentSave = await jsonRequest(
      app,
      "GET",
      "/admin/settings/workbench",
      undefined,
      token,
    );
    assert.equal(afterIndependentSave.appAnnouncement.content, "今晚维护");
    assert.equal(afterIndependentSave.appAnnouncement.enabled, "true");

    const missingAsr = await rawJsonRequest(
      app,
      "PATCH",
      "/admin/settings/iflytek-asr",
      { enabled: true, productType: "rtasr", appId: "app-id" },
      token,
    );
    assert.equal(missingAsr.statusCode, 400);
    assert.equal(missingAsr.json().error, "iflytek_asr_enable_requires_credentials");

    await jsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      {
        enabled: true,
        provider: "nvidia",
        apiKey: "bot-secret-value",
        botName: "小樱",
        skinId: "sakura",
        triggerMode: "smart",
        systemPrompt: "请简短回答",
      },
      token,
    );
    const storedSecret = one("SELECT value FROM app_settings WHERE key = 'chat_bot.apiKey'");
    assert.ok(storedSecret?.value);
    assert.notEqual(storedSecret.value, "bot-secret-value");
    assert.match(storedSecret.value, /^enc:v1:/);

    const externalAvatar = await rawJsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      { avatarUrl: "https://example.com/avatar.png", enabled: false },
      token,
    );
    assert.equal(externalAvatar.statusCode, 400);
    assert.equal(externalAvatar.json().error, "chat_bot_avatar_upload_required");
    const disguisedExternalAvatar = await rawJsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      { avatarUrl: "https://example.com/uploads/content/chatbot-avatars/1-avatar.png", enabled: false },
      token,
    );
    assert.equal(disguisedExternalAvatar.statusCode, 400);
    assert.equal(disguisedExternalAvatar.json().error, "chat_bot_avatar_upload_required");

    const invalidUpload = await uploadAvatar(app, token, Buffer.from("not an image"), "image/png");
    assert.equal(invalidUpload.statusCode, 400);
    assert.equal(invalidUpload.json().error, "chat_bot_avatar_content_invalid");

    const uploaded = await uploadAvatar(app, token, pngBytes, "image/png");
    assert.equal(uploaded.statusCode, 200, uploaded.body);
    const avatarUrl = uploaded.json().url;
    assert.match(avatarUrl, /\/uploads\/content\/chatbot-avatars\/\d+-[a-z0-9-]+\.png$/);
    await jsonRequest(
      app,
      "PATCH",
      "/admin/settings/chat-bot",
      { enabled: false, avatarUrl },
      token,
    );
    const storedAvatar = one("SELECT value FROM app_settings WHERE key = 'chat_bot.avatarUrl'");
    assert.equal(storedAvatar.value, avatarUrl);
    run(
      "UPDATE app_settings SET value = ? WHERE key = 'chat_bot.avatarUrl'",
      ["https://example.com/uploads/content/chatbot-avatars/1-avatar.png"],
    );
    assert.equal(chatBotSettings().avatarUrl, "");
    run(
      "UPDATE app_settings SET value = ? WHERE key = 'chat_bot.avatarUrl'",
      [avatarUrl],
    );
    assert.equal(chatBotSettings().avatarUrl, avatarUrl);
    const served = await app.inject({
      method: "GET",
      url: avatarUrl,
    });
    assert.equal(served.statusCode, 200);
    assert.equal(served.headers["content-type"], "image/png");

    const cleared = await app.inject({
      method: "DELETE",
      url: `${config.apiPrefix}/admin/settings/secrets/chat-bot/apiKey`,
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(cleared.statusCode, 200, cleared.body);
    assert.equal(one("SELECT value FROM app_settings WHERE key = 'chat_bot.apiKey'"), undefined);
    assert.equal(one("SELECT value FROM app_settings WHERE key = 'chat_bot.enabled'")?.value, "false");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

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

function uploadAvatar(app, token, bytes, mimeType) {
  const boundary = `----chat-bot-avatar-${Date.now()}-${Math.random()}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="avatar.png"\r\nContent-Type: ${mimeType}\r\n\r\n`,
    ),
    bytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  return app.inject({
    method: "POST",
    url: `${config.apiPrefix}/admin/settings/chat-bot/avatar`,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": `multipart/form-data; boundary=${boundary}`,
    },
    payload,
  });
}
