import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/models/wallet_models.dart';
import 'package:novel_app/services/bailian_game_service.dart';

void main() {
  test('wallet parses signed changes and calculates pagination by page', () {
    final wallet = SakuraWalletSnapshot.fromJson({
      'balance': '975',
      'ledger': {
        'page': '1',
        'pageSize': '2',
        'total': '3',
        'items': [
          {
            'id': '12',
            'action': 'game_payment',
            'coinsDelta': '-25',
            'description': '游戏支付',
            'createdAt': '2026-07-22T08:30:00.000Z',
          },
        ],
      },
    });

    expect(wallet.balance, 975);
    expect(wallet.ledger.items.single.id, '12');
    expect(wallet.ledger.items.single.coinsDelta, -25);
    expect(wallet.ledger.hasMore, isTrue);
    expect(
      const SakuraWalletLedgerPage(page: 2, pageSize: 2, total: 3).hasMore,
      isFalse,
    );
  });

  test('existing order model preserves the text ledger ID', () {
    final order = BailianPayment.fromJson({
      'id': '4b55e112-cfe2-4a08-9804-8809951090e1',
      'title': '仙玉礼包',
      'coinCost': '10',
      'status': 'fulfilled',
    });

    expect(order.id, '4b55e112-cfe2-4a08-9804-8809951090e1');
    expect(order.productName, '仙玉礼包');
    expect(order.coinCost, 10);
  });

  test('legacy server timestamps are interpreted as UTC', () {
    final order = BailianPayment.fromJson({'createdAt': '2026-07-22 08:30:00'});

    expect(order.createdAt, DateTime.utc(2026, 7, 22, 8, 30));
    expect(order.createdAt?.isUtc, isTrue);
  });

  test('updating the Sakura balance preserves other growth fields', () {
    const growth = UserGrowth(level: 4, points: 880, sakuraCoins: 20);

    final updated = growth.copyWith(sakuraCoins: 65);

    expect(updated.level, 4);
    expect(updated.points, 880);
    expect(updated.sakuraCoins, 65);
  });

  test('wallet tolerates nested balance and missing ledger', () {
    final wallet = SakuraWalletSnapshot.fromJson({
      'balance': {'sakuraCoins': '42'},
    });

    expect(wallet.balance, 42);
    expect(wallet.ledger.items, isEmpty);
  });
}
