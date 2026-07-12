import { createHash, randomUUID } from "node:crypto";

import { all, one, run } from "./db.js";
import {
  acquireServiceLease,
  advanceActivityTasks,
  assertHorseRaceBetAllowed,
  recordSeasonSettlement,
} from "./growth-operations.js";
import { badRequest } from "./validators.js";

const rulesVersion = 2;
const bettingDurationMs = 4 * 60 * 1000;
const lockedDurationMs = 20 * 1000;
const racingDurationMs = 60 * 1000;
const resultDurationMs = 40 * 1000;
const lockOffsetMs = bettingDurationMs;
const raceOffsetMs = lockOffsetMs + lockedDurationMs;
const settleOffsetMs = raceOffsetMs + racingDurationMs;
const nextRoundOffsetMs = settleOffsetMs + resultDurationMs;
const legacyTiming = {
  bettingDurationMs: 170 * 60 * 1000,
  lockedDurationMs: 10 * 60 * 1000,
  racingDurationMs: 2 * 60 * 1000,
  resultDurationMs: 60 * 1000,
  lockOffsetMs: 170 * 60 * 1000,
  raceOffsetMs: 180 * 60 * 1000,
  settleOffsetMs: 182 * 60 * 1000,
  nextRoundOffsetMs: 183 * 60 * 1000,
};
const minBet = 1;
const betLimitPerHorse = 1000;
const betLimitPerRound = 2000;
const betLimitPerDay = 20000;
const payoutRate = 0.9;
const virtualLiquidity = 2000;
const hkOffsetMs = 8 * 60 * 60 * 1000;
const dayMs = 24 * 60 * 60 * 1000;
const openHour = 6;
const closeHour = 24;

const horseTemplates = [
  { name: "阿拉德之风", color: "#60A5FA", baseWinRate: 0.17, speed: 94, stamina: 76, gate: 84, style: "领跑", specialty: "短途" },
  { name: "赛丽亚祝福", color: "#F472B6", baseWinRate: 0.15, speed: 86, stamina: 90, gate: 80, style: "先行", specialty: "均衡" },
  { name: "格兰疾影", color: "#34D399", baseWinRate: 0.14, speed: 90, stamina: 82, gate: 78, style: "差行", specialty: "中途加速" },
  { name: "天空流星", color: "#A78BFA", baseWinRate: 0.13, speed: 88, stamina: 85, gate: 74, style: "追込", specialty: "末段冲刺" },
  { name: "暗黑雷鸣", color: "#FBBF24", baseWinRate: 0.12, speed: 82, stamina: 92, gate: 72, style: "先行", specialty: "长途" },
  { name: "樱花闪电", color: "#FB7185", baseWinRate: 0.11, speed: 92, stamina: 72, gate: 91, style: "逃马", specialty: "起步" },
  { name: "机械旋风", color: "#22D3EE", baseWinRate: 0.1, speed: 84, stamina: 86, gate: 86, style: "差行", specialty: "弯道" },
  { name: "月光骑士", color: "#C084FC", baseWinRate: 0.08, speed: 79, stamina: 94, gate: 70, style: "追込", specialty: "重场" },
];

const raceProfiles = [
  { name: "樱花杯短途赛", venue: "樱都竞马场", distanceMeters: 1200, trackCondition: "良", weather: "晴", description: "直道短、节奏快，起步和冲刺能力更重要。" },
  { name: "月光杯经典赛", venue: "月湾竞马场", distanceMeters: 1600, trackCondition: "良", weather: "夜晴", description: "速度与耐力均衡，是最考验综合能力的赛程。" },
  { name: "格兰耐力挑战", venue: "格兰丘陵", distanceMeters: 2000, trackCondition: "稍重", weather: "多云", description: "赛道偏软，耐力型和后程型赛马更有优势。" },
  { name: "雨樱逆转赛", venue: "樱都竞马场", distanceMeters: 1600, trackCondition: "重", weather: "小雨", description: "湿滑赛道充满变数，稳定性和耐力决定上限。" },
];

let commonStateCache = null;
const userStateCache = new Map();
const userStatsCache = new Map();

export function horseRaceStateJson(userId = 0) {
  const common = commonHorseRaceState();
  const personal = userId ? horseRaceUserState(common, userId) : emptyUserState();
  return { ...common, ...personal };
}

export function horseRaceStatesJson(userIds = []) {
  const common = commonHorseRaceState();
  const states = new Map();
  for (const userId of new Set(userIds.map(Number).filter((id) => id > 0))) {
    states.set(userId, { ...common, ...horseRaceUserState(common, userId) });
  }
  return states;
}

