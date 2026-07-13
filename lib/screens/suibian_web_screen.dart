import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/suibian_session_service.dart';

class SuibianWebScreen extends StatefulWidget {
  const SuibianWebScreen({super.key, required this.novelToken});

  final String novelToken;

  @override
  State<SuibianWebScreen> createState() => _SuibianWebScreenState();
}

class _SuibianWebScreenState extends State<SuibianWebScreen>
    with WidgetsBindingObserver {
  static const String _webBaseUrl = String.fromEnvironment(
    'SUIBIAN_VIDEO_BASE_URL',
    defaultValue: 'https://dfyc.cc.cd',
  );

  late final WebViewController _controller;
  late final SuibianSessionService _sessionService;
  String? _pendingVideoToken;
  String _errorMessage = '';
  int _progress = 0;
  bool _preparing = true;
  bool _sessionInjected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionService = SuibianSessionService();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF080A0C))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: _onProgress,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
          onNavigationRequest: _onNavigationRequest,
        ),
      );
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionService.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_pauseWebVideo());
    }
  }

  Future<void> _initialize() async {
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      await platformController.setMediaPlaybackRequiresUserGesture(false);
    }
    await _prepareSession();
  }

  Future<void> _prepareSession() async {
    if (mounted) {
      setState(() {
        _preparing = true;
        _progress = 0;
        _errorMessage = '';
        _sessionInjected = false;
      });
    }

    try {
      final videoToken = await _sessionService.exchangeNovelToken(
        widget.novelToken,
      );
      if (!mounted) return;
      _pendingVideoToken = videoToken;
      await _controller.loadRequest(Uri.parse('$_webBaseUrl/sso-bridge'));
    } on SuibianSessionException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('随便看加载失败，请稍后重试');
    }
  }

  void _onProgress(int progress) {
    if (!mounted || _progress == progress) return;
    setState(() => _progress = progress);
  }

  void _onPageStarted(String url) {
    if (!mounted) return;
    setState(() {
      _progress = 0;
      _errorMessage = '';
    });
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted) return;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.path == '/sso-bridge' && !_sessionInjected) {
      await _injectVideoSession();
      return;
    }

    if (_sessionInjected) {
      setState(() {
        _preparing = false;
        _progress = 100;
      });
    }
  }

  Future<void> _injectVideoSession() async {
    final token = _pendingVideoToken;
    if (token == null || token.isEmpty) {
      _showError('视频站登录凭证丢失，请重试');
      return;
    }

    _sessionInjected = true;
    _pendingVideoToken = null;
    try {
      final encodedToken = jsonEncode(token);
      await _controller.runJavaScript('''
        (() => {
          window.localStorage.setItem('suibian.session', $encodedToken);
          window.location.replace('/');
        })();
      ''');
    } catch (_) {
      _sessionInjected = false;
      _showError('同步登录状态失败，请重试');
    }
  }

  void _onWebResourceError(WebResourceError error) {
    if (error.isForMainFrame != true) return;
    _showError('网页加载失败：${error.description}');
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (uri.scheme == 'about') return NavigationDecision.navigate;

    final allowedHost = Uri.tryParse(_webBaseUrl)?.host;
    if (uri.scheme == 'https' && uri.host == allowedHost) {
      return NavigationDecision.navigate;
    }
    return NavigationDecision.prevent;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _errorMessage = message;
    });
  }

  Future<void> _pauseWebVideo() async {
    try {
      await _controller.runJavaScript('''
        document.querySelectorAll('video').forEach((video) => video.pause());
      ''');
    } catch (_) {
      // The page may not have been created yet.
    }
  }

  Future<void> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _reload() async {
    if (_errorMessage.isNotEmpty) {
      await _prepareSession();
      return;
    }
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    final showProgress = _errorMessage.isEmpty && _progress < 100;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF080A0C),
        appBar: AppBar(
          backgroundColor: const Color(0xFF080A0C),
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          titleSpacing: 0,
          leading: IconButton(
            tooltip: '返回',
            onPressed: () => unawaited(_handleBack()),
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
          ),
          title: const Text(
            '随便看',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: () => unawaited(_reload()),
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 4),
          ],
          bottom: showProgress
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    value: _progress <= 0 ? null : _progress / 100,
                    backgroundColor: Colors.transparent,
                    color: const Color(0xFFFF5B51),
                  ),
                )
              : null,
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            WebViewWidget(controller: _controller),
            if (_preparing) const _SuibianLoadingView(),
            if (_errorMessage.isNotEmpty)
              _SuibianErrorView(
                message: _errorMessage,
                onRetry: () => unawaited(_prepareSession()),
              ),
          ],
        ),
      ),
    );
  }
}

class _SuibianLoadingView extends StatelessWidget {
  const _SuibianLoadingView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF080A0C),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Color(0xFFFF5B51),
              ),
            ),
            SizedBox(height: 18),
            Text(
              '正在进入随便看',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 7),
            Text(
              '正在同步登录状态…',
              style: TextStyle(color: Color(0xFF8E949C), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuibianErrorView extends StatelessWidget {
  const _SuibianErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF080A0C),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 34),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                color: Color(0xFF8E949C),
                size: 42,
              ),
              const SizedBox(height: 18),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5B51),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.refresh_rounded, size: 19),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
