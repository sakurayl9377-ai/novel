import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/interaction_auth_provider.dart';
import '../services/kdjx_game_service.dart';
import '../utils/auth_gate.dart';

class KdjxAuthorizationScreen extends StatefulWidget {
  const KdjxAuthorizationScreen({
    super.key,
    required this.request,
    required this.bridge,
    this.service,
  });

  static const Key approveButtonKey = ValueKey<String>(
    'kdjx-approve-authorization',
  );
  static const Key denyButtonKey = ValueKey<String>('kdjx-deny-authorization');
  static const Key userCodeKey = ValueKey<String>('kdjx-authorization-code');

  final KdjxAuthorizationRequest request;
  final KdjxPaymentBridge bridge;
  final KdjxGameService? service;

  @override
  State<KdjxAuthorizationScreen> createState() =>
      _KdjxAuthorizationScreenState();
}

class _KdjxAuthorizationScreenState extends State<KdjxAuthorizationScreen> {
  late final KdjxGameService _service;
  InteractionAuthProvider? _auth;
  bool _checkingSession = true;
  bool _loginFlowStarted = false;
  bool _busy = false;
  int? _authorizationUserId;
  bool _authorizationOwnerChanged = false;
  String? _resultStatus;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? KdjxGameService();
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
    if (auth == null || auth.isLoading || _loginFlowStarted) return;
    if (auth.isLoggedIn && auth.token.isNotEmpty) {
      final userId = auth.user?.id;
      if (userId == null) return;
      _authorizationUserId ??= userId;
      if (_authorizationUserId != userId) {
        _authorizationOwnerChanged = true;
        if (mounted) {
          setState(() {
            _checkingSession = false;
            _error = 'Sakura 账号已变化，请返回游戏重新发起授权';
          });
        }
        return;
      }
      if (_checkingSession && mounted) {
        setState(() => _checkingSession = false);
      }
      return;
    }
    if (_authorizationUserId != null) {
      _authorizationOwnerChanged = true;
      if (mounted) {
        setState(() {
          _checkingSession = false;
          _error = 'Sakura 登录已变化，请返回游戏重新发起授权';
        });
      }
      return;
    }
    unawaited(_loginWithSakura());
  }

  Future<void> _loginWithSakura() async {
    if (_loginFlowStarted) return;
    _loginFlowStarted = true;
    final loggedIn = await ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后授权游戏',
      message: '使用 Sakura 账号确认口袋觉醒的登录请求。',
    );
    _loginFlowStarted = false;
    if (!mounted) return;
    setState(() {
      _checkingSession = false;
      if (!loggedIn) _error = '需要登录 Sakura 后才能授权游戏';
    });
  }

  Future<void> _decide({required bool approve}) async {
    if (_busy || _resultStatus != null) return;
    final auth = _auth;
    final token = auth?.token ?? '';
    if (token.isEmpty || auth?.user == null) {
      await _loginWithSakura();
      return;
    }
    if (_authorizationOwnerChanged ||
        _authorizationUserId == null ||
        auth?.user?.id != _authorizationUserId) {
      setState(() {
        _authorizationOwnerChanged = true;
        _error = 'Sakura 账号已变化，请返回游戏重新发起授权';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final status = approve ? 'approved' : 'denied';
    try {
      await _service.decideDeviceAuthorization(
        token,
        widget.request,
        approve: approve,
      );
      final returned = await widget.bridge.returnAuthorizationToGame(
        deviceCode: widget.request.deviceCode,
        status: status,
      );
      if (!mounted) return;
      if (returned) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _busy = false;
        _resultStatus = status;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  Future<void> _cancelAndReturn() async {
    if (_busy) return;
    setState(() => _busy = true);
    var returnStatus = 'cancelled';
    try {
      final token = _auth?.token ?? '';
      if (token.isNotEmpty && !_authorizationOwnerChanged) {
        await _service.decideDeviceAuthorization(
          token,
          widget.request,
          approve: false,
        );
        returnStatus = 'denied';
      }
      await widget.bridge.returnAuthorizationToGame(
        deviceCode: widget.request.deviceCode,
        status: returnStatus,
      );
    } catch (_) {
      // The game will observe any completed decision from the server.
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _messageFor(Object error) =>
      error is KdjxGameException ? error.message : '游戏授权失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_cancelAndReturn());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '取消授权',
            onPressed: _busy ? null : _cancelAndReturn,
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('Sakura 登录授权'),
        ),
        body: SafeArea(
          child: _checkingSession
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _content(context),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final user = _auth?.user;
    final completed = _resultStatus != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        CircleAvatar(
          radius: 36,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.videogame_asset_rounded, size: 36),
        ),
        const SizedBox(height: 22),
        Text(
          completed
              ? (_resultStatus == 'approved' ? '授权成功' : '已拒绝授权')
              : '口袋觉醒正在请求登录',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Text(
          completed
              ? '请手动返回口袋觉醒继续。'
              : '将使用当前 Sakura 账号 ${user?.nickname ?? ''} 登录游戏。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        if (!completed) ...[
          const SizedBox(height: 24),
          Text(
            '授权码',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SelectableText(
            widget.request.userCode,
            key: KdjxAuthorizationScreen.userCodeKey,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请确认与游戏中显示的授权码一致',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 18),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 32),
        if (completed)
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check_rounded),
            label: const Text('完成'),
          )
        else ...[
          FilledButton.icon(
            key: KdjxAuthorizationScreen.approveButtonKey,
            onPressed: _busy || _authorizationOwnerChanged
                ? null
                : () => _decide(approve: true),
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.verified_user_rounded),
            label: const Text('允许登录'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: KdjxAuthorizationScreen.denyButtonKey,
            onPressed: _busy || _authorizationOwnerChanged
                ? null
                : () => _decide(approve: false),
            icon: const Icon(Icons.block_rounded),
            label: const Text('拒绝'),
          ),
        ],
      ],
    );
  }
}
