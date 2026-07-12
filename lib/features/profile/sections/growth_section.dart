part of '../profile_screen.dart';

class _LevelGrowthPath extends StatefulWidget {
  const _LevelGrowthPath({
    required this.rows,
    required this.currentLevel,
    required this.growth,
  });

  final List<UserLevelEffect> rows;
  final int currentLevel;
  final UserGrowth growth;

  @override
  State<_LevelGrowthPath> createState() => _LevelGrowthPathState();
}

class _LevelGrowthPathState extends State<_LevelGrowthPath>
    with SingleTickerProviderStateMixin {
  static const double _chartHeight = 124;
  static const double _labelZoneHeight = 48;
  static const double _minItemWidth = 80;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..repeat();
  final ScrollController _scroll = ScrollController();
  bool _autoCentered = false;

  @override
  void dispose() {
    _pulse.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<UserLevelEffect> _effectiveRows() {
    final source = widget.rows.length >= 2
        ? widget.rows
        : _levelPlanFor(widget.currentLevel);
    return source.take(7).toList(growable: false)
      ..sort((a, b) => a.level.compareTo(b.level));
  }

  // 用户成长值在整条路线上的位置（分段线性，0~1）。
  double _pathProgress(List<UserLevelEffect> rows) {
    final points = widget.growth.points;
    if (points >= rows.last.points) return 1;
    if (points <= rows.first.points) return 0;
    for (var i = rows.length - 2; i >= 0; i -= 1) {
      if (points >= rows[i].points) {
        final span = rows[i + 1].points - rows[i].points;
        final t = span <= 0 ? 1.0 : (points - rows[i].points) / span;
        return ((i + t) / (rows.length - 1)).clamp(0.0, 1.0).toDouble();
      }
    }
    return 0;
  }

  List<Offset> _nodeCenters(int count, double itemWidth) {
    const top = 40.0;
    const bottom = _chartHeight - 16.0;
    return List<Offset>.generate(count, (i) {
      final t = count <= 1 ? 1.0 : i / (count - 1);
      final lift = math.pow(t, 1.18).toDouble();
      return Offset(
        itemWidth * i + itemWidth / 2,
        bottom - (bottom - top) * lift,
      );
    });
  }

  void _centerCurrentLevel(double itemWidth, int index) {
    if (_autoCentered || !mounted || !_scroll.hasClients) return;
    _autoCentered = true;
    if (_scroll.position.maxScrollExtent <= 0) return;
    final viewport = _scroll.position.viewportDimension;
    final target = (itemWidth * index + itemWidth / 2 - viewport / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _effectiveRows();
    final currentStyle = _LevelVisualStyle.forLevel(widget.currentLevel);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(currentStyle.buttonColor, Colors.white, 0.92)!,
            Colors.white,
            Color.lerp(currentStyle.glowColor, Colors.white, 0.95)!,
          ],
          stops: const [0, 0.55, 1],
        ),
        borderRadius: BorderRadius.circular(_profileCardRadius),
        border: Border.all(
          color: currentStyle.buttonColor.withValues(alpha: 0.2),
        ),
        boxShadow: [
          BoxShadow(
            color: currentStyle.glowColor.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_profileCardRadius),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SakuraDecorPainter(
                    tint: currentStyle.buttonColor,
                    specs: _SakuraDecorPainter.growthSpecs,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = math.max(
                    _minItemWidth,
                    constraints.maxWidth / rows.length,
                  );
                  final contentWidth = itemWidth * rows.length;
                  final scrollable = contentWidth > constraints.maxWidth + 0.5;
                  final centers = _nodeCenters(rows.length, itemWidth);
                  final progress = _pathProgress(rows);
                  var currentIndex = rows.indexWhere(
                    (row) => row.level == widget.currentLevel,
                  );
                  if (currentIndex < 0) {
                    currentIndex = (widget.currentLevel - 1)
                        .clamp(0, rows.length - 1)
                        .toInt();
                  }
                  final anchorIndex = currentIndex;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _centerCurrentLevel(itemWidth, anchorIndex),
                  );
                  return SizedBox(
                    height: _chartHeight + _labelZoneHeight,
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          physics: scrollable
                              ? const BouncingScrollPhysics()
                              : const NeverScrollableScrollPhysics(),
                          child: SizedBox(
                            width: contentWidth,
                            height: _chartHeight + _labelZoneHeight,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  child: CustomPaint(
                                    size: Size(contentWidth, _chartHeight),
                                    painter: _GrowthPathPainter(
                                      nodes: centers,
                                      progress: progress,
                                      baseColor: const Color(0xFFE4EAF3),
                                      progressColors: [
                                        _LevelVisualStyle.forLevel(
                                          rows.first.level,
                                        ).buttonColor,
                                        currentStyle.buttonColor,
                                      ],
                                      fillColor: currentStyle.buttonColor,
                                      headColor: currentStyle.buttonColor,
                                    ),
                                  ),
                                ),
                                for (var i = 0; i < rows.length; i += 1)
                                  ..._buildNodeCluster(
                                    row: rows[i],
                                    center: centers[i],
                                    itemWidth: itemWidth,
                                    index: i,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (scrollable) ...const [
                          _EdgeFade(alignLeft: true),
                          _EdgeFade(alignLeft: false),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildNodeCluster({
    required UserLevelEffect row,
    required Offset center,
    required double itemWidth,
    required int index,
  }) {
    final style = _LevelVisualStyle.forLevel(row.level);
    final isCurrent = row.level == widget.currentLevel;
    final unlocked = widget.currentLevel >= row.level;
    final radius = isCurrent ? 16.0 : 12.0;
    return [
      Positioned(
        left: itemWidth * index,
        top: center.dy - radius - 22,
        width: itemWidth,
        child: Text(
          _formatThousands(row.points),
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: unlocked ? style.buttonColor : AppTheme.textHint,
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w800,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
      ),
      Positioned(
        left: center.dx - radius,
        top: center.dy - radius,
        child: _GrowthPathNode(
          style: style,
          unlocked: unlocked,
          isCurrent: isCurrent,
          radius: radius,
          pulse: _pulse,
        ),
      ),
      Positioned(
        left: itemWidth * index,
        top: _chartHeight + 4,
        width: itemWidth,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                gradient: isCurrent
                    ? LinearGradient(
                        colors: [
                          Color.lerp(style.buttonColor, Colors.white, 0.16)!,
                          style.buttonColor,
                        ],
                      )
                    : unlocked
                    ? LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          style.buttonColor.withValues(alpha: 0.16),
                          style.buttonColor.withValues(alpha: 0.08),
                        ],
                      )
                    : null,
                color: isCurrent || unlocked ? null : const Color(0xFFF1F4F8),
                borderRadius: BorderRadius.circular(999),
                border: isCurrent
                    ? null
                    : Border.all(
                        color: unlocked
                            ? style.buttonColor.withValues(alpha: 0.22)
                            : const Color(0xFFE2E8F0),
                      ),
                boxShadow: isCurrent
                    ? [
                        BoxShadow(
                          color: style.glowColor.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                'LV${row.level}',
                style: TextStyle(
                  color: isCurrent
                      ? Colors.white
                      : unlocked
                      ? style.buttonColor
                      : AppTheme.textHint,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  fontFamilyFallback: _profileFontFallback,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isCurrent
                    ? style.buttonColor
                    : unlocked
                    ? AppTheme.textSecondary
                    : AppTheme.textHint,
                fontSize: 11,
                height: 1.1,
                fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w500,
                fontFamilyFallback: _profileFontFallback,
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

class _GrowthPathNode extends StatelessWidget {
  const _GrowthPathNode({
    required this.style,
    required this.unlocked,
    required this.isCurrent,
    required this.radius,
    required this.pulse,
  });

  final _LevelVisualStyle style;
  final bool unlocked;
  final bool isCurrent;
  final double radius;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final core = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: unlocked
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(style.buttonColor, Colors.white, 0.22)!,
                  style.buttonColor,
                ],
              )
            : null,
        color: unlocked ? null : Colors.white,
        border: Border.all(
          color: unlocked ? Colors.white : const Color(0xFFD7DFEA),
          width: unlocked ? 2 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: unlocked
                ? style.glowColor.withValues(alpha: isCurrent ? 0.45 : 0.25)
                : const Color(0x14000000),
            blurRadius: isCurrent ? 12 : 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Icon(
        isCurrent
            ? Icons.star_rounded
            : unlocked
            ? Icons.check_rounded
            : Icons.lock_rounded,
        size: isCurrent ? 15 : 11,
        color: unlocked ? Colors.white : AppTheme.textHint,
      ),
    );
    if (!isCurrent) return core;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (context, _) {
              final t = pulse.value;
              return Container(
                width: size + 18 * t,
                height: size + 18 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: style.buttonColor.withValues(alpha: (1 - t) * 0.45),
                    width: 2,
                  ),
                ),
              );
            },
          ),
          core,
        ],
      ),
    );
  }
}

class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.alignLeft});

  final bool alignLeft;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: alignLeft ? 0 : null,
      right: alignLeft ? null : 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          width: 16,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
              end: alignLeft ? Alignment.centerRight : Alignment.centerLeft,
              colors: const [Color(0xE6FFFFFF), Color(0x00FFFFFF)],
            ),
          ),
        ),
      ),
    );
  }
}

