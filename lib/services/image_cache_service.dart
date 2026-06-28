import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AppImageCacheService {
  AppImageCacheService._();

  static const String cacheKey = 'app_image_cache_v1';

  static final CacheManager manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 1200,
      repo: JsonCacheInfoRepository(databaseName: cacheKey),
      fileService: HttpFileService(),
    ),
  );
}
