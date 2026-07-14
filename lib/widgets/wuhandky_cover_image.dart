import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class WuhandkyCoverImage extends StatefulWidget {
  const WuhandkyCoverImage({
    super.key,
    required this.imageUrl,
    this.title = '',
    this.resolveFallback,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
  final String title;
  final Future<String?> Function()? resolveFallback;
  final BoxFit fit;

  static String? httpFallbackFor(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri.replace(scheme: 'http').toString();
  }

  @override
  State<WuhandkyCoverImage> createState() => _WuhandkyCoverImageState();
}

class _WuhandkyCoverImageState extends State<WuhandkyCoverImage> {
  late String _activeUrl;
  bool _fallbackScheduled = false;
  bool _resolvedFallbackAttempted = false;
  bool _resolvingFallback = false;

  @override
  void initState() {
    super.initState();
    _activeUrl = widget.imageUrl.trim();
  }

  @override
  void didUpdateWidget(covariant WuhandkyCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _activeUrl = widget.imageUrl.trim();
      _fallbackScheduled = false;
      _resolvedFallbackAttempted = false;
      _resolvingFallback = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeUrl.isEmpty) return _placeholder(showError: true);
    return CachedNetworkImage(
      key: ValueKey(_activeUrl),
      imageUrl: _activeUrl,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) {
        final fallback = WuhandkyCoverImage.httpFallbackFor(_activeUrl);
        if (!_fallbackScheduled && fallback != null) {
          _fallbackScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _activeUrl = fallback);
          });
          return _placeholder();
        }
        if (!_resolvedFallbackAttempted && widget.resolveFallback != null) {
          _resolvedFallbackAttempted = true;
          _scheduleResolvedFallback();
          return _placeholder(showProgress: true);
        }
        return _placeholder(showError: true);
      },
    );
  }

  void _scheduleResolvedFallback() {
    if (_resolvingFallback) return;
    _resolvingFallback = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final resolved = await widget.resolveFallback?.call();
      if (!mounted) return;
      final next = resolved?.trim() ?? '';
      setState(() {
        _resolvingFallback = false;
        if (next.isNotEmpty && next != _activeUrl) {
          _activeUrl = next;
          _fallbackScheduled = false;
        }
      });
    });
  }

  Widget _placeholder({bool showError = false, bool showProgress = false}) {
    return ColoredBox(
      color: const Color(0xFFE7E7E7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: showProgress
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      showError
                          ? Icons.broken_image_outlined
                          : Icons.image_outlined,
                      color: const Color(0xFF757575),
                    ),
                    if (showError && widget.title.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        widget.title.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF666666),
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
