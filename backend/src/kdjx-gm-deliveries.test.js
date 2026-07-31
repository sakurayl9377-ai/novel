import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-kdjx-delivery-'));
process.env.NODE_ENV = 'test';
process.env.DB_PATH = path.join(tempDir, 'kdjx-delivery.sqlite');
process.env.TOKEN_SECRET = 'kdjx-delivery-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'kdjx-delivery-settings-secret';
process.env.ADMIN_USERNAME = 'kdjx-delivery-test-admin';
process.env.ADMIN_PASSWORD = 'kdjx-delivery-test-admin-password';

const Fastify = (await import('fastify')).default;
const { recordAdminAudit } = await import('./admin-audit.js');
const { adminRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, all, one, run } = await import('./db.js');
const {
  deliverKdjxGmItem,
  getKdjxGmItemCatalog,
  kdjxGmDeliveryEndpointAllowed,
  normalizeKdjxGmItemCatalog,
} = await import('./kdjx-gm-deliveries.js');
const { adminKdjxGmRoutes } = await import('./routes-admin-kdjx-gm.js');
const { hashPassword } = await import('./security.js');

migrate();

after(() => {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});

const testCatalogSha256 = 'a'.repeat(64);
const catalog = {
  schemaVersion: 1,
  source: 'test generated items.lua',
  sourceSha256: testCatalogSha256,
  sourceItemCount: 3,
  itemCount: 3,
  items: [
    {
      id: 19,
      name: 'Gold Ingot',
      description: 'A test compensation item',
      type: 0,
      quality: 4,
      maxQuantity: 9999,
    },
    {
      id: 100,
      name: 'Mail Ticket',
      description: 'A test mail item',
      type: 1,
      quality: 3,
      maxQuantity: 10,
    },
    {
      id: 401,
      name: 'Gold',
      description: 'Game gold resource',
      type: 0,
      quality: 1,
      maxQuantity: 2147483647,
    },
  ],
};
const catalogItems = [
  {
    id: '19',
    name: 'Gold Ingot',
    description: 'A test compensation item',
    type: '0',
    quality: '4',
    maxQuantity: 9999,
    deliveryTypes: ['mail'],
  },
  {
    id: '100',
    name: 'Mail Ticket',
    description: 'A test mail item',
    type: '1',
    quality: '3',
    maxQuantity: 10,
    deliveryTypes: ['mail'],
  },
  {
    id: '401',
    name: 'Gold',
    description: 'Game gold resource',
    type: '0',
    quality: '1',
    maxQuantity: 2147483647,
    deliveryTypes: ['mail'],
  },
];
const clientFigureSupplement = JSON.parse(
  fs.readFileSync(
    new URL(
      '../../deploy/kdjx-backend/catalogs/kdjx-gm-client-figure-items.json',
      import.meta.url,
    ),
    'utf8',
  ),
);

test('KDJX GM catalog exposes the generated item allow-list', () => {
  const actual = getKdjxGmItemCatalog();
  assert.equal(
    actual.sourceSha256,
    '0fdf2cae03e8100569649fca110083b78c900b71891cf5bd6afcfdb9030730bd',
  );
  assert.equal(actual.items.length, 1177);
  assert.equal(actual.byId.size, actual.items.length);
  assert.deepEqual(actual.byId.get('19'), {
    id: '19',
    name: '\u795e\u5947\u80f6\u56ca',
    description: '\u53ef\u4ee5\u6539\u53d8\u7cbe\u7075\u4e2a\u4f53\u503c\u7684\u795e\u79d8\u4e4b\u7269',
    type: '0',
    quality: '4',
    maxQuantity: 9999,
    deliveryTypes: ['mail'],
  });
  assert.equal(actual.byId.get('400').maxQuantity, 2147483647);
  assert.equal(actual.byId.get('401').maxQuantity, 2147483647);
  assert.equal(actual.byId.get('402').maxQuantity, 2147483647);
  assert.deepEqual(
    clientFigureSupplement.items.map((item) => item.id),
    Array.from({ length: 14 }, (_, index) => 2269 + index),
  );
  for (const expected of clientFigureSupplement.items) {
    assert.deepEqual(actual.byId.get(String(expected.id)), {
      id: String(expected.id),
      name: expected.name,
      description: expected.description,
      type: String(expected.type),
      quality: String(expected.quality),
      maxQuantity: expected.maxQuantity,
      deliveryTypes: ['mail'],
    });
  }
  assert.equal(
    new Set(actual.items.map((item) => item.id)).size,
    actual.items.length,
  );
});

