const String defaultInteractionAvatarAsset =
    'assets/images/profile/default_anime_avatar.png';

class InteractionUser {
  const InteractionUser({
    required this.id,
    required this.email,
    required this.nickname,
    this.avatarUrl = '',
    this.gender = 'private',
    this.bio = '',
    this.signature = '',
    this.spaceTitle = '',
    this.profileBannerUrl = '',
    this.dynamicAvatarUrl = '',
    this.profileTheme = 'sakura',
    this.privacyMode = false,
    this.role = 'user',
    this.status = 'active',
    this.growth = const UserGrowth(),
  });

  final int id;
  final String email;
  final String nickname;
  final String avatarUrl;
  final String gender;
  final String bio;
  final String signature;
  final String spaceTitle;
  final String profileBannerUrl;
  final String dynamicAvatarUrl;
  final String profileTheme;
  final bool privacyMode;
  final String role;
  final String status;
  final UserGrowth growth;

  factory InteractionUser.fromJson(Map<String, dynamic> json) {
    final growthJson = json['growth'];
    return InteractionUser(
      id: _asInt(json['id']),
      email: _asString(json['email']),
      nickname: _asString(json['nickname']),
      avatarUrl: _normalizeLocalInteractionUrl(_asString(json['avatarUrl'])),
      gender: _normalizeGender(_asString(json['gender'])),
      bio: _asString(json['bio']),
      signature: _asString(json['signature']),
      spaceTitle: _asString(json['spaceTitle']),
      profileBannerUrl: _normalizeLocalInteractionUrl(
        _asString(json['profileBannerUrl']),
      ),
      dynamicAvatarUrl: _normalizeLocalInteractionUrl(
        _asString(json['dynamicAvatarUrl']),
      ),
      profileTheme: _asString(json['profileTheme']).isEmpty
          ? 'sakura'
          : _asString(json['profileTheme']),
      privacyMode: json['privacyMode'] == true,
      role: _asString(json['role']).isEmpty ? 'user' : _asString(json['role']),
      status: _asString(json['status']).isEmpty
          ? 'active'
          : _asString(json['status']),
      growth: growthJson is Map
          ? UserGrowth.fromJson(growthJson.cast<String, dynamic>())
          : const UserGrowth(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'nickname': nickname,
      'avatarUrl': avatarUrl,
      'gender': gender,
      'bio': bio,
      'signature': signature,
      'spaceTitle': spaceTitle,
      'profileBannerUrl': profileBannerUrl,
      'dynamicAvatarUrl': dynamicAvatarUrl,
      'profileTheme': profileTheme,
      'privacyMode': privacyMode,
      'role': role,
      'status': status,
      'growth': growth.toJson(),
    };
  }

  InteractionUser copyWith({
    String? nickname,
    String? avatarUrl,
    String? gender,
    String? bio,
    String? signature,
    String? spaceTitle,
    String? profileBannerUrl,
    String? dynamicAvatarUrl,
    String? profileTheme,
    bool? privacyMode,
    UserGrowth? growth,
  }) {
    return InteractionUser(
      id: id,
      email: email,
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      gender: gender ?? this.gender,
      bio: bio ?? this.bio,
      signature: signature ?? this.signature,
      spaceTitle: spaceTitle ?? this.spaceTitle,
      profileBannerUrl: profileBannerUrl ?? this.profileBannerUrl,
      dynamicAvatarUrl: dynamicAvatarUrl ?? this.dynamicAvatarUrl,
      profileTheme: profileTheme ?? this.profileTheme,
      privacyMode: privacyMode ?? this.privacyMode,
      role: role,
      status: status,
      growth: growth ?? this.growth,
    );
  }
}

class UserGrowth {
  const UserGrowth({
    this.level = 1,
    this.maxLevel = 7,
    this.levelName = '初樱',
    this.levelEffect = '基础头像框',
    this.dailyPointCap = 60,
    this.dailyPointsEarned = 0,
    this.dailyPointsRemaining = 60,
    this.dailyCoinsEarned = 0,
    this.signInStreakDays = 0,
    this.targetDays = 0,
    this.points = 0,
    this.sakuraCoins = 0,
    this.currentLevelPoints = 0,
    this.nextLevelPoints = 420,
    this.progress = 0,
    this.effects = const [],
    this.privileges = const UserPrivileges(),
  });

