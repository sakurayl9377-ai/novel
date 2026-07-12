class InteractionUserBrief {
  const InteractionUserBrief({
    required this.id,
    required this.nickname,
    this.avatarUrl = '',
    this.badges = const [],
    this.skinId = '',
    this.avatarAsset = '',
  });

  final int id;
  final String nickname;
  final String avatarUrl;
  final List<InteractionUserBadge> badges;
  final String skinId;
  final String avatarAsset;

  factory InteractionUserBrief.fromJson(Map<String, dynamic> json) {
    return InteractionUserBrief(
      id: _asInt(json['id']),
      nickname: _asString(json['nickname']),
      avatarUrl: _asString(json['avatarUrl']),
      badges: _badgeList(json['badges']),
      skinId: _asString(json['skinId']),
      avatarAsset: _asString(json['avatarAsset']),
    );
  }
}

class InteractionUserBadge {
  const InteractionUserBadge({
    required this.key,
    required this.label,
    this.style = '',
  });

  final String key;
  final String label;
  final String style;

  bool get isRainbowAdmin => key == 'admin' && style == 'rainbow';

  factory InteractionUserBadge.fromJson(Map<String, dynamic> json) {
    return InteractionUserBadge(
      key: _asString(json['key']),
      label: _asString(json['label']),
      style: _asString(json['style']),
    );
  }
}

class ChatBotPublicProfile {
  const ChatBotPublicProfile({
    this.botName = '小樱',
    this.skinId = 'sakura',
    this.enabled = false,
    this.avatarAsset = 'assets/images/chat_bot/sakura.png',
    this.imageAsset = 'assets/images/chat_bot/sakura_body.png',
  });

  final String botName;
  final String skinId;
  final bool enabled;
  final String avatarAsset;
  final String imageAsset;

  factory ChatBotPublicProfile.fromJson(Map<String, dynamic> json) {
    final skinJson = json['skin'];
    final skin = skinJson is Map
        ? skinJson.cast<String, dynamic>()
        : const <String, dynamic>{};
    return ChatBotPublicProfile(
      botName: _asString(json['botName']).isEmpty
          ? '小樱'
          : _asString(json['botName']),
      skinId: _asString(json['skinId']).isEmpty
          ? 'sakura'
          : _asString(json['skinId']),
      enabled: _asBool(json['enabled']),
      avatarAsset: _asString(skin['avatarAsset']).isEmpty
          ? 'assets/images/chat_bot/sakura.png'
          : _asString(skin['avatarAsset']),
      imageAsset: _asString(skin['imageAsset']).isEmpty
          ? 'assets/images/chat_bot/sakura_body.png'
          : _asString(skin['imageAsset']),
    );
  }
}

class AppAnnouncement {
  const AppAnnouncement({
    this.enabled = false,
    this.id = '',
    this.title = '公告',
    this.content = '',
    this.updatedAt = '',
  });

  final bool enabled;
  final String id;
  final String title;
  final String content;
  final String updatedAt;

  bool get shouldShow => enabled && id.isNotEmpty && content.isNotEmpty;

  factory AppAnnouncement.fromJson(Map<String, dynamic> json) {
    return AppAnnouncement(
      enabled: _asBool(json['enabled']),
      id: _asString(json['id']),
      title: _asString(json['title']).isEmpty ? '公告' : _asString(json['title']),
      content: _asString(json['content']),
      updatedAt: _asString(json['updatedAt']),
    );
  }
}

class MessageUnreadSummary {
  const MessageUnreadSummary({
    this.total = 0,
    this.system = 0,
    this.privateMessages = 0,
    this.chatMessages = 0,
  });

  final int total;
  final int system;
  final int privateMessages;
  final int chatMessages;

  factory MessageUnreadSummary.fromJson(Map<String, dynamic> json) {
    return MessageUnreadSummary(
      total: _asInt(json['total']),
      system: _asInt(json['system']),
      privateMessages: _asInt(json['privateMessages'] ?? json['private']),
      chatMessages: _asInt(json['chatMessages'] ?? json['chat']),
    );
  }
}

class InteractionComment {
  const InteractionComment({
    required this.id,
    this.parentId,
    required this.targetType,
    required this.targetId,
    this.targetTitle = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.episodeId = '',
    this.episodeTitle = '',
    required this.content,
    required this.createdAt,
    required this.user,
    this.rating,
    this.likeCount = 0,
    this.replyCount = 0,
  });

  final int id;
  final int? parentId;
  final String targetType;
  final String targetId;
  final String targetTitle;
  final String chapterId;
  final String chapterTitle;
  final String episodeId;
  final String episodeTitle;
  final String content;
  final String createdAt;
  final InteractionUserBrief user;
  final int? rating;
  final int likeCount;
  final int replyCount;

