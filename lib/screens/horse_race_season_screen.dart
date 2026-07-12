import 'dart:async';

import 'package:flutter/material.dart';

import '../models/growth_models.dart';
import '../services/growth_service.dart';

const _bg = Color(0xFF07111F);
const _surface = Color(0xFF101C2D);
const _raised = Color(0xFF17263A);
const _text = Color(0xFFF8FAFC);
const _muted = Color(0xFF94A3B8);
const _gold = Color(0xFFFBBF24);
const _blue = Color(0xFF38BDF8);

class HorseRaceSeasonScreen extends StatefulWidget {
  const HorseRaceSeasonScreen({super.key, required this.token});

  final String token;

  @override
  State<HorseRaceSeasonScreen> createState() => _HorseRaceSeasonScreenState();
}

class _HorseRaceSeasonScreenState extends State<HorseRaceSeasonScreen> {
  final GrowthService _service = GrowthService.instance;
  HorseRaceSeasonPayload? _payload;
  ResponsibleGamingSettings? _responsible;
  final Set<int> _claiming = {};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (mounted) setState(() => _loading = _payload == null);
    try {
      final values = await Future.wait<Object>([
        _service.fetchHorseRaceSeason(
          token: widget.token,
          forceRefresh: forceRefresh,
        ),
        _service.fetchResponsibleGaming(token: widget.token),
      ]);
      if (!mounted) return;
      setState(() {
        _payload = values[0] as HorseRaceSeasonPayload;
        _responsible = values[1] as ResponsibleGamingSettings;
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

  Future<void> _claim(HorseRaceSeasonTask task) async {
    setState(() => _claiming.add(task.id));
    try {
      await _service.claimHorseRaceSeasonTask(
        token: widget.token,
        taskId: task.id,
      );
      if (!mounted) return;
      _message('已领取 ${task.rewardPoints} 积分、${task.rewardCoins} 樱花币');
      await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _claiming.remove(task.id));
    }
  }

  Future<void> _editResponsibleSettings() async {
    final current = _responsible;
    if (current == null) return;
    final bet = TextEditingController(
      text: current.dailyBetLimit == 0 ? '' : '${current.dailyBetLimit}',
    );
    final loss = TextEditingController(
      text: current.dailyLossLimit == 0 ? '' : '${current.dailyLossLimit}',
    );
    final reminder = TextEditingController(
      text: '${current.reminderLossThreshold}',
    );
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('理性参与设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: bet,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '每日下注上限',
                  helperText: '留空或填 0 表示不额外限制',
                ),
              ),
              TextField(
                controller: loss,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '每日亏损上限',
                  helperText: '按尚未结算的最坏情况计算',
                ),
              ),
              TextField(
                controller: reminder,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '亏损提醒阈值'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save != true || !mounted) {
      bet.dispose();
      loss.dispose();
      reminder.dispose();
      return;
    }
    try {
      final next = await _service.updateResponsibleGaming(
        token: widget.token,
        dailyBetLimit: int.tryParse(bet.text.trim()) ?? 0,
        dailyLossLimit: int.tryParse(loss.text.trim()) ?? 0,
        reminderLossThreshold: int.tryParse(reminder.text.trim()) ?? 500,
      );
      if (mounted) setState(() => _responsible = next);
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      bet.dispose();
      loss.dispose();
      reminder.dispose();
    }
  }

