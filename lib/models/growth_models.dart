class GrowthContent {
  const GrowthContent({
    required this.stableKey,
    required this.contentType,
    required this.sourceKey,
    required this.sourceItemId,
    required this.title,
    this.author = '',
    this.coverUrl = '',
    this.metadata = const {},
  });

  final String stableKey;
  final String contentType;
  final String sourceKey;
  final String sourceItemId;
  final String title;
  final String author;
  final String coverUrl;
  final Map<String, dynamic> metadata;

  factory GrowthContent.fromJson(Map<String, dynamic> json) => GrowthContent(
    stableKey: _text(json['stableKey']),
    contentType: _text(json['contentType']),
    sourceKey: _text(json['sourceKey']),
    sourceItemId: _text(json['sourceItemId']),
    title: _text(json['title']),
    author: _text(json['author']),
    coverUrl: _text(json['coverUrl'] ?? json['imageUrl']),
    metadata: _map(json['metadata']),
  );
}

class GrowthRecommendation {
  const GrowthRecommendation({
    required this.content,
    required this.rank,
    required this.score,
    this.reasons = const [],
    this.continueProgress = false,
  });

  final GrowthContent content;
  final int rank;
  final double score;
  final List<String> reasons;
  final bool continueProgress;

  factory GrowthRecommendation.fromJson(Map<String, dynamic> json) =>
      GrowthRecommendation(
        content: GrowthContent.fromJson(_map(json['content'])),
        rank: _integer(json['rank']),
        score: _number(json['score']),
        reasons: _strings(json['reasons']),
        continueProgress: json['continueProgress'] == true,
      );
}

class GrowthRankingItem {
  const GrowthRankingItem({
    required this.content,
    required this.rank,
    required this.score,
    this.explanation = '',
    this.pinned = false,
  });

  final GrowthContent content;
  final int rank;
  final double score;
  final String explanation;
  final bool pinned;

  factory GrowthRankingItem.fromJson(Map<String, dynamic> json) =>
      GrowthRankingItem(
        content: GrowthContent.fromJson(_map(json['content'])),
        rank: _integer(json['rank']),
        score: _number(json['score']),
        explanation: _text(json['explanation']),
        pinned: json['pinned'] == true,
      );
}

class ActivityCampaign {
  const ActivityCampaign({
    required this.id,
    required this.title,
    this.description = '',
    this.bannerUrl = '',
    this.startsAt = '',
    this.endsAt = '',
    this.tasks = const [],
  });

  final int id;
  final String title;
  final String description;
  final String bannerUrl;
  final String startsAt;
  final String endsAt;
  final List<ActivityTask> tasks;

  factory ActivityCampaign.fromJson(Map<String, dynamic> json) =>
      ActivityCampaign(
        id: _integer(json['id']),
        title: _text(json['title']),
        description: _text(json['description']),
        bannerUrl: _text(json['bannerUrl']),
        startsAt: _text(json['startsAt']),
        endsAt: _text(json['endsAt']),
        tasks: _maps(json['tasks']).map(ActivityTask.fromJson).toList(),
      );
}

class ActivityTask {
  const ActivityTask({
    required this.id,
    required this.title,
    required this.targetCount,
    required this.progressCount,
    this.description = '',
    this.completed = false,
    this.claimed = false,
    this.rewardPoints = 0,
    this.rewardCoins = 0,
  });

  final int id;
  final String title;
  final String description;
  final int targetCount;
  final int progressCount;
  final bool completed;
  final bool claimed;
  final int rewardPoints;
  final int rewardCoins;

  bool get canClaim => completed && !claimed;
  double get progress =>
      targetCount <= 0 ? 0 : (progressCount / targetCount).clamp(0.0, 1.0);