  factory InteractionComment.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    final parentId = _asInt(json['parentId']);
    return InteractionComment(
      id: _asInt(json['id']),
      parentId: parentId <= 0 ? null : parentId,
      targetType: _asString(json['targetType']),
      targetId: _asString(json['targetId']),
      targetTitle: _asString(json['targetTitle']),
      chapterId: _asString(json['chapterId']),
      chapterTitle: _asString(json['chapterTitle']),
      episodeId: _asString(json['episodeId']),
      episodeTitle: _asString(json['episodeTitle']),
      content: _asString(json['content']),
      createdAt: _asString(json['createdAt']),
      rating: json['rating'] == null ? null : _asInt(json['rating']),
      likeCount: _asInt(json['likeCount']),
      replyCount: _asInt(json['replyCount']),
      user: userJson is Map
          ? InteractionUserBrief.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
    );
  }

  InteractionComment copyWith({int? likeCount, int? replyCount}) {
    return InteractionComment(
      id: id,
      parentId: parentId,
      targetType: targetType,
      targetId: targetId,
      targetTitle: targetTitle,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      episodeId: episodeId,
      episodeTitle: episodeTitle,
      content: content,
      createdAt: createdAt,
      user: user,
      rating: rating,
      likeCount: likeCount ?? this.likeCount,
      replyCount: replyCount ?? this.replyCount,
    );
  }
}

class InteractionCommentSummary {
  const InteractionCommentSummary({
    required this.targetType,
    required this.targetId,
    this.chapterId = '',
    this.episodeId = '',
    this.commentCount = 0,
    this.userCount = 0,
    this.replyCount = 0,
    this.ratingAvg,
    this.lastCreatedAt = '',
    this.items = const [],
  });

  final String targetType;
  final String targetId;
  final String chapterId;
  final String episodeId;
  final int commentCount;
  final int userCount;
  final int replyCount;
  final double? ratingAvg;
  final String lastCreatedAt;
  final List<InteractionComment> items;

  factory InteractionCommentSummary.fromJson(Map<String, dynamic> json) {
    final summaryJson = json['summary'];
    final summary = summaryJson is Map
        ? summaryJson.cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawItems = json['items'];
    return InteractionCommentSummary(
      targetType: _asString(summary['targetType']),
      targetId: _asString(summary['targetId']),
      chapterId: _asString(summary['chapterId']),
      episodeId: _asString(summary['episodeId']),
      commentCount: _asInt(summary['commentCount']),
      userCount: _asInt(summary['userCount']),
      replyCount: _asInt(summary['replyCount']),
      ratingAvg: _asNullableDouble(summary['ratingAvg']),
      lastCreatedAt: _asString(summary['lastCreatedAt']),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) =>
                      InteractionComment.fromJson(item.cast<String, dynamic>()),
                )
                .toList()
          : const [],
    );
  }
}

class InteractionDanmaku {
  const InteractionDanmaku({
    required this.id,
    required this.videoId,
    required this.animeId,
    this.animeTitle = '',
    required this.episodeId,
    this.episodeTitle = '',
    required this.timeMs,
    required this.content,
    this.color = '#FFFFFF',
    this.mode = 'scroll',
    required this.createdAt,
    required this.user,
  });

  final int id;
  final String videoId;
  final String animeId;
  final String animeTitle;
  final String episodeId;
  final String episodeTitle;
  final int timeMs;
  final String content;
  final String color;
  final String mode;
  final String createdAt;
  final InteractionUserBrief user;

  factory InteractionDanmaku.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return InteractionDanmaku(
      id: _asInt(json['id']),
      videoId: _asString(json['videoId']),
      animeId: _asString(json['animeId']),
      animeTitle: _asString(json['animeTitle']),
      episodeId: _asString(json['episodeId']),
      episodeTitle: _asString(json['episodeTitle']),
      timeMs: _asInt(json['timeMs']),
      content: _asString(json['content']),
      color: _normalizeDanmakuColor(_asString(json['color'])),
      mode: _normalizeDanmakuMode(_asString(json['mode'])),
      createdAt: _asString(json['createdAt']),
      user: userJson is Map
          ? InteractionUserBrief.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.roomId,
    this.type = 'text',
    required this.content,
    this.mediaUrl = '',
    this.metadata = const {},
    required this.createdAt,
    required this.user,
  });

  final int id;
  final String roomId;
  final String type;
  final String content;
  final String mediaUrl;
  final Map<String, dynamic> metadata;
  final String createdAt;
  final InteractionUserBrief user;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return ChatMessage(
      id: _asInt(json['id']),
      roomId: _asString(json['roomId']),
      type: _asString(json['type']).isEmpty ? 'text' : _asString(json['type']),
      content: _asString(json['content']),
      mediaUrl: _asString(json['mediaUrl']),
      metadata: _mapOf(json['metadata']),
      createdAt: _asString(json['createdAt']),
      user: userJson is Map
          ? InteractionUserBrief.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
    );
  }

  Map<String, dynamic> get share => _mapOf(metadata['share']);
  Map<String, dynamic> get reply => _mapOf(metadata['reply']);
  String get chatBubble => _asString(metadata['chatBubble']);
}

