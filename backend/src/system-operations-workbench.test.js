import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-system-ops-"));
const releaseDir = path.join(tempDir, "releases");
const adminPassword = `system-admin-${process.pid}-${Date.now()}`;
process.env.DB_PATH = path.join(tempDir, "system.sqlite");
process.env.APP_RELEASE_DIR = releaseDir;
process.env.TOKEN_SECRET = `system-token-${process.pid}-${Date.now()}`;
process.env.SETTINGS_ENCRYPTION_KEY = `system-settings-${process.pid}-${Date.now()}`;
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = adminPassword;

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("system workbenches expose auditable operations, app coverage, and release integrity", async () => {
  const app = await buildServer();
  try {
    const operatorId = createUser("system-operator@example.com", "运维管理员", "admin");
    insertAudit({ adminUserId: operatorId, method: "POST", path: "/admin/users/2/ban", statusCode: 200, offsetHours: 1 });
    insertAudit({ adminUserId: operatorId, method: "GET", path: "/admin/analytics/overview?days=7", statusCode: 200, offsetHours: 2 });
    insertAudit({ adminUserId: operatorId, method: "PATCH", path: "/admin/settings", statusCode: 500, offsetHours: 3 });

    const userA = createUser("version-a@example.com", "版本用户 A", "user");
    const userB = createUser("version-b@example.com", "版本用户 B", "user");
    const userC = createUser("version-c@example.com", "版本用户 C", "user");
    const userD = createUser("version-d@example.com", "版本用户 D", "user");
    insertInstall(userA, "install-a-current", "5.4.0", 540, "android", "Pixel 9", 1);
    insertInstall(userA, "install-a-old", "5.3.0", 530, "ios", "iPhone 15", 40);
    insertInstall(userB, "install-b-old", "5.3.0", 530, "ios", "iPhone 14", 10);
    insertInstall(userD, "install-d-stale", "5.0.0", 500, "android", "Pixel 6", 45 * 24);
    assert.ok(userC > 0);

    const apk = Buffer.from("system-workbench-apk");
    const sha256 = createHash("sha256").update(apk).digest("hex");
    fs.mkdirSync(releaseDir, { recursive: true });
    fs.writeFileSync(path.join(releaseDir, "app-release.apk"), apk);
    fs.writeFileSync(path.join(releaseDir, "version.json"), JSON.stringify({
      versionName: "5.4.0",
      versionCode: 540,
      apkUrl: "https://downloads.example.test/app-release.apk",
      sha256,
      force: false,
      notes: ["系统工作台验收版本"],
    }));
    fs.writeFileSync(path.join(releaseDir, "version-5.4.0+540.json"), JSON.stringify({ versionName: "5.4.0", versionCode: 540, sha256 }));
    fs.writeFileSync(path.join(releaseDir, "version-5.3.0.json"), JSON.stringify({ versionName: "5.3.0", versionCode: 530 }));
    fs.mkdirSync(path.join(releaseDir, "backup-20260719-120000"));
    fs.mkdirSync(path.join(releaseDir, "backup-20260718-120000"));

    const login = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: adminPassword,
    });
    const token = login.token;

    const audit = await request(app, "GET", "/admin/audit/workbench?period=7d&page=1&pageSize=20", undefined, token);
    assert.equal(audit.total, 3);
    assert.equal(audit.summary.errors, 1);
    assert.equal(audit.summary.sensitiveActions, 2);
    assert.equal(audit.summary.uniqueAdmins, 1);
    assert.equal(audit.statusCounts.success, 2);
    assert.equal(audit.statusCounts.error, 1);
    assert.equal(audit.items[0].admin.nickname, "运维管理员");

    const auditErrors = await request(app, "GET", "/admin/audit/workbench?status=error&page=1&pageSize=20", undefined, token);
    assert.equal(auditErrors.total, 1);
    assert.equal(auditErrors.items[0].statusCode, 500);
    const auditSearch = await request(app, "GET", "/admin/audit/workbench?q=ban&page=1&pageSize=20", undefined, token);
    assert.equal(auditSearch.total, 1);
    assert.equal(auditSearch.items[0].path, "/admin/users/2/ban");

    const versions = await request(app, "GET", "/admin/app-versions/workbench?page=1&pageSize=20", undefined, token);
    assert.equal(versions.summary.registeredUsers, 6);
    assert.equal(versions.summary.reportingUsers, 3);
    assert.equal(versions.summary.latestVersionCode, 540);
    assert.equal(versions.summary.currentUsers, 1);
    assert.equal(versions.summary.outdatedUsers, 2);
    assert.equal(versions.summary.staleInstalls, 1);
    assert.equal(versions.total, 4);
    assert.equal(versions.items[0].versionCode, 540);
    const ios = await request(app, "GET", "/admin/app-versions/workbench?platform=ios&page=1&pageSize=20", undefined, token);
    assert.equal(ios.total, 2);
    const stale = await request(app, "GET", "/admin/app-versions/workbench?activity=stale&page=1&pageSize=20", undefined, token);
    assert.equal(stale.total, 1);
    assert.equal(stale.items[0].installId, "install-d-stale");

    const releases = await request(app, "GET", "/admin/releases/workbench", undefined, token);
    assert.equal(releases.configured, true);
    assert.equal(releases.integrityStatus, "ready");
    assert.equal(releases.checks.checksum, "verified");
    assert.equal(releases.current.versionCode, 540);
    assert.equal(releases.current.actualSha256, sha256);
    assert.equal(releases.history.length, 2);
    assert.equal(releases.history[0].fileName, "version-5.4.0+540.json");
    assert.equal(releases.backups.length, 2);
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function createUser(email, nickname, role) {
  return Number(run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, ?, 'active')`,
    [email, nickname, hashPassword("system-user-password"), role],
  ).lastInsertRowid);
}

function insertAudit({ adminUserId, method, path: requestPath, statusCode, offsetHours }) {
  const offset = `-${offsetHours} hours`;
  run(
    `INSERT INTO admin_audit_logs
       (admin_user_id, method, path, status_code, ip, user_agent, request_id, created_at)
     VALUES (?, ?, ?, ?, '127.0.0.1', 'system-workbench-test', ?, datetime('now', ?))`,
    [adminUserId, method, requestPath, statusCode, `system-request-${offsetHours}`, offset],
  );
}

function insertInstall(userId, installId, versionName, versionCode, platform, deviceModel, offsetHours) {
  const offset = `-${offsetHours} hours`;
  run(
    `INSERT INTO user_app_installs
       (user_id, install_id, version_name, version_code, platform, os_version,
        device_model, first_seen_at, last_seen_at, last_ip)
     VALUES (?, ?, ?, ?, ?, 'Android 15', ?, datetime('now', ?), datetime('now', ?), '127.0.0.1')`,
    [userId, installId, versionName, versionCode, platform, deviceModel, offset, offset],
  );
}

async function request(app, method, route, body, token = "") {
  const response = await app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    payload: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}
