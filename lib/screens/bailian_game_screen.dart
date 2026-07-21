import 'package:flutter/material.dart';
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
  WebViewController? _controller;
  Object? _error;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _launch();
  }

  Future<void> _launch() async {
    try {
      final launch = await (widget.service ?? BailianGameService())
          .createLaunch(widget.token);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0C0D1A))
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (value) {
              if (mounted) setState(() => _progress = value);
            },
            onNavigationRequest: (request) {
              final uri = Uri.tryParse(request.url);
              final allowed =
                  uri != null &&
                  uri.scheme == 'https' &&
                  uri.host == '49.232.137.85' &&
                  uri.path.startsWith('/bailian/');
              return allowed
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0D1A),
      appBar: AppBar(
        title: const Text('百练英雄'),
        backgroundColor: const Color(0xFF0C0D1A),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _controller == null ? null : () => _controller!.reload(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 42),
              const SizedBox(height: 12),
              Text(
                _error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _launch, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_progress < 100)
          LinearProgressIndicator(
            value: _progress == 0 ? null : _progress / 100,
          ),
      ],
    );
  }
}