test('KDJX GM catalog rejects invalid hashes and unsafe descriptions', () => {
  assert.equal(
    normalizeKdjxGmItemCatalog(catalog).sourceSha256,
    testCatalogSha256,
  );

  for (const sourceSha256 of [
    '',
    'a'.repeat(63),
    'A'.repeat(64),
    `${'a'.repeat(64)} `,
  ]) {
    assert.throws(
      () => normalizeKdjxGmItemCatalog({ ...catalog, sourceSha256 }),
      /Invalid KDJX GM item catalog metadata/,
    );
  }

  for (const metadata of [
    { schemaVersion: '1' },
    { itemCount: '3' },
    { sourceItemCount: '2' },
    { sourceItemCount: 0 },
  ]) {
    assert.throws(
      () => normalizeKdjxGmItemCatalog({ ...catalog, ...metadata }),
      /Invalid KDJX GM item catalog metadata/,
    );
  }

  for (const description of [
    'unsafe\ndescription',
    ' unsafe description ',
    'x'.repeat(241),
  ]) {
    assert.throws(
      () => normalizeKdjxGmItemCatalog({
        ...catalog,
        items: [
          { ...catalog.items[0], description },
          catalog.items[1],
          catalog.items[2],
        ],
      }),
      /Invalid KDJX GM item description/,
    );
  }

  for (const firstItem of [
    { ...catalog.items[0], id: '19' },
    { ...catalog.items[0], name: ' Gold Ingot' },
    { ...catalog.items[0], enabled: true },
    {
      id: catalog.items[0].id,
      name: catalog.items[0].name,
      description: catalog.items[0].description,
      type: catalog.items[0].type,
      quality: catalog.items[0].quality,
    },
  ]) {
    assert.throws(
      () => normalizeKdjxGmItemCatalog({
        ...catalog,
        items: [firstItem, catalog.items[1], catalog.items[2]],
      }),
      /Invalid/,
    );
  }
});

