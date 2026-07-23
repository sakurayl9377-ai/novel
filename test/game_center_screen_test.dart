import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/screens/game_center_screen.dart';
import 'package:novel_app/services/game_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<GameCatalogService> serviceFor(List<Map<String, Object>> games) async {
    final preferences = await SharedPreferences.getInstance();
    return GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'games': games}),
          200,
          request: request,
        );
      }),
    );
  }

  Future<void> pumpCenter(
    WidgetTester tester, {
    required Size size,
    GameCatalogService? catalogService,
    List<Map<String, Object>>? games,
    WidgetBuilder? horseRaceDestinationBuilder,
    VoidCallback? onHorseRaceTap,
    VoidCallback? onBailianTap,
    VoidCallback? onModaoTap,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: GameCenterScreen(
          catalogService:
              catalogService ??
              await serviceFor(
                games ??
                    <Map<String, Object>>[
                      _game('horse-race', sortOrder: 10),
                      _game('modao', sortOrder: 30),
                    ],
              ),
          horseRaceDestinationBuilder: horseRaceDestinationBuilder,
          onHorseRaceTap: onHorseRaceTap,
          onBailianTap: onBailianTap,
          onModaoTap: onModaoTap,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('hides stopped bailian and uses fixed local presentation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpCenter(tester, size: const Size(900, 900));

      expect(find.text('樱游阁'), findsOneWidget);
      expect(find.text('server supplied name'), findsNothing);
      expect(find.text('樱花赛马'), findsOneWidget);
      expect(find.text('百练英雄'), findsNothing);
      expect(find.text('魔道修仙'), findsOneWidget);
      expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
      expect(find.byKey(GameCenterScreen.bailianEntryKey), findsNothing);
      expect(find.byKey(GameCenterScreen.modaoEntryKey), findsOneWidget);
      expect(find.byKey(GameCenterScreen.ordersEntryKey), findsOneWidget);
      expect(find.bySemanticsLabel('樱花赛马，实时竞技'), findsOneWidget);
      expect(find.bySemanticsLabel('魔道修仙，玄幻冒险'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('removes modao when the backend hides it', (tester) async {
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      games: <Map<String, Object>>[_game('horse-race')],
    );

    expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
    expect(find.text('魔道修仙'), findsNothing);
  });

  testWidgets('uses one column on phones and two columns on tablets', (
    tester,
  ) async {
    await pumpCenter(tester, size: const Size(390, 844));
    final phoneModao = tester.getTopLeft(
      find.byKey(GameCenterScreen.modaoEntryKey),
    );
    final phoneRace = tester.getTopLeft(
      find.byKey(GameCenterScreen.horseRaceEntryKey),
    );
    expect(phoneModao.dx, phoneRace.dx);
    expect(phoneModao.dy, greaterThan(phoneRace.dy));

    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    final tabletModao = tester.getTopLeft(
      find.byKey(GameCenterScreen.modaoEntryKey),
    );
    final tabletRace = tester.getTopLeft(
      find.byKey(GameCenterScreen.horseRaceEntryKey),
    );
    expect(tabletModao.dy, tabletRace.dy);
    expect(tabletModao.dx, greaterThan(tabletRace.dx));
  });

  testWidgets('shows loading without exposing unconfirmed games', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final preferences = await SharedPreferences.getInstance();
    final service = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) => response.future),
    );

    await pumpCenter(
      tester,
      size: const Size(390, 844),
      catalogService: service,
      settle: false,
    );

    expect(find.byKey(GameCenterScreen.loadingKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.bailianEntryKey), findsNothing);

    response.complete(
      http.Response(
        jsonEncode({
          'games': [_game('horse-race')],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(GameCenterScreen.loadingKey), findsNothing);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
  });

  testWidgets('uses cache on failure and marks the catalog as stale', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      GameCatalogService.cacheKey: <String>['horse-race', 'bailian', 'modao'],
    });
    final preferences = await SharedPreferences.getInstance();
    final service = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        throw http.ClientException('offline', request.url);
      }),
    );

    await pumpCenter(
      tester,
      size: const Size(390, 844),
      catalogService: service,
    );

    expect(find.byKey(GameCenterScreen.bailianEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.staleNoticeKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.retryKey), findsOneWidget);
  });

  testWidgets('first failure never restores the stopped bailian game', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final service = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        throw http.ClientException('offline', request.url);
      }),
    );

    await pumpCenter(
      tester,
      size: const Size(390, 844),
      catalogService: service,
    );

    expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.bailianEntryKey), findsNothing);
    expect(find.byKey(GameCenterScreen.staleNoticeKey), findsOneWidget);
  });

  testWidgets('refreshes and hides a managed game when the app resumes', (
    tester,
  ) async {
    var requestCount = 0;
    final preferences = await SharedPreferences.getInstance();
    final service = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        requestCount += 1;
        return http.Response(
          jsonEncode({
            'games': requestCount == 1
                ? <Map<String, Object>>[_game('horse-race'), _game('modao')]
                : <Map<String, Object>>[_game('horse-race')],
          }),
          200,
          request: request,
        );
      }),
    );

    await pumpCenter(
      tester,
      size: const Size(390, 844),
      catalogService: service,
    );
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(requestCount, 2);
    expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.modaoEntryKey), findsNothing);
  });

  testWidgets('shows an empty state with a retry action', (tester) async {
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      games: const <Map<String, Object>>[],
    );

    expect(find.byKey(GameCenterScreen.gridKey), findsNothing);
    expect(find.byKey(GameCenterScreen.emptyKey), findsOneWidget);
    expect(find.byKey(GameCenterScreen.emptyRetryKey), findsOneWidget);
    expect(find.text('暂时没有开放中的游戏'), findsOneWidget);
  });

  testWidgets('horse race entry retains onTap and builder injection', (
    tester,
  ) async {
    var taps = 0;
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      games: <Map<String, Object>>[_game('horse-race')],
      onHorseRaceTap: () => taps += 1,
    );

    await tester.tap(find.byKey(GameCenterScreen.horseRaceEntryKey));
    await tester.pump();
    expect(taps, 1);

    await pumpCenter(
      tester,
      size: const Size(390, 844),
      games: <Map<String, Object>>[_game('horse-race')],
      horseRaceDestinationBuilder: (_) =>
          const Scaffold(body: Text('horse destination')),
    );
    await tester.tap(find.byKey(GameCenterScreen.horseRaceEntryKey));
    await tester.pumpAndSettle();
    expect(find.text('horse destination'), findsOneWidget);
  });

  testWidgets('bailian and modao entries retain caller login gates', (
    tester,
  ) async {
    var bailianTaps = 0;
    var modaoTaps = 0;
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      games: <Map<String, Object>>[
        _game('bailian', sortOrder: 10),
        _game('modao', sortOrder: 20),
      ],
      onBailianTap: () => bailianTaps += 1,
      onModaoTap: () => modaoTaps += 1,
    );

    await tester.tap(find.byKey(GameCenterScreen.bailianEntryKey));
    await tester.drag(
      find.byKey(GameCenterScreen.scrollKey),
      const Offset(0, -450),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GameCenterScreen.modaoEntryKey));
    await tester.pump();

    expect(bailianTaps, 1);
    expect(modaoTaps, 1);
  });
}

Map<String, Object> _game(
  String id, {
  bool visible = true,
  bool enabled = true,
  int sortOrder = 10,
}) {
  final entryType = switch (id) {
    'horse-race' => 'native',
    'bailian' => 'web',
    'modao' => 'apk',
    _ => 'web',
  };
  return <String, Object>{
    'id': id,
    'route': id,
    'name': 'server supplied name',
    'description': 'server supplied description',
    'visible': visible,
    'enabled': enabled,
    'sortOrder': sortOrder,
    'entryType': entryType,
    'requiresLogin': true,
  };
}