class ChatRoomInfo {
  const ChatRoomInfo({
    required this.roomId,
    this.name = '',
    this.avatarUrl = '',
    this.minLevel = 0,
    this.category = 'novel',
    this.categoryLabel = '',
    this.isOfficial = false,
    this.activeUserCount = 0,
    this.recentMessageCount = 0,
    this.latestContent = '',
    this.canEnter = true,
    this.botEnabled = false,
    this.isJoined = false,
    this.members = const [],
  });

  final String roomId;
  final String name;
  final String avatarUrl;
  final int minLevel;
  final String category;
  final String categoryLabel;
  final bool isOfficial;
  final int activeUserCount;
  final int recentMessageCount;
  final String latestContent;
  final bool canEnter;
  final bool botEnabled;
  final bool isJoined;
  final List<ChatRoomMember> members;

  String get displayName {
    if (name.isNotEmpty) return name;
    final label = displayCategoryLabel;
    return label.isEmpty ? '聊天室' : '$label聊天室';
  }

  String get displayCategoryLabel {
    if (categoryLabel.isNotEmpty) return categoryLabel;
    return _chatCategoryLabel(category);
  }

  factory ChatRoomInfo.fromJson(Map<String, dynamic> json) {
    final rawRoomId = _asString(json['roomId']);
    final fallbackId = _asString(json['id']);
    final category = _asString(json['category']);
    return ChatRoomInfo(
      roomId: rawRoomId.isEmpty ? fallbackId : rawRoomId,
      name: _asString(json['name']),
      avatarUrl: _asString(json['avatarUrl']),
      minLevel: _asInt(json['minLevel']),
      category: category.isEmpty ? 'novel' : category,
      categoryLabel: _asString(json['categoryLabel']),
      isOfficial: _asBool(json['isOfficial']),
      activeUserCount: _asInt(json['activeUserCount']),
      recentMessageCount: _asInt(json['recentMessageCount']),
      latestContent: _asString(json['latestContent']),
      canEnter: json.containsKey('canEnter') ? _asBool(json['canEnter']) : true,
      botEnabled: _asBool(json['botEnabled']),
      isJoined: _asBool(json['isJoined']),
      members: _chatRoomMemberList(json['members']),
    );
  }

  ChatRoomInfo copyWith({
    String? roomId,
    String? name,
    String? avatarUrl,
    int? minLevel,
    String? category,
    String? categoryLabel,
    bool? isOfficial,
    int? activeUserCount,
    int? recentMessageCount,
    String? latestContent,
    bool? canEnter,
    bool? botEnabled,
    bool? isJoined,
    List<ChatRoomMember>? members,
  }) {
    return ChatRoomInfo(
      roomId: roomId ?? this.roomId,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      minLevel: minLevel ?? this.minLevel,
      category: category ?? this.category,
      categoryLabel: categoryLabel ?? this.categoryLabel,
      isOfficial: isOfficial ?? this.isOfficial,
      activeUserCount: activeUserCount ?? this.activeUserCount,
      recentMessageCount: recentMessageCount ?? this.recentMessageCount,
      latestContent: latestContent ?? this.latestContent,
      canEnter: canEnter ?? this.canEnter,
      botEnabled: botEnabled ?? this.botEnabled,
      isJoined: isJoined ?? this.isJoined,
      members: members ?? this.members,
    );
  }
}

class ChatRoomMember {
  const ChatRoomMember({
    required this.id,
    required this.nickname,
    this.avatarUrl = '',
    this.avatarAsset = '',
    this.skinId = '',
    this.role = 'member',
    this.isAdmin = false,
    this.isBot = false,
    this.online = false,
    this.joinedAt = '',
    this.lastSeenAt = '',
  });

  final int id;
  final String nickname;
  final String avatarUrl;
  final String avatarAsset;
  final String skinId;
  final String role;
  final bool isAdmin;
  final bool isBot;
  final bool online;
  final String joinedAt;
  final String lastSeenAt;

