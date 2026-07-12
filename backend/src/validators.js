const targetTypes = new Set(['novel', 'manga', 'anime', 'chapter', 'episode']);
const reportTypes = new Set(['comment', 'danmaku', 'chat', 'user']);

export function requiredString(value, name, maxLength = 2000) {
  const text = String(value ?? '').trim();
  if (!text) throw badRequest(`${name} is required`);
  if (text.length > maxLength) throw badRequest(`${name} is too long`);
  return text;
}

export function optionalString(value, maxLength = 2000) {
  const text = String(value ?? '').trim();
  if (!text) return '';
  if (text.length > maxLength) throw badRequest('value is too long');
  return text;
}

export function optionalInt(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : fallback;
}

export function pageParams(query) {
  const page = Math.max(1, Math.min(200, optionalInt(query.page, 1)));
  const pageSize = Math.max(1, Math.min(100, optionalInt(query.pageSize, 20)));
  return { page, pageSize, offset: (page - 1) * pageSize };
}

export function targetType(value) {
  const text = requiredString(value, 'targetType', 32);
  if (!targetTypes.has(text)) throw badRequest('targetType is invalid');
  return text;
}

export function reportTargetType(value) {
  const text = requiredString(value, 'targetType', 32);
  if (!reportTypes.has(text)) throw badRequest('targetType is invalid');
  return text;
}

export function email(value) {
  const text = requiredString(value, 'email', 254).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) {
    throw badRequest('email is invalid');
  }
  return text;
}

export function password(value) {
  const text = String(value ?? '');
  if (text.length < 8 || text.length > 72) {
    throw badRequest('password must be 8-72 characters');
  }
  return text;
}

export function rating(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1 || number > 5) {
    throw badRequest('rating must be 1-5');
  }
  return number;
}

export function badRequest(message) {
  const error = new Error(message);
  error.statusCode = 400;
  return error;
}

export function forbidden(message = 'forbidden') {
  const error = new Error(message);
  error.statusCode = 403;
  return error;
}
