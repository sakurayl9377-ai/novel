import crypto from "node:crypto";
import dns from "node:dns/promises";
import net from "node:net";
import path from "node:path";
import { readFile, stat } from "node:fs/promises";
import WebSocket from "ws";

import { config } from "./config.js";
import { one } from "./db.js";
import { decryptSettingSecret } from "./settings-secrets.js";
import { defaultAsrHostUrl, iflytekSpeechDefaults } from "./speech-defaults.js";

const pcmChunkBytes = 1280;

export async function transcribeChatAudio(mediaUrl, { userId = 0 } = {}) {
  const settings = readAsrSettings();
  if (!settings.enabled) throw new Error("speech_asr_disabled");
  const audio = await loadAudioBytes(mediaUrl, { userId });
  const pcm = extractPcm16(audio.bytes, audio.fileName);
  if (settings.productType === "rtasr") {
    return transcribeWithRtasr({ settings, pcm });
  }
  return transcribeWithIat({ settings, pcm });
}

export function iflytekTtsConfigured() {
  const settings = readTtsSettings();
  return settings.enabled && Boolean(settings.appId && settings.apiKey && settings.apiSecret);
}

export function synthesizeIflytek(text, { voice = "x4_xiaoyan", rate = 0.5, volume = 0.85, pitch = 1 } = {}) {
  const settings = readTtsSettings();
  if (!settings.enabled || !settings.appId || !settings.apiKey || !settings.apiSecret) {
    throw new Error("speech_tts_config_missing");
  }
  const safeText = String(text || "").trim();
  if (!safeText || safeText.length > 180) throw new Error("speech_tts_text_invalid");
  const allowedVoices = new Set(["x4_xiaoyan", "x4_yezi", "aisjiuxu", "aisjinger", "aisbabyxu"]);
  if (!allowedVoices.has(voice)) throw new Error("speech_tts_voice_invalid");
  return synthesizeWithIflytek({
    settings,
    text: safeText,
    voice,
    rate: clampNumber(rate, 0, 1, 0.5),
    volume: clampNumber(volume, 0, 1, 0.85),
    pitch: clampNumber(pitch, 0.5, 2, 1),
  });
}

function readAsrSettings() {
  const productType =
    setting("iflytek_asr.productType") || iflytekSpeechDefaults.asrProductType;
  const appId = setting("iflytek_asr.appId");
  const apiKey = secretSetting("iflytek_asr.apiKey");
  const secretKey =
    secretSetting("iflytek_asr.secretKey") ||
    secretSetting("iflytek_asr.apiSecret");
  const hostUrl = setting("iflytek_asr.hostUrl") || defaultAsrHostUrl(productType);
  return {
    productType,
    appId,
    apiKey,
    secretKey,
    hostUrl,
    enabled: setting("iflytek_asr.enabled") === "true",
  };
}

function readTtsSettings() {
  return {
    appId: setting("iflytek_tts.appId"),
    apiKey: secretSetting("iflytek_tts.apiKey"),
    apiSecret: secretSetting("iflytek_tts.apiSecret"),
    hostUrl: setting("iflytek_tts.hostUrl") || iflytekSpeechDefaults.ttsHostUrl,
    enabled: setting("iflytek_tts.enabled") === "true",
  };
}

function clampNumber(value, min, max, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
}

function synthesizeWithIflytek({ settings, text, voice, rate, volume, pitch }) {
  const url = signedTtsUrl(settings);
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { perMessageDeflate: false });
    const chunks = [];
    let settled = false;
    const finish = (error, bytes) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(Buffer.concat(chunks, bytes));
    };
    const timer = setTimeout(() => {
      finish(new Error("speech_tts_timeout"));
      ws.close();
    }, 30000);
    ws.on("open", () => {
      ws.send(JSON.stringify({
        common: { app_id: settings.appId },
        business: {
          aue: "lame",
          sfl: 1,
          tte: "UTF8",
          vcn: voice,
          speed: Math.round(rate * 100),
          volume: Math.round(volume * 100),
          pitch: Math.round(pitch <= 1 ? (pitch - 0.5) * 100 : 50 + (pitch - 1) * 50),
        },
        data: { status: 2, text: Buffer.from(text, "utf8").toString("base64") },
      }));
    });
    ws.on("message", (raw) => {
      try {
        const payload = JSON.parse(raw.toString());
        if (Number(payload.code ?? 0) !== 0) throw new Error(payload.message || "speech_tts_failed");
        const audio = payload.data?.audio;
        if (audio) chunks.push(Buffer.from(audio, "base64"));
        if (Number(payload.data?.status) === 2) {
          ws.close();
          finish(null, chunks.reduce((total, chunk) => total + chunk.length, 0));
        }
      } catch (error) {
        ws.close();
        finish(error);
      }
    });
    ws.on("error", (error) => finish(error));
    ws.on("close", () => {
      if (settled) return;
      if (chunks.length) finish(null, chunks.reduce((total, chunk) => total + chunk.length, 0));
      else finish(new Error("speech_tts_connection_closed"));
    });
  });
}

