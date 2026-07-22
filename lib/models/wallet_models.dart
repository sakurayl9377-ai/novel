class SakuraWalletSnapshot {
  const SakuraWalletSnapshot({
    this.balance = 0,
    this.snapshotMaxId = 0,
    this.ledger = const SakuraWalletLedgerPage(),
  });

  final int balance;
  final int snapshotMaxId;
  final SakuraWalletLedgerPage ledger;

  factory SakuraWalletSnapshot.fromJson(Map<String, dynamic> json) {
    final rawBalance = json['balance'];
    final ledgerJson = _walletMap(json['ledger']);
    final balance = rawBalance is Map
        ? _walletInt(
            rawBalance['sakuraCoins'] ??
                rawBalance['coins'] ??
                rawBalance['balance'],
          )
        : _walletInt(json['sakuraCoins'] ?? rawBalance);
    return SakuraWalletSnapshot(
      balance: balance,
      snapshotMaxId: _walletInt(
        json['snapshotMaxId'] ?? json['maxId'] ?? ledgerJson['snapshotMaxId'],
      ),
      ledger: SakuraWalletLedgerPage.fromJson(ledgerJson),
    );
  }
}

class SakuraWalletLedgerPage {
  const SakuraWalletLedgerPage({
    this.page = 1,
    this.pageSize = 30,
    this.total = 0,
    this.items = const [],
  });

  final int page;
  final int pageSize;
  final int total;
  final List<SakuraWalletLedgerEntry> items;

  bool get hasMore => page * pageSize < total;

  factory SakuraWalletLedgerPage.fromJson(Map<String, dynamic> json) {
    return SakuraWalletLedgerPage(
      page: _walletPositiveInt(json['page'], fallback: 1),
      pageSize: _walletPositiveInt(json['pageSize'], fallback: 30),
      total: _walletInt(json['total']),
      items: _walletList(json['items'], SakuraWalletLedgerEntry.fromJson),
    );
  }
}

class SakuraWalletLedgerEntry {
  const SakuraWalletLedgerEntry({
    required this.id,
    required this.action,
    this.pointsDelta = 0,
    this.coinsDelta = 0,
    this.description = '',
    this.relatedType = '',
    this.relatedId = '',
    this.createdAt = '',
  });

  final String id;
  final String action;
  final int pointsDelta;
  final int coinsDelta;
  final String description;
  final String relatedType;
  final String relatedId;
  final String createdAt;

  factory SakuraWalletLedgerEntry.fromJson(Map<String, dynamic> json) {
    return SakuraWalletLedgerEntry(
      id: _walletString(json['id']),
      action: _walletString(json['action']),
      pointsDelta: _walletInt(json['pointsDelta'] ?? json['points']),
      coinsDelta: _walletInt(json['coinsDelta'] ?? json['coins']),
      description: _walletString(json['description']),
      relatedType: _walletString(json['relatedType']),
      relatedId: _walletString(json['relatedId']),
      createdAt: _walletString(json['createdAt']),
    );
  }
}

Map<String, dynamic> _walletMap(dynamic raw) {
  return raw is Map ? raw.cast<String, dynamic>() : const {};
}

List<T> _walletList<T>(dynamic raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => parse(item.cast<String, dynamic>()))
      .toList();
}

String _walletString(dynamic value) => value?.toString().trim() ?? '';

int _walletInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int _walletPositiveInt(dynamic value, {required int fallback}) {
  final parsed = _walletInt(value);
  return parsed > 0 ? parsed : fallback;
}