export function horseRaceHistoryJson({ userId = 0, limit = 10 } = {}) {
  const rows = all(
    `SELECT * FROM horse_race_rounds
     WHERE status = 'settling'
     ORDER BY id DESC
     LIMIT ?`,
    [Math.max(1, Math.min(30, Number(limit) || 10))],
  );
  const roundIds = rows.map((row) => row.id);
  const betsByRound = new Map();
  if (userId && roundIds.length) {
    const placeholders = roundIds.map(() => "?").join(",");
    for (const bet of all(
      `SELECT round_id, horse_index, amount, odds, payout, status
       FROM horse_race_bets
       WHERE user_id = ? AND round_id IN (${placeholders})
       ORDER BY round_id DESC, horse_index ASC`,
      [userId, ...roundIds],
    )) {
      if (!betsByRound.has(bet.round_id)) betsByRound.set(bet.round_id, []);
      betsByRound.get(bet.round_id).push(betJson(bet));
    }
  }
  return rows.map((row) => ({
    ...roundResultJson(row),
    myBets: betsByRound.get(row.id) || [],
  }));
}

export function placeHorseRaceBet({ userId, horseIndex, amount, requestId = "" }) {
  const round = ensureHorseRaceRound();
  const betAmount = Math.trunc(Number(amount));
  const normalizedRequestId = normalizeRequestId(requestId);
  if (!Number.isInteger(betAmount) || betAmount < minBet) {
    throw badRequest("horse_race_bet_amount_invalid");
  }
  if (betAmount > betLimitPerHorse) throw badRequest("horse_race_bet_limit");

  const horses = parseHorses(round.horses_json);
  if (!Number.isInteger(horseIndex) || horseIndex < 0 || horseIndex >= horses.length) {
    throw badRequest("horse_race_horse_invalid");
  }

  run("BEGIN IMMEDIATE");
  try {
    const currentRound = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
    const now = Date.now();
    const timing = roundTiming(currentRound);
    if (normalizedRequestId) {
      const previous = one(
        `SELECT round_id, horse_index, amount
         FROM horse_race_bet_requests
         WHERE user_id = ? AND request_id = ?`,
        [userId, normalizedRequestId],
      );
      if (previous) {
        if (previous.horse_index !== horseIndex || previous.amount !== betAmount) {
          throw badRequest("horse_race_request_conflict");
        }
        run("COMMIT");
        return horseRaceStateJson(userId);
      }
    }
    if (!currentRound || !horseRaceSchedule(now).isOpen) {
      throw badRequest("horse_race_closed");
    }
    if (
      currentRound.status !== "betting" ||
      now >= Number(currentRound.phase_started_at) + timing.lockOffsetMs
    ) {
      throw badRequest("horse_race_locked");
    }
    assertHorseRaceBetAllowed({ userId, additionalAmount: betAmount });

    const existed = one(
      `SELECT amount FROM horse_race_bets
       WHERE round_id = ? AND user_id = ? AND horse_index = ?`,
      [round.id, userId, horseIndex],
    );
    if ((existed?.amount || 0) + betAmount > betLimitPerHorse) {
      throw badRequest("horse_race_bet_limit");
    }
    const roundTotal = one(
      `SELECT COALESCE(SUM(amount), 0) AS total
       FROM horse_race_bets WHERE round_id = ? AND user_id = ?`,
      [round.id, userId],
    )?.total || 0;
    if (roundTotal + betAmount > betLimitPerRound) {
      throw badRequest("horse_race_round_bet_limit");
    }
    const dayStart = hkDayStartUtcMs(now);
    const dailyTotal = one(
      `SELECT COALESCE(SUM(b.amount), 0) AS total
       FROM horse_race_bets b
       JOIN horse_race_rounds r ON r.id = b.round_id
       WHERE b.user_id = ?
         AND r.phase_started_at >= ?
         AND r.phase_started_at < ?`,
      [userId, dayStart, dayStart + dayMs],
    )?.total || 0;
    if (dailyTotal + betAmount > betLimitPerDay) {
      throw badRequest("horse_race_daily_bet_limit");
    }

    const debit = run(
      `UPDATE users
       SET sakura_coins = sakura_coins - ?, updated_at = datetime('now')
       WHERE id = ? AND status = 'active' AND sakura_coins >= ?`,
      [betAmount, userId, betAmount],
    );
    if ((debit.changes || 0) !== 1) throw badRequest("coins_not_enough");

    run(
      `INSERT INTO horse_race_bets (round_id, user_id, horse_index, amount)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(round_id, user_id, horse_index) DO UPDATE SET
         amount = amount + excluded.amount`,
      [round.id, userId, horseIndex, betAmount],
    );
    if (normalizedRequestId) {
      run(
        `INSERT INTO horse_race_bet_requests
           (request_id, round_id, user_id, horse_index, amount)
         VALUES (?, ?, ?, ?, ?)`,
        [normalizedRequestId, round.id, userId, horseIndex, betAmount],
      );
    }
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'horse_race_bet', ?, '樱花赛马下注', 'horse_race', ?)`,
      [userId, -betAmount, String(round.id)],
    );
    advanceActivityTasks({
      userId,
      eventName: "horse_race_bet",
      amount: betAmount,
      context: { roundId: round.id },
    });
    run("COMMIT");
  } catch (error) {
    safeRollback();
    throw error;
  }

  invalidateHorseRaceCache(userId);
  return horseRaceStateJson(userId);
}

export function horseRaceChatMessages(limit = 40) {
  return all(
    `SELECT m.id, m.content, m.created_at, m.is_system,
            u.id AS user_id, u.nickname, u.avatar_url, u.role
     FROM horse_race_chat_messages m
     LEFT JOIN users u ON u.id = m.user_id
     ORDER BY m.id DESC
     LIMIT ?`,
    [Math.max(1, Math.min(100, limit))],
  ).reverse().map(horseRaceChatJson);
}

export function saveHorseRaceChat({ user, content }) {
  const text = String(content || "").trim().slice(0, 160);
  if (!text) throw badRequest("content is required");
  const result = run(
    "INSERT INTO horse_race_chat_messages (user_id, content) VALUES (?, ?)",
    [user.id, text],
  );
  run(
    `DELETE FROM horse_race_chat_messages
     WHERE id < COALESCE((
       SELECT id FROM horse_race_chat_messages ORDER BY id DESC LIMIT 1 OFFSET 999
     ), 0)`,
  );
  invalidateHorseRaceCache();
  return horseRaceChatById(Number(result.lastInsertRowid));
}

export function ensureHorseRaceRound() {
  const now = Date.now();
  const schedule = horseRaceSchedule(now);
  let round = one("SELECT * FROM horse_race_rounds ORDER BY id DESC LIMIT 1");
  if (!round) {
    if (!schedule.isOpen) return closedPlaceholderRound();
    if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) {
      return closedPlaceholderRound();
    }
    round = createHorseRaceRound(schedule.slotStart);
  }

  let guard = 0;
  while (guard < 10) {
    guard += 1;
    const start = Number(round.phase_started_at || now);
    const elapsed = now - start;
    const timing = roundTiming(round);
    if (round.status === "betting" && elapsed >= timing.lockOffsetMs) {
      if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) return round;
      lockHorseRaceRound(round);
      round = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
      continue;
    }
    if (round.status === "locked" && elapsed >= timing.raceOffsetMs) {
      if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) return round;
      run(
        "UPDATE horse_race_rounds SET status = 'racing' WHERE id = ? AND status = 'locked'",
        [round.id],
      );
      invalidateHorseRaceCache();
      round = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
      continue;
    }
    if (round.status === "racing" && elapsed >= timing.settleOffsetMs) {
      if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) return round;
      settleHorseRaceRound(round);
      round = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
      continue;
    }
    if (round.status === "settling" && elapsed >= timing.nextRoundOffsetMs) {
      if (schedule.isOpen) {
        if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) return round;
        round = createHorseRaceRound(schedule.slotStart);
        continue;
      }
      break;
    }
    break;
  }

  if (
    schedule.isOpen &&
    Number(round.phase_started_at || 0) < schedule.slotStart &&
    now >= Number(round.phase_started_at || 0) + roundTiming(round).nextRoundOffsetMs
  ) {
    if (!acquireServiceLease("horse-race-ticker", { leaseMs: 5000, now })) return round;
    round = createHorseRaceRound(schedule.slotStart);
    return ensureHorseRaceRound();
  }
  return round;
}

function commonHorseRaceState() {
  const now = Date.now();
  if (commonStateCache && commonStateCache.expiresAt > now) return commonStateCache.value;
  const round = ensureHorseRaceRound();
  const schedule = horseRaceSchedule(now);
  const start = Number(round.phase_started_at || now);
  const timing = roundTiming(round);
  const isActivePerformance = round.id > 0 && round.status !== "betting" && now < start + timing.nextRoundOffsetMs;
  const horses = parseHorses(round.horses_json);
  const betTotals = horseRaceBetTotals(round.id);
  const poolTotal = Object.values(betTotals).reduce((sum, value) => sum + value, 0);
  const odds = round.status === "betting"
    ? calculateOdds(horses, betTotals)
    : parseOdds(round.odds_json, horses, betTotals);
  const participantCount = round.id
    ? one("SELECT COUNT(DISTINCT user_id) AS total FROM horse_race_bets WHERE round_id = ?", [round.id])?.total || 0
    : 0;
  const race = parseJsonObject(round.race_json, defaultRaceProfile());
  const result = parseJsonObject(round.result_json, {});
  const phase = schedule.isOpen || isActivePerformance ? round.status : "closed";
  const progress = horses.map((_, index) => horseRaceProgress(round, index, now, result));
  const popularity = horses.map((horse, index) => ({
    index,
    share: poolTotal ? (betTotals[index] || 0) / poolTotal : horse.winRate,
  })).sort((a, b) => b.share - a.share);
  const popularityRanks = new Map(popularity.map((item, index) => [item.index, index + 1]));

  const value = {
    roundId: round.id,
    roundCode: round.round_key || roundCode(start),
    phase,
    isOpen: schedule.isOpen,
    now,
    phaseStartedAt: start,
    phaseEndsAt: phaseEndsAt(round, timing),
    openAt: schedule.openAt,
    closeAt: schedule.closeAt,
    nextOpenAt: schedule.nextOpenAt,
    lockAt: start + timing.lockOffsetMs,
    raceAt: start + timing.raceOffsetMs,
    settleAt: start + timing.settleOffsetMs,
    nextRoundAt: start + timing.nextRoundOffsetMs,
    minBet,
    betLimitPerHorse,
    betLimitPerRound,
    betLimitPerDay,
    poolTotal,
    participantCount,
    oddsLocked: round.status !== "betting",
    winnerIndex: round.status === "settling" ? round.winner_index : -1,
    rules: {
      version: Number(round.rules_version || 1),
      bettingSeconds: timing.bettingDurationMs / 1000,
      lockedSeconds: timing.lockedDurationMs / 1000,
      racingSeconds: timing.racingDurationMs / 1000,
      resultSeconds: timing.resultDurationMs / 1000,
      payoutRate,
      oddsMode: "estimated_until_lock",
    },
    fairness: {
      algorithm: Number(round.rules_version || 1) < rulesVersion ? "legacy-seed-v1" : "seed-commit-v1",
      seedCommit: seedCommit(round.seed || ""),
      seedReveal: round.status === "settling" ? round.seed || "" : "",
    },
    race,
    raceCommentary: raceCommentary(round, horses, progress, now),
    horses: horses.map((horse, index) => {
      const share = poolTotal ? (betTotals[index] || 0) / poolTotal : horse.winRate;
      const expectedShare = Number(horse.winRate) || 0.1;
      return {
        index,
        name: horse.name,
        color: horse.color,
        winRate: horse.winRate,
        odds: odds[index],
        totalBet: betTotals[index] || 0,
        progress: progress[index],
        formRating: horse.formRating || 80,
        recentForm: horse.recentForm || "-",
        style: horse.style || "均衡",
        specialty: horse.specialty || "综合",
        popularityRank: popularityRanks.get(index) || index + 1,
        popularityShare: Number(share.toFixed(4)),
        oddsTrend: share > expectedShare * 1.25 ? "hot" : share < expectedShare * 0.75 ? "cold" : "steady",
        returnPer100: Math.floor((odds[index] || 0) * 100),
        finishPosition: round.status === "settling" ? finishPosition(result, index) : 0,
      };
    }),
    recentResults: recentHorseRaceResults(5),
    recentChats: horseRaceChatMessages(40),
  };
  commonStateCache = { expiresAt: now + 750, value };
  return value;
}

function horseRaceUserState(common, userId) {
  const now = Date.now();
  const cached = userStateCache.get(userId);
  if (cached && cached.roundId === common.roundId && cached.expiresAt > now) {
    return personalizeBets(common, cached.value);
  }
  const walletCoins = one("SELECT sakura_coins FROM users WHERE id = ?", [userId])?.sakura_coins || 0;
  const myBets = common.roundId ? horseRaceUserBets(common.roundId, userId) : [];
  const stats = horseRaceUserStats(userId, now);
  const dayStart = hkDayStartUtcMs(now);
  const myBetToday = one(
    `SELECT COALESCE(SUM(b.amount), 0) AS total
     FROM horse_race_bets b
     JOIN horse_race_rounds r ON r.id = b.round_id
     WHERE b.user_id = ?
       AND r.phase_started_at >= ?
       AND r.phase_started_at < ?`,
    [userId, dayStart, dayStart + dayMs],
  )?.total || 0;
  const value = {
    walletCoins,
    myBets,
    myBetToday,
    myStats: {
      roundsPlayed: stats.rounds_played || 0,
      totalStaked: stats.total_staked || 0,
      totalPayout: stats.total_payout || 0,
      netProfit: (stats.total_payout || 0) - (stats.total_staked || 0),
      winningBets: stats.winning_bets || 0,
      totalBets: stats.total_bets || 0,
      winRate: stats.total_bets ? Number((stats.winning_bets / stats.total_bets).toFixed(4)) : 0,
    },
  };
  userStateCache.set(userId, { roundId: common.roundId, expiresAt: now + 10000, value });
  return personalizeBets(common, value);
}

function horseRaceUserStats(userId, now = Date.now()) {
  const cached = userStatsCache.get(userId);
  if (cached && cached.expiresAt > now) return cached.value;
  const value = one(
    `SELECT COUNT(*) AS total_bets,
            COUNT(DISTINCT round_id) AS rounds_played,
            COALESCE(SUM(amount), 0) AS total_staked,
            COALESCE(SUM(payout), 0) AS total_payout,
            COALESCE(SUM(CASE WHEN status = 'won' THEN 1 ELSE 0 END), 0) AS winning_bets
     FROM horse_race_bets WHERE user_id = ?`,
    [userId],
  ) || {};
  userStatsCache.set(userId, { expiresAt: now + 60000, value });
  return value;
}

function personalizeBets(common, value) {
  const oddsByHorse = new Map(common.horses.map((horse) => [horse.index, horse.odds]));
  const myBets = value.myBets.map((bet) => {
    const odds = Number(bet.odds) > 0 ? Number(bet.odds) : oddsByHorse.get(bet.horse_index) || 0;
    return {
      ...betJson({ ...bet, odds }),
      estimatedPayout: bet.status === "pending" ? Math.floor(bet.amount * odds) : bet.payout || 0,
    };
  });
  return {
    walletCoins: value.walletCoins,
    myBetToday: value.myBetToday || 0,
    myDailyRemaining: Math.max(0, betLimitPerDay - (value.myBetToday || 0)),
    myBetTotal: myBets.reduce((sum, bet) => sum + bet.amount, 0),
    myPotentialPayout: myBets.reduce((highest, bet) => Math.max(highest, bet.estimatedPayout), 0),
    myBets,
    myStats: value.myStats,
  };
}

function emptyUserState() {
  return {
    walletCoins: 0,
    myBetToday: 0,
    myDailyRemaining: betLimitPerDay,
    myBetTotal: 0,
    myPotentialPayout: 0,
    myBets: [],
    myStats: { roundsPlayed: 0, totalStaked: 0, totalPayout: 0, netProfit: 0, winningBets: 0, totalBets: 0, winRate: 0 },
  };
}

function horseRaceSchedule(now = Date.now()) {
  const dayStart = hkDayStartUtcMs(now);
  const openAt = dayStart + openHour * 60 * 60 * 1000;
  const closeAt = dayStart + closeHour * 60 * 60 * 1000;
  const lastSlotStart = closeAt - nextRoundOffsetMs;
  if (now < openAt) return { isOpen: false, openAt, closeAt, nextOpenAt: openAt, slotStart: lastSlotStart - dayMs };
  if (now >= closeAt) return { isOpen: false, openAt, closeAt, nextOpenAt: openAt + dayMs, slotStart: lastSlotStart };
  const slotStart = openAt + Math.floor((now - openAt) / nextRoundOffsetMs) * nextRoundOffsetMs;
  return { isOpen: true, openAt, closeAt, nextOpenAt: openAt, slotStart };
}

function hkDayStartUtcMs(now) {
  return Math.floor((now + hkOffsetMs) / dayMs) * dayMs - hkOffsetMs;
}

function createHorseRaceRound(phaseStartedAt) {
  const key = roundCode(phaseStartedAt);
  const existing = one("SELECT * FROM horse_race_rounds WHERE round_key = ?", [key]);
  if (existing) return existing;
  run(
    "DELETE FROM horse_race_bet_requests WHERE created_at < datetime('now', '-7 days')",
  );
  const seed = randomUUID();
  const race = raceProfiles[seedNumber(seed, "profile") % raceProfiles.length];
  const horses = buildRoundHorses(seed, race);
  const winnerIndex = winnerFromRates(seed, horses);
  const result = buildRaceResult(seed, horses, winnerIndex);
  run(
    `INSERT OR IGNORE INTO horse_race_rounds
       (status, seed, round_key, rules_version, horses_json, race_json, result_json, winner_index, phase_started_at)
     VALUES ('betting', ?, ?, ?, ?, ?, ?, ?, ?)`,
    [seed, key, rulesVersion, JSON.stringify(horses), JSON.stringify(race), JSON.stringify(result), winnerIndex, phaseStartedAt],
  );
  invalidateHorseRaceCache();
  return one("SELECT * FROM horse_race_rounds WHERE round_key = ?", [key]);
}

function closedPlaceholderRound() {
  const schedule = horseRaceSchedule();
  const race = defaultRaceProfile();
  const horses = buildRoundHorses("closed-placeholder", race);
  return {
    id: 0,
    status: "closed",
    seed: "closed-placeholder",
    rules_version: rulesVersion,
    round_key: "",
    horses_json: JSON.stringify(horses),
    odds_json: JSON.stringify(calculateOdds(horses, {})),
    race_json: JSON.stringify(race),
    result_json: "{}",
    winner_index: 0,
    phase_started_at: schedule.slotStart || Date.now(),
  };
}

function lockHorseRaceRound(round) {
  run("BEGIN IMMEDIATE");
  try {
    const current = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
    if (!current || current.status !== "betting") {
      run("COMMIT");
      return;
    }
    const horses = parseHorses(current.horses_json);
    const odds = calculateOdds(horses, horseRaceBetTotals(current.id));
    run(
      `UPDATE horse_race_rounds
       SET status = 'locked', odds_json = ?, locked_at = datetime('now')
       WHERE id = ? AND status = 'betting'`,
      [JSON.stringify(odds), current.id],
    );
    for (let index = 0; index < odds.length; index += 1) {
      run("UPDATE horse_race_bets SET odds = ? WHERE round_id = ? AND horse_index = ?", [odds[index], current.id, index]);
    }
    run("COMMIT");
    const waitSeconds = Math.round(roundTiming(current).lockedDurationMs / 1000);
    insertSystemChat(`第 ${current.id} 轮已封盘，赔率锁定，${waitSeconds} 秒后开赛。`);
  } catch (error) {
    safeRollback();
    throw error;
  }
  invalidateHorseRaceCache();
}

function settleHorseRaceRound(round) {
  run("BEGIN IMMEDIATE");
  try {
    const current = one("SELECT * FROM horse_race_rounds WHERE id = ?", [round.id]);
    if (!current || current.status === "settling") {
      run("COMMIT");
      return;
    }
    const horses = parseHorses(current.horses_json);
    const totals = horseRaceBetTotals(current.id);
    const odds = parseOdds(current.odds_json, horses, totals);
    const winner = horses[current.winner_index] || horses[0];
    const winnerOdds = odds[current.winner_index] || 1;
    const bets = all("SELECT * FROM horse_race_bets WHERE round_id = ? AND status = 'pending'", [current.id]);
    const perUser = new Map();
    for (const bet of bets) {
      const summary = perUser.get(bet.user_id) || { amount: 0, payout: 0 };
      summary.amount += bet.amount;
      const won = bet.horse_index === current.winner_index;
      const payout = won ? Math.max(1, Math.floor(bet.amount * winnerOdds)) : 0;
      summary.payout += payout;
      run(
        "UPDATE horse_race_bets SET odds = ?, payout = ?, status = ? WHERE id = ? AND status = 'pending'",
        [odds[bet.horse_index] || 0, payout, won ? "won" : "lost", bet.id],
      );
      perUser.set(bet.user_id, summary);
    }
    for (const [userId, summary] of perUser) {
      if (summary.payout > 0) {
        run("UPDATE users SET sakura_coins = sakura_coins + ?, updated_at = datetime('now') WHERE id = ?", [summary.payout, userId]);
        run(
          `INSERT INTO user_reward_events
             (user_id, action, coins_delta, description, related_type, related_id)
           VALUES (?, 'horse_race_payout', ?, '樱花赛马返还', 'horse_race', ?)`,
          [userId, summary.payout, String(current.id)],
        );
      }
      const delta = summary.payout - summary.amount;
      run(
        `INSERT INTO system_notifications (user_id, title, content, category)
         VALUES (?, ?, ?, 'horse_race')`,
        [
          userId,
          `第 ${current.id} 轮樱花赛马结果`,
          `${winner.name} 获胜。你本轮下注 ${summary.amount} 樱花币，返还 ${summary.payout} 樱花币，净变化 ${delta >= 0 ? "+" : ""}${delta} 樱花币。`,
        ],
      );
    }
    recordSeasonSettlement({ roundId: current.id, summaries: perUser });
    const result = {
      ...parseJsonObject(current.result_json, {}),
      winnerIndex: current.winner_index,
      winnerOdds,
      poolTotal: Object.values(totals).reduce((sum, value) => sum + value, 0),
      participantCount: perUser.size,
    };
    run(
      `UPDATE horse_race_rounds
       SET status = 'settling', odds_json = ?, result_json = ?, settled_at = datetime('now')
       WHERE id = ? AND status <> 'settling'`,
      [JSON.stringify(odds), JSON.stringify(result), current.id],
    );
    insertSystemChat(`第 ${current.id} 轮赛马结束，${winner.name} 冲线获胜，最终赔率 x${winnerOdds.toFixed(2)}。`);
    run("COMMIT");
  } catch (error) {
    safeRollback();
    throw error;
  }
  invalidateHorseRaceCache();
  userStateCache.clear();
  userStatsCache.clear();
}

function horseRaceBetTotals(roundId) {
  const totals = {};
  if (!roundId) return totals;
  for (const row of all(
    `SELECT horse_index, COALESCE(SUM(amount), 0) AS total
     FROM horse_race_bets WHERE round_id = ? GROUP BY horse_index`,
    [roundId],
  )) totals[row.horse_index] = row.total || 0;
  return totals;
}

function horseRaceUserBets(roundId, userId) {
  return all(
    `SELECT horse_index, amount, odds, payout, status
     FROM horse_race_bets
     WHERE round_id = ? AND user_id = ? ORDER BY horse_index ASC`,
    [roundId, userId],
  );
}

function calculateOdds(horses, totals) {
  const pool = Object.values(totals).reduce((sum, value) => sum + value, 0);
  return horses.map((horse, index) => {
    const probability = Math.max(0.04, Number(horse.winRate) || 0.1);
    const share = ((totals[index] || 0) + probability * virtualLiquidity) / (pool + virtualLiquidity);
    const pressureRatio = share / probability;
    const marketFactor = Math.max(0.9, Math.min(1.04, 1 - (pressureRatio - 1) * 0.08));
    return Number(Math.max(1.2, Math.min(12, (payoutRate / probability) * marketFactor)).toFixed(2));
  });
}

function parseOdds(raw, horses, totals) {
  try {
    const values = JSON.parse(raw || "[]");
    if (Array.isArray(values) && values.length === horses.length && values.every((value) => Number(value) > 0)) {
      return values.map((value) => Number(value));
    }
  } catch {
    // Use a deterministic fallback for legacy rounds.
  }
  return calculateOdds(horses, totals);
}

function phaseEndsAt(round, timing = roundTiming(round)) {
  const start = Number(round.phase_started_at || Date.now());
  if (round.status === "betting") return start + timing.lockOffsetMs;
  if (round.status === "locked") return start + timing.raceOffsetMs;
  if (round.status === "racing") return start + timing.settleOffsetMs;
  return start + timing.nextRoundOffsetMs;
}

function horseRaceProgress(round, index, now, result) {
  if (round.status === "betting" || round.status === "locked" || round.status === "closed") return 0.03;
  const checkpoints = result?.checkpoints?.[index];
  if (round.status === "settling") return Array.isArray(checkpoints) ? checkpoints.at(-1) : index === round.winner_index ? 1 : 0.82;
  const timing = roundTiming(round);
  const t = Math.min(1, Math.max(0, (now - (Number(round.phase_started_at) + timing.raceOffsetMs)) / timing.racingDurationMs));
  if (!Array.isArray(checkpoints) || checkpoints.length < 5) return Math.min(1, 0.03 + t * (index === round.winner_index ? 0.97 : 0.82));
  const position = t * 4;
  const segment = Math.min(3, Math.floor(position));
  const local = position - segment;
  const eased = local * local * (3 - 2 * local);
  return Number((checkpoints[segment] + (checkpoints[segment + 1] - checkpoints[segment]) * eased).toFixed(4));
}

function raceCommentary(round, horses, progress, now) {
  if (round.status === "betting") return "赛前展示中，赔率会随投注热度小幅变化。";
  if (round.status === "locked") return "封盘完成，骑手正在进入起跑闸。";
  if (round.status === "settling") return `${horses[round.winner_index]?.name || "冠军马"} 率先冲线，本轮已完成结算。`;
  if (round.status !== "racing") return "今日赛事将在 06:00 至 24:00 开放。";
  const timing = roundTiming(round);
  const elapsed = now - (Number(round.phase_started_at) + timing.raceOffsetMs);
  const raceRatio = elapsed / timing.racingDurationMs;
  const leader = progress.reduce((best, value, index) => value > progress[best] ? index : best, 0);
  if (raceRatio < 0.2) return `${horses[leader]?.name} 起步迅速，暂时占据领先。`;
  if (raceRatio < 0.7) return `${horses[leader]?.name} 领跑进入中段，后方马群正在逼近。`;
  return `${horses[leader]?.name} 率先进入最后冲刺，胜负即将揭晓。`;
}

function roundTiming(round) {
  if (Number(round?.rules_version || 1) < rulesVersion) return legacyTiming;
  return {
    bettingDurationMs,
    lockedDurationMs,
    racingDurationMs,
    resultDurationMs,
    lockOffsetMs,
    raceOffsetMs,
    settleOffsetMs,
    nextRoundOffsetMs,
  };
}

function buildRoundHorses(seed, race) {
  const generated = horseTemplates.map((horse, index) => {
    const formRating = 72 + (seedNumber(seed, `form:${index}`) % 25);
    const distanceSkill = race.distanceMeters <= 1200 ? horse.speed : race.distanceMeters >= 2000 ? horse.stamina : (horse.speed + horse.stamina) / 2;
    const trackSkill = race.trackCondition === "重" ? horse.stamina : race.trackCondition === "稍重" ? (horse.stamina + horse.gate) / 2 : (horse.speed + horse.gate) / 2;
    const conditionFactor = 0.9 + (distanceSkill * 0.6 + trackSkill * 0.25 + formRating * 0.15) / 1000;
    return {
      ...horse,
      formRating,
      recentForm: [0, 1, 2].map((slot) => 1 + (seedNumber(seed, `recent:${index}:${slot}`) % 8)).join("-"),
      winRate: horse.baseWinRate * conditionFactor * (0.96 + (seedNumber(seed, `variance:${index}`) % 9) / 100),
    };
  });
  return normalizeHorseRates(generated);
}

function buildRaceResult(seed, horses, winnerIndex) {
  const rest = horses.map((_, index) => index).filter((index) => index !== winnerIndex);
  rest.sort((a, b) => {
    const scoreA = horses[a].winRate * 1000 + (seedNumber(seed, `finish:${a}`) % 300) / 10;
    const scoreB = horses[b].winRate * 1000 + (seedNumber(seed, `finish:${b}`) % 300) / 10;
    return scoreB - scoreA;
  });
  const finishOrder = [winnerIndex, ...rest];
  const rankByHorse = new Map(finishOrder.map((horseIndex, rank) => [horseIndex, rank]));
  const checkpoints = horses.map((_, index) => {
    const p1 = 0.18 + (seedNumber(seed, `cp1:${index}`) % 90) / 1000;
    const p2 = p1 + 0.18 + (seedNumber(seed, `cp2:${index}`) % 70) / 1000;
    const p3 = p2 + 0.18 + (seedNumber(seed, `cp3:${index}`) % 60) / 1000;
    const rank = rankByHorse.get(index) || 0;
    const finish = rank === 0 ? 1 : 0.97 - rank * 0.022 - (seedNumber(seed, `margin:${index}`) % 8) / 1000;
    return [0.03, Number(p1.toFixed(4)), Number(p2.toFixed(4)), Number(p3.toFixed(4)), Number(Math.max(p3 + 0.05, finish).toFixed(4))];
  });
  return { winnerIndex, finishOrder, checkpoints };
}

function winnerFromRates(seed, horses) {
  const target = (seedNumber(seed, "winner") % 1000000) / 1000000;
  let cursor = 0;
  for (let index = 0; index < horses.length; index += 1) {
    cursor += horses[index].winRate;
    if (target <= cursor) return index;
  }
  return horses.length - 1;
}

function normalizeHorseRates(horses) {
  const total = horses.reduce((sum, horse) => sum + Number(horse.winRate || horse.baseWinRate || 0), 0) || 1;
  return horses.map((horse) => ({
    ...horse,
    winRate: Number((Number(horse.winRate || horse.baseWinRate || 0) / total).toFixed(6)),
  }));
}

function parseHorses(raw) {
  try {
    const parsed = JSON.parse(raw || "[]");
    if (Array.isArray(parsed) && parsed.length === horseTemplates.length) {
      return parsed.map((horse, index) => ({ ...horseTemplates[index], ...horse }));
    }
  } catch {
    // Use templates for corrupt legacy data.
  }
  return buildRoundHorses("fallback", defaultRaceProfile());
}

function recentHorseRaceResults(limit) {
  return all(
    `SELECT * FROM horse_race_rounds
     WHERE status = 'settling'
     ORDER BY id DESC LIMIT ?`,
    [limit],
  ).map(roundResultJson);
}

function roundResultJson(row) {
  const horses = parseHorses(row.horses_json);
  const result = parseJsonObject(row.result_json, {});
  const odds = parseOdds(row.odds_json, horses, {});
  const winnerIndex = Number(row.winner_index) || 0;
  const winner = horses[winnerIndex] || horses[0];
  return {
    roundId: row.id,
    roundCode: row.round_key || roundCode(Number(row.phase_started_at)),
    winnerIndex,
    winnerName: winner?.name || "",
    winnerColor: winner?.color || "#60A5FA",
    odds: result.winnerOdds || odds[winnerIndex] || 0,
    poolTotal: result.poolTotal || 0,
    participantCount: result.participantCount || 0,
    settledAt: row.settled_at || "",
    fairness: {
      algorithm: Number(row.rules_version || 1) < rulesVersion ? "legacy-seed-v1" : "seed-commit-v1",
      seedCommit: seedCommit(row.seed || ""),
      seedReveal: row.seed || "",
    },
  };
}

function finishPosition(result, horseIndex) {
  const index = Array.isArray(result?.finishOrder) ? result.finishOrder.indexOf(horseIndex) : -1;
  return index < 0 ? 0 : index + 1;
}

function betJson(bet) {
  return {
    horseIndex: bet.horse_index,
    amount: bet.amount || 0,
    odds: Number(bet.odds) || 0,
    payout: bet.payout || 0,
    status: bet.status || "pending",
  };
}

function defaultRaceProfile() {
  return raceProfiles[1];
}

function roundCode(timestamp) {
  const hk = new Date(Number(timestamp || Date.now()) + hkOffsetMs).toISOString();
  return `R${hk.slice(0, 10).replaceAll("-", "")}-${hk.slice(11, 16).replace(":", "")}`;
}

function seedNumber(seed, key) {
  let hash = 2166136261;
  for (const char of `${seed}:${key}`) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function seedCommit(seed) {
  return createHash("sha256").update(String(seed)).digest("hex");
}

function parseJsonObject(raw, fallback) {
  try {
    const parsed = JSON.parse(raw || "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
}

function normalizeRequestId(value) {
  const requestId = String(value || "").trim().slice(0, 80);
  return /^[A-Za-z0-9:_-]+$/.test(requestId) ? requestId : "";
}

function invalidateHorseRaceCache(userId = 0) {
  commonStateCache = null;
  if (userId) {
    userStateCache.delete(userId);
    userStatsCache.delete(userId);
  }
}

function safeRollback() {
  try {
    run("ROLLBACK");
  } catch {
    // Transaction was already closed.
  }
}

function insertSystemChat(content) {
  run("INSERT INTO horse_race_chat_messages (user_id, is_system, content) VALUES (0, 1, ?)", [content]);
}

function horseRaceChatById(id) {
  const row = one(
    `SELECT m.id, m.content, m.created_at, m.is_system,
            u.id AS user_id, u.nickname, u.avatar_url, u.role
     FROM horse_race_chat_messages m
     LEFT JOIN users u ON u.id = m.user_id
     WHERE m.id = ?`,
    [id],
  );
  return horseRaceChatJson(row);
}

function horseRaceChatJson(row) {
  const system = Boolean(row?.is_system);
  return {
    id: row?.id || 0,
    content: row?.content || "",
    createdAt: row?.created_at || "",
    isSystem: system,
    user: {
      id: system ? 0 : row?.user_id || 0,
      nickname: system ? "系统通知" : row?.nickname || "",
      avatarUrl: system ? "" : row?.avatar_url || "",
      role: system ? "system" : row?.role || "user",
      isAdmin: row?.role === "admin",
    },
  };
}