function signedTtsUrl(settings) {
  const url = new URL(settings.hostUrl);
  const date = new Date().toUTCString();
  const signatureOrigin = `host: ${url.host}\ndate: ${date}\nGET ${url.pathname} HTTP/1.1`;
  const signature = crypto.createHmac("sha256", settings.apiSecret).update(signatureOrigin).digest("base64");
  const authorization = Buffer.from(
    `api_key="${settings.apiKey}", algorithm="hmac-sha256", headers="host date request-line", signature="${signature}"`,
  ).toString("base64");
  url.searchParams.set("authorization", authorization);
  url.searchParams.set("date", date);
  url.searchParams.set("host", url.host);
  return url.toString();
}

function setting(key) {
  return one("SELECT value FROM app_settings WHERE key = ?", [key])?.value || "";
}

function secretSetting(key) {
  const value = setting(key);
  try {
    return decryptSettingSecret(value);
  } catch (error) {
    console.warn("[speech] failed to decrypt secret setting:", error?.message || error);
    return "";
  }
}

export async function loadAudioBytes(mediaUrl, { userId = 0 } = {}) {
  const localPath = localUploadPath(mediaUrl, userId);
  if (localPath) {
    try {
      const info = await stat(localPath);
      if (!info.isFile() || info.size <= 0) {
        throw new Error("speech_audio_file_invalid");
      }
      if (info.size > audioMaxBytes()) {
        throw new Error("speech_audio_file_too_large");
      }
      return {
        bytes: await readFile(localPath),
        fileName: path.basename(localPath),
      };
    } catch (error) {
      if (error?.code === "ENOENT") {
        throw new Error("speech_audio_file_not_found");
      }
      throw error;
    }
  }
  if (!config.speechAllowRemoteAudio) {
    throw new Error("speech_audio_url_not_allowed");
  }
  return loadRemoteAudioBytes(mediaUrl);
}

function localUploadPath(mediaUrl, userId) {
  let parsed;
  try {
    parsed = new URL(mediaUrl);
  } catch {
    return "";
  }
  const prefix = `${config.apiPrefix}/uploads/profile/chat-audio/`;
  if (!parsed.pathname.startsWith(prefix)) return "";
  const decoded = decodeURIComponent(parsed.pathname.slice(prefix.length));
  const file = path.basename(decoded);
  if (decoded !== file) return "";
  if (!/^[a-z0-9-]+\.(wav|pcm)$/i.test(file)) return "";
  if (!userId || !file.startsWith(`${Number(userId)}-`)) return "";
  return path.join(config.rootDir, "data", "uploads", "chat-audio", file);
}

async function loadRemoteAudioBytes(mediaUrl) {
  let current;
  try {
    current = new URL(mediaUrl);
  } catch {
    throw new Error("speech_audio_url_invalid");
  }

  for (let redirectCount = 0; redirectCount <= 3; redirectCount += 1) {
    await assertPublicHttpUrl(current);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), audioTimeoutMs());
    timer.unref?.();
    let response;
    try {
      response = await fetch(current, {
        redirect: "manual",
        signal: controller.signal,
      });
      if (response.status >= 300 && response.status < 400) {
        const location = response.headers.get("location");
        if (!location || redirectCount === 3) {
          throw new Error("speech_audio_redirect_invalid");
        }
        await response.body?.cancel();
        current = new URL(location, current);
        continue;
      }
      if (!response.ok) throw new Error("speech_audio_fetch_failed");
      const declaredLength = Number(response.headers.get("content-length") || 0);
      if (declaredLength > audioMaxBytes()) {
        throw new Error("speech_audio_file_too_large");
      }
      const bytes = await readResponseBytes(response, audioMaxBytes());
      return { bytes, fileName: current.pathname };
    } catch (error) {
      if (error?.name === "AbortError") {
        throw new Error("speech_audio_fetch_timeout");
      }
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error("speech_audio_redirect_invalid");
}

