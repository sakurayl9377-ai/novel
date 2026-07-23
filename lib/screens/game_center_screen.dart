import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/app_tokens.dart';
import '../providers/interaction_auth_provider.dart';
import '../utils/auth_gate.dart';
import 'bailian_game_screen.dart';
import 'bailian_orders_screen.dart';
import 'horse_race_game_screen.dart';
import 'modao_game_screen.dart';

/// The home for the app's lightweight entertainment experiences.
class GameCenterScreen extends StatelessWidget {
  const GameCenterScreen({
    super.key,
    this.horseRaceDestinationBuilder,
    this.onHorseRaceTap,
    this.onBailianTap,
    this.onModaoTap,
  });

  static const Key scrollKey = ValueKey<String>('game-center-scroll');
  static const Key gridKey = ValueKey<String>('game-center-grid');
  static const Key horseRaceEntryKey = ValueKey<String>(
    'game-entry-horse-race',
  );
  static const Key bailianEntryKey = ValueKey<String>('game-entry-bailian');
  static const Key modaoEntryKey = ValueKey<String>('game-entry-modao');
  static const Key ordersEntryKey = ValueKey<String>('game-orders-entry');

  final WidgetBuilder? horseRaceDestinationBuilder;
  final VoidCallback? onHorseRaceTap;
  final VoidCallback? onBailianTap;
  final VoidCallback? onModaoTap;

