import crypto from "node:crypto";

import { config } from "./config.js";

const prefix = "enc:v1";
const key = crypto
  .createHash("sha256")
  .update(config.settingsEncryptionKey || config.tokenSecret)
  .digest();

export function encryptSettingSecret(value) {
  const text = String(value || "");
  if (!text || text.startsWith(`${prefix}:`)) return text;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([
    cipher.update(text, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return [
    prefix,
    iv.toString("base64url"),
    tag.toString("base64url"),
    encrypted.toString("base64url"),
  ].join(":");
}

export function decryptSettingSecret(value) {
  const text = String(value || "");
  if (!text.startsWith(`${prefix}:`)) return text;
  const parts = text.split(":");
  if (parts.length !== 5 || `${parts[0]}:${parts[1]}` !== prefix) {
    throw new Error("settings_secret_format_invalid");
  }
  const iv = Buffer.from(parts[2], "base64url");
  const tag = Buffer.from(parts[3], "base64url");
  const encrypted = Buffer.from(parts[4], "base64url");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString(
    "utf8",
  );
}

export function isEncryptedSettingSecret(value) {
  return String(value || "").startsWith(`${prefix}:`);
}
