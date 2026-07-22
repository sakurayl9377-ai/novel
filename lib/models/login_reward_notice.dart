class LoginRewardNotice {
  const LoginRewardNotice({
    required this.id,
    required this.campaignId,
    required this.title,
    required this.content,
    required this.coinsAwarded,
    required this.createdAt,
  });

  final int id;
  final int campaignId;
  final String title;
  final String content;
  final int coinsAwarded;
  final String createdAt;

  factory LoginRewardNotice.fromJson(Map<String, dynamic> json) {
    return LoginRewardNotice(
      id: _asInt(json['id']),
      campaignId: _asInt(json['campaignId']),
      title: _asString(json['title']),
      content: _asString(json['content']),
      coinsAwarded: _asInt(json['coinsAwarded']),
      createdAt: _asString(json['createdAt']),
    );
  }
}

class LoginRewardSyncResult {
  const LoginRewardSyncResult({required this.balance, this.items = const []});

  final int balance;
  final List<LoginRewardNotice> items;

  factory LoginRewardSyncResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return LoginRewardSyncResult(
      balance: _asInt(json['balance']),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) =>
                      LoginRewardNotice.fromJson(item.cast<String, dynamic>()),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _asString(Object? value) => value?.toString().trim() ?? '';
