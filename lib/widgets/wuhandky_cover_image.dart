import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class WuhandkyCoverImage extends StatefulWidget {
  const WuhandkyCoverImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
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
        return _placeholder(showError: true);
      },
    );
  }

  Widget _placeholder({bool showError = false}) {
    return ColoredBox(
      color: const Color(0xFFE7E7E7),
      child: Center(
        child: Icon(
          showError ? Icons.broken_image_outlined : Icons.image_outlined,
          color: const Color(0xFF757575),
        ),
      ),
    );
  }
}
