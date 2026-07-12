import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../app_tokens.dart';

class ImmersiveDetailMetric {
  const ImmersiveDetailMetric({required this.value, required this.label});

  final String value;
  final String label;
}

class ImmersiveDetailBadge {
  const ImmersiveDetailBadge({
    required this.label,
    required this.icon,
    this.color = Colors.white,
  });

  final String label;
  final IconData icon;
  final Color color;
}

class ImmersiveDetailHeader extends StatelessWidget {
  const ImmersiveDetailHeader({
    super.key,
    required this.cover,
    required this.title,
    required this.metrics,
    this.backdrop,
    this.subtitle = '',
    this.meta = '',
    this.badges = const [],
    this.gradientColors = const [Color(0xFF101827), Color(0xFF162033)],
  });

  static const double expandedHeight = 332;

  final Widget cover;
  final Widget? backdrop;
  final String title;
  final String subtitle;
  final String meta;
  final List<ImmersiveDetailBadge> badges;
  final List<ImmersiveDetailMetric> metrics;
  final List<Color> gradientColors;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradientColors,
            ),
          ),
        ),
        Positioned(
          right: -26,
          top: 58,
          bottom: 20,
          child: Opacity(
            opacity: 0.2,
            child: SizedBox(width: 176, child: backdrop ?? cover),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.08),
                  Colors.black.withValues(alpha: 0.24),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 74, 16, 96),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 106,
                  height: 148,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 20,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: cover,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          height: 1.12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          meta,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.76),
                            fontSize: 12,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (badges.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 26,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: badges.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, index) =>
                                _ImmersiveBadgeView(badge: badges[index]),
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
        if (metrics.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: ImmersiveDetailMetrics(metrics: metrics),
          ),
      ],
    );
  }
}

class ImmersiveDetailMetrics extends StatelessWidget {
  const ImmersiveDetailMetrics({super.key, required this.metrics});

  final List<ImmersiveDetailMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      decoration: BoxDecoration(
        color: AppTokens.cardColor(context),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusSm),
        ),
        boxShadow: Theme.of(context).brightness == Brightness.light
            ? const [
                BoxShadow(
                  color: Color(0x18000000),
                  blurRadius: 18,
                  offset: Offset(0, -2),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          for (final metric in metrics) _ImmersiveMetricView(metric: metric),
        ],
      ),
    );
  }
}

class _ImmersiveBadgeView extends StatelessWidget {
  const _ImmersiveBadgeView({required this.badge});

  final ImmersiveDetailBadge badge;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badge.icon, size: 14, color: badge.color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              badge.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                height: 1.1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImmersiveMetricView extends StatelessWidget {
  const _ImmersiveMetricView({required this.metric});

  final ImmersiveDetailMetric metric;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            metric.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTokens.primaryText(context),
              fontSize: 19,
              height: 1.1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            metric.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              height: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
