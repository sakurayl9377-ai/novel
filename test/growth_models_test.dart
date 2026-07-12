import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/growth_models.dart';

void main() {
  test('growth content and recommendation tolerate mixed JSON values', () {
    final item = GrowthRecommendation.fromJson({
      'rank': '2',
      'score': '9.5',
      'continueProgress': true,
      'reasons': ['近期阅读', null, '', 7],
      'content': {
        'stableKey': 123,
        'contentType': 'novel',
        'sourceKey': 'source-a',
        'sourceItemId': 99,
        'title': '测试小说',
        'imageUrl': 'https://example.test/cover.jpg',
        'metadata': {'chapterCount': 12},
      },
    });

    expect(item.rank, 2);
    expect(item.score, 9.5);
    expect(item.continueProgress, isTrue);
    expect(item.reasons, ['近期阅读', '7']);
    expect(item.content.stableKey, '123');
    expect(item.content.sourceItemId, '99');
    expect(item.content.coverUrl, 'https://example.test/cover.jpg');
    expect(item.content.metadata['chapterCount'], 12);
  });

  test('activity task derives claim and bounded progress state', () {
    final task = ActivityTask.fromJson({
      'id': 8,
      'title': '完成阅读',
      'targetCount': 2,
      'progressCount': 5,
      'completed': true,
      'claimed': false,
      'reward': {'points': '30', 'coins': 4},
    });

    expect(task.canClaim, isTrue);
    expect(task.progress, 1);
    expect(task.rewardPoints, 30);
    expect(task.rewardCoins, 4);
  });

  test('bootstrap and horse season parse nested collections safely', () {
    final bootstrap = AppBootstrapPayload.fromJson({
      'cacheRevision': '7',
      'features': {
        'growthCenter': {'enabled': true},
      },
      'placements': {
        'home': [
          {'title': '推荐位'},
          'ignored',
        ],
      },
    });
    final season = HorseRaceSeasonPayload.fromJson({
      'season': {'id': 3, 'title': '夏季赛', 'status': 'active'},
      'leaderboard': [
        {'userId': 9, 'nickname': '玩家', 'points': '88'},
      ],
      'tasks': const [],
      'rewards': const [],
    });

    expect(bootstrap.cacheRevision, 7);
    expect(bootstrap.placements['home'], hasLength(1));
    expect(season.season?.id, 3);
    expect(season.leaderboard.single.points, 88);
  });
}