  factory ActivityTask.fromJson(Map<String, dynamic> json) {
    final reward = _map(json['reward']);
    return ActivityTask(
      id: _integer(json['id']),
      title: _text(json['title']),
      description: _text(json['description']),
      targetCount: _integer(json['targetCount'], 1),
      progressCount: _integer(json['progressCount']),
      completed: json['completed'] == true,
      claimed: json['claimed'] == true,
      rewardPoints: _integer(reward['points']),
      rewardCoins: _integer(reward['coins']),
    );
  }
}

class HorseRaceSeasonPayload {
  const HorseRaceSeasonPayload({
    this.season,
    this.leaderboard = const [],
    this.myStats,
    this.tasks = const [],
    this.rewards = const [],
  });

  final HorseRaceSeason? season;
  final List<HorseRaceSeasonStats> leaderboard;
  final HorseRaceSeasonStats? myStats;
  final List<HorseRaceSeasonTask> tasks;
  final List<HorseRaceSeasonReward> rewards;

  factory HorseRaceSeasonPayload.fromJson(Map<String, dynamic> json) {
    final rawSeason = json['season'];
    final rawStats = json['myStats'];
    return HorseRaceSeasonPayload(
      season: rawSeason is Map
          ? HorseRaceSeason.fromJson(rawSeason.cast<String, dynamic>())
          : null,
      leaderboard: _maps(
        json['leaderboard'],
      ).map(HorseRaceSeasonStats.fromJson).toList(),
      myStats: rawStats is Map
          ? HorseRaceSeasonStats.fromJson(rawStats.cast<String, dynamic>())
          : null,
      tasks: _maps(json['tasks']).map(HorseRaceSeasonTask.fromJson).toList(),
      rewards: _maps(
        json['rewards'],
      ).map(HorseRaceSeasonReward.fromJson).toList(),
    );
  }
}

class HorseRaceSeason {
  const HorseRaceSeason({
    required this.id,
    required this.title,
    required this.status,
    this.startsAt = '',
    this.endsAt = '',
    this.config = const {},
  });

  final int id;
  final String title;
  final String status;
  final String startsAt;
  final String endsAt;
  final Map<String, dynamic> config;

  factory HorseRaceSeason.fromJson(Map<String, dynamic> json) =>
      HorseRaceSeason(
        id: _integer(json['id']),
        title: _text(json['title']),
        status: _text(json['status']),
        startsAt: _text(json['startsAt']),
        endsAt: _text(json['endsAt']),
        config: _map(json['config']),
      );
}

class HorseRaceSeasonStats {
  const HorseRaceSeasonStats({
    required this.userId,
    required this.nickname,
    required this.points,
    this.rank = 0,
    this.avatarUrl = '',
    this.rounds = 0,
    this.wins = 0,
    this.totalBet = 0,
    this.totalPayout = 0,
    this.tier = 'bronze',
  });

  final int userId;
  final String nickname;
  final int rank;
  final String avatarUrl;
  final int points;
  final int rounds;
  final int wins;
  final int totalBet;
  final int totalPayout;
  final String tier;

  factory HorseRaceSeasonStats.fromJson(Map<String, dynamic> json) =>
      HorseRaceSeasonStats(
        userId: _integer(json['userId']),
        nickname: _text(json['nickname'], '赛场玩家'),
        rank: _integer(json['rank']),
        avatarUrl: _text(json['avatarUrl']),
        points: _integer(json['points']),
        rounds: _integer(json['rounds']),
        wins: _integer(json['wins']),
        totalBet: _integer(json['totalBet']),
        totalPayout: _integer(json['totalPayout']),
        tier: _text(json['tier'], 'bronze'),
      );
}

class HorseRaceSeasonTask {
  const HorseRaceSeasonTask({
    required this.id,
    required this.title,
    required this.targetCount,
    required this.progressCount,
    this.completed = false,
    this.claimed = false,
    this.rewardPoints = 0,
    this.rewardCoins = 0,
  });

