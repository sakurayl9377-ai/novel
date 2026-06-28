import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../models/novel.dart';

class BookCoverWidget extends StatelessWidget {
  final Novel novel;
  final double? width;
  final double? height;

  const BookCoverWidget({
    super.key,
    required this.novel,
    this.width = 100,
    this.height = 140,
  });

  @override
  Widget build(BuildContext context) {
    final child = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: _buildCover(),
    );
    if (width == null && height == null) {
      return SizedBox.expand(child: child);
    }
    return SizedBox(width: width, height: height, child: child);
  }

  static Widget fill({required Novel novel}) {
    return BookCoverWidget(novel: novel, width: null, height: null);
  }

  Widget _buildCover() {
    if (novel.coverUrl.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            novel.coverUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildPlaceholder(),
            loadingBuilder: (_, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return _buildPlaceholder();
            },
          ),
          // 书源标签
          if (novel.sourceName.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: const BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.only(
                    bottomRight: Radius.circular(4),
                  ),
                ),
                child: Text(
                  novel.sourceName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          // 本地标志
          if (novel.isLocal)
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Icon(
                  Icons.phone_android,
                  color: Colors.white,
                  size: 12,
                ),
              ),
            ),
        ],
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.primaryColor.withValues(alpha: 0.7),
            AppTheme.primaryDark,
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            novel.title.isNotEmpty ? _getFirstChars(novel.title, 4) : '?',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  String _getFirstChars(String text, int count) {
    if (text.characters.length <= count) return text;
    return text.characters.take(count).toString();
  }
}
