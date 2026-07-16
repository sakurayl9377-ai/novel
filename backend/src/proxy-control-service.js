import { spawn } from "node:child_process";

const helperPath = "/usr/local/sbin/novel-mihomo-control";
const maxOutputBytes = 1024 * 1024;

export function normalizeProxySubscriptionUrl(value) {
  const text = String(value || "").trim();
  if (!text || text.length > 2000 || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error("proxy_subscription_url_invalid");
  }
  let parsed;
  try {
    parsed = new URL(text);
  } catch {
    throw new Error("proxy_subscription_url_invalid");
  }
  if (parsed.protocol !== "https:" || !parsed.hostname || parsed.username || parsed.password) {
    throw new Error("proxy_subscription_url_invalid");
  }
  return parsed.href;
}

export function normalizeProxySubscriptionName(value) {
  const text = String(value || "").trim();
  if (!text || text.length > 80 || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error("proxy_subscription_name_invalid");
  }
  return text;
}

export function normalizeProxySubscriptionId(value) {
  const text = String(value || "").trim();
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(text)) {
    throw new Error("proxy_subscription_id_invalid");
  }
  return text;
}

export function normalizeProxyGroupSelection(group, choice) {
  const safeGroup = String(group || "").trim();
  const safeChoice = String(choice || "").trim();
  if (!safeGroup || !safeChoice || safeGroup.length > 200 || safeChoice.length > 300) {
    throw new Error("proxy_group_selection_invalid");
  }
  return { group: safeGroup, choice: safeChoice };
}

export function normalizeProxyNodeName(value) {
  const text = String(value || "").trim();
  if (!text || text.length > 300 || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error("proxy_node_name_invalid");
  }
  return text;
}

export function runProxyControl(payload, { timeoutMs = 90000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn("sudo", ["-n", helperPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const stdout = [];
    const stderr = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(new Error("proxy_control_timeout"));
    }, Math.max(1000, Math.min(120000, Number(timeoutMs) || 90000)));
    timer.unref?.();

    child.stdout.on("data", (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes <= maxOutputBytes) stdout.push(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes <= maxOutputBytes) stderr.push(chunk);
    });
    child.on("error", () => finish(new Error("proxy_control_unavailable")));
    child.on("close", (code) => {
      const output = Buffer.concat(stdout).toString("utf8").trim();
      let decoded;
      try {
        decoded = JSON.parse(output || "{}");
      } catch {
        decoded = null;
      }
      if (code === 0 && decoded?.ok === true) {
        finish(null, decoded.data || {});
        return;
      }
      const helperError = decoded?.error || Buffer.concat(stderr).toString("utf8").trim();
      finish(new Error(String(helperError || "proxy_control_failed").slice(0, 500)));
    });

    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload || {}));
  });
}