  final int level;
  final int maxLevel;
  final String levelName;
  final String levelEffect;
  final int dailyPointCap;
  final int dailyPointsEarned;
  final int dailyPointsRemaining;
  final int dailyCoinsEarned;
  final int signInStreakDays;
  final int targetDays;
  final int points;
  final int sakuraCoins;
  final int currentLevelPoints;
  final int nextLevelPoints;
  final double progress;
  final List<UserLevelEffect> effects;
  final UserPrivileges privileges;

  UserGrowth copyWith({int? sakuraCoins}) {
    return UserGrowth(
      level: level,
      maxLevel: maxLevel,
      levelName: levelName,
      levelEffect: levelEffect,
      dailyPointCap: dailyPointCap,
      dailyPointsEarned: dailyPointsEarned,
      dailyPointsRemaining: dailyPointsRemaining,
      dailyCoinsEarned: dailyCoinsEarned,
      signInStreakDays: signInStreakDays,
      targetDays: targetDays,
      points: points,
      sakuraCoins: sakuraCoins ?? this.sakuraCoins,
      currentLevelPoints: currentLevelPoints,
      nextLevelPoints: nextLevelPoints,
      progress: progress,
      effects: effects,
      privileges: privileges,
    );
  }

  factory UserGrowth.fromJson(Map<String, dynamic> json) {
    final privilegesJson = json['privileges'];
    return UserGrowth(
      level: _asInt(json['level']) <= 0 ? 1 : _asInt(json['level']),
      maxLevel: _asInt(json['maxLevel']) <= 0 ? 7 : _asInt(json['maxLevel']),
      levelName: _asString(json['levelName']).isEmpty
          ? '初樱'
          : _asString(json['levelName']),
      levelEffect: _asString(json['levelEffect']).isEmpty
          ? '基础头像框'
          : _asString(json['levelEffect']),
      dailyPointCap: _asInt(json['dailyPointCap']) <= 0
          ? 60
          : _asInt(json['dailyPointCap']),
      dailyPointsEarned: _asInt(json['dailyPointsEarned']),
      dailyPointsRemaining: _asInt(json['dailyPointsRemaining']),
      dailyCoinsEarned: _asInt(json['dailyCoinsEarned']),
      signInStreakDays: _asInt(json['signInStreakDays']),
      targetDays: _asInt(json['targetDays']),
      points: _asInt(json['points']),
      sakuraCoins: _asInt(json['sakuraCoins']),
      currentLevelPoints: _asInt(json['currentLevelPoints']),
      nextLevelPoints: _asInt(json['nextLevelPoints']),
      progress: _asDouble(json['progress']).clamp(0, 1).toDouble(),
      effects: _listOf(json['effects'], UserLevelEffect.fromJson),
      privileges: privilegesJson is Map
          ? UserPrivileges.fromJson(privilegesJson.cast<String, dynamic>())
          : const UserPrivileges(),
    );
  }

  Map<String, dynamic> toJson() => {
    'level': level,
    'maxLevel': maxLevel,
    'levelName': levelName,
    'levelEffect': levelEffect,
    'dailyPointCap': dailyPointCap,
    'dailyPointsEarned': dailyPointsEarned,
    'dailyPointsRemaining': dailyPointsRemaining,
    'dailyCoinsEarned': dailyCoinsEarned,
    'signInStreakDays': signInStreakDays,
    'targetDays': targetDays,
    'points': points,
    'sakuraCoins': sakuraCoins,
    'currentLevelPoints': currentLevelPoints,
    'nextLevelPoints': nextLevelPoints,
    'progress': progress,
    'effects': effects.map((item) => item.toJson()).toList(),
    'privileges': privileges.toJson(),
  };
}

class UserLevelEffect {
  const UserLevelEffect({
    required this.level,
    required this.name,
    required this.effect,
    this.permissions = const [],
    this.dailyPointCap = 60,
    this.targetDays = 0,
    this.points = 0,
    this.unlocked = false,
  });