class _GrowthPathPainter extends CustomPainter {
  const _GrowthPathPainter({
    required this.nodes,
    required this.progress,
    required this.baseColor,
    required this.progressColors,
    required this.fillColor,
    required this.headColor,
  });

  final List<Offset> nodes;
  final double progress;
  final Color baseColor;
  final List<Color> progressColors;
  final Color fillColor;
  final Color headColor;

  List<Offset> _segmentControls(int i) {
    final p0 = nodes[i == 0 ? 0 : i - 1];
    final p1 = nodes[i];
    final p2 = nodes[i + 1];
    final p3 = nodes[math.min(i + 2, nodes.length - 1)];
    return [p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.length < 2) return;

    final curve = Path()..moveTo(nodes.first.dx, nodes.first.dy);
    for (var i = 0; i < nodes.length - 1; i += 1) {
      final c = _segmentControls(i);
      curve.cubicTo(
        c[0].dx,
        c[0].dy,
        c[1].dx,
        c[1].dy,
        nodes[i + 1].dx,
        nodes[i + 1].dy,
      );
    }

    // 曲线下方的柔和渐变填充
    final baseline = size.height - 6;
    final area = Path.from(curve)
      ..lineTo(nodes.last.dx, baseline)
      ..lineTo(nodes.first.dx, baseline)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            fillColor.withValues(alpha: 0.16),
            fillColor.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );

