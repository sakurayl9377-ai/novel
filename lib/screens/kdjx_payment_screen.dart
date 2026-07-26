import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/interaction_auth_provider.dart';
import '../services/kdjx_game_service.dart';
import '../utils/auth_gate.dart';

class KdjxPaymentScreen extends StatefulWidget {
  const KdjxPaymentScreen({
    super.key,
    required this.request,
    required this.bridge,
    this.service,
  });

  static const Key confirmButtonKey = ValueKey<String>('kdjx-confirm-payment');
  static const Key returnButtonKey = ValueKey<String>('kdjx-return-game');

  final KdjxPaymentRequest request;
  final KdjxPaymentBridge bridge;
  final KdjxGameService? service;

  @override
  State<KdjxPaymentScreen> createState() => _KdjxPaymentScreenState();
}

class _KdjxPaymentScreenState extends State<KdjxPaymentScreen> {
  static const Duration _statusPollInterval = Duration(seconds: 2);
  static const Duration _statusPollWindow = Duration(minutes: 15);

  late final KdjxGameService _service;
  late final String _idempotencyKey;
  InteractionAuthProvider? _auth;
  KdjxPayment? _preview;
  KdjxPayment? _payment;
  bool _loading = true;
  bool _busy = false;
  bool _previewStarted = false;
  bool _loginFlowStarted = false;
  int _previewGeneration = 0;
  int? _previewUserId;
  String _previewToken = '';
  String _paymentToken = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? KdjxGameService();
    _idempotencyKey = _service.createPaymentIdempotencyKey(widget.request);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _auth = context.read<InteractionAuthProvider>()
        ..addListener(_authChanged);
      _authChanged();
    });
  }

  @override
  void dispose() {
    _auth?.removeListener(_authChanged);
    super.dispose();
  }

  void _authChanged() {
    final auth = _auth;
    if (auth == null || auth.isLoading || _loginFlowStarted) {
      return;
    }
    final currentUserId = auth.isLoggedIn ? auth.user?.id : null;
    final previewOwnerChanged =
        !_busy &&
        _payment == null &&
        _previewUserId != null &&
        (currentUserId != _previewUserId || auth.token != _previewToken);
    if (previewOwnerChanged) {
      _invalidatePreview();
    }
    if (_paymentToken.isNotEmpty && (_busy || _payment != null)) return;
    if (!auth.isLoggedIn || auth.token.isEmpty) {
      unawaited(_loginAndResumePayment());
      return;
    }
    if (_previewStarted || _payment != null) return;
    _previewStarted = true;
    unawaited(_loadPreview());
  }

  void _invalidatePreview() {
    _previewGeneration += 1;
    _previewStarted = false;
    _previewUserId = null;
    _previewToken = '';
    if (!mounted) return;
    setState(() {
      _preview = null;
      _loading = true;
      _error = null;
    });
  }

  Future<void> _loginAndResumePayment() async {
    if (_loginFlowStarted) return;
    _loginFlowStarted = true;
    final loggedIn = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后继续支付',
      message: '使用 Sakura 账号确认本次游戏订单。',
    );
    _loginFlowStarted = false;
    if (!mounted) return;
    if (!loggedIn) {
      setState(() {
        _loading = false;
        _error = '登录后可继续处理当前游戏订单';
      });
      return;
    }
    _previewStarted = true;
    await _loadPreview();
  }

  Future<void> _loadPreview() async {
    final auth = _auth;
    final user = auth?.user;
    final token = auth?.token ?? '';
    if (auth == null || !auth.isLoggedIn || user == null || token.isEmpty) {
      _previewStarted = false;
      return;
    }
    final generation = ++_previewGeneration;
    _previewUserId = user.id;
    _previewToken = token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await _service.previewPayment(token, widget.request);
      if (!_isCurrentPreviewOwner(generation, user.id, token)) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (!_isCurrentPreviewOwner(generation, user.id, token)) return;
      setState(() {
        _loading = false;
        _error = _messageFor(error);
      });
    }
  }

  bool _isCurrentPreviewOwner(int generation, int userId, String token) {
    final auth = _auth;
    return mounted &&
        generation == _previewGeneration &&
        auth?.isLoggedIn == true &&
        auth?.user?.id == userId &&
        auth?.token == token &&
        _previewUserId == userId &&
        _previewToken == token;
  }

  Future<void> _pay() async {
    final preview = _preview;
    final auth = _auth;
    if (_busy || preview == null || auth == null) return;
    if (auth.user?.id != _previewUserId ||
        auth.token.isEmpty ||
        auth.token != _previewToken) {
      _invalidatePreview();
      _authChanged();
      return;
    }
    final paymentToken = _previewToken;
    _paymentToken = paymentToken;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var payment = await _service.pay(
        paymentToken,
        widget.request,
        idempotencyKey: _idempotencyKey,
        expectedPreview: preview,
      );
      if (!mounted) return;
      setState(() => _payment = payment);
      await _pollUntilTerminal(payment, paymentToken);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _retryDelivery() async {
    if (_busy) return;
    final paymentToken = _paymentToken;
    if (paymentToken.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payment = await _service.retryDelivery(
        paymentToken,
        widget.request,
      );
      if (!mounted) return;
      setState(() => _payment = payment);
      await _pollUntilTerminal(payment, paymentToken);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _refreshStatus() async {
    if (_busy) return;
    final paymentToken = _paymentToken;
    if (paymentToken.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payment = await _service.paymentStatus(
        paymentToken,
        widget.request,
      );
      if (!mounted) return;
      setState(() => _payment = payment);
      await _pollUntilTerminal(payment, paymentToken);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _pollUntilTerminal(
    KdjxPayment initial,
    String paymentToken,
  ) async {
    var payment = initial;
    final deadline = DateTime.now().add(_statusPollWindow);
    while (mounted &&
        payment.awaitingDelivery &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_statusPollInterval);
      if (!mounted) return;
      try {
        payment = await _service.paymentStatus(paymentToken, widget.request);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = _messageFor(error);
        });
        return;
      }
      if (!mounted) return;
      setState(() => _payment = payment);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (payment.awaitingDelivery) {
        _error = '订单仍在处理中，请刷新状态确认最终结果';
      }
    });
  }

  Future<void> _returnToGame({bool cancelled = false}) async {
    if (_busy) return;
    if (_payment?.awaitingDelivery == true) {
      setState(() {
        _error = '订单仍在处理中，确认最终结果后才能返回游戏';
      });
      return;
    }
    final payment = _payment;
    final preview = _preview;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final launched = await widget.bridge.returnToGame(
        gameOrderId: widget.request.gameOrderId,
        status: cancelled ? 'cancelled' : payment?.status ?? 'pending',
        balance: payment?.balance ?? preview?.balance ?? 0,
        returnNonce: widget.request.returnNonce,
      );
      if (!launched) {
        throw const KdjxGameException('无法返回口袋觉醒，请手动打开游戏');
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  String _messageFor(Object error) =>
      error is KdjxGameException ? error.message : '支付操作失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _payment?.awaitingDelivery != true) {
          unawaited(_returnToGame(cancelled: _payment == null));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回游戏',
            onPressed: _busy || _payment?.awaitingDelivery == true
                ? null
                : () => _returnToGame(cancelled: _payment == null),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('确认支付'),
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: _body(),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _body() {
    final preview = _preview;
    final payment = _payment;
    if (preview == null) {
      return Column(
        children: [
          const SizedBox(height: 90),
          const Icon(Icons.lock_outline_rounded, size: 42),
          const SizedBox(height: 14),
          Text(_error ?? '支付信息加载失败', textAlign: TextAlign.center),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () {
              if (_auth?.isLoggedIn == true) {
                _previewStarted = true;
                unawaited(_loadPreview());
              } else {
                unawaited(_loginAndResumePayment());
              }
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.local_florist_rounded,
          color: Color(0xFFE75B9B),
          size: 42,
        ),
        const SizedBox(height: 14),
        Text(
          preview.productName,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          preview.displayPrice,
          key: const ValueKey<String>('kdjx-yuan-price'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: const Color(0xFFE34E58),
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 28),
        const _PaymentRow(label: '支付方式', value: '樱花币'),
        const Divider(height: 26),
        _PaymentRow(label: '本次扣除', value: '${preview.coinCost} 樱花币'),
        const Divider(height: 26),
        _PaymentRow(label: '当前余额', value: '${preview.balance} 樱花币'),
        if (payment != null) ...[
          const SizedBox(height: 26),
          _PaymentStatus(payment: payment),
        ],
        if (_error != null) ...[
          const SizedBox(height: 18),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        const SizedBox(height: 28),
        if (payment == null)
          FilledButton.icon(
            key: KdjxPaymentScreen.confirmButtonKey,
            onPressed: _busy || preview.balance < preview.coinCost
                ? null
                : _pay,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline_rounded),
            label: Text(
              preview.balance < preview.coinCost
                  ? '樱花币余额不足'
                  : '支付 ${preview.displayPrice}',
            ),
          )
        else if (payment.deliveryFailed && payment.canRetry)
          FilledButton.icon(
            onPressed: _busy ? null : _retryDelivery,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试发货'),
          )
        else if (payment.awaitingDelivery)
          FilledButton.icon(
            onPressed: _busy ? null : _refreshStatus,
            icon: const Icon(Icons.sync_rounded),
            label: const Text('刷新发货状态'),
          ),
        const SizedBox(height: 10),
        if (payment?.awaitingDelivery != true)
          OutlinedButton.icon(
            key: KdjxPaymentScreen.returnButtonKey,
            onPressed: _busy
                ? null
                : () => _returnToGame(cancelled: payment == null),
            icon: const Icon(Icons.sports_esports_rounded),
            label: Text(payment == null ? '取消并返回游戏' : '返回游戏'),
          ),
      ],
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _PaymentStatus extends StatelessWidget {
  const _PaymentStatus({required this.payment});

  final KdjxPayment payment;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, detail) = switch (payment.status) {
      'delivered' || 'fulfilled' || 'success' => (
        Icons.check_circle_rounded,
        const Color(0xFF2E9A67),
        '支付并发货成功',
        '余额 ${payment.balance} 樱花币',
      ),
      'delivery_failed' || 'failed' => (
        Icons.error_outline_rounded,
        Colors.redAccent,
        '已扣款，发货失败',
        payment.lastError.isEmpty ? '可重新发货，不会重复扣款' : payment.lastError,
      ),
      'refunded' => (
        Icons.currency_exchange_rounded,
        const Color(0xFF3876B8),
        '订单已退款',
        '余额 ${payment.balance} 樱花币',
      ),
      _ => (
        Icons.hourglass_top_rounded,
        const Color(0xFFB07920),
        '已提交，等待发货',
        '订单状态：${payment.status}',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