  factory ChatRoomMember.fromJson(Map<String, dynamic> json) {
    return ChatRoomMember(
      id: _asInt(json['id']),
      nickname: _asString(json['nickname']),
      avatarUrl: _asString(json['avatarUrl']),
      avatarAsset: _asString(json['avatarAsset']),
      skinId: _asString(json['skinId']),
      role: _asString(json['role']).isEmpty
          ? 'member'
          : _asString(json['role']),
      isAdmin: _asBool(json['isAdmin']),
      isBot: _asBool(json['isBot']),
      online: _asBool(json['online']),
      joinedAt: _asString(json['joinedAt']),
      lastSeenAt: _asString(json['lastSeenAt']),
    );
  }
}

class ChatRoomCategory {
  const ChatRoomCategory({
    required this.key,
    required this.label,
    this.hot = false,
    this.rooms = const [],
  });

  final String key;
  final String label;
  final bool hot;
  final List<ChatRoomInfo> rooms;

  factory ChatRoomCategory.fromJson(Map<String, dynamic> json) {
    final key = _asString(json['key']);
    final rooms = json['rooms'] is List
        ? (json['rooms'] as List)
              .whereType<Map>()
              .map(
                (item) => ChatRoomInfo.fromJson(item.cast<String, dynamic>()),
              )
              .where((item) => item.roomId.isNotEmpty)
              .toList()
        : const <ChatRoomInfo>[];
    return ChatRoomCategory(
      key: key.isEmpty ? 'novel' : key,
      label: _asString(json['label']).isEmpty
          ? _chatCategoryLabel(key)
          : _asString(json['label']),
      hot: _asBool(json['hot']),
      rooms: rooms,
    );
  }

  ChatRoomCategory copyWith({bool? hot, List<ChatRoomInfo>? rooms}) {
    return ChatRoomCategory(
      key: key,
      label: label,
      hot: hot ?? this.hot,
      rooms: rooms ?? this.rooms,
    );
  }
}

class ChatRoomListPayload {
  const ChatRoomListPayload({
    this.items = const [],
    this.categories = const [],
    this.hotCategory = '',
  });

  final List<ChatRoomInfo> items;
  final List<ChatRoomCategory> categories;
  final String hotCategory;

  factory ChatRoomListPayload.fromJson(Map<String, dynamic> json) {
    final items = _chatRoomList(json['items']);
    final rawCategories = json['categories'];
    final parsedCategories = rawCategories is List
        ? rawCategories
              .whereType<Map>()
              .map(
                (item) =>
                    ChatRoomCategory.fromJson(item.cast<String, dynamic>()),
              )
              .toList()
        : const <ChatRoomCategory>[];
    final hotCategory = _asString(json['hotCategory']);
    final categories = _normalizeChatRoomCategories(
      parsedCategories,
      items,
      hotCategory,
    );
    final flatItems = items.isEmpty
        ? categories.expand((item) => item.rooms).toList()
        : items;
    return ChatRoomListPayload(
      items: flatItems,
      categories: categories,
      hotCategory: hotCategory,
    );
  }
}

class SystemNotificationItem {
  const SystemNotificationItem({
    required this.id,
    this.title = '',
    this.content = '',
    this.category = 'system',
    this.readAt = '',
    this.createdAt = '',
  });

  final int id;
  final String title;
  final String content;
  final String category;
  final String readAt;
  final String createdAt;

  factory SystemNotificationItem.fromJson(Map<String, dynamic> json) {
    return SystemNotificationItem(
      id: _asInt(json['id']),
      title: _asString(json['title']),
      content: _asString(json['content']),
      category: _asString(json['category']).isEmpty
          ? 'system'
          : _asString(json['category']),
      readAt: _asString(json['readAt']),
      createdAt: _asString(json['createdAt']),
    );
  }
}

class ChatBotDirectReply {
  const ChatBotDirectReply({this.reply = '', this.share = const {}});

  final String reply;
  final Map<String, dynamic> share;

  factory ChatBotDirectReply.fromJson(Map<String, dynamic> json) {
    return ChatBotDirectReply(
      reply: _asString(json['reply']),
      share: _mapOf(json['share']),
    );
  }
}

class ChatBotDirectMessage {
  const ChatBotDirectMessage({
    required this.id,
    required this.fromUser,
    this.content = '',
    this.share = const {},
    this.createdAt = '',
  });

  final int id;
  final bool fromUser;
  final String content;
  final Map<String, dynamic> share;
  final String createdAt;

  factory ChatBotDirectMessage.fromJson(Map<String, dynamic> json) {
    return ChatBotDirectMessage(
      id: _asInt(json['id']),
      fromUser: _asString(json['sender']) == 'user',
      content: _asString(json['content']),
      share: _mapOf(json['share']),
      createdAt: _asString(json['createdAt']),
    );
  }
}

