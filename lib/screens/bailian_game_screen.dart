import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/bailian_game_service.dart';

class BailianGameScreen extends StatefulWidget {
  const BailianGameScreen({super.key, required this.token, this.service});
  final String token;
  final BailianGameService? service;

  @override
  State<BailianGameScreen> createState() => _BailianGameScreenState();
}

class _BailianGameScreenState extends State<BailianGameScreen> {
  late final BailianGameService _service;
  WebViewController? _controller;
  Object? _error;
  int _progress = 0;
  bool _paymentBusy = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BailianGameService();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _launch();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _launch() async {
    try {
      final launch = await _service.createLaunch(widget.token);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0C0D1A))
        ..addJavaScriptChannel(
          'SakuraPay',
          onMessageReceived: (message) =>
              _handlePaymentMessage(message.message),
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (value) {
              if (mounted) setState(() => _progress = value);
            },
            onNavigationRequest: (request) => _isAllowedGameUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onWebResourceError: (error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() => _error = error.description);
              }
            },
          ),
        )
        ..loadRequest(launch.launchUrl);
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  bool _isAllowedGameUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == '49.232.137.85' &&
        uri.path.startsWith('/bailian/');
  }

  Future<void> _handlePaymentMessage(String raw) async {
    if (_paymentBusy) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException();
      final action = decoded['action']?.toString() ?? 'purchase';
      final gameOrderId = decoded['gameOrderId']?.toString().trim() ?? '';
      if (gameOrderId.isEmpty || gameOrderId.length > 128) {
        throw const BailianGameException('游戏订单号无效');
      }
      if (action == 'query') {
        final payment = await _service.paymentStatus(
          widget.token,
          gameOrderId: gameOrderId,
        );
        await _notifyGame(payment);
        return;
      }
      if (action != 'purchase') throw const BailianGameException('不支持的支付操作');
      final productId = decoded['productId']?.toString().trim() ?? '';
      if (productId.isEmpty || productId.length > 128) {
        throw const BailianGameException('游戏商品无效');
      }
      setState(() => _paymentBusy = true);
      final preview = await _service.previewPayment(
        widget.token,
        gameOrderId: gameOrderId,
        productId: productId,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('确认樱花币支付'),
          content: Text(
            '${preview.productName}\n价格：${preview.coinCost} 樱花币'
            '（¥${(preview.moneyCents / 100).toStringAsFixed(2)}）\n'
            '当前余额：${preview.balance} 樱花币',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: preview.balance < preview.coinCost
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(preview.balance < preview.coinCost ? '余额不足' : '确认支付'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        await _notifyGame(preview, status: 'cancelled');
        return;
      }
      final paid = await _service.pay(
        widget.token,
        gameOrderId: gameOrderId,
        productId: productId,
      );
      await _notifyGame(paid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isSuccess(paid.status) ? '支付成功' : '订单已提交：${paid.status}',
            ),
          ),
        );
      }
    } catch (error) {
      await _notifyGameError(error.toString());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _paymentBusy = false);
    }
  }

  bool _isSuccess(String status) =>
      status == 'paid' || status == 'delivered' || status == 'success';

  Future<void> _notifyGame(BailianPayment payment, {String? status}) =>
      _sendPaymentEvent({
        'ok': _isSuccess(status ?? payment.status),
        'gameOrderId': payment.gameOrderId,
        'productId': payment.productId,
        'status': status ?? payment.status,
        'balance': payment.balance,
      });

  Future<void> _notifyGameError(String message) =>
      _sendPaymentEvent({'ok': false, 'status': 'failed', 'message': message});

  Future<void> _sendPaymentEvent(Map<String, dynamic> detail) async {
    final payload = jsonEncode(detail);
    await _controller?.runJavaScript('''
      window.dispatchEvent(new CustomEvent('sakura-payment-result', {detail: $payload}));
      if (window.onSakuraPaymentResult) window.onSakuraPaymentResult($payload);
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      },
      child: Scaffold(backgroundColor: const Color(0xFF0C0D1A), body: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: FilledButton(onPressed: _launch, child: const Text('加载失败，点击重试')),
      );
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _controller!),
        if (_progress < 100)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
            ),
          ),
        if (_paymentBusy)
          const ColoredBox(
            color: Color(0x33000000),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
