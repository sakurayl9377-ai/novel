import { one } from "./db.js";

const defaultTitle = "公告";

export function appAnnouncementSettings() {
  const enabled = setting("app_announcement.enabled", "false") === "true";
  const title = setting("app_announcement.title", defaultTitle) || defaultTitle;
  const content = setting("app_announcement.content", "");
  const version = setting("app_announcement.version", "");
  return {
    enabled,
    title,
    content,
    version,
  };
}

export function publicAppAnnouncement() {
  const settings = appAnnouncementSettings();
  const id = announcementId(settings);
  return {
    enabled: settings.enabled && settings.content.trim().length > 0,
    id,
    title: settings.title || defaultTitle,
    content: settings.content,
    updatedAt: announcementUpdatedAt(),
  };
}

export function normalizeAppAnnouncementSettings(values = {}) {
  return {
    enabled: values.enabled === true || values.enabled === "true",
    title: optionalSettingString(values.title, 80),
    content: optionalSettingString(values.content, 4000),
  };
}

export function appAnnouncementChanged(next) {
  const current = appAnnouncementSettings();
  return (
    (next.enabled ? "true" : "false") !== (current.enabled ? "true" : "false") ||
    next.title !== current.title ||
    next.content !== current.content
  );
}

function announcementId(settings) {
  const version = String(settings.version || "").trim();
  if (version) return version;
  return Buffer.from(`${settings.title}\n${settings.content}`).toString("base64url").slice(0, 32);
}

function announcementUpdatedAt() {
  return (
    one("SELECT updated_at FROM app_settings WHERE key = ?", [
      "app_announcement.content",
    ])?.updated_at || ""
  );
}

function setting(key, fallback = "") {
  return one("SELECT value FROM app_settings WHERE key = ?", [key])?.value || fallback;
}

function optionalSettingString(value, maxLength = 2000) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  return text.length > maxLength ? text.slice(0, maxLength) : text;
}
