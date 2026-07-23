import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/interaction_auth_provider.dart';
import '../services/modao_game_service.dart';
import 'interaction_auth_screen.dart';

typedef ModaoLoginLauncher = Future<bool> Function(BuildContext context);

class ModaoSsoAuthorizationScreen extends StatefulWidget {
  const ModaoSsoAuthorizationScreen({
    super.key,
    required this.request,
    required this.bridge,
    this.service,
    this.loginLauncher,
  });

  final ModaoSsoAuthorizationRequest request;
  final ModaoPaymentBridge bridge;
  final ModaoGameService? service;
  final ModaoLoginLauncher? loginLauncher;

  @override
  State<ModaoSsoAuthorizationScreen> createState() =>
      _ModaoSsoAuthorizationScreenState();
}

class _ModaoSsoAuthorizationScreenState
    extends State<ModaoSsoAuthorizationScreen> {
  late final ModaoGameService _service;
  InteractionAuthProvider? _auth;
  bool _busy = false;
  bool _loginFlowRunning = false;
  bool _loginAttempted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ModaoGameService();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _auth = context.read<InteractionAuthProvider>()
        ..addListener(_handleAuthChanged);
      _handleAuthChanged();
    });
  }

  @override
  void dispose() {
    _auth?.removeListener(_handleAuthChanged);
    super.dispose();
  }

  void _handleAuthChanged() {
    final auth = _auth;
    if (auth == null || auth.isLoading || auth.isLoggedIn) {
      if (mounted) setState(() {});
      return;
    }
    if (!_loginAttempted && !_loginFlowRunning) {
      unawaited(_openLogin());
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openLogin() async {
    if (_loginFlowRunning || _busy) return;
    _loginFlowRunning = true;
    _loginAttempted = true;
    if (mounted) {
      setState(() {
        _error = null;
      });
    }
    final loggedIn = await (widget.loginLauncher ?? _defaultLoginLauncher)(
      context,
    );
    _loginFlowRunning = false;
    if (!mounted) return;
    final authorized = loggedIn && (_auth?.isLoggedIn ?? false);
    setState(() {
      if (!authorized) {
        _error = '请先登录小说 App 账号，再授权进入游戏';
      }
    });
  }

  Future<bool> _defaultLoginLauncher(BuildContext context) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/account/login'),
        builder: (_) => const InteractionAuthScreen(),
      ),
    );
    return context.mounted &&
        context.read<InteractionAuthProvider>().isLoggedIn;
  }

  Future<void> _authorize() async {
    if (_busy) return;
    final auth = _auth;
    if (auth == null || !auth.isLoggedIn || auth.token.isEmpty) {
      _loginAttempted = false;
      await _openLogin();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ticket = await _service.createSsoTicket(auth.token);
      final launched = await widget.bridge.returnSsoAuthorizationToGame(
        request: widget.request,
        ticket: ticket,
      );
      if (!launched) {
        throw const ModaoGameException('无法返回游戏，请确认游戏仍已安装');
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is ModaoGameException ? error.message : '游戏登录授权失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final user = auth.user;
    final accountName = user == null
        ? ''
        : user.nickname.trim().isNotEmpty
        ? user.nickname.trim()
        : user.email.trim();

    return PopScope<void>(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('授权登录游戏')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: auth.isLoading
                    ? const Center(
                        key: ValueKey<String>('modao-auth-restoring'),
                        child: CircularProgressIndicator(),
                      )
                    : _buildContent(auth, accountName),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(InteractionAuthProvider auth, String accountName) {
    if (!auth.isLoggedIn) {
      return Column(
        key: const ValueKey<String>('modao-auth-login-required'),
        children: [
          const Icon(Icons.account_circle_outlined, size: 52),
          const SizedBox(height: 16),
          Text(_error ?? '请登录小说 App 账号后继续', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey<String>('modao-auth-login'),
            onPressed: _loginFlowRunning
                ? null
                : () {
                    _loginAttempted = false;
                    unawaited(_openLogin());
                  },
            icon: const Icon(Icons.login_rounded),
            label: const Text('登录小说 App'),
          ),
        ],
      );
    }

    return Column(
      key: const ValueKey<String>('modao-auth-confirmation'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.verified_user_outlined,
          size: 52,
          color: Color(0xFF2E9A67),
        ),
        const SizedBox(height: 16),
        Text(
          '魔道修仙请求使用当前小说 App 账号登录',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_outline_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  accountName.isEmpty ? '当前已登录账号' : accountName,
                  key: const ValueKey<String>('modao-auth-account'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '授权后，游戏只能获取用于登录的账号标识和公开昵称，不会获得你的密码。',
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const ValueKey<String>('modao-auth-confirm'),
          onPressed: _busy ? null : _authorize,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sports_esports_rounded),
          label: const Text('授权并返回游戏'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          key: const ValueKey<String>('modao-auth-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('暂不授权'),
        ),
      ],
    );
  }
}
