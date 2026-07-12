part of '../profile_screen.dart';

class _AvatarEditPreview extends StatelessWidget {
  const _AvatarEditPreview({
    required this.avatarUrl,
    required this.fallbackUser,
    required this.isUploading,
  });

  final String avatarUrl;
  final InteractionUser fallbackUser;
  final bool isUploading;

  @override
  Widget build(BuildContext context) {
    const size = _profileEditAvatarSize;
    final level = fallbackUser.growth.level.clamp(1, 7).toInt();
    final style = _LevelVisualStyle.forLevel(level);
    final color = _levelColor(level);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _FramedAvatar(
              avatarUrl: avatarUrl,
              level: level,
              size: size,
            ),
          ),
          if (isUploading)
            Positioned.fill(
              child: Container(
                margin: EdgeInsets.all(size * _avatarFrameInsetRatio),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.36),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 27,
              height: 27,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: style.buttonColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.24),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.photo_camera_outlined,
                color: Colors.white,
                size: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileImageUploadTile extends StatelessWidget {
  const _ProfileImageUploadTile({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.aspectRatio,
    required this.icon,
    required this.isUploading,
    required this.onTap,
    required this.onClear,
    this.locked = false,
  });

  final String title;
  final String subtitle;
  final String imageUrl;
  final double aspectRatio;
  final IconData icon;
  final bool isUploading;
  final bool locked;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final isWide = aspectRatio > 1;
    final previewWidth = isWide ? 132.0 : 76.0;
    final previewHeight = isWide ? 78.0 : 76.0;
    return InkWell(
      onTap: locked ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: locked ? const Color(0xFFF7F8FA) : const Color(0xFFFBFCFE),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.dividerColor),
        ),
        child: Row(
          children: [
            SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: _ProfileImagePreview(
                imageUrl: imageUrl,
                icon: locked ? Icons.lock_outline_rounded : icon,
                isUploading: isUploading,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: locked
                          ? AppTheme.textSecondary
                          : AppTheme.textPrimary,
                      fontSize: 15,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      fontFamilyFallback: _profileFontFallback,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      fontFamilyFallback: _profileFontFallback,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (onClear != null)
              IconButton(
                onPressed: onClear,
                tooltip: '清空',
                icon: const Icon(Icons.close_rounded),
              )
            else
              Icon(
                locked
                    ? Icons.lock_outline_rounded
                    : Icons.cloud_upload_outlined,
                color: AppTheme.textHint,
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileImagePreview extends StatelessWidget {
  const _ProfileImagePreview({
    required this.imageUrl,
    required this.icon,
    required this.isUploading,
  });

  final String imageUrl;
  final IconData icon;
  final bool isUploading;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isEmpty)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFEAF3FF), Color(0xFFFFE7EF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(icon, color: AppTheme.textSecondary, size: 24),
            )
          else
            Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: const Color(0xFFF0F3F8),
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          if (isUploading)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.34),
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditablePhotoWallSlot extends StatelessWidget {
  const _EditablePhotoWallSlot({
    required this.imageUrl,
    required this.index,
    required this.isAddSlot,
    required this.isUploading,
    required this.onTap,
    required this.onClear,
  });

  final String imageUrl;
  final int index;
  final bool isAddSlot;
  final bool isUploading;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _ProfileImagePreview(
            imageUrl: imageUrl,
            icon: isAddSlot
                ? Icons.add_photo_alternate_outlined
                : Icons.image_outlined,
            isUploading: isUploading,
          ),
          if (imageUrl.isEmpty && !isUploading)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.76),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(8),
                  ),
                ),
                child: Text(
                  isAddSlot ? '添加照片' : '照片${index + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ),
            ),
          if (onClear != null)
            Positioned(
              top: 5,
              right: 5,
              child: GestureDetector(
                onTap: onClear,
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.48),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
