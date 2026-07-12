import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as chat_core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart' as chat_ui;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/theme.dart';
import '../models/interaction_models.dart';
import '../models/interaction_user.dart';
import '../models/local_library.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/storage_service.dart';
import '../services/interaction_service.dart';
import '../widgets/interaction_ui.dart';
import 'anime_detail_screen.dart';
import 'interaction_auth_screen.dart';
import 'message_center_screen.dart';
import 'manga_detail_screen.dart';
import 'search_screen.dart';

part 'chat_room_state_connection.dart';
part 'chat_room_state_composer.dart';
part 'chat_room_state_room.dart';
part 'chat_room_view.dart';
part 'chat_room_room_widgets.dart';
part 'chat_room_message_widgets.dart';
part 'chat_room_composer_widgets.dart';
part 'chat_room_expression_widgets.dart';
part 'chat_room_attachment_widgets.dart';
part 'chat_room_user_profile.dart';
part 'chat_room_models_utils.dart';

const _chatEmojiItems = [
  '😀',
  '😄',
  '😁',
  '😆',
  '😊',
  '😍',
  '😘',
  '😋',
  '😎',
  '😭',
  '😤',
  '😡',
  '😳',
  '😱',
  '🥺',
  '🤔',
  '🤭',
  '🤫',
  '🙄',
  '😴',
  '😇',
  '😈',
  '🤩',
  '🥳',
  '😅',
  '😂',
  '🤣',
  '😌',
  '😔',
  '😢',
  '😵',
  '🤯',
  '👍',
  '👎',
  '👏',
  '🙏',
  '💪',
  '👌',
  '✌️',
  '🤝',
  '💗',
  '💖',
  '✨',
  '🌸',
  '🌙',
  '⭐',
  '🔥',
  '🍵',
];

const _chatStickerPacks = [
  _ChatStickerPack(
    id: 'sakura',
    label: '樱花小剧场',
    stickers: [
      _ChatSticker(
        'sakura_wave',
        '挥手',
        '🌸',
        Icons.waving_hand_outlined,
        assetPath: 'assets/stickers/chat/sakura_wave.svg',
      ),
      _ChatSticker(
        'sakura_love',
        '喜欢',
        '💗',
        Icons.favorite_border_outlined,
        assetPath: 'assets/stickers/chat/sakura_love.svg',
      ),
      _ChatSticker(
        'sakura_sleep',
        '困了',
        '😴',
        Icons.nightlight_round,
        assetPath: 'assets/stickers/chat/sakura_sleep.svg',
      ),
    ],
  ),
  _ChatStickerPack(
    id: 'moon',
    label: '月光读者',
    stickers: [
      _ChatSticker(
        'moon_hi',
        '打招呼',
        '👋',
        Icons.waving_hand_outlined,
        assetPath: 'assets/stickers/chat/moon_hi.svg',
      ),
      _ChatSticker(
        'moon_star',
        '星星',
        '⭐',
        Icons.star_border_rounded,
        assetPath: 'assets/stickers/chat/moon_star.svg',
      ),
      _ChatSticker(
        'moon_shy',
        '害羞',
        '😊',
        Icons.sentiment_satisfied_alt_outlined,
        assetPath: 'assets/stickers/chat/moon_shy.svg',
      ),
    ],
  ),
];

const _legacyChatStickers = [
  _ChatSticker('sakura_smile', '樱花笑', '🌸', Icons.local_florist_outlined),
  _ChatSticker('thumbs_up', '赞', '👍', Icons.thumb_up_alt_outlined),
  _ChatSticker('sparkle', '闪光', '✨', Icons.auto_awesome_outlined),
  _ChatSticker('tea', '喝茶', '🍵', Icons.emoji_food_beverage_outlined),
  _ChatSticker('heart', '喜欢', '💗', Icons.favorite_border_outlined),
  _ChatSticker('sleepy', '困了', '😴', Icons.nightlight_round),
];

enum _VoiceReleaseAction { send, cancel, transcribe }

const _chatHistoryPageSize = 50;

class ChatRoomScreen extends StatefulWidget {
  const ChatRoomScreen({super.key, this.roomId = 'global', this.title = '聊天室'});

  final String roomId;
  final String title;

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}
