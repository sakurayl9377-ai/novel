part of '../profile_screen.dart';

class ProfileLoadErrorBanner extends StatelessWidget {
  const ProfileLoadErrorBanner({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF5F5).withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(_profileCardRadius),
      child: InkWell(
        onTap: onRetry,
        borderRadius: BorderRadius.circular(_profileCardRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Color(0xFFD54A4A),
                size: 20,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF7A3434),
                    fontSize: 13,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '重试',
                style: TextStyle(
                  color: _profileAccentBlue,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
