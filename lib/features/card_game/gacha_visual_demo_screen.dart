import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Stable identifiers shared by widget and integration tests for the visual
/// prototype. The screen is intentionally local-only: no wallet or network
/// operation is performed by any action on this page.
abstract final class GachaVisualDemoKeys {
  static const screen = ValueKey<String>('gacha-visual-demo-screen');
  static const particleLayer = ValueKey<String>('gacha-particle-layer');
  static const localModeBadge = ValueKey<String>('gacha-local-mode-badge');
  static const reducedMotionBadge = ValueKey<String>(
    'gacha-reduced-motion-badge',
  );
  static const singlePullButton = ValueKey<String>('gacha-single-pull-button');
  static const tenPullButton = ValueKey<String>('gacha-ten-pull-button');
  static const skipButton = ValueKey<String>('gacha-skip-animation-button');
  static const animationStage = ValueKey<String>('gacha-animation-stage');
  static const urRevealOverlay = ValueKey<String>('gacha-ur-reveal-overlay');
  static const resultView = ValueKey<String>('gacha-result-view');
  static const singleResultCard = ValueKey<String>('gacha-single-result-card');
  static const tenResultGrid = ValueKey<String>('gacha-ten-result-grid');
  static const returnButton = ValueKey<String>('gacha-return-button');
  static const replayButton = ValueKey<String>('gacha-replay-button');

  static ValueKey<String> rarity(GachaDemoRarity rarity) =>
      ValueKey<String>('gacha-rarity-${rarity.code.toLowerCase()}');

  static ValueKey<String> resultCard(int index) =>
      ValueKey<String>('gacha-result-card-$index');
}

/// The four art/effect tiers covered by the first visual prototype.
enum GachaDemoRarity {
  n(
    code: 'N',
    label: '微光',
    assetPath: 'assets/images/card_game/card_n.png',
    accent: Color(0xFFDCE7F2),
    glow: Color(0xFF8EA7C0),
    rank: 0,
  ),
  sr(
    code: 'SR',
    label: '幻紫',
    assetPath: 'assets/images/card_game/card_sr.png',
    accent: Color(0xFFD798FF),
    glow: Color(0xFF8B35E8),
    rank: 1,
  ),
  ssr(
    code: 'SSR',
    label: '曜金',
    assetPath: 'assets/images/card_game/card_ssr.png',
    accent: Color(0xFFFFD875),
    glow: Color(0xFFFF8A34),
    rank: 2,
  ),
  ur(
    code: 'UR',
    label: '虹曜',
    assetPath: 'assets/images/card_game/card_ur.png',
    accent: Color(0xFFFFF1AD),
    glow: Color(0xFFFF4FCB),
    rank: 3,
  );

  const GachaDemoRarity({
    required this.code,
    required this.label,
    required this.assetPath,
    required this.accent,
    required this.glow,
    required this.rank,
  });

  final String code;
  final String label;
  final String assetPath;
  final Color accent;
  final Color glow;
  final int rank;

  List<Color> get frameColors => switch (this) {
    GachaDemoRarity.n => const [Color(0xFFF4FAFF), Color(0xFF8EA7C0)],
    GachaDemoRarity.sr => const [Color(0xFFFFB8FF), Color(0xFF7438E8)],
    GachaDemoRarity.ssr => const [Color(0xFFFFFFC6), Color(0xFFFF9B38)],
    GachaDemoRarity.ur => const [
      Color(0xFFFFE7A8),
      Color(0xFFFF73D1),
      Color(0xFF7FE9FF),
      Color(0xFFA790FF),
      Color(0xFFFFE7A8),
    ],
  };
}

class GachaVisualDemoScreen extends StatefulWidget {
  const GachaVisualDemoScreen({super.key});

  @override
  State<GachaVisualDemoScreen> createState() => _GachaVisualDemoScreenState();
}

enum _DemoPhase { idle, charging, reveal, urReveal, results }

@immutable
class _DemoCardData {
  const _DemoCardData({
    required this.rarity,
    required this.name,
    required this.epithet,
  });

  final GachaDemoRarity rarity;
  final String name;
  final String epithet;
}

const Map<GachaDemoRarity, _DemoCardData> _demoCards = {
  GachaDemoRarity.n: _DemoCardData(
    rarity: GachaDemoRarity.n,
    name: '青羽・初晴',
    epithet: '风从花枝间醒来',
  ),
  GachaDemoRarity.sr: _DemoCardData(
    rarity: GachaDemoRarity.sr,
    name: '星璃・夜航',
    epithet: '循着银河的回声',
  ),
  GachaDemoRarity.ssr: _DemoCardData(
    rarity: GachaDemoRarity.ssr,
    name: '苍岚・樱誓',
    epithet: '以长风为誓，守望花开',
  ),
  GachaDemoRarity.ur: _DemoCardData(
    rarity: GachaDemoRarity.ur,
    name: '樱音・万象星门',
    epithet: '今夜，命运回应你的愿望',
  ),
};

