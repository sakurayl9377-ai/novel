import crypto from 'node:crypto';
import { config } from './config.js';
import { growthFromUser } from './growth.js';

const passwordIterations = 120000;
const passwordKeyLength = 32;
const tokenTtlDays = 30;

export function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('base64url');
  const hash = crypto
    .pbkdf2Sync(password, salt, passwordIterations, passwordKeyLength, 'sha256')
    .toString('base64url');
  return `pbkdf2_sha256$${passwordIterations}$${salt}$${hash}`;
}

export function verifyPassword(password, encoded) {
  const [algorithm, iterationsText, salt, expected] = String(encoded).split('$');
  if (algorithm !== 'pbkdf2_sha256' || !salt || !expected) return false;
  const iterations = Number(iterationsText);
  if (!Number.isFinite(iterations)) return false;
  const actual = crypto
    .pbkdf2Sync(password, salt, iterations, passwordKeyLength, 'sha256')
    .toString('base64url');
  return safeEqual(actual, expected);
}

export function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export function hashToken(token) {
  return crypto
    .createHmac('sha256', config.tokenSecret)
    .update(token)
    .digest('base64url');
}

export function tokenExpiry() {
  const date = new Date();
  date.setDate(date.getDate() + tokenTtlDays);
  return date.toISOString();
}

export function hashCode(code, scope) {
  return crypto
    .createHmac('sha256', config.tokenSecret)
    .update(`${scope}:${String(code).toLowerCase()}`)
    .digest('base64url');
}

export function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

export function publicUser(user, options = {}) {
  if (!user) return null;
  return {
    id: user.id,
    email: user.email,
    nickname: user.nickname,
    avatarUrl: user.avatar_url ?? '',
    gender: user.gender ?? 'private',
    bio: user.bio ?? '',
    signature: user.signature ?? '',
    spaceTitle: user.space_title ?? '',
    profileBannerUrl: user.profile_banner_url ?? '',
    dynamicAvatarUrl: user.dynamic_avatar_url ?? '',
    profileTheme: user.profile_theme ?? 'sakura',
    privacyMode: Boolean(user.privacy_mode),
    role: user.role,
    status: user.status,
    growth: growthFromUser(user, options.dailyGrowth),
    createdAt: user.created_at,
  };
}

export function createSvgCaptcha() {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  const answer = Array.from({ length: 4 }, () =>
    alphabet[Math.floor(Math.random() * alphabet.length)],
  ).join('');
  const width = 132;
  const height = 48;
  const chars = answer
    .split('')
    .map((char, index) => {
      const x = 18 + index * 27;
      const y = 31 + Math.round(Math.random() * 6 - 3);
      const rotate = Math.round(Math.random() * 18 - 9);
      const color = ['#1f6feb', '#0f766e', '#b45309', '#be123c'][index % 4];
      return `<text x="${x}" y="${y}" fill="${color}" transform="rotate(${rotate} ${x} ${y})">${char}</text>`;
    })
    .join('');
  const lines = Array.from({ length: 5 }, (_, index) => {
    const x1 = Math.round(Math.random() * width);
    const y1 = Math.round(Math.random() * height);
    const x2 = Math.round(Math.random() * width);
    const y2 = Math.round(Math.random() * height);
    const color = ['#93c5fd', '#99f6e4', '#fcd34d', '#fda4af', '#c4b5fd'][
      index
    ];
    return `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${color}" stroke-width="1.4" opacity="0.85" />`;
  }).join('');
  const dots = Array.from({ length: 20 }, () => {
    const cx = Math.round(Math.random() * width);
    const cy = Math.round(Math.random() * height);
    return `<circle cx="${cx}" cy="${cy}" r="1" fill="#94a3b8" opacity="0.55" />`;
  }).join('');

  return {
    answer,
    svg:
      `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">` +
      `<rect width="100%" height="100%" rx="8" fill="#f8fafc" />` +
      `${dots}${lines}` +
      `<g font-family="Arial, sans-serif" font-size="26" font-weight="700" letter-spacing="2">${chars}</g>` +
      `</svg>`,
  };
}

export function sixDigitCode() {
  return String(crypto.randomInt(100000, 1000000));
}

export function minutesFromNow(minutes) {
  return new Date(Date.now() + minutes * 60 * 1000).toISOString();
}

export function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}
