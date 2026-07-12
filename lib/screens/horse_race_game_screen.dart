import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_service.dart';
import '../services/app_telemetry_service.dart';
import 'horse_race_season_screen.dart';

const _raceBg = Color(0xFF07111F);
const _raceSurface = Color(0xFF101C2D);
const _raceRaised = Color(0xFF17263A);
const _raceOutline = Color(0x263B82F6);
const _raceText = Color(0xFFF8FAFC);
const _raceMuted = Color(0xFF94A3B8);
const _raceGold = Color(0xFFFBBF24);
const _raceGreen = Color(0xFF22C55E);
const _raceOrange = Color(0xFFF59E0B);
const _raceBlue = Color(0xFF38BDF8);
const _racePurple = Color(0xFFA78BFA);

class HorseRaceGameScreen extends StatefulWidget {
  const HorseRaceGameScreen({super.key});

  @override
  State<HorseRaceGameScreen> createState() => _HorseRaceGameScreenState();
}

class _HorseRaceGameScreenState extends State<HorseRaceGameScreen>
    with WidgetsBindingObserver {
  final InteractionService _service = InteractionService();
  final TextEditingController _amountController = TextEditingController(
    text: '100',
  );
  final TextEditingController _chatController = TextEditingController();
  final ValueNotifier<int> _serverClock = ValueNotifier<int>(
    DateTime.now().millisecondsSinceEpoch,
  );
  final ValueNotifier<int> _draftAmount = ValueNotifier<int>(100);
  final ValueNotifier<List<HorseRaceChatMessage>> _chatMessages =
      ValueNotifier<List<HorseRaceChatMessage>>(const []);
  final ValueNotifier<bool> _chatConnected = ValueNotifier<bool>(false);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _ticker;
  Timer? _reconnectTimer;
  HorseRaceState? _state;
  int? _selectedHorse;
  int _serverOffsetMs = 0;
  int _socketSerial = 0;
  int _chatUnreadCount = 0;
  int _pingTick = 0;
  int _lastHttpRefreshAt = 0;
  int _lastSocketMessageAt = 0;
  bool _loading = true;
  bool _refreshingState = false;
  bool _betting = false;
  bool _chatVisible = false;
  bool _socketReady = false;
  bool _chatSending = false;
  String _error = '';
  late final AppTelemetryScreenTrace _telemetryTrace;

  @override
  void initState() {
    super.initState();
    _telemetryTrace = AppTelemetryService.instance.openScreen('horse_race');
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
      _connect();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _serverClock.value =
          DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;
      _pingTick += 1;
      final state = _state;
      final phase = state?.phase;
      final fast = phase == 'racing' || phase == 'locked';
      final phaseRemaining = (state?.phaseEndsAt ?? 0) - _serverClock.value;
      final socketPingSeconds = phase == 'racing'
          ? 1
          : phase == 'locked'
          ? 2
          : 8;
      if (_pingTick % socketPingSeconds == 0 || phaseRemaining.abs() < 1800) {
        unawaited(_sendSocket({'type': 'ping'}));
      }
      final localNow = DateTime.now().millisecondsSinceEpoch;
      final refreshInterval = phase == 'racing'
          ? 1800
          : phase == 'locked'
          ? 2000
          : phase == 'settling'
          ? 3000
          : phase == 'betting'
          ? 10000
          : 15000;
      final nearBoundary =
          state != null && state.phaseEndsAt > 0 && phaseRemaining <= 1500;
      final socketStale =
          !_socketReady ||
          _lastSocketMessageAt == 0 ||
          localNow - _lastSocketMessageAt > (fast ? 3500 : 12000);
      if (state == null ||
          nearBoundary ||
          socketStale ||
          localNow - _lastHttpRefreshAt >= refreshInterval) {
        unawaited(_load(silent: true));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_load(silent: true));
    if (!_socketReady) _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_socketSub?.cancel());
    _channel?.sink.close();
    _amountController.dispose();
    _chatController.dispose();
    _serverClock.dispose();
    _draftAmount.dispose();
    _chatMessages.dispose();
    _chatConnected.dispose();
    _telemetryTrace.close(
      metadata: {
        'phase': _state?.phase ?? '',
        'socketReady': _socketReady,
        'betTotal': _state?.myBetTotal ?? 0,
      },
      success: _error.isEmpty,
    );
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshingState) return;
    final stopwatch = Stopwatch()..start();
    _refreshingState = true;
    _lastHttpRefreshAt = DateTime.now().millisecondsSinceEpoch;
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) {
      if (mounted && !silent) {
        setState(() {
          _loading = false;
          _error = '登录后才能进入樱花赛马';
        });
      }
      _refreshingState = false;
      return;
    }
    try {
      final state = await _service.fetchHorseRaceState(token: token);
      if (!mounted) return;
      _applyState(state);
      AppTelemetryService.instance.trackEvent(
        'race_state_sync',
        screen: 'horse_race',
        durationMs: stopwatch.elapsedMilliseconds,
        success: true,
        metadata: {'phase': state.phase, 'silent': silent},
      );
    } catch (error) {
      AppTelemetryService.instance.trackEvent(
        'race_state_sync',
        screen: 'horse_race',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {'silent': silent, 'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      if (!silent || _state == null) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    } finally {
      _refreshingState = false;
    }
  }

  void _applyState(HorseRaceState state) {
    final previousPhase = _state?.phase;
    final localNow = DateTime.now().millisecondsSinceEpoch;
    _serverOffsetMs = state.now > 0 ? state.now - localNow : 0;
    _serverClock.value = localNow + _serverOffsetMs;
    _chatMessages.value = state.recentChats;
    final selectedStillExists = state.horses.any(
      (horse) => horse.index == _selectedHorse,
    );
    setState(() {
      _state = state;
      _loading = false;
      _error = '';
      if (!selectedStillExists) _selectedHorse = null;
    });
    if (previousPhase != state.phase) {
      AppTelemetryService.instance.trackEvent(
        'race_phase',
        screen: 'horse_race',
        metadata: {'from': previousPhase ?? '', 'to': state.phase},
      );
    }
  }

  void _connect() {
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final serial = ++_socketSerial;
    _setSocketReady(false);
    unawaited(_socketSub?.cancel());
    final channel = _service.connectHorseRaceGame(token: token);
    _channel = channel;
    channel.ready
        .then((_) {
          if (!mounted || serial != _socketSerial) return;
          _setSocketReady(true);
          unawaited(_sendSocket({'type': 'ping'}));
        })
        .catchError((_) {
          if (!mounted || serial != _socketSerial) return;
          _setSocketReady(false);
          _reconnectLater();
        });
    _socketSub = channel.stream.listen(
      _handleSocketMessage,
      onError: (_) {
        _setSocketReady(false);
        _reconnectLater();
      },
      onDone: () {
        _setSocketReady(false);
        _reconnectLater();
      },
    );
  }

  void _setSocketReady(bool value) {
    final changed = _socketReady != value;
    _socketReady = value;
    _chatConnected.value = value;
    if (mounted) setState(() {});
    if (changed) {
      AppTelemetryService.instance.trackEvent(
        'race_socket_state',
        screen: 'horse_race',
        success: value,
        metadata: {'connected': value},
      );
    }
  }

  void _reconnectLater() {
    if (!mounted || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      unawaited(_socketSub?.cancel());
      _channel?.sink.close();
      _connect();
    });
  }

  void _handleSocketMessage(dynamic raw) {
    if (!mounted) return;
    _lastSocketMessageAt = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw.toString()) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = payload['type']?.toString() ?? '';
    if (type == 'horse_race_state') {
      final item = payload['item'];
      if (item is Map) {
        _applyState(HorseRaceState.fromJson(item.cast<String, dynamic>()));
      }
      return;
    }
    if (type == 'game_chat') {
      final item = payload['item'];
      if (item is! Map) return;
      final message = HorseRaceChatMessage.fromJson(
        item.cast<String, dynamic>(),
      );
      final next = [..._chatMessages.value, message];
      _chatMessages.value = next.length > 80
          ? next.sublist(next.length - 80)
          : next;
      if (!_chatVisible) {
        setState(() => _chatUnreadCount += 1);
      }
      return;
    }
    if (type == 'error') {
      _showMessage(payload['error']?.toString() ?? '游戏连接异常');
    }
  }

  Future<void> _placeBet() async {
    final state = _state;
    final selected = _selectedHorse;
    if (state == null || !state.isOpen) {
      _showMessage('赛场暂未开放');
      return;
    }
    if (state.phase != 'betting') {
      _showMessage('本轮已经封盘，请等待下一轮');
      return;
    }
    if (selected == null) {
      _showMessage('请先选择一匹赛马');
      return;
    }
    final amount = int.tryParse(_amountController.text.trim()) ?? 0;
    final horseBet = state.myBetOn(selected);
    final horseRemaining = state.betLimitPerHorse - horseBet;
    final roundRemaining = state.betLimitPerRound - state.myBetTotal;
    final maxAllowed = [
      horseRemaining,
      roundRemaining,
      state.myDailyRemaining,
      state.walletCoins,
    ].reduce((a, b) => a < b ? a : b);
    if (amount < state.minBet) {
      _showMessage('单次至少下注 ${state.minBet} 樱花币');
      return;
    }
    if (amount > maxAllowed) {
      _showMessage('本次最多还能下注 $maxAllowed 樱花币');
      return;
    }
    final token = context.read<InteractionAuthProvider>().token;
    if (amount >= 500 && !await _confirmLargeBet(amount)) return;
    if (!mounted) return;
    setState(() => _betting = true);
    final stopwatch = Stopwatch()..start();
    try {
      final next = await _service.placeHorseRaceBet(
        token: token,
        horseIndex: selected,
        amount: amount,
      );
      if (!mounted) return;
      _applyState(next);
      AppTelemetryService.instance.trackEvent(
        'race_bet',
        screen: 'horse_race',
        durationMs: stopwatch.elapsedMilliseconds,
        success: true,
        metadata: {
          'horseIndex': selected,
          'amountBucket': _betAmountBucket(amount),
        },
      );
      await HapticFeedback.mediumImpact();
      _showMessage(horseBet > 0 ? '追加下注成功' : '下注成功，祝你好运');
    } catch (error) {
      AppTelemetryService.instance.trackEvent(
        'race_bet',
        screen: 'horse_race',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {
          'horseIndex': selected,
          'amountBucket': _betAmountBucket(amount),
          'errorType': error.runtimeType.toString(),
        },
      );
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _betting = false);
    }
  }

  String _betAmountBucket(int amount) {
    if (amount < 100) return 'under_100';
    if (amount < 500) return '100_499';
    if (amount < 1000) return '500_999';
    return '1000_plus';
  }

  Future<bool> _confirmLargeBet(int amount) async {
    final horse = _selectedHorseItem;
    if (horse == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('确认大额下注'),
            content: Text('确认向 ${horse.name} 下注 $amount 樱花币？下注后不可撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('再想想'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认下注'),
              ),
            ],
          ),
        ) ??
        false;
  }

  HorseRaceHorse? get _selectedHorseItem {
    final state = _state;
    final selected = _selectedHorse;
    if (state == null || selected == null) return null;
    for (final horse in state.horses) {
      if (horse.index == selected) return horse;
    }
    return null;
  }

  void _setAmount(int amount) {
    final value = amount < 0 ? 0 : amount;
    _amountController.text = '$value';
    _amountController.selection = TextSelection.collapsed(
      offset: _amountController.text.length,
    );
    _draftAmount.value = value;
  }

  Future<void> _sendChat() async {
    final content = _chatController.text.trim();
    if (content.isEmpty || _chatSending) return;
    if (!_socketReady) {
      _reconnectLater();
      _showMessage('聊天正在重连，请稍后再发');
      return;
    }
    setState(() => _chatSending = true);
    final sent = await _sendSocket({
      'type': 'chat',
      'content': content,
    }, requireReady: true);
    if (!mounted) return;
    setState(() => _chatSending = false);
    if (sent) {
      _chatController.clear();
    } else {
      _showMessage('消息发送失败，正在重连');
    }
  }

  Future<bool> _sendSocket(
    Map<String, dynamic> payload, {
    bool requireReady = false,
  }) async {
    final channel = _channel;
    if (channel == null) {
      if (requireReady) _reconnectLater();
      return false;
    }
    if (requireReady && !_socketReady) {
      try {
        await channel.ready.timeout(const Duration(seconds: 2));
        _setSocketReady(true);
      } catch (_) {
        _reconnectLater();
        return false;
      }
    }
    try {
      channel.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      _reconnectLater();
      return false;
    }
  }

  Future<void> _openChat() async {
    setState(() {
      _chatVisible = true;
      _chatUnreadCount = 0;
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _raceSurface,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.76,
        child: _GameChatPanel(
          chats: _chatMessages,
          connected: _chatConnected,
          controller: _chatController,
          sending: _chatSending,
          onSend: _sendChat,
        ),
      ),
    );
    if (mounted) setState(() => _chatVisible = false);
  }

  Future<void> _openRules() {
    final rules = _state?.rules ?? const HorseRaceRules();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '赛马规则',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              _RuleLine(label: '下注阶段', value: '${rules.bettingSeconds} 秒'),
              _RuleLine(label: '封盘准备', value: '${rules.lockedSeconds} 秒'),
              _RuleLine(label: '比赛时间', value: '${rules.racingSeconds} 秒'),
              _RuleLine(label: '赛果展示', value: '${rules.resultSeconds} 秒'),
              _RuleLine(
                label: '返还系数',
                value: '${(rules.payoutRate * 100).round()}%',
              ),
              const SizedBox(height: 12),
              const Text(
                '赔率会随奖池热度变化，封盘后锁定；页面展示的是预计返还，最终以锁盘赔率为准。下注不可撤销，请理性参与。',
                style: TextStyle(height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSeason() {
    final token = context.read<InteractionAuthProvider>().token;
    if (token.isEmpty) {
      _showMessage('登录后才能查看赛季任务和理性参与设置');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HorseRaceSeasonScreen(token: token)),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      backgroundColor: _raceBg,
      appBar: AppBar(
        backgroundColor: _raceBg,
        foregroundColor: _raceText,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '樱花赛马',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            Text(
              state?.roundCode.isNotEmpty == true
                  ? '${state!.race.name} · ${state.roundCode}'
                  : '短局实时竞技场',
              style: const TextStyle(color: _raceMuted, fontSize: 11),
            ),
          ],
        ),
        actions: [
          _ConnectionChip(connected: _socketReady),
          if (state != null) _WalletChip(coins: state.walletCoins),
          IconButton(
            tooltip: '赛季与限额',
            onPressed: _openSeason,
            icon: const Icon(Icons.emoji_events_outlined),
          ),
          IconButton(
            tooltip: '规则',
            onPressed: _openRules,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final content = _RaceContent(
            state: state,
            loading: _loading,
            error: _error,
            clock: _serverClock,
            selectedHorse: _selectedHorse,
            onSelectHorse: (index) => setState(() => _selectedHorse = index),
            onRetry: () => unawaited(_load()),
          );
          if (!wide) return content;
          return Row(
            children: [
              Expanded(child: content),
              Container(
                width: 360,
                decoration: const BoxDecoration(
                  color: Color(0xFF0B1727),
                  border: Border(left: BorderSide(color: _raceOutline)),
                ),
                child: Column(
                  children: [
                    _BetTicket(
                      state: state,
                      selectedHorse: _selectedHorseItem,
                      amountController: _amountController,
                      amount: _draftAmount,
                      betting: _betting,
                      onAmountChanged: (value) {
                        _draftAmount.value = int.tryParse(value) ?? 0;
                      },
                      onQuickAmount: _setAmount,
                      onBet: _placeBet,
                    ),
                    const Divider(height: 1, color: _raceOutline),
                    Expanded(
                      child: _GameChatPanel(
                        chats: _chatMessages,
                        connected: _chatConnected,
                        controller: _chatController,
                        sending: _chatSending,
                        onSend: _sendChat,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width >= 900
          ? null
          : _BetTicket(
              state: state,
              selectedHorse: _selectedHorseItem,
              amountController: _amountController,
              amount: _draftAmount,
              betting: _betting,
              compact: true,
              onAmountChanged: (value) {
                _draftAmount.value = int.tryParse(value) ?? 0;
              },
              onQuickAmount: _setAmount,
              onBet: _placeBet,
            ),
      floatingActionButton: MediaQuery.sizeOf(context).width >= 900
          ? null
          : FloatingActionButton.extended(
              onPressed: _openChat,
              backgroundColor: _raceRaised,
              foregroundColor: _raceText,
              icon: const Icon(Icons.forum_rounded),
              label: Text(
                _chatUnreadCount > 0 ? '赛场 $_chatUnreadCount' : '赛场聊天',
              ),
            ),
    );
  }
}

class _RaceContent extends StatelessWidget {
  const _RaceContent({
    required this.state,
    required this.loading,
    required this.error,
    required this.clock,
    required this.selectedHorse,
    required this.onSelectHorse,
    required this.onRetry,
  });

  final HorseRaceState? state;
  final bool loading;
  final String error;
  final ValueListenable<int> clock;
  final int? selectedHorse;
  final ValueChanged<int> onSelectHorse;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading && state == null) {
      return const Center(child: CircularProgressIndicator(color: _raceGold));
    }
    if (state == null) {
      return _ErrorState(message: error, onRetry: onRetry);
    }
    final current = state!;
    return RefreshIndicator(
      onRefresh: () async => onRetry(),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 120),
            sliver: SliverList.list(
              children: [
                _PhaseOverview(state: current, clock: clock),
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _InlineNotice(message: error),
                ],
                const SizedBox(height: 12),
                _RaceMetaStrip(state: current),
                const SizedBox(height: 14),
                _PhaseBody(
                  state: current,
                  selectedHorse: selectedHorse,
                  onSelectHorse: onSelectHorse,
                ),
                if (current.myBets.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _MyTicketsCard(state: current),
                ],
                if (current.recentResults.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _RecentResultsCard(results: current.recentResults),
                ],
                if (current.myStats.totalBets > 0) ...[
                  const SizedBox(height: 14),
                  _StatsCard(stats: current.myStats),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseOverview extends StatelessWidget {
  const _PhaseOverview({required this.state, required this.clock});

  final HorseRaceState state;
  final ValueListenable<int> clock;

  @override
  Widget build(BuildContext context) {
    final phaseColor = _phaseColor(state.phase);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [phaseColor.withValues(alpha: 0.28), _raceSurface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: phaseColor.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _PhasePill(phase: state.phase),
              const Spacer(),
              Text(
                state.roundCode.isEmpty
                    ? '第 ${state.roundId} 轮'
                    : state.roundCode,
                style: const TextStyle(color: _raceMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ValueListenableBuilder<int>(
            valueListenable: clock,
            builder: (context, now, _) {
              final target = state.phase == 'closed'
                  ? state.nextOpenAt
                  : state.phaseEndsAt;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _countdown(target, now),
                    style: const TextStyle(
                      color: _raceText,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      _phaseCountdownLabel(state.phase),
                      style: TextStyle(
                        color: phaseColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            state.raceCommentary.isNotEmpty
                ? state.raceCommentary
                : _phaseDescription(state.phase),
            style: const TextStyle(color: _raceMuted, height: 1.45),
          ),
          const SizedBox(height: 16),
          _PhaseTimeline(phase: state.phase),
        ],
      ),
    );
  }
}

class _PhaseTimeline extends StatelessWidget {
  const _PhaseTimeline({required this.phase});

  final String phase;

  @override
  Widget build(BuildContext context) {
    const phases = ['betting', 'locked', 'racing', 'settling'];
    final active = phases.indexOf(phase);
    return Row(
      children: [
        for (var i = 0; i < phases.length; i++) ...[
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: i <= active
                        ? _phaseColor(phases[i])
                        : Colors.white12,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _phaseLabel(phases[i]),
                  style: TextStyle(
                    color: i == active ? _raceText : _raceMuted,
                    fontSize: 11,
                    fontWeight: i == active ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (i != phases.length - 1) const SizedBox(width: 7),
        ],
      ],
    );
  }
}

class _RaceMetaStrip extends StatelessWidget {
  const _RaceMetaStrip({required this.state});

  final HorseRaceState state;

  @override
  Widget build(BuildContext context) {
    final race = state.race;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _MetaChip(icon: Icons.place_rounded, label: race.venue),
        _MetaChip(
          icon: Icons.straighten_rounded,
          label: '${race.distanceMeters}m',
        ),
        _MetaChip(
          icon: Icons.grass_rounded,
          label: '场地 ${race.trackCondition}',
        ),
        _MetaChip(icon: Icons.wb_sunny_rounded, label: race.weather),
        _MetaChip(icon: Icons.savings_rounded, label: '奖池 ${state.poolTotal}'),
        _MetaChip(
          icon: Icons.groups_rounded,
          label: '${state.participantCount} 人参与',
        ),
      ],
    );
  }
}

class _PhaseBody extends StatelessWidget {
  const _PhaseBody({
    required this.state,
    required this.selectedHorse,
    required this.onSelectHorse,
  });

  final HorseRaceState state;
  final int? selectedHorse;
  final ValueChanged<int> onSelectHorse;

  @override
  Widget build(BuildContext context) {
    return switch (state.phase) {
      'racing' => _LiveRaceTrack(state: state),
      'settling' => _ResultStage(state: state),
      _ => _HorseGrid(
        state: state,
        selectedHorse: selectedHorse,
        onSelectHorse: onSelectHorse,
      ),
    };
  }
}

class _HorseGrid extends StatelessWidget {
  const _HorseGrid({
    required this.state,
    required this.selectedHorse,
    required this.onSelectHorse,
  });

  final HorseRaceState state;
  final int? selectedHorse;
  final ValueChanged<int> onSelectHorse;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '选择你的赛马',
                style: TextStyle(
                  color: _raceText,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              state.oddsLocked ? '赔率已锁定' : '赔率实时浮动',
              style: TextStyle(
                color: state.oddsLocked ? _raceOrange : _raceGreen,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: state.horses.length,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 390,
            mainAxisExtent: 188,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemBuilder: (context, index) {
            final horse = state.horses[index];
            return _HorseCard(
              horse: horse,
              myBet: state.myBetOn(horse.index),
              selected: selectedHorse == horse.index,
              readOnly: state.phase != 'betting',
              onTap: () => onSelectHorse(horse.index),
            );
          },
        ),
      ],
    );
  }
}

class _HorseCard extends StatelessWidget {
  const _HorseCard({
    required this.horse,
    required this.myBet,
    required this.selected,
    required this.readOnly,
    required this.onTap,
  });

  final HorseRaceHorse horse;
  final int myBet;
  final bool selected;
  final bool readOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(horse.color);
    return Material(
      color: selected ? color.withValues(alpha: 0.18) : _raceSurface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? color : Colors.white12,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  _HorseAvatar(horse: horse, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${horse.index + 1}号 ${horse.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _raceText,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            horse.style,
                            horse.specialty,
                          ].where((item) => item.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _raceMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _TrendBadge(trend: horse.oddsTrend),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  _HorseMetric(
                    label: '预计返还',
                    value: '${horse.returnPer100}/100',
                  ),
                  _HorseMetric(
                    label: '本轮状态',
                    value: horse.formRating > 0 ? '${horse.formRating}' : '--',
                  ),
                  _HorseMetric(
                    label: '热度',
                    value:
                        '${(horse.popularityShare * 100).toStringAsFixed(0)}%',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    horse.recentForm.isEmpty
                        ? '近况 --'
                        : '近况 ${horse.recentForm}',
                    style: const TextStyle(color: _raceMuted, fontSize: 11),
                  ),
                  const Spacer(),
                  if (myBet > 0)
                    Text(
                      '我的票 $myBet',
                      style: const TextStyle(
                        color: _raceGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  else
                    Text(
                      readOnly ? '未下注' : '点按选择',
                      style: TextStyle(
                        color: selected ? color : _raceMuted,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveRaceTrack extends StatelessWidget {
  const _LiveRaceTrack({required this.state});

  final HorseRaceState state;

  @override
  Widget build(BuildContext context) {
    final horses = [...state.horses]
      ..sort((a, b) => b.progress.compareTo(a.progress));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _raceSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _raceOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_rounded, color: _raceBlue),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '实时赛况',
                  style: TextStyle(
                    color: _raceText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (horses.isNotEmpty)
                Text(
                  '${horses.first.name} 暂时领跑',
                  style: const TextStyle(color: _raceGold, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 14),
          for (var rank = 0; rank < horses.length; rank++) ...[
            _RaceLane(
              horse: horses[rank],
              rank: rank + 1,
              highlighted: state.myBetOn(horses[rank].index) > 0,
            ),
            if (rank != horses.length - 1) const SizedBox(height: 7),
          ],
        ],
      ),
    );
  }
}

class _RaceLane extends StatelessWidget {
  const _RaceLane({
    required this.horse,
    required this.rank,
    required this.highlighted,
  });

  final HorseRaceHorse horse;
  final int rank;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(horse.color);
    return RepaintBoundary(
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: highlighted ? _raceGold.withValues(alpha: 0.08) : _raceRaised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted
                ? _raceGold.withValues(alpha: 0.55)
                : Colors.white10,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 82,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$rank · ${horse.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _raceText,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (highlighted)
                      const Text(
                        '我的赛马',
                        style: TextStyle(color: _raceGold, fontSize: 9),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: const _TrackPainter()),
                      ),
                      Positioned(right: 8, child: _FinishFlag(color: color)),
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                          end: horse.progress.clamp(0.02, 1),
                        ),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutCubic,
                        builder: (context, progress, child) {
                          final maxX = constraints.maxWidth - 48;
                          return Transform.translate(
                            offset: Offset(maxX * progress, 0),
                            child: child,
                          );
                        },
                        child: _HorseRunner(color: color),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultStage extends StatelessWidget {
  const _ResultStage({required this.state});

  final HorseRaceState state;

  @override
  Widget build(BuildContext context) {
    final winner = state.horses
        .where((h) => h.index == state.winnerIndex)
        .firstOrNull;
    final payout = state.myBets.fold<int>(0, (sum, bet) => sum + bet.payout);
    final net = payout - state.myBetTotal;
    final winnerColor = winner == null ? _raceGold : _parseColor(winner.color);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [winnerColor.withValues(alpha: 0.32), _raceSurface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: winnerColor.withValues(alpha: 0.55)),
      ),
      child: Column(
        children: [
          Icon(Icons.emoji_events_rounded, color: winnerColor, size: 54),
          const SizedBox(height: 8),
          Text(
            winner == null ? '本轮赛果' : '${winner.index + 1}号 ${winner.name} 获胜',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _raceText,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            winner == null
                ? '赛果正在确认'
                : '锁盘赔率 x${winner.odds.toStringAsFixed(2)}',
            style: const TextStyle(color: _raceMuted),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              _ResultMetric(label: '本轮下注', value: '${state.myBetTotal}'),
              _ResultMetric(label: '返还', value: '$payout'),
              _ResultMetric(
                label: '净变化',
                value: '${net >= 0 ? '+' : ''}$net',
                valueColor: net >= 0 ? _raceGreen : const Color(0xFFFB7185),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MyTicketsCard extends StatelessWidget {
  const _MyTicketsCard({required this.state});

  final HorseRaceState state;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '我的本轮票',
      trailing: Text(
        '合计 ${state.myBetTotal} · 预计返还 ${state.myPotentialPayout}',
        style: const TextStyle(color: _raceGold, fontSize: 11),
      ),
      child: Column(
        children: [
          for (final bet in state.myBets) ...[
            _BetRow(state: state, bet: bet),
            if (bet != state.myBets.last)
              const Divider(height: 16, color: Colors.white10),
          ],
        ],
      ),
    );
  }
}

class _BetRow extends StatelessWidget {
  const _BetRow({required this.state, required this.bet});

  final HorseRaceState state;
  final HorseRaceBet bet;

  @override
  Widget build(BuildContext context) {
    final horse = state.horses
        .where((h) => h.index == bet.horseIndex)
        .firstOrNull;
    final won = bet.status == 'won';
    final lost = bet.status == 'lost';
    return Row(
      children: [
        if (horse != null) _HorseAvatar(horse: horse, size: 36),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                horse == null ? '${bet.horseIndex + 1}号' : horse.name,
                style: const TextStyle(
                  color: _raceText,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '下注 ${bet.amount} · 赔率 x${bet.odds.toStringAsFixed(2)}',
                style: const TextStyle(color: _raceMuted, fontSize: 11),
              ),
            ],
          ),
        ),
        Text(
          won
              ? '+${bet.payout}'
              : lost
              ? '-${bet.amount}'
              : '预计 ${bet.estimatedPayout}',
          style: TextStyle(
            color: won
                ? _raceGreen
                : lost
                ? const Color(0xFFFB7185)
                : _raceGold,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _RecentResultsCard extends StatelessWidget {
  const _RecentResultsCard({required this.results});

  final List<HorseRaceResult> results;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '最近赛果',
      child: SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: results.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final result = results[index];
            final color = _parseColor(result.winnerColor);
            return Container(
              width: 170,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _raceRaised,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.roundCode,
                    style: const TextStyle(color: _raceMuted, fontSize: 10),
                  ),
                  const Spacer(),
                  Text(
                    '${result.winnerIndex + 1}号 ${result.winnerName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _raceText,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '赔率 x${result.odds.toStringAsFixed(2)} · 奖池 ${result.poolTotal}',
                    style: TextStyle(color: color, fontSize: 10),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});

  final HorseRaceStats stats;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '我的赛场数据',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _StatTile(label: '参与轮次', value: '${stats.roundsPlayed}'),
          _StatTile(
            label: '命中率',
            value: '${(stats.winRate * 100).toStringAsFixed(1)}%',
          ),
          _StatTile(label: '累计下注', value: '${stats.totalStaked}'),
          _StatTile(
            label: '历史盈亏',
            value: '${stats.netProfit >= 0 ? '+' : ''}${stats.netProfit}',
            color: stats.netProfit >= 0 ? _raceGreen : const Color(0xFFFB7185),
          ),
        ],
      ),
    );
  }
}

class _BetTicket extends StatelessWidget {
  const _BetTicket({
    required this.state,
    required this.selectedHorse,
    required this.amountController,
    required this.amount,
    required this.betting,
    required this.onAmountChanged,
    required this.onQuickAmount,
    required this.onBet,
    this.compact = false,
  });

  final HorseRaceState? state;
  final HorseRaceHorse? selectedHorse;
  final TextEditingController amountController;
  final ValueListenable<int> amount;
  final bool betting;
  final ValueChanged<String> onAmountChanged;
  final ValueChanged<int> onQuickAmount;
  final VoidCallback onBet;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = state;
    final horse = selectedHorse;
    final canBet = current?.phase == 'betting' && horse != null;
    final existingBet = horse == null ? 0 : current?.myBetOn(horse.index) ?? 0;
    return Material(
      color: const Color(0xFF0B1727),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, compact ? 10 : 14, 14, 12),
          child: ValueListenableBuilder<int>(
            valueListenable: amount,
            builder: (context, value, _) {
              final returnPer100 = horse?.returnPer100 ?? 0;
              final estimated = returnPer100 > 0
                  ? (value * returnPer100 / 100).floor()
                  : (value *
                            (horse?.odds ?? 0) *
                            (current?.rules.payoutRate ?? 0.82))
                        .floor();
              final horseRemaining = horse == null
                  ? 0
                  : (current?.betLimitPerHorse ?? 0) - existingBet;
              final roundRemaining =
                  (current?.betLimitPerRound ?? 0) - (current?.myBetTotal ?? 0);
              final maxAmount = [
                horseRemaining,
                roundRemaining,
                current?.myDailyRemaining ?? 0,
                current?.walletCoins ?? 0,
              ].reduce((a, b) => a < b ? a : b).clamp(0, 1 << 30);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (horse != null) _HorseAvatar(horse: horse, size: 38),
                      if (horse != null) const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              horse == null
                                  ? '请选择赛马'
                                  : '${horse.index + 1}号 ${horse.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _raceText,
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              horse == null
                                  ? '点选马匹后生成下注单'
                                  : '已投 $existingBet · 今日剩 ${current?.myDailyRemaining ?? 0} · 预计返还 $estimated',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _raceMuted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      for (final quick in [10, 50, 100, 300]) ...[
                        _QuickAmountChip(
                          value: quick,
                          selected: value == quick,
                          onTap: () => onQuickAmount(quick),
                        ),
                        const SizedBox(width: 6),
                      ],
                      _QuickAmountChip(
                        label: '最大',
                        value: maxAmount,
                        selected: value == maxAmount && maxAmount > 0,
                        onTap: () => onQuickAmount(maxAmount),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      SizedBox(
                        width: 92,
                        height: 44,
                        child: TextField(
                          controller: amountController,
                          onChanged: onAmountChanged,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          style: const TextStyle(
                            color: _raceText,
                            fontWeight: FontWeight.w800,
                          ),
                          decoration: InputDecoration(
                            hintText: '${current?.minBet ?? 10}',
                            filled: true,
                            fillColor: _raceRaised,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: FilledButton.icon(
                            onPressed: canBet && !betting && value > 0
                                ? onBet
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: _raceGold,
                              foregroundColor: const Color(0xFF111827),
                              disabledBackgroundColor: Colors.white12,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: betting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.local_activity_rounded),
                            label: Text(
                              current?.phase == 'betting'
                                  ? '${existingBet > 0 ? '追加' : '下注'} $value'
                                  : _phaseButtonLabel(current?.phase),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GameChatPanel extends StatelessWidget {
  const _GameChatPanel({
    required this.chats,
    required this.connected,
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final ValueListenable<List<HorseRaceChatMessage>> chats;
  final ValueListenable<bool> connected;
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(
            children: [
              const Icon(Icons.forum_rounded, color: _raceBlue, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '赛场聊天',
                  style: TextStyle(
                    color: _raceText,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: connected,
                builder: (context, value, _) => Text(
                  value ? '实时连接' : '重连中',
                  style: TextStyle(
                    color: value ? _raceGreen : _raceOrange,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          child: ValueListenableBuilder<List<HorseRaceChatMessage>>(
            valueListenable: chats,
            builder: (context, items, _) {
              if (items.isEmpty) {
                return const Center(
                  child: Text('还没有人发言', style: TextStyle(color: _raceMuted)),
                );
              }
              final reversed = items.reversed.toList();
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: reversed.length,
                itemBuilder: (context, index) {
                  final item = reversed[index];
                  if (item.isSystem) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        item.content,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _raceGold, fontSize: 11),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(color: _raceText, height: 1.35),
                        children: [
                          TextSpan(
                            text: '${item.user.nickname}  ',
                            style: const TextStyle(
                              color: _raceBlue,
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                            ),
                          ),
                          TextSpan(text: item.content),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            10 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 160,
                  style: const TextStyle(color: _raceText),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '聊聊本轮赛况…',
                    hintStyle: const TextStyle(color: _raceMuted),
                    filled: true,
                    fillColor: _raceRaised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _raceSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _raceOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _raceText,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _HorseAvatar extends StatelessWidget {
  const _HorseAvatar({required this.horse, required this.size});

  final HorseRaceHorse horse;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(horse.color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      alignment: Alignment.center,
      child: Text(
        '${horse.index + 1}',
        style: TextStyle(
          color: color,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _HorseRunner extends StatelessWidget {
  const _HorseRunner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 12),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.directions_run_rounded,
        color: Colors.white,
        size: 22,
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    for (double x = 18; x < size.width; x += 34) {
      canvas.drawLine(Offset(x, 8), Offset(x, size.height - 8), line);
    }
    final center = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset.zero.translate(0, size.height / 2),
      Offset(size.width, size.height / 2),
      center,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FinishFlag extends StatelessWidget {
  const _FinishFlag({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.flag_rounded, color: color, size: 20),
        Container(width: 2, height: 24, color: Colors.white54),
      ],
    );
  }
}

class _HorseMetric extends StatelessWidget {
  const _HorseMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _raceMuted, fontSize: 10)),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: _raceText,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendBadge extends StatelessWidget {
  const _TrendBadge({required this.trend});

  final String trend;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (trend) {
      'hot' => ('升温', _raceOrange),
      'cold' => ('冷门', _raceBlue),
      _ => ('稳定', _raceGreen),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _PhasePill extends StatelessWidget {
  const _PhasePill({required this.phase});

  final String phase;

  @override
  Widget build(BuildContext context) {
    final color = _phaseColor(phase);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        _phaseLabel(phase),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = connected ? _raceGreen : _raceOrange;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: connected ? '实时连接正常' : '正在重连',
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _WalletChip extends StatelessWidget {
  const _WalletChip({required this.coins});

  final int coins;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: _raceGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_florist_rounded, color: _raceGold, size: 15),
          const SizedBox(width: 4),
          Text(
            '$coins',
            style: const TextStyle(
              color: _raceGold,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: _raceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _raceMuted),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: _raceText, fontSize: 11)),
        ],
      ),
    );
  }
}

class _QuickAmountChip extends StatelessWidget {
  const _QuickAmountChip({
    required this.value,
    required this.selected,
    required this.onTap,
    this.label,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: value > 0 ? onTap : null,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _raceGold.withValues(alpha: 0.2) : _raceRaised,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? _raceGold : Colors.white10),
          ),
          child: Text(
            label ?? '$value',
            style: TextStyle(
              color: selected ? _raceGold : _raceText,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultMetric extends StatelessWidget {
  const _ResultMetric({
    required this.label,
    required this.value,
    this.valueColor = _raceText,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: _raceMuted, fontSize: 10)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.color = _raceText,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 138,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _raceRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _raceMuted, fontSize: 10)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleLine extends StatelessWidget {
  const _RuleLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: _raceOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _raceOrange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: _raceOrange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(color: _raceText)),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_score_rounded, color: _raceMuted, size: 54),
            const SizedBox(height: 12),
            Text(
              message.isEmpty ? '赛场加载失败' : message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _raceText),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}

Color _parseColor(String value) {
  final hex = value.replaceAll('#', '');
  return Color(int.tryParse('FF$hex', radix: 16) ?? 0xFF60A5FA);
}

Color _phaseColor(String phase) => switch (phase) {
  'betting' => _raceGreen,
  'locked' => _raceOrange,
  'racing' => _raceBlue,
  'settling' => _racePurple,
  _ => _raceMuted,
};

String _phaseLabel(String phase) => switch (phase) {
  'betting' => '下注',
  'locked' => '封盘',
  'racing' => '比赛',
  'settling' => '赛果',
  _ => '休场',
};

String _phaseDescription(String phase) => switch (phase) {
  'betting' => '查看马匹状态和奖池热度，选择赛马后提交你的本轮票。',
  'locked' => '赔率已经锁定，赛马正在进入闸门。',
  'racing' => '比赛进行中，赛道会根据实时状态平滑更新。',
  'settling' => '本轮已经结束，正在展示赛果和个人收益。',
  _ => '赛场休息中，可查看历史赛果和个人数据。',
};

String _phaseCountdownLabel(String phase) => switch (phase) {
  'betting' => '后封盘',
  'locked' => '后开赛',
  'racing' => '后冲线',
  'settling' => '后下一轮',
  _ => '后开放',
};

String _phaseButtonLabel(String? phase) => switch (phase) {
  'locked' => '已封盘',
  'racing' => '比赛中',
  'settling' => '等待下一轮',
  _ => '暂不可下注',
};

String _countdown(int targetMs, int nowMs) {
  if (targetMs <= 0) return '--:--';
  final seconds = ((targetMs - nowMs) / 1000).ceil().clamp(0, 24 * 60 * 60);
  final minutes = seconds ~/ 60;
  final remain = seconds % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    return '${hours.toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
}