class HorseRaceState {
  const HorseRaceState({
    this.roundId = 0,
    this.roundCode = '',
    this.phase = 'closed',
    this.isOpen = false,
    this.now = 0,
    this.phaseStartedAt = 0,
    this.phaseEndsAt = 0,
    this.openAt = 0,
    this.closeAt = 0,
    this.nextOpenAt = 0,
    this.lockAt = 0,
    this.raceAt = 0,
    this.settleAt = 0,
    this.nextRoundAt = 0,
    this.walletCoins = 0,
    this.minBet = 10,
    this.betLimitPerHorse = 1000,
    this.betLimitPerRound = 2000,
    this.betLimitPerDay = 20000,
    this.poolTotal = 0,
    this.myBetTotal = 0,
    this.myBetToday = 0,
    this.myDailyRemaining = 20000,
    this.myPotentialPayout = 0,
    this.participantCount = 0,
    this.oddsLocked = false,
    this.raceCommentary = '',
    this.winnerIndex = -1,
    this.myBets = const [],
    this.horses = const [],
    this.recentChats = const [],
    this.rules = const HorseRaceRules(),
    this.fairness = const HorseRaceFairness(),
    this.race = const HorseRaceMeet(),
    this.recentResults = const [],
    this.myStats = const HorseRaceStats(),
  });

  final int roundId;
  final String roundCode;
  final String phase;
  final bool isOpen;
  final int now;
  final int phaseStartedAt;
  final int phaseEndsAt;
  final int openAt;
  final int closeAt;
  final int nextOpenAt;
  final int lockAt;
  final int raceAt;
  final int settleAt;
  final int nextRoundAt;
  final int walletCoins;
  final int minBet;
  final int betLimitPerHorse;
  final int betLimitPerRound;
  final int betLimitPerDay;
  final int poolTotal;
  final int myBetTotal;
  final int myBetToday;
  final int myDailyRemaining;
  final int myPotentialPayout;
  final int participantCount;
  final bool oddsLocked;
  final String raceCommentary;
  final int winnerIndex;
  final List<HorseRaceBet> myBets;
  final List<HorseRaceHorse> horses;
  final List<HorseRaceChatMessage> recentChats;
  final HorseRaceRules rules;
  final HorseRaceFairness fairness;
  final HorseRaceMeet race;
  final List<HorseRaceResult> recentResults;
  final HorseRaceStats myStats;

  factory HorseRaceState.fromJson(Map<String, dynamic> json) {
    return HorseRaceState(
      roundId: _asInt(json['roundId']),
      roundCode: _asString(json['roundCode']),
      phase: _asString(json['phase']).isEmpty
          ? 'closed'
          : _asString(json['phase']),
      isOpen: _asBool(json['isOpen']),
      now: _asInt(json['now']),
      phaseStartedAt: _asInt(json['phaseStartedAt']),
      phaseEndsAt: _asInt(json['phaseEndsAt']),
      openAt: _asInt(json['openAt']),
      closeAt: _asInt(json['closeAt']),
      nextOpenAt: _asInt(json['nextOpenAt']),
      lockAt: _asInt(json['lockAt']),
      raceAt: _asInt(json['raceAt']),
      settleAt: _asInt(json['settleAt']),
      nextRoundAt: _asInt(json['nextRoundAt']),
      walletCoins: _asInt(json['walletCoins']),
      minBet: _asInt(json['minBet']) <= 0 ? 10 : _asInt(json['minBet']),
      betLimitPerHorse: _asInt(json['betLimitPerHorse']) <= 0
          ? 1000
          : _asInt(json['betLimitPerHorse']),
      betLimitPerRound: _asInt(json['betLimitPerRound']) <= 0
          ? 2000
          : _asInt(json['betLimitPerRound']),
      betLimitPerDay: _asInt(json['betLimitPerDay']) <= 0
          ? 20000
          : _asInt(json['betLimitPerDay']),
      poolTotal: _asInt(json['poolTotal']),
      myBetTotal: _asInt(json['myBetTotal']),
      myBetToday: _asInt(json['myBetToday']),
      myDailyRemaining: _asInt(json['myDailyRemaining']),
      myPotentialPayout: _asInt(json['myPotentialPayout']),
      participantCount: _asInt(json['participantCount']),
      oddsLocked: _asBool(json['oddsLocked']),
      raceCommentary: _asString(json['raceCommentary']),
      winnerIndex: _asInt(json['winnerIndex']),
      myBets: _horseRaceBetList(json['myBets']),
      horses: _horseRaceHorseList(json['horses']),
      recentChats: _horseRaceChatList(json['recentChats']),
      rules: json['rules'] is Map
          ? HorseRaceRules.fromJson(
              (json['rules'] as Map).cast<String, dynamic>(),
            )
          : const HorseRaceRules(),
      fairness: json['fairness'] is Map
          ? HorseRaceFairness.fromJson(
              (json['fairness'] as Map).cast<String, dynamic>(),
            )
          : const HorseRaceFairness(),
      race: json['race'] is Map
          ? HorseRaceMeet.fromJson(
              (json['race'] as Map).cast<String, dynamic>(),
            )
          : const HorseRaceMeet(),
      recentResults: _horseRaceResultList(json['recentResults']),
      myStats: json['myStats'] is Map
          ? HorseRaceStats.fromJson(
              (json['myStats'] as Map).cast<String, dynamic>(),
            )
          : const HorseRaceStats(),
    );
  }

