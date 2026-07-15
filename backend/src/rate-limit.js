const buckets = new Map();
const maxBuckets = 20000;
let consumeCount = 0;

export function consumeRateLimit({
  scope,
  key,
  limit,
  windowMs,
  now = Date.now(),
}) {
  const safeLimit = Math.max(1, Math.trunc(Number(limit) || 1));
  const safeWindowMs = Math.max(1000, Math.trunc(Number(windowMs) || 1000));
  const bucketKey = `${scope}:${String(key || 'anonymous').slice(0, 300)}`;
  let bucket = buckets.get(bucketKey);

  if (!bucket || bucket.resetAt <= now) {
    bucket = { count: 0, resetAt: now + safeWindowMs, touchedAt: now };
  }
  bucket.count += 1;
  bucket.touchedAt = now;
  buckets.delete(bucketKey);
  buckets.set(bucketKey, bucket);

  consumeCount += 1;
  if (consumeCount % 256 === 0) pruneExpiredBuckets(now);
  while (buckets.size > maxBuckets) {
    buckets.delete(buckets.keys().next().value);
  }

  return {
    limited: bucket.count > safeLimit,
    remaining: Math.max(0, safeLimit - bucket.count),
    retryAfter: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)),
  };
}

export function enforceRateLimits(request, reply, rules) {
  for (const rule of rules) {
    const result = consumeRateLimit(rule);
    if (!result.limited) continue;
    reply.header('Retry-After', String(result.retryAfter));
    return reply.code(429).send({
      error: rule.error || 'rate_limited',
      retryAfter: result.retryAfter,
    });
  }
  return null;
}

export function clearRateLimitsForTests() {
  buckets.clear();
  consumeCount = 0;
}

export function rateLimitBucketCountForTests() {
  return buckets.size;
}

function pruneExpiredBuckets(now) {
  for (const [key, bucket] of buckets) {
    if (bucket.resetAt <= now) buckets.delete(key);
  }
}
