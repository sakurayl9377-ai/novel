import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/growth_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/app_telemetry_service.dart';
import '../services/growth_service.dart';
import 'anime_detail_screen.dart';
import 'manga_detail_screen.dart';
import 'search_screen.dart';

class GrowthCenterScreen extends StatelessWidget {
  const GrowthCenterScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('发现中心'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '为你推荐'),
              Tab(text: '内容榜单'),
              Tab(text: '活动中心'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_RecommendationTab(), _RankingTab(), _ActivityTab()],
        ),
      ),
    );
  }
}

class _RecommendationTab extends StatefulWidget {
  const _RecommendationTab();

  @override
  State<_RecommendationTab> createState() => _RecommendationTabState();
}

class _RecommendationTabState extends State<_RecommendationTab>
    with AutomaticKeepAliveClientMixin {
  final GrowthService _service = GrowthService.instance;
  List<GrowthRecommendation> _items = const [];
  String _type = '';
  String _error = '';
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (mounted) setState(() => _loading = _items.isEmpty);
    final token = context.read<InteractionAuthProvider>().token;
    try {
      final items = await _service.fetchRecommendations(
        token: token,
        contentType: _type,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = '';
      });
      AppTelemetryService.instance.trackEvent(
        'growth_recommendations_view',
        screen: 'growth_center',
        metadata: {'contentType': _type, 'count': items.length},
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        _ContentTypeSelector(
          value: _type,
          onChanged: (value) {
            setState(() => _type = value);
            unawaited(_load());
          },
        ),
        Expanded(
          child: _loading
              ? const _LoadingState(label: '正在生成个性化推荐')
              : _items.isEmpty
              ? _EmptyState(
                  message: _error.isEmpty ? '暂时没有可推荐内容' : _error,
                  onRetry: () => unawaited(_load(forceRefresh: true)),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(forceRefresh: true),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _ContentCard(
                        content: item.content,
                        badge: item.continueProgress
                            ? '继续上次进度'
                            : '推荐 ${item.rank}',
                        description: item.reasons.isEmpty
                            ? '根据近期热度与内容质量推荐'
                            : item.reasons.take(2).join(' · '),
                        onTap: () => _openContent(
                          context,
                          item.content,
                          source: 'recommendation',
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _RankingTab extends StatefulWidget {
  const _RankingTab();

  @override
  State<_RankingTab> createState() => _RankingTabState();
}

class _RankingTabState extends State<_RankingTab>
    with AutomaticKeepAliveClientMixin {
  final GrowthService _service = GrowthService.instance;
  List<GrowthRankingItem> _items = const [];
  String _type = '';
  String _period = 'weekly';
  String _metric = 'hot';
  String _error = '';
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (mounted) setState(() => _loading = _items.isEmpty);
    try {
      final items = await _service.fetchRankings(
        token: context.read<InteractionAuthProvider>().token,
        period: _period,
        metric: _metric,
        contentType: _type,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        _ContentTypeSelector(
          value: _type,
          onChanged: (value) {
            setState(() => _type = value);
            unawaited(_load());
          },
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'daily', label: Text('日榜')),
                  ButtonSegment(value: 'weekly', label: Text('周榜')),
                ],
                selected: {_period},
                showSelectedIcon: false,
                onSelectionChanged: (value) {
                  setState(() => _period = value.first);
                  unawaited(_load());
                },
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _metric,
                items: const [
                  DropdownMenuItem(value: 'hot', child: Text('综合热度')),
                  DropdownMenuItem(value: 'new', child: Text('近期上新')),
                  DropdownMenuItem(value: 'following', child: Text('收藏趋势')),
                  DropdownMenuItem(value: 'completion', child: Text('完读完播')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _metric = value);
                  unawaited(_load());
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const _LoadingState(label: '榜单计算中')
              : _items.isEmpty
              ? _EmptyState(
                  message: _error.isEmpty ? '当前榜单暂无内容' : _error,
                  onRetry: () => unawaited(_load(forceRefresh: true)),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(forceRefresh: true),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _ContentCard(
                        content: item.content,
                        rank: item.rank,
                        badge: item.pinned
                            ? '运营精选'
                            : '热度 ${item.score.round()}',
                        description: item.explanation,
                        onTap: () => _openContent(
                          context,
                          item.content,
                          source: 'ranking',
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _ActivityTab extends StatefulWidget {
  const _ActivityTab();

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab>
    with AutomaticKeepAliveClientMixin {
  final GrowthService _service = GrowthService.instance;
  List<ActivityCampaign> _campaigns = const [];
  final Set<int> _claiming = {};
  String _error = '';
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (mounted) setState(() => _loading = _campaigns.isEmpty);
    try {
      final campaigns = await _service.fetchActivities(
        token: context.read<InteractionAuthProvider>().token,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _campaigns = campaigns;
        _loading = false;
        _error = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _claim(ActivityCampaign campaign, ActivityTask task) async {
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('登录后才能领取活动奖励')));
      return;
    }
    setState(() => _claiming.add(task.id));
    try {
      await _service.claimActivityTask(
        token: token,
        campaignId: campaign.id,
        taskId: task.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('领取成功：${task.rewardPoints} 积分、${task.rewardCoins} 樱花币'),
        ),
      );
      await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _claiming.remove(task.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const _LoadingState(label: '正在加载活动');
    if (_campaigns.isEmpty) {
      return _EmptyState(
        message: _error.isEmpty ? '当前没有进行中的活动' : _error,
        onRetry: () => unawaited(_load(forceRefresh: true)),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: _campaigns.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final campaign = _campaigns[index];
          return _CampaignCard(
            campaign: campaign,
            claiming: _claiming,
            onClaim: (task) => _claim(campaign, task),
          );
        },
      ),
    );
  }
}

class _ContentTypeSelector extends StatelessWidget {
  const _ContentTypeSelector({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: '', label: Text('全部')),
          ButtonSegment(value: 'novel', label: Text('小说')),
          ButtonSegment(value: 'manga', label: Text('漫画')),
          ButtonSegment(value: 'anime', label: Text('动漫')),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (values) => onChanged(values.first),
      ),
    );
  }
}

class _ContentCard extends StatelessWidget {
  const _ContentCard({
    required this.content,
    required this.badge,
    required this.description,
    required this.onTap,
    this.rank,
  });

  final GrowthContent content;
  final String badge;
  final String description;
  final VoidCallback onTap;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final rankValue = rank;
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (rankValue != null)
                SizedBox(
                  width: 34,
                  child: Text(
                    '$rankValue',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: rankValue <= 3
                          ? const Color(0xFFE59A18)
                          : AppTheme.textSecondary,
                      fontWeight: FontWeight.w900,
                      fontSize: rankValue <= 3 ? 22 : 16,
                    ),
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 68,
                  height: 92,
                  child: content.coverUrl.isEmpty
                      ? const ColoredBox(
                          color: Color(0xFFF2E8EC),
                          child: Icon(Icons.auto_stories_outlined),
                        )
                      : CachedNetworkImage(
                          imageUrl: content.coverUrl,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 120),
                          placeholder: (_, _) =>
                              const ColoredBox(color: Color(0xFFF2E8EC)),
                          errorWidget: (_, _, _) => const ColoredBox(
                            color: Color(0xFFF2E8EC),
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      content.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (content.author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        content.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: AppTheme.primaryColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _CampaignCard extends StatelessWidget {
  const _CampaignCard({
    required this.campaign,
    required this.claiming,
    required this.onClaim,
  });

  final ActivityCampaign campaign;
  final Set<int> claiming;
  final ValueChanged<ActivityTask> onClaim;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (campaign.bannerUrl.isNotEmpty)
            AspectRatio(
              aspectRatio: 3.2,
              child: CachedNetworkImage(
                imageUrl: campaign.bannerUrl,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const ColoredBox(
                  color: Color(0xFFFFEEF3),
                  child: Icon(Icons.celebration_outlined, size: 42),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  campaign.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (campaign.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    campaign.description,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final task in campaign.tasks)
            ListTile(
              title: Text(task.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (task.description.isNotEmpty) Text(task.description),
                  const SizedBox(height: 7),
                  LinearProgressIndicator(value: task.progress),
                  const SizedBox(height: 4),
                  Text(
                    '${task.progressCount}/${task.targetCount} · '
                    '${task.rewardPoints} 积分 + ${task.rewardCoins} 樱花币',
                  ),
                ],
              ),
              trailing: task.claimed
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : FilledButton.tonal(
                      onPressed: task.canClaim && !claiming.contains(task.id)
                          ? () => onClaim(task)
                          : null,
                      child: claiming.contains(task.id)
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(task.canClaim ? '领取' : '未完成'),
                    ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 46),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
          ),
        ],
      ),
    ),
  );
}

void _openContent(
  BuildContext context,
  GrowthContent content, {
  required String source,
}) {
  final token = context.read<InteractionAuthProvider>().token;
  unawaited(
    GrowthService.instance
        .recordBehavior(
          content: content,
          event: 'click',
          source: source,
          token: token,
        )
        .catchError((_) {}),
  );
  Widget? destination;
  switch (content.contentType) {
    case 'novel':
      destination = SearchScreen(
        initialKeyword: content.title,
        autofocus: false,
        autoOpenFirst: true,
      );
    case 'manga':
      if (content.sourceItemId.isNotEmpty) {
        destination = MangaDetailScreen(
          mangaId: content.sourceItemId,
          title: content.title,
        );
      }
    case 'anime':
      final id =
          int.tryParse(content.sourceItemId) ??
          int.tryParse(content.metadata['id']?.toString() ?? '') ??
          0;
      if (id > 0) {
        destination = AnimeDetailScreen(animeId: id, title: content.title);
      }
  }
  if (destination == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('该内容的来源信息不完整，暂时无法打开')));
    return;
  }
  Navigator.push(context, MaterialPageRoute(builder: (_) => destination!));
}