  int myBetOn(int horseIndex) {
    for (final bet in myBets) {
      if (bet.horseIndex == horseIndex) return bet.amount;
    }
    return 0;
  }

  HorseRaceBet? betOn(int horseIndex) {
    for (final bet in myBets) {
      if (bet.horseIndex == horseIndex) return bet;
    }
    return null;
  }
}

class HorseRaceHorse {
  const HorseRaceHorse({
    required this.index,
    this.name = '',
    this.color = '#60A5FA',
    this.winRate = 0,
    this.odds = 1,
    this.totalBet = 0,
    this.progress = 0,
    this.formRating = 0,
    this.recentForm = '',
    this.style = '',
    this.specialty = '',
    this.popularityRank = 0,
    this.popularityShare = 0,
    this.oddsTrend = 'steady',
    this.returnPer100 = 0,
    this.finishPosition = 0,
  });

  final int index;
  final String name;
  final String color;
  final double winRate;
  final double odds;
  final int totalBet;
  final double progress;
  final int formRating;
  final String recentForm;
  final String style;
  final String specialty;
  final int popularityRank;
  final double popularityShare;
  final String oddsTrend;
  final int returnPer100;
  final int finishPosition;

  factory HorseRaceHorse.fromJson(Map<String, dynamic> json) {
    return HorseRaceHorse(
      index: _asInt(json['index']),
      name: _asString(json['name']),
      color: _asString(json['color']).isEmpty
          ? '#60A5FA'
          : _asString(json['color']),
      winRate: _asDouble(json['winRate']),
      odds: _asDouble(json['odds']),
      totalBet: _asInt(json['totalBet']),
      progress: _asDouble(json['progress']).clamp(0, 1).toDouble(),
      formRating: _asInt(json['formRating']),
      recentForm: _asString(json['recentForm']),
      style: _asString(json['style']),
      specialty: _asString(json['specialty']),
      popularityRank: _asInt(json['popularityRank']),
      popularityShare: _asDouble(json['popularityShare']),
      oddsTrend: _asString(json['oddsTrend']).isEmpty
          ? 'steady'
          : _asString(json['oddsTrend']),
      returnPer100: _asInt(json['returnPer100']),
      finishPosition: _asInt(json['finishPosition']),
    );
  }
}

class HorseRaceBet {
  const HorseRaceBet({
    required this.horseIndex,
    this.amount = 0,
    this.payout = 0,
    this.status = 'pending',
    this.odds = 1,
    this.estimatedPayout = 0,
  });

  final int horseIndex;
  final int amount;
  final int payout;
  final String status;
  final double odds;
  final int estimatedPayout;

  factory HorseRaceBet.fromJson(Map<String, dynamic> json) {
    return HorseRaceBet(
      horseIndex: _asInt(json['horseIndex']),
      amount: _asInt(json['amount']),
      payout: _asInt(json['payout']),
      status: _asString(json['status']).isEmpty
          ? 'pending'
          : _asString(json['status']),
      odds: _asDouble(json['odds']),
      estimatedPayout: _asInt(json['estimatedPayout']),
    );
  }
}

class HorseRaceRules {
  const HorseRaceRules({
    this.version = 1,
    this.bettingSeconds = 240,
    this.lockedSeconds = 20,
    this.racingSeconds = 60,
    this.resultSeconds = 40,
    this.payoutRate = 0.82,
    this.oddsMode = 'dynamic_locked',
  });

  final int version;
  final int bettingSeconds;
  final int lockedSeconds;
  final int racingSeconds;
  final int resultSeconds;
  final double payoutRate;
  final String oddsMode;

  factory HorseRaceRules.fromJson(Map<String, dynamic> json) => HorseRaceRules(
    version: _asInt(json['version']),
    bettingSeconds: _asInt(json['bettingSeconds']),
    lockedSeconds: _asInt(json['lockedSeconds']),
    racingSeconds: _asInt(json['racingSeconds']),
    resultSeconds: _asInt(json['resultSeconds']),
    payoutRate: _asDouble(json['payoutRate']),
    oddsMode: _asString(json['oddsMode']),
  );
}

