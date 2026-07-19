import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/services/interaction_service.dart';

void main() {
  test('ShopItem reads the uploaded preview URL', () {
    final item = ShopItem.fromJson(const {
      'id': 'bubble-night',
      'name': '夜樱气泡',
      'itemType': 'chat_bubble',
      'assetValue': 'night_sakura',
      'previewUrl': 'https://cdn.example.com/night.png',
    });

    expect(item.previewUrl, 'https://cdn.example.com/night.png');
    expect(item.assetValue, 'night_sakura');
  });

  test(
    'shop responses resolve API-relative preview URLs for Image.network',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          '${InteractionService.apiBaseUrl}/shop/items',
        );
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'skin-sakura',
                'name': '樱花资料卡',
                'itemType': 'profile_skin',
                'assetValue': 'sakura',
                'previewUrl':
                    '/novel-api/uploads/content/shop-previews/1-preview.png',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final items = await InteractionService(
        httpClient: client,
      ).fetchShopItems();

      expect(items, hasLength(1));
      expect(
        items.single.previewUrl,
        Uri.parse(InteractionService.apiBaseUrl)
            .resolve('/novel-api/uploads/content/shop-previews/1-preview.png')
            .toString(),
      );
    },
  );
}