  final int level;
  final String name;
  final String effect;
  final List<String> permissions;
  final int dailyPointCap;
  final int targetDays;
  final int points;
  final bool unlocked;

  factory UserLevelEffect.fromJson(Map<String, dynamic> json) {
    return UserLevelEffect(
      level: _asInt(json['level']),
      name: _asString(json['name']),
      effect: _asString(json['effect']),
      permissions: _stringList(json['permissions']),
      dailyPointCap: _asInt(json['dailyPointCap']) <= 0
          ? 60
          : _asInt(json['dailyPointCap']),
      targetDays: _asInt(json['targetDays']),
      points: _asInt(json['points']),
      unlocked: json['unlocked'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'level': level,
    'name': name,
    'effect': effect,
    'permissions': permissions,
    'dailyPointCap': dailyPointCap,
    'targetDays': targetDays,
    'points': points,
    'unlocked': unlocked,
  };
}

class UserPrivileges {
  const UserPrivileges({
    this.basicComments = false,
    this.basicDanmaku = false,
    this.chatText = false,
    this.dynamicAvatar = false,
    this.advancedDanmaku = false,
    this.profileSkins = false,
    this.profileEffects = false,
    this.photoWall = false,
    this.chatImages = false,
    this.chatStickers = false,
    this.chatEntranceEffect = false,
    this.exclusiveChatBubble = false,
    this.coinShop = false,
    this.rareShopItems = false,
  });

  final bool basicComments;
  final bool basicDanmaku;
  final bool chatText;
  final bool dynamicAvatar;
  final bool advancedDanmaku;
  final bool profileSkins;
  final bool profileEffects;
  final bool photoWall;
  final bool chatImages;
  final bool chatStickers;
  final bool chatEntranceEffect;
  final bool exclusiveChatBubble;
  final bool coinShop;
  final bool rareShopItems;

  factory UserPrivileges.fromJson(Map<String, dynamic> json) {
    return UserPrivileges(
      basicComments: json['basicComments'] == true,
      basicDanmaku: json['basicDanmaku'] == true,
      chatText: json['chatText'] == true,
      dynamicAvatar: json['dynamicAvatar'] == true,
      advancedDanmaku: json['advancedDanmaku'] == true,
      profileSkins: json['profileSkins'] == true,
      profileEffects: json['profileEffects'] == true,
      photoWall: json['photoWall'] == true,
      chatImages: json['chatImages'] == true,
      chatStickers: json['chatStickers'] == true,
      chatEntranceEffect: json['chatEntranceEffect'] == true,
      exclusiveChatBubble: json['exclusiveChatBubble'] == true,
      coinShop: json['coinShop'] == true,
      rareShopItems: json['rareShopItems'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'basicComments': basicComments,
    'basicDanmaku': basicDanmaku,
    'chatText': chatText,
    'dynamicAvatar': dynamicAvatar,
    'advancedDanmaku': advancedDanmaku,
    'profileSkins': profileSkins,
    'profileEffects': profileEffects,
    'photoWall': photoWall,
    'chatImages': chatImages,
    'chatStickers': chatStickers,
    'chatEntranceEffect': chatEntranceEffect,
    'exclusiveChatBubble': exclusiveChatBubble,
    'coinShop': coinShop,
    'rareShopItems': rareShopItems,
  };
}

class UserProfile {
  const UserProfile({
    required this.user,
    this.stats = const UserProfileStats(),
    this.photos = const [],
    this.inventory = const [],
    this.equipment = const [],
    this.recentRewards = const [],
    this.dailyRewards = const [],
    this.dailyCaps = const UserDailyCaps(),
    this.followedByMe = false,
  });

  final InteractionUser user;
  final UserProfileStats stats;
  final List<ProfilePhoto> photos;
  final List<ShopItem> inventory;
  final List<EquippedShopItem> equipment;
  final List<RewardEvent> recentRewards;
  final List<DailyRewardProgress> dailyRewards;
  final UserDailyCaps dailyCaps;
  final bool followedByMe;

  UserProfile copyWith({InteractionUser? user}) {
    return UserProfile(
      user: user ?? this.user,
      stats: stats,
      photos: photos,
      inventory: inventory,
      equipment: equipment,
      recentRewards: recentRewards,
      dailyRewards: dailyRewards,
      dailyCaps: dailyCaps,
      followedByMe: followedByMe,
    );
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    final statsJson = json['stats'];
    return UserProfile(
      user: userJson is Map
          ? InteractionUser.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUser(id: 0, email: '', nickname: '用户'),
      stats: statsJson is Map
          ? UserProfileStats.fromJson(statsJson.cast<String, dynamic>())
          : const UserProfileStats(),
      photos: _listOf(json['photos'], ProfilePhoto.fromJson),
      inventory: _listOf(json['inventory'], ShopItem.fromJson),
      equipment: _listOf(json['equipment'], EquippedShopItem.fromJson),
      recentRewards: _listOf(json['recentRewards'], RewardEvent.fromJson),
      dailyRewards: _listOf(json['dailyRewards'], DailyRewardProgress.fromJson),
      dailyCaps: json['dailyCaps'] is Map
          ? UserDailyCaps.fromJson(
              (json['dailyCaps'] as Map).cast<String, dynamic>(),
            )
          : const UserDailyCaps(),
      followedByMe: json['followedByMe'] == true,
    );
  }

  ShopItem? equippedItem(String slot) {
    for (final entry in equipment) {
      if (entry.slot == slot) return entry.item;
    }
    return null;
  }
}

class DailySignInResult {
  const DailySignInResult({
    required this.profile,
    required this.alreadySigned,
    this.reward,
  });

  final UserProfile profile;
  final bool alreadySigned;
  final RewardEvent? reward;

  factory DailySignInResult.fromJson(Map<String, dynamic> json) {
    final rewardJson = json['reward'];
    return DailySignInResult(
      profile: UserProfile.fromJson(json),
      alreadySigned: json['alreadySigned'] == true,
      reward: rewardJson is Map
          ? RewardEvent.fromJson(rewardJson.cast<String, dynamic>())
          : null,
    );
  }
}

class EquippedShopItem {
  const EquippedShopItem({
    required this.slot,
    required this.item,
    this.updatedAt = '',
  });

  final String slot;
  final ShopItem item;
  final String updatedAt;

  factory EquippedShopItem.fromJson(Map<String, dynamic> json) {
    final itemJson = json['item'];
    return EquippedShopItem(
      slot: _asString(json['slot']),
      updatedAt: _asString(json['updatedAt']),
      item: itemJson is Map
          ? ShopItem.fromJson(itemJson.cast<String, dynamic>())
          : const ShopItem(id: '', name: ''),
    );
  }
}

class UserDailyCaps {
  const UserDailyCaps({
    this.coins = 12,
    this.coinsEarned = 0,
    this.coinsRemaining = 12,
  });

  final int coins;
  final int coinsEarned;
  final int coinsRemaining;

  factory UserDailyCaps.fromJson(Map<String, dynamic> json) {
    return UserDailyCaps(
      coins: _asInt(json['coins']) <= 0 ? 12 : _asInt(json['coins']),
      coinsEarned: _asInt(json['coinsEarned']),
      coinsRemaining: _asInt(json['coinsRemaining']),
    );
  }
}

class DailyRewardProgress {
  const DailyRewardProgress({
    required this.action,
    this.description = '',
    this.points = 0,
    this.coins = 0,
    this.dailyLimit,
    this.once = false,
    this.count = 0,
    this.pointsEarned = 0,
    this.coinsEarned = 0,
    this.completed = false,
  });

  final String action;
  final String description;
  final int points;
  final int coins;
  final int? dailyLimit;
  final bool once;
  final int count;
  final int pointsEarned;
  final int coinsEarned;
  final bool completed;

  factory DailyRewardProgress.fromJson(Map<String, dynamic> json) {
    final rawLimit = json['dailyLimit'];
    return DailyRewardProgress(
      action: _asString(json['action']),
      description: _asString(json['description']),
      points: _asInt(json['points']),
      coins: _asInt(json['coins']),
      dailyLimit: rawLimit == null ? null : _asInt(rawLimit),
      once: json['once'] == true,
      count: _asInt(json['count']),
      pointsEarned: _asInt(json['pointsEarned']),
      coinsEarned: _asInt(json['coinsEarned']),
      completed: json['completed'] == true,
    );
  }
}

class UserProfileStats {
  const UserProfileStats({
    this.following = 0,
    this.followers = 0,
    this.comments = 0,
    this.danmaku = 0,
    this.chat = 0,
  });

  final int following;
  final int followers;
  final int comments;
  final int danmaku;
  final int chat;

  factory UserProfileStats.fromJson(Map<String, dynamic> json) {
    return UserProfileStats(
      following: _asInt(json['following']),
      followers: _asInt(json['followers']),
      comments: _asInt(json['comments']),
      danmaku: _asInt(json['danmaku']),
      chat: _asInt(json['chat']),
    );
  }
}

class ProfilePhoto {
  const ProfilePhoto({
    required this.id,
    required this.imageUrl,
    this.caption = '',
  });

  final int id;
  final String imageUrl;
  final String caption;

  factory ProfilePhoto.fromJson(Map<String, dynamic> json) {
    return ProfilePhoto(
      id: _asInt(json['id']),
      imageUrl: _asString(json['imageUrl']),
      caption: _asString(json['caption']),
    );
  }
}

class ShopItem {
  const ShopItem({
    required this.id,
    required this.name,
    this.description = '',
    this.priceCoins = 0,
    this.itemType = 'cosmetic',
    this.minLevel = 0,
    this.assetValue = '',
    this.previewUrl = '',
    this.acquiredAt = '',
  });

  final String id;
  final String name;
  final String description;
  final int priceCoins;
  final String itemType;
  final int minLevel;
  final String assetValue;
  final String previewUrl;
  final String acquiredAt;

  factory ShopItem.fromJson(Map<String, dynamic> json) {
    return ShopItem(
      id: _asString(json['id']),
      name: _asString(json['name']),
      description: _asString(json['description']),
      priceCoins: _asInt(json['priceCoins']),
      itemType: _asString(json['itemType']).isEmpty
          ? 'cosmetic'
          : _asString(json['itemType']),
      minLevel: _asInt(json['minLevel']),
      assetValue: _asString(json['assetValue']),
      previewUrl: _asString(json['previewUrl']),
      acquiredAt: _asString(json['acquiredAt']),
    );
  }
}

class RewardEvent {
  const RewardEvent({
    required this.action,
    this.points = 0,
    this.coins = 0,
    this.description = '',
    this.createdAt = '',
  });

  final String action;
  final int points;
  final int coins;
  final String description;
  final String createdAt;

  factory RewardEvent.fromJson(Map<String, dynamic> json) {
    return RewardEvent(
      action: _asString(json['action']),
      points: _asInt(json['points']),
      coins: _asInt(json['coins']),
      description: _asString(json['description']),
      createdAt: _asString(json['createdAt']),
    );
  }
}

class InteractionAccountSession {
  const InteractionAccountSession({required this.token, required this.user});

  final String token;
  final InteractionUser user;

  factory InteractionAccountSession.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    return InteractionAccountSession(
      token: _asString(json['token']),
      user: userJson is Map
          ? InteractionUser.fromJson(userJson.cast<String, dynamic>())
          : const InteractionUser(id: 0, email: '', nickname: '用户'),
    );
  }

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson()};
}

String _asString(dynamic value) => value?.toString().trim() ?? '';

String _normalizeGender(String value) {
  final gender = value.trim().toLowerCase();
  return switch (gender) {
    'male' || 'female' => gender,
    _ => 'private',
  };
}

String _normalizeLocalInteractionUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;

  final host = uri.host.toLowerCase();
  final isLocalHost =
      host == '10.0.2.2' || host == '127.0.0.1' || host == 'localhost';
  if (!isLocalHost || !uri.path.startsWith('/novel-api/')) return trimmed;

  final hasExplicitPort = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^@/?#]+@)?[^:/?#]+:\d+',
  ).hasMatch(trimmed);
  final port = hasExplicitPort ? uri.port : 3010;
  return uri.replace(host: '10.0.2.2', port: port).toString();
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

List<T> _listOf<T>(dynamic raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => parse(item.cast<String, dynamic>()))
      .toList();
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList();
}