class HorseRaceMeet {
  const HorseRaceMeet({
    this.name = '樱花杯',
    this.venue = '月见赛场',
    this.distanceMeters = 1200,
    this.trackCondition = '良',
    this.weather = '晴',
    this.description = '',
  });

  final String name;
  final String venue;
  final int distanceMeters;
  final String trackCondition;
  final String weather;
  final String description;

  factory HorseRaceMeet.fromJson(Map<String, dynamic> json) => HorseRaceMeet(
    name: _asString(json['name']).isEmpty ? '樱花杯' : _asString(json['name']),
    venue: _asString(json['venue']).isEmpty ? '月见赛场' : _asString(json['venue']),
    distanceMeters: _asInt(json['distanceMeters']),
    trackCondition: _asString(json['trackCondition']),
    weather: _asString(json['weather']),
    description: _asString(json['description']),
  );
}

class HorseRaceFairness {
  const HorseRaceFairness({
    this.algorithm = 'seed-commit-v1',
    this.seedCommit = '',
    this.seedReveal = '',
  });

  final String algorithm;
  final String seedCommit;
  final String seedReveal;

  bool get revealed => seedReveal.isNotEmpty;

  factory HorseRaceFairness.fromJson(Map<String, dynamic> json) =>
      HorseRaceFairness(
        algorithm: _asString(json['algorithm']),
        seedCommit: _asString(json['seedCommit']),
        seedReveal: _asString(json['seedReveal']),
      );
}

class HorseRaceResult {
  const HorseRaceResult({
    this.roundId = 0,
    this.roundCode = '',
    this.winnerIndex = -1,
    this.winnerName = '',
    this.winnerColor = '#60A5FA',
    this.odds = 1,
    this.poolTotal = 0,
    this.participantCount = 0,
    this.settledAt = '',
  });

  final int roundId;
  final String roundCode;
  final int winnerIndex;
  final String winnerName;
  final String winnerColor;
  final double odds;
  final int poolTotal;
  final int participantCount;
  final String settledAt;

  factory HorseRaceResult.fromJson(Map<String, dynamic> json) =>
      HorseRaceResult(
        roundId: _asInt(json['roundId']),
        roundCode: _asString(json['roundCode']),
        winnerIndex: _asInt(json['winnerIndex']),
        winnerName: _asString(json['winnerName']),
        winnerColor: _asString(json['winnerColor']),
        odds: _asDouble(json['odds']),
        poolTotal: _asInt(json['poolTotal']),
        participantCount: _asInt(json['participantCount']),
        settledAt: _asString(json['settledAt']),
      );
}

class HorseRaceStats {
  const HorseRaceStats({
    this.roundsPlayed = 0,
    this.totalStaked = 0,
    this.totalPayout = 0,
    this.netProfit = 0,
    this.winningBets = 0,
    this.totalBets = 0,
    this.winRate = 0,
  });

  final int roundsPlayed;
  final int totalStaked;
  final int totalPayout;
  final int netProfit;
  final int winningBets;
  final int totalBets;
  final double winRate;

  factory HorseRaceStats.fromJson(Map<String, dynamic> json) => HorseRaceStats(
    roundsPlayed: _asInt(json['roundsPlayed']),
    totalStaked: _asInt(json['totalStaked']),
    totalPayout: _asInt(json['totalPayout']),
    netProfit: _asInt(json['netProfit']),
    winningBets: _asInt(json['winningBets']),
    totalBets: _asInt(json['totalBets']),
    winRate: _asDouble(json['winRate']),
  );
}

class HorseRaceChatMessage {
  const HorseRaceChatMessage({
    required this.id,
    this.content = '',
    this.createdAt = '',
    this.isSystem = false,
    required this.user,
  });

  final int id;
  final String content;
  final String createdAt;
  final bool isSystem;
  final InteractionUserBrief user;

  factory HorseRaceChatMessage.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return HorseRaceChatMessage(
      id: _asInt(json['id']),
      content: _asString(json['content']),
      createdAt: _asString(json['createdAt']),
      isSystem: _asBool(json['isSystem']),
      user: userJson is Map
          ? InteractionUserBrief.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '系统通知'),
    );
  }
}

class PrivateConversation {
  const PrivateConversation({
    required this.peer,
    this.latestContent = '',
    this.latestAt = '',
    this.unreadCount = 0,
    this.fromMe = false,
  });

  final InteractionUserBrief peer;
  final String latestContent;
  final String latestAt;
  final int unreadCount;
  final bool fromMe;

