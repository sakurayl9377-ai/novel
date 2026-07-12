import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/interaction_models.dart';
import '../../../services/interaction_service.dart';

const String _assistantSkinKey = 'profile.assistant.skinId';
const String _assistantDockXKey = 'profile.assistant.dock.dx';
const String _assistantDockYKey = 'profile.assistant.dock.dy';

class ProfileAssistantPreferences {
  const ProfileAssistantPreferences({this.skinId = '', this.dockOffset});

  final String skinId;
  final Offset? dockOffset;
}

class ProfileAssistantService {
  ProfileAssistantService(this._service);

  final InteractionService _service;

  Future<ChatBotPublicProfile> fetchPublicProfile({required String token}) {
    return _service.fetchChatBotProfile(token: token);
  }

  Future<ProfileAssistantPreferences> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final dx = prefs.getDouble(_assistantDockXKey);
    final dy = prefs.getDouble(_assistantDockYKey);
    return ProfileAssistantPreferences(
      skinId: prefs.getString(_assistantSkinKey) ?? '',
      dockOffset: dx == null || dy == null ? null : Offset(dx, dy),
    );
  }

  Future<void> saveDockOffset(Offset offset) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait<bool>(<Future<bool>>[
      prefs.setDouble(_assistantDockXKey, offset.dx),
      prefs.setDouble(_assistantDockYKey, offset.dy),
    ]);
  }

  Future<void> saveSkinId(String skinId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_assistantSkinKey, skinId);
  }

  Future<List<ChatBotDirectMessage>> fetchMessages({
    required String token,
    int limit = 50,
  }) {
    return _service.fetchChatBotDirectMessages(token: token, limit: limit);
  }

  Future<ChatBotDirectReply> sendMessage({
    required String token,
    required String content,
  }) {
    return _service.sendChatBotDirectMessage(token: token, content: content);
  }
}
