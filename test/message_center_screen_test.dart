import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/message_center_screen.dart';
import 'package:novel_app/services/interaction_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'message center keeps conversations before a bounded notification preview',
    (tester) async {
      final requests = <http.Request>[];
      final service = InteractionService(
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/messages/system/read-all')) {
            return _jsonResponse({
              'ok': true,
              'markedCount': 5,
              'unread': {
                'total': 0,
                'system': 0,
                'privateMessages': 0,
                'chatMessages': 0,
              },
            });
          }
          if (request.url.path.endsWith('/chat/rooms')) {
            return _jsonResponse({'items': []});
          }
          if (request.url.path.endsWith('/messages/conversations')) {
            return _jsonResponse({'items': []});
          }
          if (request.url.path.endsWith('/messages/unread-summary')) {
            return _jsonResponse({
              'total': 5,
              'system': 5,
              'privateMessages': 0,
              'chatMessages': 0,
            });
          }
          if (request.url.path.endsWith('/messages/system')) {
            return _jsonResponse({
              'items': List.generate(
                5,
                (index) => {
                  'id': 5 - index,
                  'title': '通知 ${5 - index}',
                  'content': '消息正文 ${5 - index}',
                  'category': 'system',
                  'readAt': '',
                  'createdAt': '2026-07-20 12:00:00',
                },
              ),
            });
          }
          return _jsonResponse({});
        }),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<InteractionAuthProvider>.value(
          value: _AuthenticatedInteractionAuthProvider(),
          child: MaterialApp(home: MessageCenterScreen(service: service)),
        ),
      );
      await tester.pumpAndSettle();

      final conversationHeader = find.text('聊天与私信');
      final notificationHeader = find.text('系统通知');
      expect(conversationHeader, findsOneWidget);
      expect(notificationHeader, findsOneWidget);
      expect(
        tester.getTopLeft(conversationHeader).dy,
        lessThan(tester.getTopLeft(notificationHeader).dy),
      );
      expect(find.text('通知 5'), findsOneWidget);

      final markAll = find.byKey(
        const ValueKey('message-center-mark-all-notifications'),
      );
      await tester.scrollUntilVisible(markAll, 300);
      await tester.tap(markAll);
      await tester.pumpAndSettle();

      expect(
        requests.any(
          (request) =>
              request.method == 'POST' &&
              request.url.path.endsWith('/messages/system/read-all'),
        ),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('message-center-mark-all-notifications')),
        findsNothing,
      );
      await tester.scrollUntilVisible(find.text('通知 2'), 300);
      expect(find.text('通知 2'), findsOneWidget);
      expect(find.text('通知 1'), findsNothing);
    },
  );
}

http.Response _jsonResponse(Map<String, dynamic> value) {
  return http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

class _AuthenticatedInteractionAuthProvider extends InteractionAuthProvider {
  @override
  bool get isLoggedIn => true;

  @override
  String get token => 'reader-token';
}
