import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/interaction_service.dart';

void main() {
  test(
    'system notification service pages history and marks all read',
    () async {
      final requests = <http.Request>[];
      final service = InteractionService(
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'id': 91,
                    'title': '章节审核结果',
                    'content': '本次提交已审核通过',
                    'category': 'ai_novel_review',
                    'readAt': '',
                    'createdAt': '2026-07-20 12:00:00',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'markedCount': 3,
              'unread': {
                'total': 4,
                'system': 0,
                'privateMessages': 1,
                'chatMessages': 3,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final notifications = await service.fetchSystemNotifications(
        token: 'reader-token',
        limit: 12,
        beforeId: 100,
      );
      final unread = await service.markAllSystemNotificationsRead(
        token: 'reader-token',
      );

      expect(notifications, hasLength(1));
      expect(notifications.single.id, 91);
      expect(requests[0].method, 'GET');
      expect(requests[0].url.path, endsWith('/messages/system'));
      expect(requests[0].url.queryParameters, {
        'limit': '12',
        'beforeId': '100',
      });
      expect(requests[0].headers['Authorization'], 'Bearer reader-token');
      expect(requests[1].method, 'POST');
      expect(requests[1].url.path, endsWith('/messages/system/read-all'));
      expect(requests[1].headers['Authorization'], 'Bearer reader-token');
      expect(jsonDecode(requests[1].body), isEmpty);
      expect(unread.system, 0);
      expect(unread.privateMessages, 1);
      expect(unread.chatMessages, 3);
    },
  );
}
