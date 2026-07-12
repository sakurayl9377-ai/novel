part of '../profile_screen.dart';

const List<String> _profileFontFallback = <String>[
  'PingFang SC',
  'HarmonyOS Sans SC',
  'MiSans',
  'Noto Sans SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'Microsoft YaHei UI',
  'Roboto',
];

const double _profileHorizontalPadding = 20;
const double _profileCardRadius = 8;
const double _profileModuleGap = 12;
const double _avatarFrameInsetRatio = 0.12;
const double _avatarFrameImageInsetRatio = 0.19;
const double _profileHeaderAvatarSize = 104;
const double _profileEditAvatarSize = 92;
const double _miniAssistantDockWidth = 128;
const double _miniAssistantDockHeight = 154;
const double _miniAssistantDockEdgeMargin = 8;
const double _memberCardCompactAspectRatio = 1.86;
const double _memberCenterCardCompactAspectRatio = 1.82;
const String _defaultProfileSakuraBackgroundAsset =
    'assets/images/profile/profile_sakura_home_bg.png';
const Color _profileTopBackground = Color(0xFFEAF3FF);
const Color _profileMidBackground = Color(0xFFF6F8FA);
const Color _profileBottomBackground = Color(0xFFF8FAFC);
const Color _profileSectionTitleColor = Color(0xFF202A3A);
const Color _profileAccentBlue = Color(0xFF237CFF);
const int _currentMaxGrowthCap = 99999;

const TextStyle _profileSectionTitleStyle = TextStyle(
  color: _profileSectionTitleColor,
  fontSize: 16,
  height: 1.1,
  fontWeight: FontWeight.w600,
  fontFamilyFallback: _profileFontFallback,
);

const List<_MiniAssistantSkin> _assistantSkins = [
  _MiniAssistantSkin(
    id: 'sakura',
    label: '樱花',
    imageAsset: 'assets/images/chat_bot/sakura.png',
    bodyAsset: 'assets/images/chat_bot/sakura_body.png',
    colors: [Color(0xFFFF7A9E), Color(0xFFFFD2E0)],
    icon: Icons.local_florist_outlined,
  ),
  _MiniAssistantSkin(
    id: 'witch',
    label: '魔法',
    imageAsset: 'assets/images/chat_bot/witch.png',
    bodyAsset: 'assets/images/chat_bot/witch_body.png',
    colors: [Color(0xFF7C4DFF), Color(0xFFD7C7FF)],
    icon: Icons.auto_fix_high_outlined,
  ),
  _MiniAssistantSkin(
    id: 'elf',
    label: '精灵',
    imageAsset: 'assets/images/chat_bot/elf.png',
    bodyAsset: 'assets/images/chat_bot/elf_body.png',
    colors: [Color(0xFF1BA7A5), Color(0xFFC5F3EC)],
    icon: Icons.spa_outlined,
  ),
  _MiniAssistantSkin(
    id: 'snow',
    label: '雪蓝',
    imageAsset: 'assets/images/chat_bot/snow.png',
    bodyAsset: 'assets/images/chat_bot/snow_body.png',
    colors: [Color(0xFF4D7CFE), Color(0xFFD9E5FF)],
    icon: Icons.ac_unit_rounded,
  ),
  _MiniAssistantSkin(
    id: 'luna',
    label: '月华',
    imageAsset: 'assets/images/chat_bot/luna.png',
    bodyAsset: 'assets/images/chat_bot/luna_body.png',
    colors: [Color(0xFFD64A3C), Color(0xFFFFD8B8)],
    icon: Icons.brightness_2_outlined,
  ),
  _MiniAssistantSkin(
    id: 'mint',
    label: '青羽',
    imageAsset: 'assets/images/chat_bot/mint.png',
    bodyAsset: 'assets/images/chat_bot/mint_body.png',
    colors: [Color(0xFF13A884), Color(0xFFC8F1DE)],
    icon: Icons.eco_outlined,
  ),
  _MiniAssistantSkin(
    id: 'ribbon',
    label: '缎带',
    imageAsset: 'assets/images/chat_bot/ribbon.png',
    bodyAsset: 'assets/images/chat_bot/ribbon_body.png',
    colors: [Color(0xFFE15252), Color(0xFFFFD4D4)],
    icon: Icons.card_giftcard_outlined,
  ),
  _MiniAssistantSkin(
    id: 'knight',
    label: '骑士',
    imageAsset: 'assets/images/chat_bot/knight.png',
    bodyAsset: 'assets/images/chat_bot/knight_body.png',
    colors: [Color(0xFF4778D9), Color(0xFFFFE0A8)],
    icon: Icons.shield_outlined,
  ),
  _MiniAssistantSkin(
    id: 'devil',
    label: '恶魔',
    imageAsset: 'assets/images/chat_bot/devil.png',
    bodyAsset: 'assets/images/chat_bot/devil_body.png',
    colors: [Color(0xFF8B4DDB), Color(0xFFFFC0D8)],
    icon: Icons.dark_mode_outlined,
  ),
];

int _assistantSkinIndexById(String skinId) {
  final index = _assistantSkins.indexWhere((skin) => skin.id == skinId);
  return index < 0 ? 0 : index;
}