async function assertPublicHttpUrl(url) {
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("speech_audio_url_invalid");
  }
  const addresses = await withTimeout(
    dns.lookup(url.hostname, { all: true, verbatim: true }),
    audioTimeoutMs(),
    "speech_audio_dns_timeout",
  );
  if (!addresses.length || addresses.some((item) => isBlockedIp(item.address))) {
    throw new Error("speech_audio_url_not_allowed");
  }
}

function isBlockedIp(value) {
  const address = String(value || "").toLowerCase();
  const version = net.isIP(address);
  if (version === 4) {
    const parts = address.split(".").map(Number);
    const [a, b] = parts;
    return (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 198 && (b === 18 || b === 19))
    );
  }
  if (version === 6) {
    if (address === "::" || address === "::1") return true;
    if (address.startsWith("fc") || address.startsWith("fd")) return true;
    if (/^fe[89ab]/.test(address)) return true;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(address);
    return mapped ? isBlockedIp(mapped[1]) : false;
  }
  return true;
}

async function readResponseBytes(response, maxBytes) {
  if (!response.body) throw new Error("speech_audio_fetch_failed");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error("speech_audio_file_too_large");
    }
    chunks.push(Buffer.from(value));
  }
  if (total <= 0) throw new Error("speech_audio_fetch_failed");
  return Buffer.concat(chunks, total);
}

function audioMaxBytes() {
  return Math.max(1024, Math.min(20 * 1024 * 1024, config.speechAudioMaxBytes));
}

function audioTimeoutMs() {
  return Math.max(1000, Math.min(30000, config.speechAudioTimeoutMs));
}

async function withTimeout(promise, timeoutMs, errorCode) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(errorCode)), timeoutMs);
        timer.unref?.();
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function extractPcm16(bytes, fileName = "") {
  const buffer = Buffer.from(bytes);
  if (/\.pcm$/i.test(fileName)) {
    return { data: buffer, sampleRate: 16000 };
  }
  if (
    buffer.length < 44 ||
    buffer.toString("ascii", 0, 4) !== "RIFF" ||
    buffer.toString("ascii", 8, 12) !== "WAVE"
  ) {
    throw new Error("speech_audio_format_unsupported");
  }

  let offset = 12;
  let fmt = null;
  let data = null;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const start = offset + 8;
    const end = Math.min(start + size, buffer.length);
    if (id === "fmt ") {
      fmt = {
        audioFormat: buffer.readUInt16LE(start),
        channels: buffer.readUInt16LE(start + 2),
        sampleRate: buffer.readUInt32LE(start + 4),
        bitsPerSample: buffer.readUInt16LE(start + 14),
      };
    } else if (id === "data") {
      data = buffer.subarray(start, end);
    }
    offset = start + size + (size % 2);
  }

  if (!fmt || !data || fmt.audioFormat !== 1 || fmt.bitsPerSample !== 16) {
    throw new Error("speech_audio_format_unsupported");
  }
  if (fmt.channels !== 1 || ![8000, 16000].includes(fmt.sampleRate)) {
    throw new Error("speech_audio_format_unsupported");
  }
  return { data, sampleRate: fmt.sampleRate };
}

function transcribeWithIat({ settings, pcm }) {
  if (!settings.appId || !settings.apiKey || !settings.secretKey) {
    throw new Error("speech_asr_config_missing");
  }
  const url = signedIatUrl(settings);
  const resultParts = [];
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { perMessageDeflate: false });
    let offset = 0;
    let first = true;
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("speech_asr_timeout"));
    }, 45000);

    ws.on("open", () => sendIatFrame());
    ws.on("message", (raw) => {
      try {
        const payload = JSON.parse(raw.toString());
        const code = Number(payload.code ?? 0);
        if (code !== 0) {
          throw new Error(payload.message || "speech_asr_failed");
        }
        const text = iatText(payload.data?.result);
        if (text) resultParts.push(text);
        if (payload.data?.status === 2) {
          clearTimeout(timer);
          ws.close();
          resolve(resultParts.join("").trim());
        }
      } catch (error) {
        clearTimeout(timer);
        ws.close();
        reject(error);
      }
    });
    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    function sendIatFrame() {
      if (ws.readyState !== WebSocket.OPEN) return;
      const next = pcm.data.subarray(offset, offset + pcmChunkBytes);
      offset += next.length;
      const isLast = offset >= pcm.data.length;
      const frame = {
        data: {
          status: first ? 0 : isLast ? 2 : 1,
          format: `audio/L16;rate=${pcm.sampleRate}`,
          encoding: "raw",
          audio: next.toString("base64"),
        },
      };
      if (first) {
        frame.common = { app_id: settings.appId };
        frame.business = {
          language: "zh_cn",
          domain: "iat",
          accent: "mandarin",
          vad_eos: 5000,
        };
      }
      first = false;
      ws.send(JSON.stringify(frame));
      if (!isLast) setTimeout(sendIatFrame, 40);
    }
  });
}