  Future<void> _startCooldown() async {
    final hours = await _chooseDuration(
      title: '开启冷静期',
      description: '冷静期内无法下注，开启后不能提前结束。',
      choices: const {24: '24 小时', 72: '3 天', 168: '7 天'},
    );
    if (hours == null || !mounted) return;
    try {
      final next = await _service.startCooldown(
        token: widget.token,
        hours: hours,
      );
      if (mounted) setState(() => _responsible = next);
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  Future<void> _startSelfExclusion() async {
    final days = await _chooseDuration(
      title: '开启自我排除',
      description: '排除期内无法参与赛马下注，开启后不能提前结束。',
      choices: const {7: '7 天', 30: '30 天', 90: '90 天'},
    );
    if (days == null || !mounted) return;
    try {
      final next = await _service.startSelfExclusion(
        token: widget.token,
        days: days,
      );
      if (mounted) setState(() => _responsible = next);
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  Future<int?> _chooseDuration({
    required String title,
    required String description,
    required Map<int, String> choices,
  }) {
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description),
            const SizedBox(height: 12),
            for (final choice in choices.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(choice.value),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(dialogContext, choice.key),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        title: const Text('赛季与理性参与'),
        actions: [
          IconButton(
            onPressed: () => unawaited(_load(forceRefresh: true)),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _gold))
          : _payload == null
          ? _ErrorView(
              message: _error,
              onRetry: () => unawaited(_load(forceRefresh: true)),
            )
          : RefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                children: [
                  _SeasonHeader(payload: _payload!),
                  if (_payload!.tasks.isNotEmpty) ...[
                    const _SectionTitle('赛季任务'),
                    _TaskCard(
                      tasks: _payload!.tasks,
                      claiming: _claiming,
                      onClaim: _claim,
                    ),
                  ],
                  const _SectionTitle('赛季排行榜'),
                  _LeaderboardCard(payload: _payload!),
                  if (_payload!.rewards.isNotEmpty) ...[
                    const _SectionTitle('赛季奖励'),
                    _RewardCard(rewards: _payload!.rewards),
                  ],
                  const _SectionTitle('理性参与'),
                  _ResponsibleCard(
                    settings: _responsible,
                    onEdit: _editResponsibleSettings,
                    onCooldown: _startCooldown,
                    onSelfExclusion: _startSelfExclusion,
                  ),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(_error, style: const TextStyle(color: Colors.orange)),
                  ],
                ],
              ),
            ),
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({required this.payload});

  final HorseRaceSeasonPayload payload;

  @override
  Widget build(BuildContext context) {
    final season = payload.season;
    final mine = payload.myStats;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF503A13), _surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            season?.title ?? '暂无赛季',
            style: const TextStyle(
              color: _text,
              fontSize: 23,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            season == null
                ? '赛季开启后，参与比赛可获得积分与段位奖励。'
                : '${_statusLabel(season.status)} · 截止 ${_shortDate(season.endsAt)}',
            style: const TextStyle(color: _muted),
          ),
          if (mine != null) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 18,
              runSpacing: 10,
              children: [
                _Metric(label: '积分', value: '${mine.points}'),
                _Metric(label: '段位', value: _tierLabel(mine.tier)),
                _Metric(label: '参赛', value: '${mine.rounds}'),
                _Metric(label: '胜场', value: '${mine.wins}'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
      const SizedBox(height: 2),
      Text(
        value,
        style: const TextStyle(
          color: _text,
          fontWeight: FontWeight.w900,
          fontSize: 16,
        ),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 20, 2, 9),
    child: Text(
      title,
      style: const TextStyle(
        color: _text,
        fontSize: 17,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.tasks,
    required this.claiming,
    required this.onClaim,
  });

  final List<HorseRaceSeasonTask> tasks;
  final Set<int> claiming;
  final ValueChanged<HorseRaceSeasonTask> onClaim;

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      children: [
        for (var index = 0; index < tasks.length; index++) ...[
          _TaskTile(
            task: tasks[index],
            claiming: claiming.contains(tasks[index].id),
            onClaim: () => onClaim(tasks[index]),
          ),
          if (index != tasks.length - 1)
            const Divider(height: 1, color: Colors.white12),
        ],
      ],
    ),
  );
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.claiming,
    required this.onClaim,
  });

  final HorseRaceSeasonTask task;
  final bool claiming;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                style: const TextStyle(
                  color: _text,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: task.progress,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: _blue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${task.progressCount}/${task.targetCount} · '
                '${task.rewardPoints} 积分 + ${task.rewardCoins} 币',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (task.claimed)
          const Icon(Icons.check_circle, color: Colors.green)
        else
          FilledButton.tonal(
            onPressed: task.canClaim && !claiming ? onClaim : null,
            child: claiming
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(task.canClaim ? '领取' : '进行中'),
          ),
      ],
    ),
  );
}