const List<GachaDemoRarity> _tenPullRarities = [
  GachaDemoRarity.n,
  GachaDemoRarity.sr,
  GachaDemoRarity.n,
  GachaDemoRarity.n,
  GachaDemoRarity.ssr,
  GachaDemoRarity.n,
  GachaDemoRarity.sr,
  GachaDemoRarity.n,
  GachaDemoRarity.n,
  GachaDemoRarity.ur,
];

class _GachaVisualDemoScreenState extends State<GachaVisualDemoScreen>
    with TickerProviderStateMixin {
  late final AnimationController _ambientController;
  late final AnimationController _sequenceController;

  _DemoPhase _phase = _DemoPhase.idle;
  GachaDemoRarity _selectedRarity = GachaDemoRarity.ssr;
  List<_DemoCardData> _results = const [];
  _DemoCardData? _spotlightCard;
  int _pullCount = 1;
  int _sequenceGeneration = 0;
  bool _reduceMotion = false;
  Future<void>? _artPrecache;

  bool get _isAnimating =>
      _phase == _DemoPhase.charging ||
      _phase == _DemoPhase.reveal ||
      _phase == _DemoPhase.urReveal;

  GachaDemoRarity get _activeRarity =>
      _spotlightCard?.rarity ?? _selectedRarity;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _sequenceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _artPrecache ??= _precacheCardArt();
    final mediaQuery = MediaQuery.maybeOf(context);
    final reduceMotion =
        mediaQuery?.disableAnimations == true ||
        mediaQuery?.accessibleNavigation == true;
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (_reduceMotion) {
      _ambientController
        ..stop()
        ..value = 0.38;
      if (_isAnimating) _skipSequence();
    } else if (!_ambientController.isAnimating) {
      _ambientController.repeat();
    }
  }

  @override
  void dispose() {
    _sequenceGeneration++;
    _ambientController.dispose();
    _sequenceController.dispose();
    super.dispose();
  }

  List<_DemoCardData> _createResults(int count) {
    if (count == 1) return [_demoCards[_selectedRarity]!];
    return _tenPullRarities.map((rarity) => _demoCards[rarity]!).toList();
  }

  Future<void> _precacheCardArt() async {
    await Future.wait(
      GachaDemoRarity.values.map(
        (rarity) => precacheImage(
          AssetImage(rarity.assetPath),
          context,
          onError: (error, stackTrace) {
            // Generated art may be added after this interaction prototype.
            // The code-drawn fallback remains functional in the meantime.
          },
        ),
      ),
    );
  }

  _DemoCardData _strongestCard(List<_DemoCardData> cards) {
    return cards.reduce(
      (current, card) =>
          card.rarity.rank > current.rarity.rank ? card : current,
    );
  }

  Future<void> _startPull(int count) async {
    if (_isAnimating) return;
    HapticFeedback.selectionClick();
    final cards = _createResults(count);
    final strongest = _strongestCard(cards);
    final generation = ++_sequenceGeneration;

    if (_reduceMotion) {
      setState(() {
        _pullCount = count;
        _results = cards;
        _spotlightCard = strongest;
        _phase = _DemoPhase.results;
      });
      return;
    }

    setState(() {
      _pullCount = count;
      _results = cards;
      _spotlightCard = strongest;
      _phase = _DemoPhase.charging;
    });

    try {
      await _artPrecache;
      if (!mounted || generation != _sequenceGeneration) return;
      _sequenceController.duration = const Duration(milliseconds: 900);
      await _sequenceController.forward(from: 0).orCancel;
      if (!mounted || generation != _sequenceGeneration) return;

      if (strongest.rarity == GachaDemoRarity.ur) {
        HapticFeedback.heavyImpact();
        setState(() => _phase = _DemoPhase.urReveal);
        _sequenceController.duration = const Duration(milliseconds: 2400);
      } else {
        HapticFeedback.mediumImpact();
        setState(() => _phase = _DemoPhase.reveal);
        _sequenceController.duration = Duration(
          milliseconds: switch (strongest.rarity) {
            GachaDemoRarity.n => 700,
            GachaDemoRarity.sr => 1000,
            GachaDemoRarity.ssr => 1300,
            GachaDemoRarity.ur => 1800,
          },
        );
      }

      await _sequenceController.forward(from: 0).orCancel;
      if (!mounted || generation != _sequenceGeneration) return;
      setState(() => _phase = _DemoPhase.results);
    } on TickerCanceled {
      // Skip/dispose intentionally cancels the current visual timeline.
    }
  }

  void _skipSequence() {
    if (!_isAnimating) return;
    _sequenceGeneration++;
    _sequenceController.stop(canceled: true);
    if (!mounted) return;
    setState(() => _phase = _DemoPhase.results);
  }

  void _returnToLobby() {
    _sequenceGeneration++;
    _sequenceController.stop(canceled: true);
    setState(() {
      _phase = _DemoPhase.idle;
      _results = const [];
      _spotlightCard = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeRarity = _activeRarity;
    return Scaffold(
      key: GachaVisualDemoKeys.screen,
      backgroundColor: const Color(0xFF070815),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _DemoBackdrop(),
          ExcludeSemantics(
            child: IgnorePointer(
              child: RepaintBoundary(
                key: GachaVisualDemoKeys.particleLayer,
                child: CustomPaint(
                  painter: _SakuraParticlePainter(
                    animation: _ambientController,
                    color: activeRarity.glow,
                    intensity: _isAnimating ? 1.0 : 0.55,
                  ),
                ),
              ),
            ),
          ),
          ExcludeSemantics(
            excluding: _isAnimating,
            child: AnimatedSwitcher(
              duration: _reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              child: _phase == _DemoPhase.results
                  ? _buildResults(context)
                  : _buildLobby(context),
            ),
          ),
          if (_isAnimating) _buildSequenceOverlay(),
        ],
      ),
    );
  }

  Widget _buildLobby(BuildContext context) {
    return SafeArea(
      key: const ValueKey<String>('gacha-lobby-view'),
      child: Column(
        children: [
          _DemoHeader(
            title: '樱愿召唤',
            subtitle: '首批视觉样片',
            onBack: Navigator.canPop(context)
                ? () => Navigator.maybePop(context)
                : null,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const _GlassBadge(
                            key: GachaVisualDemoKeys.localModeBadge,
                            icon: Icons.science_outlined,
                            label: '本地演示 · 不扣樱花币',
                          ),
                          if (_reduceMotion) ...[
                            const SizedBox(width: 8),
                            const _GlassBadge(
                              key: GachaVisualDemoKeys.reducedMotionBadge,
                              icon: Icons.motion_photos_off_outlined,
                              label: '已简化动效',
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 14),
                      _PoolShowcase(
                        selectedCard: _demoCards[_selectedRarity]!,
                        animation: _ambientController,
                      ),
                      const SizedBox(height: 18),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '选择单抽演示级别',
                          style: TextStyle(
                            color: Color(0xFFDDE2FF),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: GachaDemoRarity.values.map((rarity) {
                          return Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                right: rarity == GachaDemoRarity.ur ? 0 : 8,
                              ),
                              child: _RarityChoice(
                                key: GachaVisualDemoKeys.rarity(rarity),
                                rarity: rarity,
                                selected: rarity == _selectedRarity,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _selectedRarity = rarity);
                                },
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                      const _PoolNotice(),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _PullButton(
                              key: GachaVisualDemoKeys.singlePullButton,
                              title: '单次召唤',
                              price: '500',
                              colors: const [
                                Color(0xFF8467ED),
                                Color(0xFF4F4CC9),
                              ],
                              onPressed: () => _startPull(1),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _PullButton(
                              key: GachaVisualDemoKeys.tenPullButton,
                              title: '十连召唤',
                              price: '4,500',
                              badge: '必看 UR 演出',
                              colors: const [
                                Color(0xFFFF68B5),
                                Color(0xFF8F48E8),
                              ],
                              onPressed: () => _startPull(10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final strongest = _strongestCard(_results);
    return SafeArea(
      key: GachaVisualDemoKeys.resultView,
      child: Column(
        children: [
          Semantics(
            container: true,
            liveRegion: true,
            label: '抽卡结果，最高稀有度 ${strongest.rarity.code}，${strongest.name}',
            child: const SizedBox.shrink(),
          ),
          _DemoHeader(
            title: _pullCount == 1 ? '召唤回应' : '十连结果',
            subtitle: '最高稀有度 ${strongest.rarity.code}',
            onBack: _returnToLobby,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                  child: _pullCount == 1
                      ? _SingleResult(card: _results.single)
                      : _TenPullResults(cards: _results),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: GachaVisualDemoKeys.returnButton,
                      onPressed: _returnToLobby,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.28),
                        ),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: const Text('返回卡池'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: GachaVisualDemoKeys.replayButton,
                      onPressed: () => _startPull(_pullCount),
                      style: FilledButton.styleFrom(
                        backgroundColor: strongest.rarity.glow,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: Text(_pullCount == 1 ? '再次单抽' : '再来十连'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSequenceOverlay() {
    return Positioned.fill(
      key: GachaVisualDemoKeys.animationStage,
      child: ColoredBox(
        color: const Color(0xFF03040D).withValues(alpha: 0.96),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _sequenceController,
                builder: (context, _) {
                  return switch (_phase) {
                    _DemoPhase.charging => _ChargingStage(
                      progress: _sequenceController.value,
                      rarity: _activeRarity,
                      pullCount: _pullCount,
                    ),
                    _DemoPhase.reveal => _RevealStage(
                      progress: _sequenceController.value,
                      card: _spotlightCard!,
                    ),
                    _DemoPhase.urReveal => _UrRevealStage(
                      key: GachaVisualDemoKeys.urRevealOverlay,
                      progress: _sequenceController.value,
                      card: _spotlightCard!,
                    ),
                    _ => const SizedBox.shrink(),
                  };
                },
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: TextButton.icon(
                    key: GachaVisualDemoKeys.skipButton,
                    onPressed: _skipSequence,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black.withValues(alpha: 0.3),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.fast_forward_rounded, size: 18),
                    label: const Text('跳过'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoBackdrop extends StatelessWidget {
  const _DemoBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.2, -0.65),
          radius: 1.25,
          colors: [Color(0xFF35255C), Color(0xFF111329), Color(0xFF060711)],
          stops: [0, 0.48, 1],
        ),
      ),
      child: CustomPaint(painter: _ConstellationPainter()),
    );
  }
}

class _DemoHeader extends StatelessWidget {
  const _DemoHeader({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          const SizedBox(width: 8),
          IconButton(
            tooltip: '返回',
            onPressed: onBack,
            color: Colors.white,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.56),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.local_florist_rounded,
                  color: Color(0xFFFF9AC5),
                  size: 16,
                ),
                SizedBox(width: 5),
                Text(
                  '∞',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassBadge extends StatelessWidget {
  const _GlassBadge({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFFFFB3D3)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PoolShowcase extends StatelessWidget {
  const _PoolShowcase({required this.selectedCard, required this.animation});

  final _DemoCardData selectedCard;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 250,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            selectedCard.rarity.glow.withValues(alpha: 0.34),
            const Color(0xFF15172E).withValues(alpha: 0.94),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: selectedCard.rarity.glow.withValues(alpha: 0.18),
            blurRadius: 34,
            spreadRadius: -8,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BannerOrnamentPainter(color: selectedCard.rarity.glow),
            ),
          ),
          Positioned(
            left: 20,
            top: 22,
            bottom: 22,
            width: 132,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) => _CardFace(
                key: const ValueKey<String>('gacha-preview-card'),
                card: selectedCard,
                shine: animation.value,
                compact: true,
              ),
            ),
          ),
          Positioned(
            left: 172,
            right: 18,
            top: 30,
            bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'SAKURA WISH',
                  style: TextStyle(
                    color: selectedCard.rarity.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.1,
                  ),
                ),
                const SizedBox(height: 8),
                const FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '万象星门',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '四档卡面与召唤演出实时预览',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: selectedCard.rarity.glow.withValues(alpha: 0.15),
                    border: Border.all(
                      color: selectedCard.rarity.accent.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    '${selectedCard.rarity.code} · ${selectedCard.rarity.label}特效',
                    style: TextStyle(
                      color: selectedCard.rarity.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RarityChoice extends StatelessWidget {
  const _RarityChoice({
    super.key,
    required this.rarity,
    required this.selected,
    required this.onTap,
  });

  final GachaDemoRarity rarity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${rarity.code} ${rarity.label}特效',
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: selected
                ? rarity.glow.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.055),
            border: Border.all(
              color: selected
                  ? rarity.accent.withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.1),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: rarity.glow.withValues(alpha: 0.24),
                      blurRadius: 15,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                rarity.code,
                style: TextStyle(
                  color: selected ? rarity.accent : Colors.white70,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                rarity.label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.48),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PoolNotice extends StatelessWidget {
  const _PoolNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.17),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            color: Color(0xFFFFD478),
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '十连固定包含四档样片，用于一次验收粒子、卡框与 UR 全屏节奏。',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 10,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PullButton extends StatelessWidget {
  const _PullButton({
    super.key,
    required this.title,
    required this.price,
    required this.colors,
    required this.onPressed,
    this.badge,
  });

  final String title;
  final String price;
  final List<Color> colors;
  final VoidCallback onPressed;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title，演示价格 $price 樱花币',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            height: 66,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
              boxShadow: [
                BoxShadow(
                  color: colors.last.withValues(alpha: 0.32),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.local_florist_rounded,
                            size: 13,
                            color: Color(0xFFFFD1E3),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            price,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (badge != null)
                  Positioned(
                    top: -8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFE8A8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          color: Color(0xFF5F2B67),
                          fontSize: 8,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChargingStage extends StatelessWidget {
  const _ChargingStage({
    required this.progress,
    required this.rarity,
    required this.pullCount,
  });

  final double progress;
  final GachaDemoRarity rarity;
  final int pullCount;

  @override
  Widget build(BuildContext context) {
    final eased = Curves.easeInOutCubic.transform(progress);
    final cardScale = 0.82 + math.sin(progress * math.pi) * 0.12;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _SummonGatePainter(
            progress: progress,
            color: rarity.glow,
            lineColor: rarity.accent,
          ),
        ),
        Center(
          child: Transform.scale(
            scale: cardScale,
            child: Transform.rotate(
              angle: math.sin(progress * math.pi * 2) * 0.025,
              child: _CardBack(
                width: 170,
                height: 248,
                glow: rarity.glow.withValues(alpha: 0.55 + 0.35 * eased),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, 0.76),
          child: Opacity(
            opacity: _interval(progress, 0, 0.35),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pullCount == 1 ? '愿望正在汇聚' : '十道愿望正在共鸣',
                  style: TextStyle(
                    color: rarity.accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'TOUCH THE STARS',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.36),
                    fontSize: 9,
                    letterSpacing: 3.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RevealStage extends StatelessWidget {
  const _RevealStage({required this.progress, required this.card});

  final double progress;
  final _DemoCardData card;

  @override
  Widget build(BuildContext context) {
    final appear = Curves.easeOutBack.transform(_interval(progress, 0.08, 0.7));
    final flash = math.sin(_interval(progress, 0, 0.38) * math.pi);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                card.rarity.glow.withValues(alpha: 0.36 * flash),
                const Color(0xFF070815),
              ],
            ),
          ),
        ),
        CustomPaint(
          painter: _BurstPainter(
            progress: progress,
            color: card.rarity.accent,
            rayCount: switch (card.rarity) {
              GachaDemoRarity.n => 10,
              GachaDemoRarity.sr => 18,
              GachaDemoRarity.ssr => 28,
              GachaDemoRarity.ur => 34,
            },
          ),
        ),
        Center(
          child: Opacity(
            opacity: _interval(progress, 0.04, 0.3),
            child: Transform.scale(
              scale: 0.72 + appear * 0.28,
              child: SizedBox(
                width: 228,
                height: 342,
                child: _CardFace(card: card, shine: progress),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, 0.83),
          child: Opacity(
            opacity: _interval(progress, 0.48, 0.78),
            child: _RarityRevealLabel(rarity: card.rarity),
          ),
        ),
      ],
    );
  }
}

class _UrRevealStage extends StatelessWidget {
  const _UrRevealStage({super.key, required this.progress, required this.card});

  final double progress;
  final _DemoCardData card;

  @override
  Widget build(BuildContext context) {
    final gate = Curves.easeOutCubic.transform(_interval(progress, 0.08, 0.5));
    final reveal = Curves.easeOutBack.transform(_interval(progress, 0.5, 0.82));
    final flash = 1 - (_interval(progress, 0.47, 0.58) - 0.5).abs() * 2;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: _interval(progress, 0.06, 0.25),
            child: CustomPaint(painter: _UrStarGatePainter(progress: gate)),
          ),
          if (progress < 0.36)
            Align(
              alignment: const Alignment(0, -0.72),
              child: Opacity(
                opacity: math.sin(_interval(progress, 0.05, 0.32) * math.pi),
                child: const Text(
                  '命 运 轨 迹 发 生 偏 转',
                  style: TextStyle(
                    color: Color(0xFFFFEEC3),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                ),
              ),
            ),
          if (progress >= 0.47)
            Center(
              child: Opacity(
                opacity: _interval(progress, 0.49, 0.58),
                child: Transform.scale(
                  scale: 0.5 + reveal * 0.5,
                  child: SizedBox(
                    width: 238,
                    height: 356,
                    child: _CardFace(card: card, shine: progress * 2.4),
                  ),
                ),
              ),
            ),
          IgnorePointer(
            child: ColoredBox(
              color: Colors.white.withValues(
                alpha: (flash.clamp(0.0, 1.0) * 0.86).toDouble(),
              ),
            ),
          ),
          if (progress > 0.62)
            Align(
              alignment: const Alignment(0, 0.84),
              child: Opacity(
                opacity: _interval(progress, 0.64, 0.84),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'U L T R A   R A R E',
                      style: TextStyle(
                        color: Color(0xFFFFF1B4),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4.5,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'UR · 万象回应',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RarityRevealLabel extends StatelessWidget {
  const _RarityRevealLabel({required this.rarity});

  final GachaDemoRarity rarity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: rarity.accent.withValues(alpha: 0.72)),
        color: rarity.glow.withValues(alpha: 0.18),
        boxShadow: [
          BoxShadow(color: rarity.glow.withValues(alpha: 0.32), blurRadius: 22),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
        child: Text(
          '${rarity.code} · ${rarity.label}降临',
          style: TextStyle(
            color: rarity.accent,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}

class _SingleResult extends StatelessWidget {
  const _SingleResult({required this.card});

  final _DemoCardData card;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '愿望已被听见',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${card.rarity.code} · ${card.rarity.label}卡片',
            style: TextStyle(
              color: card.rarity.accent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            key: GachaVisualDemoKeys.singleResultCard,
            width: 230,
            height: 345,
            child: _CardFace(card: card, shine: 0.72),
          ),
          const SizedBox(height: 15),
          Text(
            card.epithet,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.58),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _TenPullResults extends StatelessWidget {
  const _TenPullResults({required this.cards});

  final List<_DemoCardData> cards;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          '十愿同辉',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'N / SR / SSR / UR 四档视觉同时验收',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 560 ? 5 : 5;
              return GridView.builder(
                key: GachaVisualDemoKeys.tenResultGrid,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 4),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: 0.62,
                  crossAxisSpacing: 7,
                  mainAxisSpacing: 9,
                ),
                itemCount: cards.length,
                itemBuilder: (context, index) {
                  return _CardFace(
                    key: GachaVisualDemoKeys.resultCard(index),
                    card: cards[index],
                    shine: index / cards.length,
                    compact: true,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    super.key,
    required this.card,
    required this.shine,
    this.compact = false,
  });

  final _DemoCardData card;
  final double shine;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rarity = card.rarity;
    final borderWidth = switch (rarity) {
      GachaDemoRarity.n => 2.0,
      GachaDemoRarity.sr => 2.5,
      GachaDemoRarity.ssr => 3.0,
      GachaDemoRarity.ur => 3.5,
    };
    final shadowStrength = switch (rarity) {
      GachaDemoRarity.n => 0.12,
      GachaDemoRarity.sr => 0.3,
      GachaDemoRarity.ssr => 0.42,
      GachaDemoRarity.ur => 0.58,
    };

    return Semantics(
      image: true,
      excludeSemantics: true,
      label: '${rarity.code} 卡片 ${card.name}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: SweepGradient(
            transform: GradientRotation(shine * math.pi * 2),
            colors: rarity.frameColors,
          ),
          borderRadius: BorderRadius.circular(compact ? 13 : 18),
          boxShadow: [
            BoxShadow(
              color: rarity.glow.withValues(alpha: shadowStrength),
              blurRadius: compact ? 14 : 30,
              spreadRadius: rarity.rank >= 2 ? 1 : -2,
            ),
            if (rarity == GachaDemoRarity.ur)
              BoxShadow(
                color: const Color(0xFF67EFFF).withValues(alpha: 0.28),
                blurRadius: compact ? 10 : 25,
                offset: const Offset(-5, 2),
              ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(borderWidth),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 11 : 15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  rarity.assetPath,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      _CardArtFallback(rarity: rarity),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color(0x14000000),
                        Color(0xE6080913),
                      ],
                      stops: [0.42, 0.66, 1],
                    ),
                  ),
                ),
                if (rarity.rank >= 1)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Transform.translate(
                        offset: Offset((shine % 1) * 220 - 110, 0),
                        child: Transform.rotate(
                          angle: -0.28,
                          child: FractionallySizedBox(
                            widthFactor: rarity == GachaDemoRarity.ur
                                ? 0.34
                                : 0.2,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    rarity.accent.withValues(
                                      alpha: rarity == GachaDemoRarity.ur
                                          ? 0.46
                                          : 0.24,
                                    ),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: compact ? 6 : 10,
                  top: compact ? 6 : 10,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 5 : 8,
                      vertical: compact ? 2 : 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090A14).withValues(alpha: 0.68),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: rarity.accent.withValues(alpha: 0.68),
                      ),
                    ),
                    child: Text(
                      rarity.code,
                      style: TextStyle(
                        color: rarity.accent,
                        fontWeight: FontWeight.w900,
                        fontSize: compact ? 8 : 12,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
                if (rarity.rank >= 2)
                  Positioned(
                    right: compact ? 5 : 9,
                    top: compact ? 5 : 9,
                    child: Icon(
                      rarity == GachaDemoRarity.ur
                          ? Icons.blur_on_rounded
                          : Icons.auto_awesome_rounded,
                      color: rarity.accent,
                      size: compact ? 12 : 20,
                      shadows: [Shadow(color: rarity.glow, blurRadius: 8)],
                    ),
                  ),
                Positioned(
                  left: compact ? 7 : 12,
                  right: compact ? 7 : 12,
                  bottom: compact ? 7 : 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        card.name,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 8 : 15,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 6),
                          ],
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(height: 4),
                        Text(
                          card.epithet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardArtFallback extends StatelessWidget {
  const _CardArtFallback({required this.rarity});

  final GachaDemoRarity rarity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            rarity.glow.withValues(alpha: 0.92),
            const Color(0xFF17142D),
            const Color(0xFF080914),
          ],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.local_florist_rounded,
            color: rarity.accent.withValues(alpha: 0.2),
            size: 82,
          ),
          CustomPaint(
            size: const Size.square(160),
            painter: _FallbackSigilPainter(color: rarity.accent),
          ),
        ],
      ),
    );
  }
}

class _CardBack extends StatelessWidget {
  const _CardBack({
    required this.width,
    required this.height,
    required this.glow,
  });

  final double width;
  final double height;
  final Color glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const SweepGradient(
          colors: [
            Color(0xFFFFE8B0),
            Color(0xFFFF70D2),
            Color(0xFF6FE8FF),
            Color(0xFFFFE8B0),
          ],
        ),
        boxShadow: [BoxShadow(color: glow, blurRadius: 40, spreadRadius: 5)],
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          gradient: const RadialGradient(
            colors: [Color(0xFF524093), Color(0xFF17132E), Color(0xFF080914)],
          ),
          border: Border.all(color: Colors.white24),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(120),
              painter: _FallbackSigilPainter(color: const Color(0xFFFFD3E5)),
            ),
            const Icon(
              Icons.local_florist_rounded,
              color: Color(0xFFFFE4EE),
              size: 34,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConstellationPainter extends CustomPainter {
  const _ConstellationPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 0.7;
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.12);
    const points = [
      Offset(0.08, 0.16),
      Offset(0.23, 0.08),
      Offset(0.39, 0.19),
      Offset(0.67, 0.1),
      Offset(0.87, 0.22),
      Offset(0.72, 0.42),
      Offset(0.92, 0.61),
      Offset(0.58, 0.77),
      Offset(0.25, 0.72),
      Offset(0.09, 0.88),
    ];
    for (var i = 0; i < points.length; i++) {
      final point = Offset(
        points[i].dx * size.width,
        points[i].dy * size.height,
      );
      canvas.drawCircle(point, i.isEven ? 1.4 : 0.8, dot);
      if (i > 0) {
        final previous = Offset(
          points[i - 1].dx * size.width,
          points[i - 1].dy * size.height,
        );
        canvas.drawLine(previous, point, line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConstellationPainter oldDelegate) => false;
}

class _SakuraParticlePainter extends CustomPainter {
  _SakuraParticlePainter({
    required this.animation,
    required this.color,
    required this.intensity,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final count = (22 + 22 * intensity).round();
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final seed = _fract(i * 0.61803398875 + 0.17);
      final speed = 0.12 + (i % 7) * 0.014;
      final x = _fract(seed * 7.71 + t * (0.08 + (i % 5) * 0.018));
      final y = _fract(seed * 13.37 + t * speed);
      final position = Offset(
        x * size.width + math.sin((t + seed) * math.pi * 2) * 14,
        y * size.height,
      );
      final radius = 1.4 + (i % 4) * 0.65;
      final alpha = (0.16 + (i % 5) * 0.055) * intensity;
      paint.color = Color.lerp(
        const Color(0xFFFFD5E7),
        color,
        seed,
      )!.withValues(alpha: alpha.clamp(0.0, 0.62));
      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.rotate((seed + t) * math.pi * 2);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: radius * 1.15,
          height: radius * 2.25,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _SakuraParticlePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.intensity != intensity;
  }
}

class _BannerOrnamentPainter extends CustomPainter {
  const _BannerOrnamentPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.12);
    final center = Offset(size.width * 0.78, size.height * 0.34);
    for (var i = 0; i < 5; i++) {
      canvas.drawCircle(center, 34.0 + i * 18, paint);
    }
    for (var i = 0; i < 12; i++) {
      final angle = i * math.pi / 6;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * 28,
        center + Offset(math.cos(angle), math.sin(angle)) * 112,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BannerOrnamentPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _FallbackSigilPainter extends CustomPainter {
  const _FallbackSigilPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.38;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = color.withValues(alpha: 0.38);
    canvas.drawCircle(center, radius, paint);
    canvas.drawCircle(center, radius * 0.7, paint);
    final path = Path();
    for (var i = 0; i <= 10; i++) {
      final angle = -math.pi / 2 + i * math.pi * 4 / 10;
      final point = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FallbackSigilPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SummonGatePainter extends CustomPainter {
  const _SummonGatePainter({
    required this.progress,
    required this.color,
    required this.lineColor,
  });

  final double progress;
  final Color color;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.min(size.width, size.height) * 0.44;
    final reveal = Curves.easeOut.transform(_interval(progress, 0, 0.55));
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.34 * reveal),
          color.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));
    canvas.drawCircle(center, maxRadius, glowPaint);

    final ringPaint = Paint()..style = PaintingStyle.stroke;
    for (var ring = 0; ring < 4; ring++) {
      final radius = maxRadius * (0.44 + ring * 0.16) * reveal;
      ringPaint
        ..strokeWidth = ring.isEven ? 1.4 : 0.7
        ..color = Color.lerp(
          color,
          lineColor,
          ring / 4,
        )!.withValues(alpha: 0.24 + ring * 0.07);
      final start = progress * math.pi * (ring.isEven ? 2 : -2);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        math.pi * 1.52,
        false,
        ringPaint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start + math.pi,
        math.pi * 0.34,
        false,
        ringPaint,
      );
    }

    final rayPaint = Paint()
      ..strokeWidth = 0.9
      ..color = lineColor.withValues(alpha: 0.32 * reveal);
    for (var i = 0; i < 16; i++) {
      final angle = i * math.pi / 8 - progress * math.pi;
      final inner = center + Offset(math.cos(angle), math.sin(angle)) * 54;
      final outer =
          center + Offset(math.cos(angle), math.sin(angle)) * maxRadius * 0.9;
      canvas.drawLine(inner, outer, rayPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SummonGatePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.lineColor != lineColor;
}

class _BurstPainter extends CustomPainter {
  const _BurstPainter({
    required this.progress,
    required this.color,
    required this.rayCount,
  });

  final double progress;
  final Color color;
  final int rayCount;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final spread = Curves.easeOutCubic.transform(_interval(progress, 0, 0.72));
    final fade = 1 - _interval(progress, 0.6, 1);
    final maxRadius = math.max(size.width, size.height) * 0.58;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < rayCount; i++) {
      final angle = i * math.pi * 2 / rayCount + i * 0.13;
      final innerRadius = (42 + (i % 4) * 7).toDouble();
      final length = maxRadius * (0.42 + (i % 6) * 0.09) * spread;
      paint
        ..strokeWidth = 0.7 + (i % 3) * 0.65
        ..color = color.withValues(alpha: (0.12 + (i % 4) * 0.07) * fade);
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * innerRadius,
        center + Offset(math.cos(angle), math.sin(angle)) * length,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.rayCount != rayCount;
}

class _UrStarGatePainter extends CustomPainter {
  const _UrStarGatePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.48 * progress;
    final aura = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFF2B0).withValues(alpha: 0.42 * progress),
          const Color(0xFFFF58C8).withValues(alpha: 0.22 * progress),
          const Color(0xFF67EFFF).withValues(alpha: 0.06 * progress),
          Colors.transparent,
        ],
        stops: const [0, 0.32, 0.68, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.25));
    canvas.drawCircle(center, radius * 1.25, aura);

    const palette = [
      Color(0xFFFFF0B3),
      Color(0xFFFF63CB),
      Color(0xFF74E9FF),
      Color(0xFFB28BFF),
    ];
    final ringPaint = Paint()..style = PaintingStyle.stroke;
    for (var ring = 0; ring < 5; ring++) {
      ringPaint
        ..strokeWidth = ring == 0 ? 2.1 : 0.9
        ..color = palette[ring % palette.length].withValues(
          alpha: 0.48 - ring * 0.055,
        );
      final ringRadius = radius * (0.34 + ring * 0.14);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        progress * math.pi * (ring.isEven ? 2.8 : -2.1),
        math.pi * (1.18 + ring * 0.09),
        false,
        ringPaint,
      );
    }

    final pathPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..color = const Color(0xFFFFE8B1).withValues(alpha: 0.48);
    final path = Path();
    for (var i = 0; i <= 16; i++) {
      final outer = i.isEven;
      final angle = -math.pi / 2 + i * math.pi / 8 + progress * 0.9;
      final point =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              radius *
              (outer ? 0.91 : 0.36);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path, pathPaint);

    final rayPaint = Paint();
    for (var i = 0; i < 44; i++) {
      final angle = i * math.pi * 2 / 44 + progress * (i.isEven ? 1.4 : -0.7);
      final start = radius * (0.26 + (i % 5) * 0.08);
      final end = radius * (0.82 + (i % 4) * 0.08);
      rayPaint
        ..strokeWidth = i % 3 == 0 ? 1.6 : 0.7
        ..color = palette[i % palette.length].withValues(
          alpha: 0.16 + (i % 4) * 0.055,
        );
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * start,
        center + Offset(math.cos(angle), math.sin(angle)) * end,
        rayPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UrStarGatePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

double _fract(double value) => value - value.floorToDouble();

double _interval(double value, double start, double end) {
  if (end <= start) return value >= end ? 1 : 0;
  return ((value - start) / (end - start)).clamp(0.0, 1.0).toDouble();
}
