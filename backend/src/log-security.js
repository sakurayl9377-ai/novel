const redacted = "[REDACTED]";
const sensitiveQueryKeys = new Set([
  "access_token",
  "api_key",
  "apikey",
  "auth",
  "authorization",
  "client_secret",
  "code",
  "code_verifier",
  "password",
  "refresh_token",
  "secret",
  "token",
]);

export function redactSensitiveUrl(value) {
  const text = String(value || "");
  if (!text) return "";
  try {
    const absolute = /^[a-z][a-z0-9+.-]*:\/\//i.test(text);
    const url = new URL(text, "http://local.invalid");
    for (const key of [...url.searchParams.keys()]) {
      if (sensitiveQueryKeys.has(key.toLowerCase())) {
        url.searchParams.set(key, redacted);
      }
    }
    const suffix = `${url.pathname}${url.search}${url.hash}`;
    return absolute ? `${url.protocol}//${url.host}${suffix}` : suffix;
  } catch {
    return redactSensitiveText(text);
  }
}

export function redactSensitiveText(value) {
  return String(value || "")
    .replace(/\bBearer\s+[^\s,;]+/gi, `Bearer ${redacted}`)
    .replace(
      /([?&](?:access_token|api_key|apikey|auth|authorization|client_secret|code|code_verifier|password|refresh_token|secret|token)=)[^&#\s]*/gi,
      `$1${redacted}`,
    )
    .replace(
      /(["'](?:accessToken|apiKey|authorization|clientSecret|client_secret|codeVerifier|code_verifier|password|refreshToken|refresh_token|secret|token)["']\s*:\s*["'])[^"']*/gi,
      `$1${redacted}`,
    );
}

export function secureRequestSerializer(request) {
  const raw = request?.raw || request;
  const headers = request?.headers || raw?.headers || {};
  const socket = request?.socket || raw?.socket;
  return {
    method: request?.method || raw?.method,
    url: redactSensitiveUrl(request?.url || raw?.url),
    host: request?.hostname || headers.host,
    remoteAddress: request?.ip || socket?.remoteAddress,
    remotePort: socket?.remotePort,
  };
}

export function secureErrorSerializer(error) {
  if (!error) return error;
  return {
    type: error.name || error.constructor?.name || "Error",
    message: redactSensitiveText(error.message),
    stack: redactSensitiveText(error.stack),
    code: error.code,
    statusCode: error.statusCode,
  };
}

export function secureLoggerOptions() {
  return {
    hooks: {
      logMethod(argumentsList, method) {
        return method.apply(this, argumentsList.map(redactLogArgument));
      },
    },
    redact: {
      censor: redacted,
      paths: [
        "req.headers.authorization",
        "req.headers.cookie",
        "req.headers['sec-websocket-protocol']",
        "req.headers['x-sakura-user-token']",
        "headers.authorization",
        "headers.cookie",
        "headers['sec-websocket-protocol']",
        "headers['x-sakura-user-token']",
        "authorization",
        "token",
        "accessToken",
        "refreshToken",
        "refresh_token",
        "clientSecret",
        "client_secret",
        "codeVerifier",
        "code_verifier",
        "password",
        "secret",
        "apiKey",
        "path",
        "url",
        "*.authorization",
        "*.token",
        "*.accessToken",
        "*.refreshToken",
        "*.refresh_token",
        "*.clientSecret",
        "*.client_secret",
        "*.codeVerifier",
        "*.code_verifier",
        "*.password",
        "*.secret",
        "*.apiKey",
      ],
    },
    serializers: {
      req: secureRequestSerializer,
      err: secureErrorSerializer,
    },
  };
}

function redactLogArgument(value) {
  if (typeof value === "string") return redactSensitiveText(value);
  if (!(value instanceof Error)) return value;

  const safeError = new Error(redactSensitiveText(value.message));
  safeError.name = value.name || "Error";
  safeError.stack = redactSensitiveText(value.stack);
  for (const key of Object.keys(value)) {
    const item = value[key];
    safeError[key] = typeof item === "string" ? redactSensitiveText(item) : item;
  }
  return safeError;
}