  factory PrivateConversation.fromJson(Map<String, dynamic> json) {
    final peerJson = json['peer'];
    return PrivateConversation(
      peer: peerJson is Map
          ? InteractionUserBrief.fromJson(peerJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
      latestContent: _asString(json['latestContent']),
      latestAt: _asString(json['latestAt']),
      unreadCount: _asInt(json['unreadCount']),
      fromMe: _asBool(json['fromMe']),
    );
  }
}

class PrivateMessage {
  const PrivateMessage({
    required this.id,
    required this.content,
    this.createdAt = '',
    this.readAt = '',
    this.fromMe = false,
    required this.sender,
    required this.receiver,
  });

  final int id;
  final String content;
  final String createdAt;
  final String readAt;
  final bool fromMe;
  final InteractionUserBrief sender;
  final InteractionUserBrief receiver;

  factory PrivateMessage.fromJson(Map<String, dynamic> json) {
    final senderJson = json['sender'];
    final receiverJson = json['receiver'];
    return PrivateMessage(
      id: _asInt(json['id']),
      content: _asString(json['content']),
      createdAt: _asString(json['createdAt']),
      readAt: _asString(json['readAt']),
      fromMe: _asBool(json['fromMe']),
      sender: senderJson is Map
          ? InteractionUserBrief.fromJson(senderJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
      receiver: receiverJson is Map
          ? InteractionUserBrief.fromJson(receiverJson.cast<String, dynamic>())
          : const InteractionUserBrief(id: 0, nickname: '用户'),
    );
  }
}

String _asString(dynamic value) => value?.toString().trim() ?? '';

Map<String, dynamic> _mapOf(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

List<InteractionUserBadge> _badgeList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map(
        (item) => InteractionUserBadge.fromJson(item.cast<String, dynamic>()),
      )
      .where((item) => item.key.isNotEmpty)
      .toList();
}

List<ChatRoomMember> _chatRoomMemberList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => ChatRoomMember.fromJson(item.cast<String, dynamic>()))
      .where((item) => item.id > 0)
      .toList();
}

List<HorseRaceBet> _horseRaceBetList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => HorseRaceBet.fromJson(item.cast<String, dynamic>()))
      .toList();
}

List<HorseRaceHorse> _horseRaceHorseList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => HorseRaceHorse.fromJson(item.cast<String, dynamic>()))
      .toList();
}

List<HorseRaceChatMessage> _horseRaceChatList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map(
        (item) => HorseRaceChatMessage.fromJson(item.cast<String, dynamic>()),
      )
      .toList();
}

List<HorseRaceResult> _horseRaceResultList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => HorseRaceResult.fromJson(item.cast<String, dynamic>()))
      .toList();
}

String _normalizeDanmakuColor(String value) {
  final raw = value.trim();
  final match = RegExp(r'^#?[0-9a-fA-F]{6}$').firstMatch(raw);
  if (match == null) return '#FFFFFF';
  final hex = raw.replaceFirst('#', '').toUpperCase();
  return '#$hex';
}

String _normalizeDanmakuMode(String value) {
  final mode = value.trim().toLowerCase();
  return switch (mode) {
    'top' || 'bottom' || 'special' => mode,
    _ => 'scroll',
  };
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool _asBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes';
}

double? _asNullableDouble(dynamic value) {
  if (value == null || value == '') return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

List<ChatRoomInfo> _chatRoomList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => ChatRoomInfo.fromJson(item.cast<String, dynamic>()))
      .where((item) => item.roomId.isNotEmpty)
      .toList();
}

List<ChatRoomCategory> _normalizeChatRoomCategories(
  List<ChatRoomCategory> categories,
  List<ChatRoomInfo> items,
  String hotCategory,
) {
  const defaultKeys = ['novel', 'anime', 'manga'];
  final grouped = <String, List<ChatRoomInfo>>{};
  for (final room in items) {
    grouped.putIfAbsent(room.category, () => []).add(room);
  }

  final byKey = <String, ChatRoomCategory>{};
  for (final category in categories) {
    final rooms = category.rooms.isEmpty
        ? grouped[category.key] ?? const <ChatRoomInfo>[]
        : category.rooms;
    byKey[category.key] = category.copyWith(
      hot: category.hot || category.key == hotCategory,
      rooms: rooms,
    );
  }

  for (final key in defaultKeys) {
    byKey.putIfAbsent(
      key,
      () => ChatRoomCategory(
        key: key,
        label: _chatCategoryLabel(key),
        hot: key == hotCategory,
        rooms: grouped[key] ?? const <ChatRoomInfo>[],
      ),
    );
  }

  return [
    for (final key in defaultKeys) byKey[key]!,
    for (final entry in byKey.entries)
      if (!defaultKeys.contains(entry.key)) entry.value,
  ];
}

String _chatCategoryLabel(String key) {
  return switch (key) {
    'novel' => '小说',
    'anime' => '动漫',
    'manga' => '漫画',
    _ => key.isEmpty ? '其他' : key,
  };
}
