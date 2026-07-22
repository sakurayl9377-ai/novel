import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-signin-"));
process.env.DB_PATH = path.join(tempDir, "signin.sqlite");
process.env.TOKEN_SECRET = "signin-test-token-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "signin-test-settings-secret";
process.env.ADMIN_USERNAME = "signin-test-admin";
process.env.ADMIN_PASSWORD = "signin-test-admin-password";
process.env.SMTP_HOST = "";
process.env.SMTP_USER = "";
process.env.SMTP_PASS = "";

const Fastify = (await import("fastify")).default;
const { authRequired, createSession } = await import("./auth.js");
const { closeDb, migrate, one, run } = await import("./db.js");
const { userRoutes } = await import("./routes-user.js");
const { hashPassword } = await import("./security.js");

test("daily sign-in is idempotent and follows the Shanghai calendar day", async () => {
  migrate();
  const app = Fastify({ logger: false });
  app.decorate("authRequired", authRequired);
  app.register(userRoutes);
  await app.ready();

  try {
    const userId = insertUser("signin-once");
    const token = createSession(userId);
    const first = await signIn(app, token);
    const second = await signIn(app, token);

    assert.equal(first.statusCode, 200);
    assert.equal(first.json().alreadySigned, false);
    assert.deepEqual(first.json().reward, {
      id: first.json().reward.id,
      action: "daily_signin",
      points: 20,
      coins: 500,
      description: first.json().reward.description,
    });
    assert.equal(second.statusCode, 200);
    assert.equal(second.json().alreadySigned, true);
    assert.equal(second.json().reward, null);
    assert.equal(
      one(
        "SELECT COUNT(*) AS count FROM user_reward_events WHERE user_id = ? AND action = 'daily_signin'",
        [userId],
      ).count,
      1,
    );
    const balance = one(
      "SELECT points, sakura_coins FROM users WHERE id = ?",
      [userId],
    );
    assert.equal(balance.points, 20);
    assert.equal(balance.sakura_coins, 500);

    const profile = second.json();
    assert.equal(
      profile.dailyRewards.find((item) => item.action === "daily_signin")
        .completed,
      true,
    );
    assert.equal(profile.user.growth.signInStreakDays, 1);

    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'shop_redeem', -60, '商城消费', 'shop_item', 'test-item')`,
      [userId],
    );
    const afterDebit = await profileFor(app, token);
    assert.equal(afterDebit.user.growth.dailyCoinsEarned, 500);
    assert.equal(afterDebit.dailyCaps.coinsEarned, 500);
    assert.equal(afterDebit.dailyCaps.coinsRemaining, 0);

    const boundaryUserId = insertUser("signin-boundary");
    const boundaryToken = createSession(boundaryUserId);
    run(
      `INSERT INTO user_reward_events
         (user_id, action, points_delta, coins_delta, description, created_at)
       VALUES (?, 'daily_signin', 20, 500, '每日签到', ?)`,
      [boundaryUserId, shanghaiTodayAtFiveMinutesPastMidnightUtc()],
    );
    const boundaryProfile = await profileFor(app, boundaryToken);
    assert.equal(
      boundaryProfile.dailyRewards.find(
        (item) => item.action === "daily_signin",
      ).completed,
      true,
    );
    assert.equal(boundaryProfile.user.growth.signInStreakDays, 1);
    const boundaryRepeat = await signIn(app, boundaryToken);
    assert.equal(boundaryRepeat.json().alreadySigned, true);
    assert.equal(
      one(
        "SELECT COUNT(*) AS count FROM user_reward_events WHERE user_id = ? AND action = 'daily_signin'",
        [boundaryUserId],
      ).count,
      1,
    );
  } finally {
    await app.close();
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function insertUser(suffix) {
  return Number(
    run(
      `INSERT INTO users (email, nickname, password_hash)
       VALUES (?, ?, ?)`,
      [
        `${suffix}@example.test`,
        suffix,
        hashPassword("test-password"),
      ],
    ).lastInsertRowid,
  );
}

function signIn(app, token) {
  return app.inject({
    method: "POST",
    url: "/users/me/signin",
    headers: { authorization: `Bearer ${token}` },
    payload: {},
  });
}

async function profileFor(app, token) {
  const response = await app.inject({
    method: "GET",
    url: "/users/me/profile",
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(response.statusCode, 200);
  return response.json();
}

function shanghaiTodayAtFiveMinutesPastMidnightUtc() {
  const nowInShanghai = new Date(Date.now() + 8 * 60 * 60 * 1000);
  const utc = new Date(
    Date.UTC(
      nowInShanghai.getUTCFullYear(),
      nowInShanghai.getUTCMonth(),
      nowInShanghai.getUTCDate(),
      -8,
      5,
    ),
  );
  return utc.toISOString().slice(0, 19).replace("T", " ");
}