test('KDJX GM delivery APIs protect, whitelist, reconcile, and audit grants', async () => {
  const calls = [];
  const app = await makeApp(async (input) => {
    calls.push(input);
    if (input.requestId === '22222222-2222-4222-8222-222222222222') {
      return {
        status: 'unknown',
        errorCode: 'kdjx_gm_delivery_transport_unknown',
      };
    }
    if (input.requestId === '33333333-3333-4333-8333-333333333333') {
      return {
        status: 'failed',
        errorCode: 'game_role_offline',
      };
    }
    return {
      status: 'succeeded',
      remoteReference: 'grant-reference-123',
    };
  });

  try {
    const adminId = seedUser('delivery-admin@example.test', 'admin');
    const playerId = seedUser('delivery-player@example.test', 'user');
    const incompletePlayerId = seedUser(
      'delivery-incomplete@example.test',
      'user',
    );
    const ordinaryId = seedUser('ordinary-user@example.test', 'user');
    const adminToken = createSession(adminId);
    const ordinaryToken = createSession(ordinaryId);
    seedLink(playerId);
    seedLink(incompletePlayerId, {
      gameOpenId: 'sakura_delivery_incomplete_01',
      gameAccountId: '64a000000000000000000002',
      roleId: '64b000000000000000000002',
      serverKey: 'game.cn.2',
    });
    const link = one(
      `SELECT last_role_id, last_server_key, updated_at
       FROM kdjx_game_account_links WHERE novel_user_id = ?`,
      [playerId],
    );

    const anonymous = await app.inject({
      method: 'GET',
      url: '/admin/games/kdjx/gm/catalog',
    });
    assert.equal(anonymous.statusCode, 401);
    assert.equal(anonymous.json().error, 'unauthorized');

    const forbidden = await adminRequest(
      app,
      ordinaryToken,
      'GET',
      '/admin/games/kdjx/gm/deliveries',
    );
    assert.equal(forbidden.statusCode, 403);
    assert.equal(forbidden.json().error, 'admin_required');

    const listedCatalog = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/catalog',
    );
    assert.equal(listedCatalog.statusCode, 200);
    assert.equal(listedCatalog.headers['cache-control'], 'no-store');
    assert.equal(
      listedCatalog.json().sourceSha256,
      testCatalogSha256,
    );
    assert.deepEqual(listedCatalog.json().items, catalogItems);
    assertRedacted(listedCatalog.body);

    const identityContract = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/workbench?pageSize=100',
    );
    assert.equal(identityContract.statusCode, 200, identityContract.body);
    const playersById = new Map(
      identityContract.json().players.map((player) => [player.userId, player]),
    );
    assert.equal(playersById.get(playerId).canDeliverItems, true);
    assert.equal(playersById.get(playerId).deliveryBlockCode, '');
    assert.equal(playersById.get(incompletePlayerId).canDeliverItems, false);
    assert.equal(
      playersById.get(incompletePlayerId).deliveryBlockCode,
      'kdjx_player_identity_incomplete',
    );

    const playerDetail = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/players/${playerId}`,
    );
    assert.equal(playerDetail.statusCode, 200, playerDetail.body);
    assert.equal(playerDetail.json().player.canDeliverItems, true);
    assert.equal(playerDetail.json().player.deliveryBlockCode, '');

    const incompleteDetail = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/players/${incompletePlayerId}`,
    );
    assert.equal(incompleteDetail.statusCode, 200, incompleteDetail.body);
    assert.equal(incompleteDetail.json().player.canDeliverItems, false);
    assert.equal(
      incompleteDetail.json().player.deliveryBlockCode,
      'kdjx_player_identity_incomplete',
    );

    const common = {
      deliveryType: 'mail',
      itemId: '19',
      quantity: 9999,
      expectedRoleId: link.last_role_id,
      expectedServerKey: link.last_server_key,
      expectedLinkUpdatedAt: link.updated_at,
      reason: 'Compensation for incident',
    };
    const unexpectedRequestField = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        itemName: 'Forged item name',
      },
    );
    assert.equal(unexpectedRequestField.statusCode, 400);
    assert.equal(
      unexpectedRequestField.json().error,
      'delivery_request_fields_invalid',
    );
    assert.equal(calls.length, 0);

    const incompleteLink = one(
      `SELECT last_role_id, last_server_key, updated_at
       FROM kdjx_game_account_links WHERE novel_user_id = ?`,
      [incompletePlayerId],
    );
    const blockedIdentity = await postDelivery(
      app,
      adminToken,
      incompletePlayerId,
      {
        ...common,
        requestId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        expectedRoleId: incompleteLink.last_role_id,
        expectedServerKey: incompleteLink.last_server_key,
        expectedLinkUpdatedAt: incompleteLink.updated_at,
      },
    );
    assert.equal(blockedIdentity.statusCode, 409);
    assert.equal(
      blockedIdentity.json().error,
      'kdjx_player_identity_incomplete',
    );
    assert.equal(calls.length, 0);

    const invalidUuid = await postDelivery(
      app,
      adminToken,
      playerId,
      { ...common, requestId: 'not-a-uuid' },
    );
    assert.equal(invalidUuid.statusCode, 400);
    assert.equal(invalidUuid.json().error, 'request_id_invalid');

    const unknownItem = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        itemId: '9999999999',
      },
    );
    assert.equal(unknownItem.statusCode, 404);
    assert.equal(unknownItem.json().error, 'kdjx_gm_item_not_found');
    assert.equal(calls.length, 0);

    const invalidMode = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        itemId: '100',
        deliveryType: 'direct',
      },
    );
    assert.equal(invalidMode.statusCode, 400);
    assert.equal(
      invalidMode.json().error,
      'delivery_type_invalid',
    );

    const globalOverLimit = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        quantity: 10000,
      },
    );
    assert.equal(globalOverLimit.statusCode, 400);
    assert.equal(globalOverLimit.json().error, 'kdjx_gm_quantity_exceeds_limit');

    const overLimit = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        itemId: '100',
        quantity: 11,
      },
    );
    assert.equal(overLimit.statusCode, 400);
    assert.equal(
      overLimit.json().error,
      'kdjx_gm_quantity_exceeds_limit',
    );

    const staleTarget = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        expectedRoleId: '64b000000000000000000099',
      },
    );
    assert.equal(staleTarget.statusCode, 409);
    assert.equal(staleTarget.json().error, 'kdjx_player_link_changed');
    assert.equal(calls.length, 0);

    const succeeded = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '11111111-1111-4111-8111-111111111111',
      },
    );
    assert.equal(succeeded.statusCode, 200);
    assert.equal(succeeded.json().ok, true);
    assert.equal(succeeded.json().idempotent, false);
    assert.equal(succeeded.json().delivery.status, 'succeeded');
    assert.equal(
      succeeded.json().delivery.remoteReference,
      'grant-reference-123',
    );
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      requestId: '11111111-1111-4111-8111-111111111111',
      gameOpenId: 'sakura_delivery_player_01',
      accountId: '64a000000000000000000001',
      roleId: '64b000000000000000000001',
      serverKey: 'game.cn.1',
      itemId: '19',
      itemName: 'Gold Ingot',
      quantity: 9999,
      catalogSha256: testCatalogSha256,
    });
    assertRedacted(succeeded.body);

    const repeated = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '11111111-1111-4111-8111-111111111111',
      },
    );
    assert.equal(repeated.statusCode, 200);
    assert.equal(repeated.json().ok, true);
    assert.equal(repeated.json().idempotent, true);
    assert.equal(calls.length, 1);

    const conflict = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '11111111-1111-4111-8111-111111111111',
        quantity: 9998,
      },
    );
    assert.equal(conflict.statusCode, 409);
    assert.equal(
      conflict.json().error,
      'kdjx_gm_delivery_idempotency_conflict',
    );
    assert.equal(calls.length, 1);

    const unknown = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '22222222-2222-4222-8222-222222222222',
      },
    );
    assert.equal(unknown.statusCode, 200);
    assert.equal(unknown.json().ok, false);
    assert.equal(unknown.json().delivery.status, 'unknown');

    const failed = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '33333333-3333-4333-8333-333333333333',
      },
    );
    assert.equal(failed.statusCode, 200);
    assert.equal(failed.json().ok, false);
    assert.equal(failed.json().delivery.status, 'failed');
    assert.equal(failed.json().delivery.errorCode, 'game_role_offline');
    assert.equal(calls.length, 3);

    const deliveries = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/deliveries?userId=${playerId}` +
      '&deliveryType=mail&status=unknown&q=gold',
    );
    assert.equal(deliveries.statusCode, 200, deliveries.body);
    assert.equal(deliveries.json().total, 1);
    assert.equal(deliveries.json().deliveries[0].status, 'unknown');
    assert.equal(deliveries.json().deliveries[0].deliveryType, 'mail');
    assertRedacted(deliveries.body);

    const detail = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/players/${playerId}`,
    );
    assert.equal(detail.statusCode, 200);
    assert.equal(detail.json().deliveries.length, 3);
    assert.equal(
      detail.json().deliveries.some(
        (delivery) => delivery.requestId ===
          '11111111-1111-4111-8111-111111111111',
      ),
      true,
    );

    const rows = all(
      `SELECT request_id, status FROM kdjx_gm_deliveries
       ORDER BY request_id`,
    );
    assert.equal(rows.length, 3);
    assert.equal(rows.some((row) => row.status === 'pending'), false);
    assert.ok(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE action = 'deliver_item' AND target_type = 'delivery'`,
    ).count) >= 10);
    assert.ok(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE action = 'deliver_item' AND result = 'success'`,
    ).count) >= 2);
    assert.ok(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE action = 'deliver_item'
         AND error_code = 'kdjx_player_link_changed'`,
    ).count) >= 1);
    assert.equal(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE result = 'pending'`,
    ).count), 0);
    assert.ok(Number(one(
      `SELECT COUNT(*) AS count FROM admin_audit_logs
       WHERE path LIKE '%/admin/games/kdjx/gm/players/%/deliveries'`,
    ).count) >= 10);

    const controlCharacterReason = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: '44444444-4444-4444-8444-444444444444',
        reason: 'Compensation\nfor incident',
      },
    );
    assert.equal(controlCharacterReason.statusCode, 400);
    assert.equal(controlCharacterReason.json().error, 'reason_invalid');

    run(
      `UPDATE kdjx_gm_deliveries
       SET status = 'pending',
           outcome_reference = '',
           error_code = '',
           completed_at = NULL,
           created_at = datetime('now', '-3 minutes'),
           updated_at = datetime('now', '-3 minutes')
       WHERE request_id = ?`,
      ['11111111-1111-4111-8111-111111111111'],
    );
    run(
      `INSERT INTO kdjx_gm_action_logs
        (admin_user_id, action, target_type, target_id, reason, result,
         created_at)
       VALUES (?, 'deliver_item', 'delivery', ?, ?, 'pending',
               datetime('now', '-3 minutes'))`,
      [
        adminId,
        '11111111-1111-4111-8111-111111111111',
        'Interrupted delivery',
      ],
    );
    run(
      `INSERT INTO kdjx_gm_action_logs
        (admin_user_id, action, target_type, target_id, reason, result,
         created_at)
       VALUES (?, 'deliver_item', 'delivery', ?, ?, 'pending',
               datetime('now', '-3 minutes'))`,
      [
        adminId,
        '55555555-5555-4555-8555-555555555555',
        'Interrupted before claim',
      ],
    );
    const recovered = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/deliveries',
    );
    assert.equal(recovered.statusCode, 200, recovered.body);
    assert.equal(one(
      `SELECT status FROM kdjx_gm_deliveries WHERE request_id = ?`,
      ['11111111-1111-4111-8111-111111111111'],
    ).status, 'unknown');
    assert.equal(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE action = 'deliver_item' AND result = 'pending'`,
    ).count), 0);
    assert.equal(one(
      `SELECT error_code FROM kdjx_gm_action_logs
       WHERE target_id = ? AND reason = ?`,
      [
        '11111111-1111-4111-8111-111111111111',
        'Interrupted delivery',
      ],
    ).error_code, 'kdjx_gm_delivery_stale_claim');
    assert.equal(one(
      `SELECT error_code FROM kdjx_gm_action_logs
       WHERE target_id = ?`,
      ['55555555-5555-4555-8555-555555555555'],
    ).error_code, 'kdjx_gm_delivery_stale_audit');

    const resourceGrant = await postDelivery(
      app,
      adminToken,
      playerId,
      {
        ...common,
        requestId: 'abcdabcd-abcd-4bcd-8bcd-abcdabcdabcd',
        itemId: '401',
        quantity: 900000000,
      },
    );
    assert.equal(resourceGrant.statusCode, 200, resourceGrant.body);
    assert.equal(resourceGrant.json().delivery.quantity, 900000000);
    assert.equal(calls.at(-1).itemId, '401');
    assert.equal(calls.at(-1).quantity, 900000000);
  } finally {
    await app.close();
  }
});

test('KDJX GM delivery transport signs requests and classifies ambiguity', async () => {
  const secret = 'transport-test-secret-never-return';
  const input = {
    requestId: '44444444-4444-4444-8444-444444444444',
    gameOpenId: 'sakura_transport_player_01',
    accountId: '64a000000000000000000010',
    roleId: '64b000000000000000000010',
    serverKey: 'game.cn_qd.10',
    itemId: '19',
    itemName: 'Gold Ingot',
    quantity: 2,
    catalogSha256: testCatalogSha256,
    mailSubject: 'must not be forwarded',
    unexpectedField: 'must not be forwarded',
  };
  let captured;
  const result = await deliverKdjxGmItem(input, {
    deliveryUrl: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
    hmacSecret: secret,
    timeoutMs: 2000,
    fetchImpl: async (url, options) => {
      captured = { url, options };
      return jsonResponse(200, {
        ok: true,
        delivered: true,
        requestId: input.requestId,
        reference: 'remote-grant-id',
      });
    },
  });
  assert.deepEqual(result, {
    status: 'succeeded',
    remoteReference: 'remote-grant-id',
    errorCode: '',
  });
  assert.equal(
    captured.url,
    'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
  );
  const timestamp = captured.options.headers['x-novel-timestamp'];
  const nonce = captured.options.headers['x-novel-nonce'];
  const expectedSignature = createHmac('sha256', secret)
    .update(`${timestamp}\n${nonce}\n${captured.options.body}`)
    .digest('hex');
  assert.equal(
    captured.options.headers['x-novel-signature'],
    expectedSignature,
  );
  assert.equal(captured.options.body.includes(secret), false);
  assert.deepEqual(JSON.parse(captured.options.body), {
    requestId: input.requestId,
    gameOpenId: input.gameOpenId,
    accountId: input.accountId,
    roleId: input.roleId,
    serverKey: input.serverKey,
    itemId: 19,
    quantity: 2,
    itemName: 'Gold Ingot',
    catalogSha256: testCatalogSha256,
    mailSender: '\u6a31\u82b1 GM',
    mailSubject: '\u7cfb\u7edf\u8865\u53d1',
    mailContent: '\u7cfb\u7edf\u8865\u53d1\u7269\u54c1\uff0c' +
      `\u8bf7\u67e5\u6536\u3002\n\u8ffd\u8e2a\u7f16\u53f7\uff1a${input.requestId}`,
  });

  let called = false;
  const invalidCatalogHash = await deliverKdjxGmItem(
    { ...input, catalogSha256: 'A'.repeat(64) },
    {
      deliveryUrl: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
      hmacSecret: secret,
      fetchImpl: async () => {
        called = true;
        throw new Error('must not call');
      },
    },
  );
  assert.equal(called, false);
  assert.deepEqual(invalidCatalogHash, {
    status: 'failed',
    remoteReference: '',
    errorCode: 'kdjx_gm_delivery_unavailable',
  });

  const unavailable = await deliverKdjxGmItem(input, {
    deliveryUrl: 'https://example.com/internal/sakura/gm/deliveries',
    hmacSecret: secret,
    fetchImpl: async () => {
      called = true;
      throw new Error('must not call');
    },
  });
  assert.equal(called, false);
  assert.equal(unavailable.status, 'failed');
  assert.equal(unavailable.errorCode, 'kdjx_gm_delivery_unavailable');

  const rejected = await deliverKdjxGmItem(input, {
    deliveryUrl: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
    hmacSecret: secret,
    fetchImpl: async () => jsonResponse(409, {
      ok: false,
      error: 'role_not_found',
    }),
  });
  assert.equal(rejected.status, 'failed');
  assert.equal(rejected.errorCode, 'game_role_not_found');

  const serverError = await deliverKdjxGmItem(input, {
    deliveryUrl: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
    hmacSecret: secret,
    fetchImpl: async () => jsonResponse(500, {
      ok: false,
      requestId: input.requestId,
      errorCode: 'internal_error',
    }),
  });
  assert.equal(serverError.status, 'unknown');

  const networkError = await deliverKdjxGmItem(input, {
    deliveryUrl: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
    hmacSecret: secret,
    fetchImpl: async () => {
      throw new Error(secret);
    },
  });
  assert.deepEqual(networkError, {
    status: 'unknown',
    remoteReference: '',
    errorCode: 'kdjx_gm_delivery_transport_unknown',
  });

  assert.equal(kdjxGmDeliveryEndpointAllowed(
    'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
  ), true);
  for (const disallowed of [
    'http://localhost:18080/internal/sakura/gm/deliveries',
    'http://127.0.0.1:18081/internal/sakura/gm/deliveries',
    'http://127.0.0.1:18080/internal/sakura/gm/deliveries?next=x',
    'https://127.0.0.1:18080/internal/sakura/gm/deliveries',
  ]) {
    assert.equal(kdjxGmDeliveryEndpointAllowed(disallowed), false);
  }
});

async function makeApp(deliverItem) {
  const app = Fastify({ logger: false });
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error: error.publicCode || (status >= 500 ? 'internal_error' : error.message),
    });
  });
  app.addHook('onResponse', async (request, reply) => {
    recordAdminAudit(request, reply);
  });
  app.decorate('adminRequired', adminRequired);
  app.register(adminKdjxGmRoutes, {
    deliverItem,
    itemCatalog: catalog,
  });
  await app.ready();
  return app;
}

function seedUser(email, role) {
  return Number(run(
    `INSERT INTO users
      (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, ?, 'active')`,
    [email, email.split('@')[0], hashPassword('test-password'), role],
  ).lastInsertRowid);
}

function seedLink(userId, {
  gameOpenId = 'sakura_delivery_player_01',
  gameAccountId = '64a000000000000000000001',
  roleId = '64b000000000000000000001',
  serverKey = 'game.cn.1',
} = {}) {
  run(
    `INSERT INTO kdjx_game_account_links
      (novel_user_id, game_open_id, account_password_cipher,
       game_account_id, last_role_id, last_server_key)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      userId,
      gameOpenId,
      'delivery-password-cipher-never-return',
      gameAccountId,
      roleId,
      serverKey,
    ],
  );
}

function adminRequest(app, token, method, url, payload) {
  return app.inject({
    method,
    url,
    headers: { authorization: `Bearer ${token}` },
    ...(payload ? { payload } : {}),
  });
}

function postDelivery(app, token, userId, payload) {
  return adminRequest(
    app,
    token,
    'POST',
    `/admin/games/kdjx/gm/players/${userId}/deliveries`,
    payload,
  );
}

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function assertRedacted(body) {
  for (const marker of [
    'delivery-password-cipher-never-return',
    'kdjx-delivery-test-token-secret',
    'kdjx-delivery-settings-secret',
    'transport-test-secret-never-return',
    'sakura_delivery_player_01',
    '64a000000000000000000001',
  ]) {
    assert.equal(body.includes(marker), false, `response leaked ${marker}`);
  }
  assert.doesNotMatch(
    body,
    /accountPassword|passwordCipher|tokenHash|hmacSecret|sharedSecret/i,
  );
}