function signedIatUrl(settings) {
  const url = new URL(settings.hostUrl || defaultAsrHostUrl("iat"));
  const host = url.host;
  const date = new Date().toUTCString();
  const requestLine = `GET ${url.pathname} HTTP/1.1`;
  const signatureOrigin = `host: ${host}\ndate: ${date}\n${requestLine}`;
  const signature = crypto
    .createHmac("sha256", settings.secretKey)
    .update(signatureOrigin)
    .digest("base64");
  const authorization = Buffer.from(
    `api_key="${settings.apiKey}", algorithm="hmac-sha256", headers="host date request-line", signature="${signature}"`,
  ).toString("base64");
  url.searchParams.set("authorization", authorization);
  url.searchParams.set("date", date);
  url.searchParams.set("host", host);
  return url.toString();
}

function iatText(result) {
  const words = result?.ws;
  if (!Array.isArray(words)) return "";
  return words
    .map((item) =>
      Array.isArray(item.cw)
        ? item.cw.map((candidate) => candidate.w || "").join("")
        : "",
    )
    .join("");
}

function transcribeWithRtasr({ settings, pcm }) {
  if (!settings.appId || !settings.apiKey) {
    throw new Error("speech_asr_config_missing");
  }
  const url = signedRtasrUrl(settings);
  const parts = [];
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { perMessageDeflate: false });
    let offset = 0;
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("speech_asr_timeout"));
    }, 45000);

    ws.on("open", () => sendRtasrFrame());
    ws.on("message", (raw) => {
      try {
        const payload = JSON.parse(raw.toString());
        const code = Number(payload.code ?? 0);
        if (payload.action === "error" || code !== 0) {
          throw new Error(payload.desc || payload.message || "speech_asr_failed");
        }
        if (payload.action === "result") {
          const text = rtasrText(payload.data);
          if (text) parts.push(text);
        }
      } catch (error) {
        clearTimeout(timer);
        ws.close();
        reject(error);
      }
    });
    ws.on("close", () => {
      clearTimeout(timer);
      resolve(parts.join("").trim());
    });
    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    function sendRtasrFrame() {
      if (ws.readyState !== WebSocket.OPEN) return;
      if (offset >= pcm.data.length) {
        ws.send('{"end": true}');
        return;
      }
      const next = pcm.data.subarray(offset, offset + pcmChunkBytes);
      offset += next.length;
      ws.send(next);
      setTimeout(sendRtasrFrame, 40);
    }
  });
}

function signedRtasrUrl(settings) {
  const url = new URL(settings.hostUrl || defaultAsrHostUrl("rtasr"));
  const ts = Math.floor(Date.now() / 1000).toString();
  const md5 = crypto.createHash("md5").update(settings.appId + ts).digest("hex");
  const signa = crypto
    .createHmac("sha1", settings.apiKey)
    .update(md5)
    .digest("base64");
  url.searchParams.set("appid", settings.appId);
  url.searchParams.set("ts", ts);
  url.searchParams.set("signa", signa);
  return url.toString();
}

function rtasrText(data) {
  let parsed = data;
  if (typeof parsed === "string") {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return "";
    }
  }
  const segments = parsed?.cn?.st?.rt;
  if (!Array.isArray(segments)) return "";
  return segments
    .flatMap((segment) => (Array.isArray(segment.ws) ? segment.ws : []))
    .flatMap((word) => (Array.isArray(word.cw) ? word.cw : []))
    .map((candidate) => candidate.w || "")
    .join("");
}