  final int id;
  final String title;
  final int targetCount;
  final int progressCount;
  final bool completed;
  final bool claimed;
  final int rewardPoints;
  final int rewardCoins;

  bool get canClaim => completed && !claimed;
  double get progress =>
      targetCount <= 0 ? 0 : (progressCount / targetCount).clamp(0.0, 1.0);

  factory HorseRaceSeasonTask.fromJson(Map<String, dynamic> json) {
    final reward = _map(json['reward']);
    return HorseRaceSeasonTask(
      id: _integer(json['id']),
      title: _text(json['title']),
      targetCount: _integer(json['targetCount'], 1),
      progressCount: _integer(json['progressCount']),
      completed: json['completed'] == true,
      claimed: json['claimed'] == true,
      rewardPoints: _integer(reward['points']),
      rewardCoins: _integer(reward['coins']),
    );
  }
}

class HorseRaceSeasonReward {
  const HorseRaceSeasonReward({
    required this.id,
    required this.title,
    this.tier = '',
    this.minRank = 0,
    this.maxRank = 0,
    this.rewardPoints = 0,
    this.rewardCoins = 0,
  });

  final int id;
  final String title;
  final String tier;
  final int minRank;
  final int maxRank;
  final int rewardPoints;
  final int rewardCoins;

  factory HorseRaceSeasonReward.fromJson(Map<String, dynamic> json) {
    final reward = _map(json['reward']);
    return HorseRaceSeasonReward(
      id: _integer(json['id']),
      title: _text(json['title']),
      tier: _text(json['tier']),
      minRank: _integer(json['minRank']),
      maxRank: _integer(json['maxRank']),
      rewardPoints: _integer(reward['points']),
      rewardCoins: _integer(reward['coins']),
    );
  }
}

class ResponsibleGamingSettings {
  const ResponsibleGamingSettings({
    this.cooldownUntil = '',
    this.selfExcludedUntil = '',
    this.dailyBetLimit = 0,
    this.dailyLossLimit = 0,
    this.reminderLossThreshold = 500,
    this.todayBet = 0,
    this.todayPayout = 0,
    this.todayLoss = 0,
  });

  final String cooldownUntil;
  final String selfExcludedUntil;
  final int dailyBetLimit;
  final int dailyLossLimit;
  final int reminderLossThreshold;
  final int todayBet;
  final int todayPayout;
  final int todayLoss;

  factory ResponsibleGamingSettings.fromJson(Map<String, dynamic> json) =>
      ResponsibleGamingSettings(
        cooldownUntil: _text(json['cooldownUntil']),
        selfExcludedUntil: _text(json['selfExcludedUntil']),
        dailyBetLimit: _integer(json['dailyBetLimit']),
        dailyLossLimit: _integer(json['dailyLossLimit']),
        reminderLossThreshold: _integer(json['reminderLossThreshold'], 500),
        todayBet: _integer(json['todayBet']),
        todayPayout: _integer(json['todayPayout']),
        todayLoss: _integer(json['todayLoss']),
      );
}

class AppBootstrapPayload {
  const AppBootstrapPayload({
    this.cacheRevision = 0,
    this.features = const {},
    this.placements = const {},
  });

  final int cacheRevision;
  final Map<String, dynamic> features;
  final Map<String, List<Map<String, dynamic>>> placements;

  factory AppBootstrapPayload.fromJson(Map<String, dynamic> json) {
    final rawPlacements = _map(json['placements']);
    return AppBootstrapPayload(
      cacheRevision: _integer(json['cacheRevision']),
      features: _map(json['features']),
      placements: rawPlacements.map(
        (key, value) => MapEntry(key, _maps(value)),
      ),
    );
  }
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : const {};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map((item) => _map(item)).toList()
    : const [];

List<String> _strings(Object? value) => value is List
    ? value.map((item) => _text(item)).where((item) => item.isNotEmpty).toList()
    : const [];

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

int _integer(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _number(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}
