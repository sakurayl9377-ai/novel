import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/interaction_models.dart';
import '../models/interaction_user.dart';
import '../models/wallet_models.dart';
import 'interaction_auth_service.dart';

class InteractionServiceException implements Exception {
  const InteractionServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class InteractionService {
  InteractionService({this.httpClient});

  static final http.Client _sharedHttpClient = http.Client();
  static const Uuid _uuid = Uuid();

  static const String apiBaseUrl = InteractionAuthService.baseUrl;
  static const String wsBaseUrl = String.fromEnvironment(
    'NOVEL_WS_BASE_URL',
    defaultValue: 'wss://49.232.137.85/novel-ws',
  );

  final http.Client? httpClient;

  Future<UserProfile> fetchMyProfile({required String token}) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/users/me/profile'),
      token: token,
    );
    return UserProfile.fromJson(json);
  }

  Future<SakuraWalletSnapshot> fetchWallet({
    required String token,
    int page = 1,
    int pageSize = 30,
    int snapshotMaxId = 0,
  }) async {
    final queryParameters = <String, String>{
      'page': page.clamp(1, 999999).toString(),
      'pageSize': pageSize.clamp(1, 50).toString(),
    };
    if (snapshotMaxId > 0) {
      queryParameters['snapshotMaxId'] = snapshotMaxId.toString();
    }
    final uri = Uri.parse(
      '$apiBaseUrl/users/me/wallet',
    ).replace(queryParameters: queryParameters);
    final json = await _request('GET', uri, token: token);
    return SakuraWalletSnapshot.fromJson(json);
  }

  Future<UserProfile> fetchUserProfile({
    required int userId,
    String token = '',
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/users/$userId/profile'),
      token: token,
    );
    return UserProfile.fromJson(json);
  }

  Future<UserProfile> updateMyProfile({
    required String token,
    required String nickname,
    String avatarUrl = '',
    String gender = 'private',
    String bio = '',
    String signature = '',
    String spaceTitle = '',
    String profileBannerUrl = '',
    String dynamicAvatarUrl = '',
    String profileTheme = 'sakura',
    bool privacyMode = false,
    List<Map<String, String>>? photoWall,
  }) async {
    final body = <String, dynamic>{
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
    };
    if (photoWall != null) body['photoWall'] = photoWall;
    final json = await _request(
      'PATCH',
      Uri.parse('$apiBaseUrl/users/me/profile'),
      token: token,
      body: body,
    );
    return UserProfile.fromJson(json);
  }

  Future<String> uploadAvatar({
    required String token,
    required List<int> bytes,
    required String mimeType,
  }) {
    return uploadProfileImage(
      token: token,
      kind: 'avatar',
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  Future<String> uploadProfileImage({
    required String token,
    required String kind,
    required List<int> bytes,
    required String mimeType,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/users/me/profile-image'),
      token: token,
      body: {
        'kind': kind,
        'mimeType': mimeType,
        'dataBase64': base64Encode(bytes),
      },
    );
    final url = json['url'];
    if (url is! String || url.trim().isEmpty) {
      throw const InteractionServiceException('图片上传结果异常');
    }
    return url.trim();
  }

  Future<String> transcribeChatAudio({
    required String token,
    required String mediaUrl,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/speech/transcribe'),
      token: token,
      body: {'mediaUrl': mediaUrl},
    );
    return (json['text']?.toString() ?? '').trim();
  }

  Future<ChatBotPublicProfile> fetchChatBotProfile({String token = ''}) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/chat/bot'),
      token: token,
    );
    return ChatBotPublicProfile.fromJson(json);
  }

  Future<AppAnnouncement> fetchAppAnnouncement() async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/app/announcement'),
    );
    final item = json['item'];
    return item is Map
        ? AppAnnouncement.fromJson(item.cast<String, dynamic>())
        : const AppAnnouncement();
  }

  Future<ChatBotDirectReply> sendChatBotDirectMessage({
    required String token,
    required String content,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/chat/bot/direct'),
      token: token,
      body: {'content': content},
    );
    return ChatBotDirectReply.fromJson(json);
  }

  Future<List<ChatBotDirectMessage>> fetchChatBotDirectMessages({
    required String token,
    int beforeId = 0,
    int limit = 20,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/chat/bot/direct/messages').replace(
      queryParameters: {
        if (beforeId > 0) 'beforeId': beforeId.toString(),
        'limit': limit.toString(),
      },
    );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(ChatBotDirectMessage.fromJson).toList();
  }

  Future<DailySignInResult> dailySignIn({required String token}) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/users/me/signin'),
      token: token,
      body: const {},
    );
    return DailySignInResult.fromJson(json);
  }

  Future<UserProfile> followUser({
    required String token,
    required int userId,
    required bool follow,
  }) async {
    final json = await _request(
      follow ? 'POST' : 'DELETE',
      Uri.parse('$apiBaseUrl/users/$userId/follow'),
      token: token,
      body: follow ? const {} : null,
    );
    return UserProfile.fromJson(json);
  }

  Future<List<InteractionUser>> fetchUserFollowers({
    required int userId,
    String token = '',
    int page = 1,
    int pageSize = 50,
  }) {
    return _fetchUserFollowList(
      userId: userId,
      kind: 'followers',
      token: token,
      page: page,
      pageSize: pageSize,
    );
  }

  Future<List<InteractionUser>> fetchUserFollowing({
    required int userId,
    String token = '',
    int page = 1,
    int pageSize = 50,
  }) {
    return _fetchUserFollowList(
      userId: userId,
      kind: 'following',
      token: token,
      page: page,
      pageSize: pageSize,
    );
  }

  Future<List<ShopItem>> fetchShopItems() async {
    final json = await _request('GET', Uri.parse('$apiBaseUrl/shop/items'));
    final raw = json['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final value = item.cast<String, dynamic>();
      value['previewUrl'] = _absoluteApiResourceUrl(value['previewUrl']);
      return ShopItem.fromJson(value);
    }).toList();
  }

  Future<UserProfile> redeemShopItem({
    required String token,
    required String itemId,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/shop/items/$itemId/redeem'),
      token: token,
      body: const {},
    );
    return UserProfile.fromJson(json);
  }

  Future<UserProfile> equipShopItem({
    required String token,
    required String slot,
    required String itemId,
  }) async {
    final json = await _request(
      'PUT',
      Uri.parse('$apiBaseUrl/users/me/equipment/$slot'),
      token: token,
      body: {'itemId': itemId},
    );
    return UserProfile.fromJson(json);
  }

  Future<List<InteractionComment>> fetchComments({
    required String targetType,
    required String targetId,
    String chapterId = '',
    String episodeId = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/comments').replace(
      queryParameters: {
        'targetType': targetType,
        'targetId': targetId,
        if (chapterId.isNotEmpty) 'chapterId': chapterId,
        if (episodeId.isNotEmpty) 'episodeId': episodeId,
        'sort': sort,
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    );
    final json = await _request('GET', uri);
    return _items(json).map(InteractionComment.fromJson).toList();
  }

  Future<List<InteractionComment>> fetchReplies({
    required int commentId,
    int page = 1,
    int pageSize = 30,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/comments/$commentId/replies').replace(
      queryParameters: {
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    );
    final json = await _request('GET', uri);
    return _items(json).map(InteractionComment.fromJson).toList();
  }

  Future<InteractionCommentSummary> fetchCommentSummary({
    required String targetType,
    required String targetId,
    String chapterId = '',
    String episodeId = '',
    String sort = 'hot',
    int previewSize = 2,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/comments/summary').replace(
      queryParameters: {
        'targetType': targetType,
        'targetId': targetId,
        if (chapterId.isNotEmpty) 'chapterId': chapterId,
        if (episodeId.isNotEmpty) 'episodeId': episodeId,
        'sort': sort,
        'previewSize': previewSize.toString(),
      },
    );
    final json = await _request('GET', uri);
    return InteractionCommentSummary.fromJson(json);
  }

  Future<InteractionComment> postComment({
    required String token,
    required String targetType,
    required String targetId,
    required String content,
    String targetTitle = '',
    String chapterId = '',
    String chapterTitle = '',
    String episodeId = '',
    String episodeTitle = '',
    int? parentId,
    int? rating,
  }) async {
    final body = <String, dynamic>{
      'targetType': targetType,
      'targetId': targetId,
      'content': content,
      if (targetTitle.isNotEmpty) 'targetTitle': targetTitle,
      if (chapterId.isNotEmpty) 'chapterId': chapterId,
      if (chapterTitle.isNotEmpty) 'chapterTitle': chapterTitle,
      if (episodeId.isNotEmpty) 'episodeId': episodeId,
      if (episodeTitle.isNotEmpty) 'episodeTitle': episodeTitle,
    };
    if (parentId != null) body['parentId'] = parentId;
    if (rating != null) body['rating'] = rating;

    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/comments'),
      token: token,
      body: body,
    );
    final item = json['item'];
    if (item is! Map) throw const InteractionServiceException('评论结果异常');
    return InteractionComment.fromJson(item.cast<String, dynamic>());
  }

  Future<void> likeComment({
    required String token,
    required int commentId,
  }) async {
    await _request(
      'POST',
      Uri.parse('$apiBaseUrl/comments/$commentId/like'),
      token: token,
      body: const {},
    );
  }

  Future<void> reportTarget({
    required String token,
    required String targetType,
    required String targetId,
    required String reason,
  }) async {
    await _request(
      'POST',
      Uri.parse('$apiBaseUrl/reports'),
      token: token,
      body: {'targetType': targetType, 'targetId': targetId, 'reason': reason},
    );
  }

  Future<List<InteractionDanmaku>> fetchDanmaku({
    required String videoId,
    String animeId = '',
    String animeTitle = '',
    String episodeId = '',
    String episodeTitle = '',
    int fromMs = 0,
    int toMs = 86400000,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/danmaku').replace(
      queryParameters: {
        'videoId': videoId,
        'fromMs': fromMs.toString(),
        'toMs': toMs.toString(),
        if (animeId.isNotEmpty) 'animeId': animeId,
        if (animeTitle.isNotEmpty) 'animeTitle': animeTitle,
        if (episodeId.isNotEmpty) 'episodeId': episodeId,
        if (episodeTitle.isNotEmpty) 'episodeTitle': episodeTitle,
      },
    );
    final json = await _request('GET', uri);
    return _items(json).map(InteractionDanmaku.fromJson).toList();
  }

  Future<InteractionDanmaku> postDanmaku({
    required String token,
    required String videoId,
    required int timeMs,
    required String content,
    String animeId = '',
    String animeTitle = '',
    String episodeId = '',
    String episodeTitle = '',
    String color = '#FFFFFF',
    String mode = 'scroll',
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/danmaku'),
      token: token,
      body: {
        'videoId': videoId,
        'timeMs': timeMs,
        'content': content,
        'color': color,
        'mode': mode,
        if (animeId.isNotEmpty) 'animeId': animeId,
        if (animeTitle.isNotEmpty) 'animeTitle': animeTitle,
        if (episodeId.isNotEmpty) 'episodeId': episodeId,
        if (episodeTitle.isNotEmpty) 'episodeTitle': episodeTitle,
      },
    );
    final item = json['item'];
    if (item is! Map) throw const InteractionServiceException('弹幕结果异常');
    return InteractionDanmaku.fromJson(item.cast<String, dynamic>());
  }

  Future<List<InteractionComment>> fetchMyComments({
    required String token,
    int page = 1,
    int pageSize = 30,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/users/me/interactions/comments').replace(
      queryParameters: {
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(InteractionComment.fromJson).toList();
  }

  Future<List<InteractionDanmaku>> fetchMyDanmaku({
    required String token,
    int page = 1,
    int pageSize = 30,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/users/me/interactions/danmaku').replace(
      queryParameters: {
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(InteractionDanmaku.fromJson).toList();
  }

  Future<ChatRoomListPayload> fetchChatRooms({String token = ''}) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/chat/rooms'),
      token: token,
    );
    return ChatRoomListPayload.fromJson(json);
  }

  Future<ChatRoomInfo> fetchChatRoom({
    required String roomId,
    String token = '',
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/chat/rooms/${Uri.encodeComponent(roomId)}'),
      token: token,
    );
    return _chatRoomFromResponse(json);
  }

  Future<List<ChatMessage>> fetchChatRoomMessages({
    required String roomId,
    String query = '',
    String token = '',
    int page = 1,
    int pageSize = 30,
    int beforeId = 0,
  }) async {
    final uri =
        Uri.parse(
          '$apiBaseUrl/chat/rooms/${Uri.encodeComponent(roomId)}/messages',
        ).replace(
          queryParameters: {
            if (query.trim().isNotEmpty) 'q': query.trim(),
            if (beforeId > 0) 'beforeId': beforeId.toString(),
            'page': page.toString(),
            'pageSize': pageSize.toString(),
          },
        );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(ChatMessage.fromJson).toList();
  }

  Future<ChatRoomInfo> joinChatRoom({
    required String token,
    required String roomId,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/chat/rooms/${Uri.encodeComponent(roomId)}/join'),
      token: token,
      body: const {},
    );
    return _chatRoomFromResponse(json);
  }

  Future<ChatRoomInfo> leaveChatRoom({
    required String token,
    required String roomId,
  }) async {
    final json = await _request(
      'DELETE',
      Uri.parse('$apiBaseUrl/chat/rooms/${Uri.encodeComponent(roomId)}/join'),
      token: token,
    );
    return _chatRoomFromResponse(json);
  }

  Future<List<PrivateConversation>> fetchPrivateConversations({
    required String token,
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/messages/conversations'),
      token: token,
    );
    return _items(json).map(PrivateConversation.fromJson).toList();
  }

  Future<MessageUnreadSummary> fetchMessageUnreadSummary({
    required String token,
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/messages/unread-summary'),
      token: token,
    );
    return MessageUnreadSummary.fromJson(json);
  }

  Future<List<SystemNotificationItem>> fetchSystemNotifications({
    required String token,
    int limit = 50,
    int beforeId = 0,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/messages/system').replace(
      queryParameters: {
        'limit': limit.toString(),
        if (beforeId > 0) 'beforeId': beforeId.toString(),
      },
    );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(SystemNotificationItem.fromJson).toList();
  }

  Future<MessageUnreadSummary> markSystemNotificationRead({
    required String token,
    required int id,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/messages/system/$id/read'),
      token: token,
      body: const {},
    );
    final unread = json['unread'];
    return unread is Map
        ? MessageUnreadSummary.fromJson(unread.cast<String, dynamic>())
        : MessageUnreadSummary.fromJson(json);
  }

  Future<MessageUnreadSummary> markAllSystemNotificationsRead({
    required String token,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/messages/system/read-all'),
      token: token,
      body: const {},
    );
    final unread = json['unread'];
    return unread is Map
        ? MessageUnreadSummary.fromJson(unread.cast<String, dynamic>())
        : MessageUnreadSummary.fromJson(json);
  }

  Future<List<PrivateMessage>> fetchPrivateMessages({
    required String token,
    required int userId,
  }) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/messages/private/$userId'),
      token: token,
    );
    return _items(json).map(PrivateMessage.fromJson).toList();
  }

  Future<PrivateMessage> sendPrivateMessage({
    required String token,
    required int userId,
    required String content,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/messages/private/$userId'),
      token: token,
      body: {'content': content},
    );
    final item = json['item'];
    if (item is! Map) throw const InteractionServiceException('私信发送结果异常');
    return PrivateMessage.fromJson(item.cast<String, dynamic>());
  }

  Future<ChatRoomInfo> createChatRoom({
    required String token,
    required String name,
    required String category,
    String avatarUrl = '',
    int minLevel = 0,
    bool botEnabled = false,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/admin/chat/rooms'),
      token: token,
      body: {
        'name': name,
        'category': category,
        'avatarUrl': avatarUrl,
        'minLevel': minLevel,
        'botEnabled': botEnabled,
      },
    );
    return _chatRoomFromResponse(json);
  }

  Future<ChatRoomInfo> updateChatRoom({
    required String token,
    required String roomId,
    required String name,
    required String category,
    String avatarUrl = '',
    int minLevel = 0,
    bool botEnabled = false,
  }) async {
    final json = await _request(
      'PATCH',
      Uri.parse('$apiBaseUrl/admin/chat/rooms/${Uri.encodeComponent(roomId)}'),
      token: token,
      body: {
        'name': name,
        'category': category,
        'avatarUrl': avatarUrl,
        'minLevel': minLevel,
        'botEnabled': botEnabled,
      },
    );
    return _chatRoomFromResponse(json);
  }

  Future<void> dissolveChatRoom({
    required String token,
    required String roomId,
  }) async {
    await _request(
      'DELETE',
      Uri.parse('$apiBaseUrl/admin/chat/rooms/${Uri.encodeComponent(roomId)}'),
      token: token,
    );
  }

  Future<ChatBotPublicProfile> updateChatBotSkin({
    required String token,
    required String skinId,
  }) async {
    final json = await _request(
      'PATCH',
      Uri.parse('$apiBaseUrl/admin/settings'),
      token: token,
      body: {
        'chatBot': {'skinId': skinId},
      },
    );
    final chatBotJson = json['chatBot'];
    final skinsJson = json['chatBotSkins'];
    final selectedSkinId = chatBotJson is Map
        ? (chatBotJson['skinId']?.toString() ?? skinId)
        : skinId;
    Map<String, dynamic> skin = const {};
    if (skinsJson is List) {
      for (final item in skinsJson.whereType<Map>()) {
        final candidate = item.cast<String, dynamic>();
        if (candidate['id']?.toString() == selectedSkinId) {
          skin = candidate;
          break;
        }
      }
    }
    return ChatBotPublicProfile.fromJson({
      'botName': chatBotJson is Map ? chatBotJson['botName'] : '小樱',
      'skinId': selectedSkinId,
      'enabled': chatBotJson is Map ? chatBotJson['enabled'] == 'true' : false,
      'skin': skin,
    });
  }

  WebSocketChannel connectChat({
    required String token,
    required String roomId,
    bool announceEntrance = false,
  }) {
    final uri = Uri.parse('$wsBaseUrl/chat').replace(
      queryParameters: {
        'roomId': roomId,
        if (announceEntrance) 'entrance': '1',
      },
    );
    return IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
  }

  Future<HorseRaceState> fetchHorseRaceState({required String token}) async {
    final json = await _request(
      'GET',
      Uri.parse('$apiBaseUrl/games/horse-race'),
      token: token,
    );
    final item = json['item'];
    if (item is Map) {
      return HorseRaceState.fromJson(item.cast<String, dynamic>());
    }
    return HorseRaceState.fromJson(json);
  }

  Future<HorseRaceState> placeHorseRaceBet({
    required String token,
    required int horseIndex,
    required int amount,
    String? requestId,
  }) async {
    final json = await _request(
      'POST',
      Uri.parse('$apiBaseUrl/games/horse-race/bets'),
      token: token,
      body: {
        'horseIndex': horseIndex,
        'amount': amount,
        'requestId': requestId ?? _uuid.v4(),
      },
    );
    final item = json['item'];
    if (item is! Map) {
      throw const InteractionServiceException('赛马下注结果异常');
    }
    return HorseRaceState.fromJson(item.cast<String, dynamic>());
  }

  WebSocketChannel connectHorseRaceGame({required String token}) {
    final uri = Uri.parse('$wsBaseUrl/game');
    return IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
  }

  Future<List<InteractionUser>> _fetchUserFollowList({
    required int userId,
    required String kind,
    required String token,
    required int page,
    required int pageSize,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/users/$userId/$kind').replace(
      queryParameters: {
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    );
    final json = await _request('GET', uri, token: token);
    return _items(json).map(InteractionUser.fromJson).toList();
  }

  String _absoluteApiResourceUrl(Object? rawValue) {
    final value = rawValue?.toString().trim() ?? '';
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri?.hasScheme ?? false) return value;
    return Uri.parse(apiBaseUrl).resolve(value).toString();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final client = httpClient ?? _sharedHttpClient;
    final response = switch (method) {
      'GET' =>
        await client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15)),
      'POST' =>
        await client
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 15)),
      'PATCH' =>
        await client
            .patch(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 15)),
      'PUT' =>
        await client
            .put(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 15)),
      'DELETE' =>
        await client
            .delete(uri, headers: headers)
            .timeout(const Duration(seconds: 15)),
      _ => throw ArgumentError('Unsupported method $method'),
    };
    final decoded = _decodeJson(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverError =
          decoded['message']?.toString() ?? decoded['error']?.toString() ?? '';
      throw InteractionServiceException(_friendlyError(serverError));
    }
    return decoded;
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }

  ChatRoomInfo _chatRoomFromResponse(Map<String, dynamic> json) {
    final item = json['item'];
    if (item is Map) return ChatRoomInfo.fromJson(item.cast<String, dynamic>());
    final room = json['room'];
    if (room is Map) return ChatRoomInfo.fromJson(room.cast<String, dynamic>());
    return ChatRoomInfo.fromJson(json);
  }

  Map<String, dynamic> _decodeJson(List<int> bytes) {
    final body = utf8.decode(bytes, allowMalformed: true);
    if (body.trimLeft().startsWith('<')) {
      throw const InteractionServiceException('互动服务暂不可用，请检查服务器配置');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const InteractionServiceException('服务响应格式异常');
    }
    if (decoded is! Map) {
      throw const InteractionServiceException('服务响应异常');
    }
    return decoded.cast<String, dynamic>();
  }

  String _friendlyError(String error) {
    return switch (error) {
      'unauthorized' => '请先登录',
      'account_banned' => '账号已被封禁',
      'content is required' => '请输入内容',
      'reason is required' => '请选择举报原因',
      'nickname is required' => '请输入昵称',
      'coins_not_enough' => '樱花币不足',
      'level_required' => '等级还不够',
      'level_required_dynamic_avatar' => 'Lv5 解锁动态头像',
      'level_required_profile_skin' => 'Lv2 解锁空间皮肤',
      'photo_wall_limit' => '照片墙数量超过当前等级上限',
      'level_required_chat_image' => 'Lv3 解锁聊天室图片消息',
      'level_required_chat_sticker' => 'Lv4 解锁表情包快捷发送',
      'profile_private' => '对方已开启隐私模式',
      'item_not_owned' => '请先在商城兑换该装扮',
      'equipment_slot_invalid' => '装扮类型不匹配',
      'speech_asr_disabled' => '语音转文字暂未启用',
      'speech_asr_config_missing' => '语音转文字配置不完整',
      'speech_audio_format_unsupported' => '当前语音格式暂不支持转文字',
      'speech_audio_url_invalid' => '语音文件地址无效',
      'speech_audio_fetch_failed' => '语音文件读取失败',
      'speech_asr_timeout' => '语音转文字超时，请稍后重试',
      'speech_asr_bad_request' => '讯飞实时转写拒绝连接，请检查 RTASR 的 APPID 和 APIKey',
      'speech_asr_failed' => '语音转文字失败',
      'horse_race_closed' => '樱花赛马每天 06:00 到 24:00 开放',
      'horse_race_locked' => '本轮已锁盘，等待开赛',
      'horse_race_horse_invalid' => '请选择要支持的赛马',
      'horse_race_bet_limit' => '单匹马本轮最多下注 1000 樱花币',
      'horse_race_bet_amount_invalid' => '下注金额不符合本轮规则',
      'horse_race_round_bet_limit' => '已达到本轮下注总上限',
      'horse_race_daily_bet_limit' => '已达到今日赛马下注上限，请明天再来',
      'horse_race_request_conflict' => '下注请求重复或已失效，请刷新后重试',
      _ => error.isEmpty ? '请求失败，请稍后再试' : error,
    };
  }
}
