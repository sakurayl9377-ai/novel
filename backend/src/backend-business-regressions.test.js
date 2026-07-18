import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-backend-business-'));
process.env.DB_PATH = path.join(tempDir, 'business-regressions.sqlite');
process.env.TOKEN_SECRET = 'business-regressions-token-secret';
process.env.ADMIN_USERNAME = 'business-regressions-admin';
process.env.ADMIN_PASSWORD = 'business-regressions-admin-password';
process.env.SMTP_HOST = '';
process.env.SMTP_USER = '';
process.env.SMTP_PASS = '';

const Fastify = (await import('fastify')).default;
const { authRequired, createSession } = await import('./auth.js');
const { config } = await import('./config.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { contentRoutes } = await import('./routes-content.js');
const { userRoutes } = await import('./routes-user.js');

test('backend business consistency regressions', async (t) => {
  config.rootDir = tempDir;
  migrate();

  const app = Fastify({ logger: false });
  app.decorate('authRequired', authRequired);
  app.register(contentRoutes);
  app.register(userRoutes);
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error:
        error.publicCode ||
        (status >= 500 ? 'internal_error' : error.message),
    });
  });

  try {
    await app.ready();

    await t.test('shop redemption is atomic and idempotent', async () => {
      const shopper = insertUser({
        email: 'shopper@example.test',
        nickname: 'shopper',
        level: 10,
        sakuraCoins: 1000,
      });
      const token = createSession(shopper.id);
      const item = one("SELECT * FROM shop_items WHERE id = 'skin-sakura-card'");
      assert.ok(item);

      const responses = await Promise.all([
        redeem(app, token, item.id),
        redeem(app, token, item.id),
      ]);
      assert.deepEqual(
        responses.map((response) => response.statusCode),
        [200, 200],
      );
      assert.deepEqual(
        responses.map((response) => response.json().alreadyOwned).sort(),
        [false, true],
      );
      assert.equal(
        one('SELECT sakura_coins FROM users WHERE id = ?', [shopper.id])
          .sakura_coins,
        1000 - item.price_coins,
      );
      assert.equal(
        one(
          'SELECT COUNT(*) AS count FROM user_inventory WHERE user_id = ? AND item_id = ?',
          [shopper.id, item.id],
        ).count,
        1,
      );
      const shopLedger = one(
        `SELECT * FROM user_reward_events
         WHERE user_id = ? AND action = 'shop_redeem' AND related_id = ?`,
        [shopper.id, item.id],
      );
      assert.equal(shopLedger.coins_delta, -item.price_coins);
      assert.equal(shopLedger.related_type, 'shop_item');
      assert.equal(
        one(
          `SELECT COUNT(*) AS count FROM user_reward_events
           WHERE user_id = ? AND action = 'shop_redeem' AND related_id = ?`,
          [shopper.id, item.id],
        ).count,
        1,
        'an idempotent replay must not duplicate the ledger debit',
      );

      const poorShopper = insertUser({
        email: 'poor-shopper@example.test',
        nickname: 'poor-shopper',
        level: 10,
        sakuraCoins: 0,
      });
      const rejected = await redeem(app, createSession(poorShopper.id), item.id);
      assert.equal(rejected.statusCode, 400);
      assert.equal(rejected.json().error, 'coins_not_enough');
      assert.equal(
        one(
          'SELECT COUNT(*) AS count FROM user_inventory WHERE user_id = ? AND item_id = ?',
          [poorShopper.id, item.id],
        ).count,
        0,
        'a failed debit must roll back the provisional inventory row',
      );
      assert.equal(
        one(
          `SELECT COUNT(*) AS count FROM user_reward_events
           WHERE user_id = ? AND action = 'shop_redeem'`,
          [poorShopper.id],
        ).count,
        0,
        'a failed debit must not leave a ledger event',
      );
    });

    await t.test('following the same user can only earn one lifetime reward', async () => {
      const follower = insertUser({
        email: 'follower@example.test',
        nickname: 'follower',
      });
      const target = insertUser({
        email: 'follow-target@example.test',
        nickname: 'follow-target',
      });
      const token = createSession(follower.id);

      assert.equal((await follow(app, token, target.id)).statusCode, 200);
      assert.equal((await follow(app, token, target.id)).statusCode, 200);
      assert.equal(
        (
          await app.inject({
            method: 'DELETE',
            url: `/users/${target.id}/follow`,
            headers: bearer(token),
          })
        ).statusCode,
        200,
      );
      assert.equal((await follow(app, token, target.id)).statusCode, 200);

      const reward = one(
        `SELECT COUNT(*) AS count, COALESCE(SUM(points_delta), 0) AS points
         FROM user_reward_events
         WHERE user_id = ?
           AND action = 'follow_user'
           AND related_type = 'user'
           AND related_id = ?`,
        [follower.id, String(target.id)],
      );
      assert.equal(reward.count, 1);
      assert.equal(reward.points, 2);
      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_follow_reward_claims
           WHERE follower_id = ? AND following_id = ?`,
          [follower.id, target.id],
        ).count,
        1,
      );
    });

    await t.test('a capped first follow still consumes its per-target reward claim', async () => {
      const follower = insertUser({
        email: 'capped-follower@example.test',
        nickname: 'capped-follower',
      });
      const target = insertUser({
        email: 'capped-target@example.test',
        nickname: 'capped-target',
      });
      for (let index = 0; index < 10; index += 1) {
        run(
          `INSERT INTO user_reward_events
             (user_id, action, related_type, related_id)
           VALUES (?, 'follow_user', 'user', ?)`,
          [follower.id, `historic-${index}`],
        );
      }
      const token = createSession(follower.id);
      assert.equal((await follow(app, token, target.id)).statusCode, 200);
      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_reward_events
           WHERE user_id = ? AND action = 'follow_user' AND related_id = ?`,
          [follower.id, String(target.id)],
        ).count,
        0,
      );
      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_follow_reward_claims
           WHERE follower_id = ? AND following_id = ?`,
          [follower.id, target.id],
        ).count,
        1,
      );

      await app.inject({
        method: 'DELETE',
        url: `/users/${target.id}/follow`,
        headers: bearer(token),
      });
      run(
        "UPDATE user_reward_events SET created_at = datetime('now', '-1 day') WHERE user_id = ?",
        [follower.id],
      );
      assert.equal((await follow(app, token, target.id)).statusCode, 200);
      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_reward_events
           WHERE user_id = ? AND action = 'follow_user' AND related_id = ?`,
          [follower.id, String(target.id)],
        ).count,
        0,
      );
    });

    await t.test('migration preserves already-earned follow reward history', () => {
      const follower = insertUser({
        email: 'legacy-follower@example.test',
        nickname: 'legacy-follower',
      });
      const target = insertUser({
        email: 'legacy-follow-target@example.test',
        nickname: 'legacy-follow-target',
      });
      run(
        `INSERT INTO user_reward_events
           (user_id, action, points_delta, related_id)
         VALUES (?, 'follow_user', 2, ?)`,
        [follower.id, String(target.id)],
      );
      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_follow_reward_claims
           WHERE follower_id = ? AND following_id = ?`,
          [follower.id, target.id],
        ).count,
        0,
      );

      migrate();

      assert.equal(
        one(
          `SELECT COUNT(*) AS count
           FROM user_follow_reward_claims
           WHERE follower_id = ? AND following_id = ?`,
          [follower.id, target.id],
        ).count,
        1,
      );
    });

    await t.test('comment replies stay on one target and one level deep', async () => {
      const author = insertUser({
        email: 'commenter@example.test',
        nickname: 'commenter',
      });
      const token = createSession(author.id);
      const root = await postComment(app, token, {
        targetType: 'novel',
        targetId: 'novel-a',
        chapterId: 'chapter-1',
        content: 'root comment',
      });
      assert.equal(root.statusCode, 200);
      const rootId = root.json().item.id;

      const reply = await postComment(app, token, {
        targetType: 'novel',
        targetId: 'novel-a',
        chapterId: 'chapter-1',
        parentId: rootId,
        content: 'valid reply',
      });
      assert.equal(reply.statusCode, 200);
      const replyId = reply.json().item.id;

      const crossTarget = await postComment(app, token, {
        targetType: 'novel',
        targetId: 'novel-b',
        chapterId: 'chapter-1',
        parentId: rootId,
        content: 'cross-target reply',
      });
      assert.equal(crossTarget.statusCode, 400);
      assert.equal(crossTarget.json().error, 'parent_comment_target_mismatch');

      const nested = await postComment(app, token, {
        targetType: 'novel',
        targetId: 'novel-a',
        chapterId: 'chapter-1',
        parentId: replyId,
        content: 'nested reply',
      });
      assert.equal(nested.statusCode, 400);
      assert.equal(nested.json().error, 'nested_comment_reply_not_allowed');
      assert.equal(
        one('SELECT COUNT(*) AS count FROM comments WHERE user_id = ?', [author.id])
          .count,
        2,
      );
      assert.equal(
        one('SELECT reply_count FROM comments WHERE id = ?', [rootId]).reply_count,
        1,
      );
    });

    await t.test('chat history requires active room membership', async () => {
      const member = insertUser({
        email: 'chat-member@example.test',
        nickname: 'chat-member',
      });
      const speaker = insertUser({
        email: 'chat-speaker@example.test',
        nickname: 'chat-speaker',
      });
      run(
        `INSERT INTO chat_rooms
           (id, name, min_level, category, status, bot_enabled)
         VALUES ('private-test-room', 'Private Test Room', 1, 'novel', 'active', 0)`,
      );
      run(
        `INSERT INTO chat_messages (room_id, user_id, content)
         VALUES ('private-test-room', ?, 'member-only history')`,
        [speaker.id],
      );
      const token = createSession(member.id);

      const rejected = await app.inject({
        method: 'GET',
        url: '/chat/rooms/private-test-room/messages',
        headers: bearer(token),
      });
      assert.equal(rejected.statusCode, 403);
      assert.equal(rejected.json().error, 'chat_room_join_required');

      run(
        `INSERT INTO chat_room_members (room_id, user_id)
         VALUES ('private-test-room', ?)`,
        [member.id],
      );
      const allowed = await app.inject({
        method: 'GET',
        url: '/chat/rooms/private-test-room/messages',
        headers: bearer(token),
      });
      assert.equal(allowed.statusCode, 200);
      assert.deepEqual(
        allowed.json().items.map((item) => item.content),
        ['member-only history'],
      );
    });

    await t.test('public danmaku writes cannot create or override global aliases', async () => {
      const author = insertUser({
        email: 'danmaku-author@example.test',
        nickname: 'danmaku-author',
      });
      const token = createSession(author.id);

      const firstWrite = await postDanmaku(app, token, {
        videoId: 'first-write-source',
        animeId: 'attacker-anime',
        episodeId: 'episode-1',
        sourceName: 'trusted-provider',
        content: 'first write',
      });
      assert.equal(firstWrite.statusCode, 200);
      assert.equal(
        firstWrite.json().item.videoId,
        'anime:attacker-anime:episode:episode-1',
      );
      assert.equal(
        one(
          'SELECT COUNT(*) AS count FROM danmaku_video_aliases WHERE alias_video_id = ?',
          ['first-write-source'],
        ).count,
        0,
      );

      run(
        `INSERT INTO danmaku_video_aliases
           (alias_video_id, canonical_video_id, anime_id, episode_id, source_name)
         VALUES ('legacy-untrusted-source', 'anime:poison:episode:1', 'poison', '1', '')`,
      );
      const legacyUntrusted = await postDanmaku(app, token, {
        videoId: 'legacy-untrusted-source',
        content: 'ignore untrusted alias',
      });
      assert.equal(legacyUntrusted.statusCode, 200);
      assert.equal(legacyUntrusted.json().item.videoId, 'legacy-untrusted-source');

      run(
        `INSERT INTO danmaku_video_aliases
           (alias_video_id, canonical_video_id, anime_id, episode_id, source_name)
         VALUES ('trusted-source', 'anime:legit:episode:1', 'legit', '1', 'trusted-provider')`,
      );
      const trusted = await postDanmaku(app, token, {
        videoId: 'trusted-source',
        content: 'trusted alias',
      });
      assert.equal(trusted.statusCode, 200);
      assert.equal(trusted.json().item.videoId, 'anime:legit:episode:1');

      const conflictingContext = await postDanmaku(app, token, {
        videoId: 'trusted-source',
        animeId: 'other-anime',
        episodeId: 'episode-9',
        content: 'context wins',
      });
      assert.equal(conflictingContext.statusCode, 200);
      assert.equal(
        conflictingContext.json().item.videoId,
        'anime:legit:episode:1',
      );
      assert.equal(
        one(
          'SELECT canonical_video_id FROM danmaku_video_aliases WHERE alias_video_id = ?',
          ['trusted-source'],
        ).canonical_video_id,
        'anime:legit:episode:1',
      );
    });
  } finally {
    await app.close();
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function insertUser({
  email,
  nickname,
  level = 0,
  points = 0,
  sakuraCoins = 0,
}) {
  const result = run(
    `INSERT INTO users
       (email, nickname, password_hash, level, points, sakura_coins, status)
     VALUES (?, ?, 'unused-test-password-hash', ?, ?, ?, 'active')`,
    [email, nickname, level, points, sakuraCoins],
  );
  return one('SELECT * FROM users WHERE id = ?', [result.lastInsertRowid]);
}

function bearer(token) {
  return { authorization: `Bearer ${token}` };
}

function redeem(app, token, itemId) {
  return app.inject({
    method: 'POST',
    url: `/shop/items/${itemId}/redeem`,
    headers: bearer(token),
  });
}

function follow(app, token, targetId) {
  return app.inject({
    method: 'POST',
    url: `/users/${targetId}/follow`,
    headers: bearer(token),
  });
}

function postComment(app, token, payload) {
  return app.inject({
    method: 'POST',
    url: '/comments',
    headers: bearer(token),
    payload,
  });
}

function postDanmaku(app, token, payload) {
  return app.inject({
    method: 'POST',
    url: '/danmaku',
    headers: bearer(token),
    payload: {
      timeMs: 1000,
      ...payload,
    },
  });
}
