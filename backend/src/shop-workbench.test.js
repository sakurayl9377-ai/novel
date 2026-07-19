import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-shop-workbench-"));
process.env.DB_PATH = path.join(tempDir, "shop.sqlite");
process.env.TOKEN_SECRET = "shop-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "shop-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const legacyDb = new DatabaseSync(process.env.DB_PATH);
legacyDb.exec(`
  CREATE TABLE shop_items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    price_coins INTEGER NOT NULL,
    item_type TEXT NOT NULL DEFAULT 'cosmetic',
    min_level INTEGER NOT NULL DEFAULT 0,
    asset_value TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  INSERT INTO shop_items
    (id, name, description, price_coins, item_type, min_level, asset_value)
  VALUES
    ('legacy-shop-item', 'Legacy item', 'Migrated row', 9, 'cosmetic', 0, 'legacy');
`);
legacyDb.close();

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");

test("shop workbench manages upload-backed products without losing ownership", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const migrated = one("SELECT * FROM shop_items WHERE id = 'legacy-shop-item'");
    assert.equal(migrated.preview_url, "");
    assert.equal(migrated.revision, 1);
    assert.equal(migrated.updated_at, migrated.created_at);

    const login = await jsonRequest(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = login.token;

    const invalidImage = await uploadMultipart(
      app,
      token,
      Buffer.from("not an image"),
      "image/png",
      "fake.png",
    );
    assert.equal(invalidImage.statusCode, 400);
    assert.equal(invalidImage.json().error, "shop_preview_content_invalid");

    const firstPreview = await uploadPreview(app, token, "first.png");
    assert.match(firstPreview.url, /\/uploads\/content\/shop-previews\/\d+-[a-z0-9-]+\.png$/);
    const firstPreviewPath = path.join(
      tempDir,
      "data",
      "uploads",
      "shop-previews",
      path.basename(firstPreview.url),
    );
    assert.equal(fs.existsSync(firstPreviewPath), true);

    const remotePreview = await rawJsonRequest(
      app,
      "POST",
      "/admin/shop/items",
      {
        name: "Remote preview product",
        description: "Must be rejected",
        priceCoins: 20,
        itemType: "profile_skin",
        minLevel: 1,
        assetValue: "sakura",
        previewUrl: "https://example.com/product.png",
        sortOrder: 1,
      },
      token,
    );
    assert.equal(remotePreview.statusCode, 400);
    assert.equal(remotePreview.json().error, "shop_preview_upload_required");

    const seeded = await jsonRequest(
      app,
      "GET",
      "/admin/shop/items/skin-sakura-card",
      undefined,
      token,
    );
    const deactivatedSeed = await jsonRequest(
      app,
      "POST",
      "/admin/shop/items/skin-sakura-card/status",
      {
        status: "inactive",
        expectedRevision: seeded.item.revision,
        note: "Replace the original seeded listing",
      },
      token,
    );
    await jsonRequest(
      app,
      "POST",
      "/admin/shop/items/skin-sakura-card/status",
      {
        status: "archived",
        expectedRevision: deactivatedSeed.item.revision,
        note: "Keep ownership history while replacing the listing",
      },
      token,
    );

    const created = await jsonRequest(
      app,
      "POST",
      "/admin/shop/items",
      {
        name: "Sakura profile card V2",
        description: "Upload-backed product preview",
        priceCoins: 150,
        itemType: "profile_skin",
        minLevel: 2,
        assetValue: "sakura",
        previewUrl: `https://untrusted.example${firstPreview.url}`,
        sortOrder: 5,
        changeNote: "Replace the legacy listing",
      },
      token,
    );
    assert.match(created.item.id, /^shop-profile_skin-/);
    assert.equal(created.item.status, "inactive");
    assert.equal(created.item.previewUrl, firstPreview.url);
    assert.equal(created.item.revision, 1);

    const publicBefore = await jsonRequest(app, "GET", "/shop/items");
    assert.equal(publicBefore.items.some((item) => item.id === created.item.id), false);

    const activated = await jsonRequest(
      app,
      "POST",
      `/admin/shop/items/${created.item.id}/status`,
      {
        status: "active",
        expectedRevision: created.item.revision,
        note: "Preview and price have been reviewed",
      },
      token,
    );
    assert.equal(activated.item.status, "active");
    assert.equal(activated.item.revision, 2);

    const publicAfter = await jsonRequest(app, "GET", "/shop/items");
    const publicItem = publicAfter.items.find((item) => item.id === created.item.id);
    assert.equal(publicItem.previewUrl, firstPreview.url);
    assert.equal(publicItem.sortOrder, 5);

    const stale = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/shop/items/${created.item.id}`,
      {
        expectedRevision: 1,
        name: "Stale overwrite",
        changeNote: "This must not win",
      },
      token,
    );
    assert.equal(stale.statusCode, 409);
    assert.equal(stale.json().error, "shop_item_revision_conflict");

    const holderId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, status, points, sakura_coins)
         VALUES ('shop-holder@example.com', 'Shop holder', 'unused', 'active', 500, 50)`,
      ).lastInsertRowid,
    );
    run("INSERT INTO user_inventory (user_id, item_id) VALUES (?, ?)", [
      holderId,
      created.item.id,
    ]);
    run(
      `INSERT INTO user_equipment (user_id, slot, item_id)
       VALUES (?, 'profile_skin', ?)`,
      [holderId, created.item.id],
    );

    const deactivated = await jsonRequest(
      app,
      "POST",
      `/admin/shop/items/${created.item.id}/status`,
      {
        status: "inactive",
        expectedRevision: activated.item.revision,
        note: "Pause sales while keeping current owners equipped",
      },
      token,
    );
    assert.equal(deactivated.item.holderCount, 1);
    assert.equal(deactivated.item.equipmentCount, 1);

    const identityChange = await rawJsonRequest(
      app,
      "PATCH",
      `/admin/shop/items/${created.item.id}`,
      {
        expectedRevision: deactivated.item.revision,
        itemType: "avatar_frame",
        assetValue: "lv5_crystal",
        changeNote: "Unsafe identity replacement",
      },
      token,
    );
    assert.equal(identityChange.statusCode, 409);
    assert.equal(identityChange.json().error, "shop_item_identity_locked");

    const secondPreview = await uploadPreview(app, token, "second.png");
    const updated = await jsonRequest(
      app,
      "PATCH",
      `/admin/shop/items/${created.item.id}`,
      {
        expectedRevision: deactivated.item.revision,
        name: "Sakura profile card V2.1",
        priceCoins: 175,
        previewUrl: secondPreview.url,
        changeNote: "Refresh listing artwork and price",
      },
      token,
    );
    assert.equal(updated.item.revision, 4);
    assert.equal(updated.item.priceCoins, 175);
    assert.equal(fs.existsSync(firstPreviewPath), false, "replaced previews must retire");

    const detail = await jsonRequest(
      app,
      "GET",
      `/admin/shop/items/${created.item.id}?holderQ=shop-holder&holderPage=1&holderPageSize=10`,
      undefined,
      token,
    );
    assert.equal(detail.holders.total, 1);
    assert.deepEqual(detail.holders.items[0].equipmentSlots, ["profile_skin"]);
    assert.deepEqual(
      new Set(detail.events.map((event) => event.action)),
      new Set(["create", "activate", "deactivate", "update"]),
    );

    const workbench = await jsonRequest(
      app,
      "GET",
      "/admin/shop/workbench?status=inactive&itemType=profile_skin&q=V2.1&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(workbench.total, 1);
    assert.equal(workbench.items[0].id, created.item.id);
    assert.equal(workbench.integrity.healthy, false);
    assert.equal(workbench.integrity.untrackedHoldings, 1);
    assert.ok(workbench.catalog.some((item) => item.type === "chat_bubble"));

    const archived = await jsonRequest(
      app,
      "POST",
      `/admin/shop/items/${created.item.id}/status`,
      {
        status: "archived",
        expectedRevision: updated.item.revision,
        note: "Retire sales but preserve the owner's entitlement",
      },
      token,
    );
    assert.equal(archived.item.status, "archived");
    assert.equal(
      one("SELECT COUNT(*) AS count FROM user_inventory WHERE item_id = ?", [created.item.id])
        .count,
      1,
    );
    assert.throws(
      () => run("DELETE FROM shop_items WHERE id = ?", [created.item.id]),
      /shop_items_must_be_archived/,
    );
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

const pngBytes = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

async function uploadPreview(app, token, fileName) {
  const response = await uploadMultipart(app, token, pngBytes, "image/png", fileName);
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

function uploadMultipart(app, token, bytes, mimeType, fileName) {
  const boundary = `----shop-preview-${Date.now()}-${Math.random()}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: ${mimeType}\r\n\r\n`,
    ),
    bytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  return app.inject({
    method: "POST",
    url: `${config.apiPrefix}/admin/shop/previews`,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": `multipart/form-data; boundary=${boundary}`,
    },
    payload,
  });
}

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
