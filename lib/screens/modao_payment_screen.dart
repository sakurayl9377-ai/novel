import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/interaction_auth_provider.dart';
import '../services/modao_game_service.dart';
import '../utils/auth_gate.dart';

class ModaoPaymentScreen extends StatefulWidget {
  const ModaoPaymentScreen({
    super.key,
    required this.request,
    required this.bridge,
    this.service,
  });

  final ModaoPaymentRequest request;
  final ModaoPaymentBridge bridge;
  final ModaoGameService? service;

  @override
  State<ModaoPaymentScreen> createState() => _ModaoPaymentScreenState();
}

class _ModaoPaymentScreenState extends State<ModaoPaymentScreen> {
  late final ModaoGameService _service;
  late final String _idempotencyKey;
  InteractionAuthProvider? _auth;
  ModaoPayment? _preview;
  ModaoPayment? _payment;
  bool _loading = true;
  bool _busy = false;
  bool _previewStarted = false;
  bool _loginFlowStarted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ModaoGameService();
    _idempotencyKey = _service.createPaymentIdempotencyKey();
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
    if (auth == null ||
        auth.isLoading ||
        _previewStarted ||
        _loginFlowStarted) {
      return;
    }
    if (!auth.isLoggedIn || auth.token.isEmpty) {
      unawaited(_loginAndResumePayment());
      return;
    }
    _previewStarted = true;
    unawaited(_loadPreview());
  }

  Future<void> _loginAndResumePayment() async {
    if (_loginFlowStarted) return;
    _loginFlowStarted = true;
    final loggedIn = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后继续支付',
      message: '使用小说 App 账号确认本次樱花币支付。',
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
    final token = _auth?.token ?? '';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await _service.previewPayment(token, widget.request);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _pay() async {
    if (_busy || _preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var payment = await _service.pay(
        _auth?.token ?? '',
        widget.request,
        idempotencyKey: _idempotencyKey,
      );
      if (!mounted) return;
      setState(() => _payment = payment);
      for (
        var attempt = 0;
        attempt < 3 && payment.awaitingDelivery;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        payment = await _service.paymentStatus(
          _auth?.token ?? '',
          widget.request,
        );
        if (!mounted) return;
        setState(() => _payment = payment);
      }
      if (mounted) setState(() => _busy = false);
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payment = await _service.retryDelivery(
        _auth?.token ?? '',
        widget.request,
      );
      if (!mounted) return;
      setState(() {
        _payment = payment;
        _busy = false;
      });
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payment = await _service.paymentStatus(
        _auth?.token ?? '',
        widget.request,
      );
      if (!mounted) return;
      setState(() {
        _payment = payment;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _returnToGame({bool cancelled = false}) async {
    if (_busy) return;
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
      );
      if (!launched) {
        throw const ModaoGameException('无法返回游戏，请手动打开魔道修仙');
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
      error is ModaoGameException ? error.message : '支付操作失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_returnToGame(cancelled: _payment == null));
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回游戏',
            onPressed: _busy
                ? null
                : () => _returnToGame(cancelled: _payment == null),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('樱花币支付'),
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
        const SizedBox(height: 26),
        _PaymentRow(label: '支付金额', value: '${preview.coinCost} 樱花币'),
        const Divider(height: 26),
        _PaymentRow(
          label: '商品价格',
          value: '¥${(preview.moneyCents / 100).toStringAsFixed(2)}',
        ),
        const Divider(height: 26),
        const _PaymentRow(label: '兑换比例', value: '10 樱花币 = ¥1.00'),
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
            key: const ValueKey<String>('modao-confirm-payment'),
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
              preview.balance < preview.coinCost ? '樱花币余额不足' : '确认支付',
            ),
          )
        else if (payment.deliveryFailed && payment.canRetry)
          FilledButton.icon(
            key: const ValueKey<String>('modao-retry-delivery'),
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
        OutlinedButton.icon(
          key: const ValueKey<String>('modao-return-game'),
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

  final ModaoPayment payment;

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