    // 全程底线
    canvas.drawPath(
      curve,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = baseColor,
    );

    // 已完成进度（柔光底衬 + 渐变高亮）
    final segCount = nodes.length - 1;
    final scaled = progress.clamp(0.0, 1.0).toDouble() * segCount;
    var fullSegments = scaled.floor();
    var t = scaled - fullSegments;
    if (fullSegments >= segCount) {
      fullSegments = segCount;
      t = 0;
    }

    Offset? head;
    if (fullSegments > 0 || t > 0) {
      final progressPath = Path()..moveTo(nodes.first.dx, nodes.first.dy);
      for (var i = 0; i < fullSegments; i += 1) {
        final c = _segmentControls(i);
        progressPath.cubicTo(
          c[0].dx,
          c[0].dy,
          c[1].dx,
          c[1].dy,
          nodes[i + 1].dx,
          nodes[i + 1].dy,
        );
      }
      if (t > 0 && fullSegments < segCount) {
        final c = _segmentControls(fullSegments);
        final segment = Path()
          ..moveTo(nodes[fullSegments].dx, nodes[fullSegments].dy)
          ..cubicTo(
            c[0].dx,
            c[0].dy,
            c[1].dx,
            c[1].dy,
            nodes[fullSegments + 1].dx,
            nodes[fullSegments + 1].dy,
          );
        final metric = segment.computeMetrics().first;
        final cut = metric.length * t;
        progressPath.addPath(metric.extractPath(0, cut), Offset.zero);
        head = metric.getTangentForOffset(cut)?.position;
      } else if (fullSegments > 0 && fullSegments < segCount) {
        head = nodes[fullSegments];
      }
      canvas.drawPath(
        progressPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round
          ..color = progressColors.last.withValues(alpha: 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawPath(
        progressPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..shader = LinearGradient(
            colors: progressColors,
          ).createShader(Offset.zero & size),
      );
    }

    // 当前成长值所在位置的指示点
    if (head != null) {
      canvas.drawCircle(
        head,
        10,
        Paint()
          ..color = headColor.withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(head, 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        head,
        5.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = headColor,
      );
    }
  }

  @override
  bool shouldRepaint(_GrowthPathPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.headColor != headColor ||
        !listEquals(oldDelegate.nodes, nodes) ||
        !listEquals(oldDelegate.progressColors, progressColors);
  }
}

class _PetalSpec {
  const _PetalSpec(
    this.dx,
    this.dy,
    this.size,
    this.rotation,
    this.alpha, {
    this.blossom = false,
    this.pink = true,
  });

  final double dx;
  final double dy;
  final double size;
  final double rotation;
  final double alpha;
  final bool blossom;
  final bool pink;
}

// 樱花花瓣 + 星点 + 角落柔光的装饰背景。
class _SakuraDecorPainter extends CustomPainter {
  const _SakuraDecorPainter({required this.tint, required this.specs});

  final Color tint;
  final List<_PetalSpec> specs;

  static const Color _pink = Color(0xFFFF8FB1);

  static const List<_PetalSpec> growthSpecs = [
    _PetalSpec(0.90, 0.14, 9, 0.5, 0.30, blossom: true),
    _PetalSpec(0.70, 0.62, 5, 1.9, 0.15),
    _PetalSpec(0.30, 0.20, 6, 2.6, 0.14),
    _PetalSpec(0.11, 0.55, 5, 0.9, 0.17),
    _PetalSpec(0.52, 0.08, 4, 1.2, 0.12),
    _PetalSpec(0.965, 0.58, 6, 2.2, 0.16, pink: false),
    _PetalSpec(0.43, 0.80, 4, 2.9, 0.12, pink: false),
  ];

  static const List<_PetalSpec> cardSpecs = [
    _PetalSpec(0.94, 0.10, 8, 0.6, 0.26, blossom: true),
    _PetalSpec(0.79, 0.24, 5, 2.0, 0.13),
    _PetalSpec(0.09, 0.90, 5, 1.1, 0.13),
    _PetalSpec(0.57, 0.05, 4, 2.8, 0.10, pink: false),
    _PetalSpec(0.97, 0.52, 5, 1.6, 0.12),
  ];

  static const List<Offset> _sparkles = [
    Offset(0.22, 0.13),
    Offset(0.64, 0.30),
    Offset(0.87, 0.80),
    Offset(0.06, 0.24),
  ];

  Path _petalPath(double s) {
    return Path()
      ..moveTo(0, -s)
      ..cubicTo(s * 0.55, -s * 0.55, s * 0.5, s * 0.25, 0, s * 0.55)
      ..cubicTo(-s * 0.5, s * 0.25, -s * 0.55, -s * 0.55, 0, -s)
      ..close();
  }

  void _drawBlossom(Canvas canvas, double s, Paint paint) {
    for (var i = 0; i < 5; i += 1) {
      canvas.save();
      canvas.rotate(i * 2 * math.pi / 5);
      canvas.translate(0, -s * 0.9);
      canvas.drawPath(_petalPath(s), paint);
      canvas.restore();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      Offset(size.width * 0.92, size.height * 0.08),
      56,
      Paint()
        ..color = tint.withValues(alpha: 0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );
    canvas.drawCircle(
      Offset(size.width * 0.05, size.height * 0.92),
      48,
      Paint()
        ..color = _pink.withValues(alpha: 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28),
    );

    final sparklePaint = Paint()..color = tint.withValues(alpha: 0.22);
    for (final spot in _sparkles) {
      canvas.drawCircle(
        Offset(size.width * spot.dx, size.height * spot.dy),
        1.8,
        sparklePaint,
      );
    }

    for (final spec in specs) {
      final paint = Paint()
        ..color = (spec.pink ? _pink : tint).withValues(alpha: spec.alpha);
      canvas.save();
      canvas.translate(size.width * spec.dx, size.height * spec.dy);
      canvas.rotate(spec.rotation);
      if (spec.blossom) {
        _drawBlossom(canvas, spec.size, paint);
        canvas.drawCircle(
          Offset.zero,
          spec.size * 0.28,
          Paint()..color = Colors.white.withValues(alpha: spec.alpha * 0.9),
        );
      } else {
        canvas.drawPath(_petalPath(spec.size), paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SakuraDecorPainter oldDelegate) {
    return oldDelegate.tint != tint || !identical(oldDelegate.specs, specs);
  }
}