  void _open(BuildContext context, WidgetBuilder builder) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
  }

  Future<void> _openBailian(BuildContext context) async {
    final allowed = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后进入游戏',
      message: '百练英雄使用小说 App 账号直接登录。',
    );
    if (!allowed || !context.mounted) return;
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) return;
    _open(context, (_) => BailianGameScreen(token: token));
  }

  Future<void> _openModao(BuildContext context) async {
    final allowed = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后进入游戏',
      message: '魔道修仙使用小说 App 账号直接登录。',
    );
    if (!allowed || !context.mounted) return;
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) return;
    _open(context, (_) => ModaoGameScreen(token: token));
  }

  Future<void> _openOrders(BuildContext context) async {
    final allowed = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后查看订单',
      message: '登录后可查看全部樱花币消费记录。',
    );
    if (!allowed || !context.mounted) return;
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) return;
    _open(context, (_) => BailianOrdersScreen(token: token));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C0D1A),
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '樱游阁',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2),
        ),
        actions: [
          IconButton(
            key: ordersEntryKey,
            tooltip: '我的订单',
            onPressed: () => _openOrders(context),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 720 ? 2 : 1;
          return CustomScrollView(
            key: scrollKey,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.spaceLg,
                  AppTokens.spaceSm,
                  AppTokens.spaceLg,
                  AppTokens.spaceLg,
                ),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: const _GameCenterHero(),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: _SectionTitle(),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                sliver: SliverLayoutBuilder(
                  builder: (context, sliverConstraints) {
                    final horizontalInset =
                        (sliverConstraints.crossAxisExtent - 1080) / 2;
                    return SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalInset > 0 ? horizontalInset : 0,
                      ),
                      sliver: SliverGrid(
                        key: gridKey,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: columns == 1 ? 218 : 236,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                        ),
                        delegate: SliverChildListDelegate.fixed([
                          _GameEntryCard(
                            key: horseRaceEntryKey,
                            eyebrow: '实时竞技',
                            title: '樱花赛马',
                            description: '挑选你的幸运赛马，在短局竞速中感受冲线时刻。',
                            actionLabel: '前往赛场',
                            icon: Icons.emoji_events_rounded,
                            colors: const [
                              Color(0xFF146B73),
                              Color(0xFF174D77),
                              Color(0xFF262E65),
                            ],
                            accent: const Color(0xFFFFD979),
                            onTap:
                                onHorseRaceTap ??
                                () => _open(
                                  context,
                                  horseRaceDestinationBuilder ??
                                      (_) => const HorseRaceGameScreen(),
                                ),
                          ),
                          _GameEntryCard(
                            key: bailianEntryKey,
                            eyebrow: '单点登录',
                            title: '百练英雄',
                            description: '养成英雄、挑战关卡，阅读任务奖励也将可同步到游戏。',
                            actionLabel: '进入游戏',
                            icon: Icons.shield_rounded,
                            colors: const [
                              Color(0xFF8A4B18),
                              Color(0xFF57361D),
                              Color(0xFF252239),
                            ],
                            accent: const Color(0xFFFFD27A),
                            onTap: onBailianTap ?? () => _openBailian(context),
                          ),
                          _GameEntryCard(
                            key: modaoEntryKey,
                            eyebrow: '玄幻冒险',
                            title: '魔道修仙',
                            description: '踏入修真世界，探索天地机缘，开启属于你的仙途。',
                            actionLabel: '查看游戏',
                            icon: Icons.forest_rounded,
                            colors: const [
                              Color(0xFF1F654E),
                              Color(0xFF29463F),
                              Color(0xFF24253A),
                            ],
                            accent: const Color(0xFF9BE2BE),
                            onTap: onModaoTap ?? () => _openModao(context),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GameCenterHero extends StatelessWidget {
  const _GameCenterHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 178,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        border: Border.all(color: const Color(0x40FF9BCB)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF30203D), Color(0xFF1A1931), Color(0xFF111526)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x332E102D),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _PetalPainter())),
          ),
          Positioned(
            right: -26,
            top: -42,
            child: Container(
              width: 150,
              height: 150,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x66FF7FBC), Color(0x00FF7FBC)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _HeroPill(),
                const Spacer(),
                const Text(
                  '赴一场樱色奇遇',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    height: 1.12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '收藏惊喜、实时竞技，找到今天的小小好运。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 13,
                    height: 1.35,
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

class _HeroPill extends StatelessWidget {
  const _HeroPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_florist_rounded, color: Color(0xFFFFA9D0), size: 14),
          SizedBox(width: 6),
          Text(
            'SAKURA PLAY',
            style: TextStyle(
              color: Color(0xFFFFD5E8),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '选择游戏',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: 3),
        Text(
          '每一次进入，都可能遇见新的惊喜',
          style: TextStyle(color: Color(0xFF9899AF), fontSize: 12),
        ),
      ],
    );
  }
}

class _GameEntryCard extends StatelessWidget {
  const _GameEntryCard({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.icon,
    required this.colors,
    required this.accent,
    required this.onTap,
  });

  final String eyebrow;
  final String title;
  final String description;
  final String actionLabel;
  final IconData icon;
  final List<Color> colors;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: '$title，$eyebrow',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
            border: Border.all(color: accent.withValues(alpha: 0.24)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
            splashColor: accent.withValues(alpha: 0.14),
            highlightColor: accent.withValues(alpha: 0.07),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  right: -18,
                  top: -22,
                  child: Icon(
                    icon,
                    size: 142,
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0x1FFFFFFF),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Icon(icon, color: accent, size: 24),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              eyebrow,
                              style: TextStyle(
                                color: accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            actionLabel,
                            style: TextStyle(
                              color: accent,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: accent,
                            size: 18,
                          ),
                        ],
                      ),
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

class _PetalPainter extends CustomPainter {
  const _PetalPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x36FFD0E5);
    final petals = <(Offset, double, double)>[
      (Offset(size.width * 0.62, 24), 6, -0.3),
      (Offset(size.width * 0.76, 72), 8, 0.5),
      (Offset(size.width * 0.87, 126), 5, -0.7),
      (Offset(size.width * 0.52, 144), 5, 0.8),
      (Offset(size.width * 0.94, 36), 7, 0.2),
    ];

    for (final (center, radius, rotation) in petals) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(rotation);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: radius * 1.25,
          height: radius * 2,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalPainter oldDelegate) => false;
}
