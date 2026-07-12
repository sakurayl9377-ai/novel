import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-security-"));
process.env.DB_PATH = path.join(tempDir, "security.sqlite");
process.env.TOKEN_SECRET = "security-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "initial-admin-password";
process.env.ALLOW_DEV_AUTH_CODES = "false";
process.env.SPEECH_ALLOW_REMOTE_AUDIO = "false";

const { closeDb, migrate, one, run, seedAdmin } = await import("./db.js");
const { config } = await import("./config.js");
const { hashPassword } = await import("./security.js");
const {
  iflytekTtsConfigured,
  loadAudioBytes,
  synthesizeIflytek,
} = await import("./speech-service.js");
const {
  clearRateLimitsForTests,
  consumeRateLimit,
} = await import("./rate-limit.js");
const {
  inspectUserUploadUsage,
  validateUploadBytes,
} = await import("./upload-security.js");
const {
  chatBotSettings,
  resolveChatBotProviderSettings,
  testChatBotReply,
} = await import("./chat-bot.js");
const {
  decryptSettingSecret,
  encryptSettingSecret,
  isEncryptedSettingSecret,
} = await import("./settings-secrets.js");
const {
  normalizeProxyGroupSelection,
  normalizeProxySubscriptionUrl,
} = await import("./proxy-control-service.js");