class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({required this.payload});

  final HorseRaceSeasonPayload payload;

  @override
  Widget build(BuildContext context) {
    if (payload.leaderboard.isEmpty) {
      return const _Card(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text('赛季刚开始，暂时还没有排名。', style: TextStyle(color: _muted)),
        ),
      );
    }
    return _Card(
      child: Column(
        children: [
          for (var index = 0; index < payload.leaderboard.length; index++) ...[
            Builder(
              builder: (context) {
                final item = payload.leaderboard[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: item.rank <= 3 ? _gold : _raised,
                    foregroundColor: item.rank <= 3 ? _bg : _text,
                    child: Text('${item.rank}'),
                  ),
                  title: Text(
                    item.nickname,
                    style: const TextStyle(
                      color: _text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    '${_tierLabel(item.tier)} · ${item.wins} 胜 / ${item.rounds} 场',
                    style: const TextStyle(color: _muted),
                  ),
                  trailing: Text(
                    '${item.points} 分',
                    style: const TextStyle(
                      color: _gold,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                );
              },
            ),
            if (index != payload.leaderboard.length - 1)
              const Divider(height: 1, color: Colors.white12),
          ],
        ],
      ),
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({required this.rewards});

  final List<HorseRaceSeasonReward> rewards;

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      children: [
        for (final reward in rewards)
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined, color: _gold),
            title: Text(reward.title, style: const TextStyle(color: _text)),
            subtitle: Text(
              _rewardCondition(reward),
              style: const TextStyle(color: _muted),
            ),
            trailing: Text(
              '${reward.rewardPoints}分\n${reward.rewardCoins}币',
              textAlign: TextAlign.right,
              style: const TextStyle(color: _gold),
            ),
          ),
      ],
    ),
  );
}

class _ResponsibleCard extends StatelessWidget {
  const _ResponsibleCard({
    required this.settings,
    required this.onEdit,
    required this.onCooldown,
    required this.onSelfExclusion,
  });

  final ResponsibleGamingSettings? settings;
  final VoidCallback onEdit;
  final VoidCallback onCooldown;
  final VoidCallback onSelfExclusion;

  @override
  Widget build(BuildContext context) {
    final current = settings;
    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '赛马使用虚拟樱花币，也建议设定自己的参与边界。',
              style: TextStyle(color: _muted, height: 1.45),
            ),
            if (current != null) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _ValueChip(label: '今日下注', value: current.todayBet),
                  _ValueChip(label: '今日返还', value: current.todayPayout),
                  _ValueChip(label: '今日净支出', value: current.todayLoss),
                ],
              ),
              if (current.cooldownUntil.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '冷静期至 ${current.cooldownUntil}',
                  style: const TextStyle(color: Colors.orange),
                ),
              ],
              if (current.selfExcludedUntil.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '自我排除至 ${current.selfExcludedUntil}',
                  style: const TextStyle(color: Colors.orange),
                ),
              ],
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.tune),
                  label: const Text('每日限额'),
                ),
                OutlinedButton.icon(
                  onPressed: onCooldown,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('开启冷静期'),
                ),
                OutlinedButton.icon(
                  onPressed: onSelfExclusion,
                  icon: const Icon(Icons.block),
                  label: const Text('自我排除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text('$label $value', style: const TextStyle(color: _text)),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white12),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: _muted, size: 44),
          const SizedBox(height: 12),
          Text(
            message.isEmpty ? '赛季信息加载失败' : message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _text),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

String _statusLabel(String value) => switch (value) {
  'active' => '进行中',
  'paused' => '已暂停',
  'ended' => '已结束',
  _ => '准备中',
};

String _tierLabel(String value) => switch (value) {
  'silver' => '白银',
  'gold' => '黄金',
  'platinum' => '铂金',
  'diamond' => '钻石',
  'master' => '大师',
  _ => '青铜',
};

String _shortDate(String value) {
  final parsed = DateTime.tryParse(value.replaceFirst(' ', 'T'));
  if (parsed == null) return value.isEmpty ? '待定' : value;
  return '${parsed.month}月${parsed.day}日';
}

String _rewardCondition(HorseRaceSeasonReward reward) {
  if (reward.tier.isNotEmpty) return '${_tierLabel(reward.tier)}段位奖励';
  if (reward.minRank > 0 && reward.maxRank > 0) {
    return '第 ${reward.minRank}-${reward.maxRank} 名';
  }
  if (reward.minRank > 0) return '第 ${reward.minRank} 名起';
  return '赛季参与奖励';
}