try {
  config.rootDir = tempDir;
  migrate();
  seedAdmin();
  const admin = one("SELECT * FROM users WHERE email = ?", ["admin@admin.local"]);
  assert(admin, "seedAdmin should create the initial administrator");

  const rotatedHash = hashPassword("rotated-password");
  run(
    `UPDATE users
     SET nickname = 'locked-admin', password_hash = ?, status = 'banned'
     WHERE id = ?`,
    [rotatedHash, admin.id],
  );
  seedAdmin();
  const preserved = one("SELECT * FROM users WHERE id = ?", [admin.id]);
  assert.equal(preserved.nickname, "locked-admin");
  assert.equal(preserved.password_hash, rotatedHash);
  assert.equal(preserved.status, "banned");

  const encryptedFixture = encryptSettingSecret("nvapi-encryption-fixture");
  assert.equal(isEncryptedSettingSecret(encryptedFixture), true);
  assert.equal(decryptSettingSecret(encryptedFixture), "nvapi-encryption-fixture");
  run(
    `INSERT INTO app_settings (key, value, is_secret)
     VALUES ('chat_bot.apiKey', 'nvapi-legacy-plaintext', 1)`,
  );
  migrate();
  const storedChatBotKey = one(
    "SELECT value FROM app_settings WHERE key = 'chat_bot.apiKey'",
  )?.value;
  assert.equal(isEncryptedSettingSecret(storedChatBotKey), true);
  assert.equal(chatBotSettings().apiKey, "nvapi-legacy-plaintext");

  assert.equal(
    normalizeProxySubscriptionUrl("https://subscription.example/path?token=test"),
    "https://subscription.example/path?token=test",
  );
  assert.equal(
    normalizeProxySubscriptionUrl("https://subscription.example/path with space"),
    "https://subscription.example/path%20with%20space",
  );
  assert.throws(
    () => normalizeProxySubscriptionUrl("http://subscription.example/path"),
    /proxy_subscription_url_invalid/,
  );
  assert.throws(
    () => normalizeProxySubscriptionUrl("https://user:pass@subscription.example/path"),
    /proxy_subscription_url_invalid/,
  );
  assert.deepEqual(normalizeProxyGroupSelection("GLOBAL", "US-AUTO"), {
    group: "GLOBAL",
    choice: "US-AUTO",
  });

  assert.equal(iflytekTtsConfigured(), false);
  for (const [key, value, isSecret] of [
    ["iflytek_tts.appId", "test-app-id", 0],
    ["iflytek_tts.apiKey", encryptSettingSecret("test-api-key"), 1],
    ["iflytek_tts.apiSecret", encryptSettingSecret("test-api-secret"), 1],
    ["iflytek_tts.enabled", "true", 0],
  ]) {
    run(
      `INSERT INTO app_settings (key, value, is_secret)
       VALUES (?, ?, ?)`,
      [key, value, isSecret],
    );
  }
  assert.equal(iflytekTtsConfigured(), true);
  assert.throws(
    () => synthesizeIflytek("test", { voice: "premium-voice" }),
    /speech_tts_voice_invalid/,
  );
  assert.throws(
    () => synthesizeIflytek("x".repeat(181)),
    /speech_tts_text_invalid/,
  );

  const nvidiaSettings = resolveChatBotProviderSettings({
    provider: "nvidia",
    baseUrl: "https://wrong.example/v1",
    model: "wrong-model",
  });
  assert.equal(nvidiaSettings.baseUrl, "https://integrate.api.nvidia.com/v1");
  assert.equal(nvidiaSettings.model, "google/diffusiongemma-26b-a4b-it");

  const originalFetch = globalThis.fetch;
  let nvidiaRequest;
  globalThis.fetch = async (url, options) => {
    nvidiaRequest = { url: String(url), options };
    return new Response(
      JSON.stringify({
        choices: [
          {
            message: {
              content: "<|channel>thought内部推理<channel|>在呢，我来帮你看看。",
            },
          },
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };
  try {
    const tested = await testChatBotReply({
      content: "测试连接",
      overrides: { provider: "nvidia", apiKey: "nvapi-test-key" },
    });
    const payload = JSON.parse(nvidiaRequest.options.body);
    assert.equal(
      nvidiaRequest.url,
      "https://integrate.api.nvidia.com/v1/chat/completions",
    );
    assert.equal(nvidiaRequest.options.headers.Authorization, "Bearer nvapi-test-key");
    assert.equal(payload.model, "google/diffusiongemma-26b-a4b-it");
    assert.equal(payload.temperature, 1);
    assert.equal(payload.top_p, 0.95);
    assert.equal(payload.stream, false);
    assert.equal(tested.reply, "在呢，我来帮你看看。");
  } finally {
    globalThis.fetch = originalFetch;
  }

  clearRateLimitsForTests();
  const rule = {
    scope: "security_test",
    key: "client",
    limit: 2,
    windowMs: 60000,
    now: 1000,
  };
  assert.equal(consumeRateLimit(rule).limited, false);
  assert.equal(consumeRateLimit(rule).limited, false);
  assert.equal(consumeRateLimit(rule).limited, true);

  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "base64",
  );
  assert.equal(validateUploadBytes("image/png", png), true);
  assert.equal(validateUploadBytes("image/png", Buffer.from("not-a-png")), false);
  assert.equal(validateUploadBytes("application/pdf", png), false);

  const quotaRoot = path.join(tempDir, "quota-root");
  const quotaDir = path.join(quotaRoot, "data", "uploads", "avatars");
  fs.mkdirSync(quotaDir, { recursive: true });
  fs.writeFileSync(path.join(quotaDir, `${admin.id}-one.png`), Buffer.alloc(12));
  fs.writeFileSync(path.join(quotaDir, `${admin.id}-two.png`), Buffer.alloc(20));
  fs.writeFileSync(path.join(quotaDir, `${admin.id + 1}-other.png`), Buffer.alloc(50));
  const usage = await inspectUserUploadUsage({
    rootDir: quotaRoot,
    folders: ["avatars"],
    userId: admin.id,
  });
  assert.deepEqual(usage, { files: 2, bytes: 32 });

  await assert.rejects(
    loadAudioBytes("http://127.0.0.1/internal.wav", { userId: admin.id }),
    /speech_audio_url_not_allowed/,
  );

  const audioDir = path.join(tempDir, "data", "uploads", "chat-audio");
  fs.mkdirSync(audioDir, { recursive: true });
  const audioName = `${admin.id}-owned.wav`;
  const wavHeader = Buffer.alloc(44);
  wavHeader.write("RIFF", 0, "ascii");
  wavHeader.write("WAVE", 8, "ascii");
  fs.writeFileSync(path.join(audioDir, audioName), wavHeader);
  const localAudio = await loadAudioBytes(
    `https://app.example${config.apiPrefix}/uploads/profile/chat-audio/${audioName}`,
    { userId: admin.id },
  );
  assert.equal(localAudio.bytes.length, 44);
  config.speechAudioMaxBytes = 1024;
  const oversizedName = `${admin.id}-oversized.wav`;
  fs.writeFileSync(path.join(audioDir, oversizedName), Buffer.alloc(1025));
  await assert.rejects(
    loadAudioBytes(
      `https://app.example${config.apiPrefix}/uploads/profile/chat-audio/${oversizedName}`,
      { userId: admin.id },
    ),
    /speech_audio_file_too_large/,
  );

  await assert.rejects(
    loadAudioBytes(
      `https://app.example${config.apiPrefix}/uploads/profile/chat-audio/${audioName}`,
      { userId: admin.id + 1 },
    ),
    /speech_audio_url_not_allowed/,
  );

  console.log("security ok");
} finally {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
}
