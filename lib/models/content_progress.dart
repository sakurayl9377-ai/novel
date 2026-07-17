import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'novel.dart';

enum ContentType {
  novel('novel'),
  manga('manga'),
  anime('anime');

  const ContentType(this.wireName);

  final String wireName;

  static ContentType? fromWireName(String value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

class ContentIdentity {
  const ContentIdentity({
    required this.contentType,
    required this.sourceKey,
    required this.itemId,
    this.syncEligible = true,
  });

  static const String mangaSourceKey = 'manga_baozi';
  static const String animeSourceKey = 'anime_yinhua';
  static const String legacyNovelSourceKey = 'legacy';
  static const String localNovelSourceKey = 'local';
  static const String wenku8NovelSourceKey = 'builtin_wenku8';
  static const String bqgNovelSourceKey = 'builtin_bqg995';

  final ContentType contentType;
  final String sourceKey;
  final String itemId;
  final bool syncEligible;

  factory ContentIdentity.novel(Novel novel) {
    final isLocal = novel.isLocal;
    final wenku8BookId = isLocal ? null : extractWenku8BookId(novel);
    final bqgBookId = isLocal || wenku8BookId != null
        ? null
        : extractBqgBookId(novel);
    return ContentIdentity(
      contentType: ContentType.novel,
      sourceKey: isLocal
          ? localNovelSourceKey
          : wenku8BookId != null
          ? wenku8NovelSourceKey
          : bqgBookId != null
          ? bqgNovelSourceKey
          : normalizeSourceKey(novel.sourceId).isEmpty
          ? legacyNovelSourceKey
          : normalizeSourceKey(novel.sourceId),
      itemId: wenku8BookId != null
          ? 'wenku8:$wenku8BookId'
          : bqgBookId != null
          ? 'bqg:$bqgBookId'
          : normalizeItemId(novel.id),
      syncEligible: !isLocal,
    );
  }

  static String? extractWenku8BookId(Novel novel) {
    final idMatch = RegExp(r'_wenku8_(\d+)$').firstMatch(novel.id);
    if (idMatch != null) return idMatch.group(1);

    final sourceKey = normalizeSourceKey(novel.sourceId);
    final looksLikeWenku8 =
        sourceKey == wenku8NovelSourceKey ||
        novel.chapterUrl.toLowerCase().contains('wenku8.');
    if (!looksLikeWenku8) return null;
    return RegExp(
      r'(?:[?&](?:aid|id)=)(\d+)',
    ).firstMatch(novel.chapterUrl)?.group(1);
  }

  static String? wenku8BookIdFromIdentity(ContentIdentity identity) {
    if (identity.contentType != ContentType.novel ||
        identity.sourceKey != wenku8NovelSourceKey) {
      return null;
    }
    return RegExp(r'^wenku8:(\d+)$').firstMatch(identity.itemId)?.group(1);
  }

  static String? extractBqgBookId(Novel novel) {
    final idMatch = RegExp(r'_bqg_(\d+)$').firstMatch(novel.id);
    if (idMatch != null) return idMatch.group(1);

    final sourceKey = normalizeSourceKey(novel.sourceId);
    final looksLikeBqg =
        sourceKey == bqgNovelSourceKey ||
        novel.chapterUrl.contains('/#/book/') ||
        novel.chapterUrl.contains('/book/');
    if (!looksLikeBqg) return null;
    return RegExp(r'/#?/book/(\d+)').firstMatch(novel.chapterUrl)?.group(1) ??
        RegExp(r'[?&]id=(\d+)').firstMatch(novel.chapterUrl)?.group(1);
  }

  static String? canonicalOnlineNovelToken(ContentIdentity identity) {
    if (identity.contentType != ContentType.novel) return null;
    if (identity.sourceKey == wenku8NovelSourceKey &&
        RegExp(r'^wenku8:\d+$').hasMatch(identity.itemId)) {
      return identity.itemId;
    }
    if (identity.sourceKey == bqgNovelSourceKey &&
        RegExp(r'^bqg:\d+$').hasMatch(identity.itemId)) {
      return identity.itemId;
    }
    return null;
  }

  static String? canonicalOnlineNovelTokenFromLegacyId(String novelId) {
    final wenku8 = RegExp(r'_wenku8_(\d+)$').firstMatch(novelId)?.group(1);
    if (wenku8 != null) return 'wenku8:$wenku8';
    final bqg = RegExp(r'_bqg_(\d+)$').firstMatch(novelId)?.group(1);
    return bqg == null ? null : 'bqg:$bqg';
  }

  factory ContentIdentity.legacyNovel(String novelId) => ContentIdentity(
    contentType: ContentType.novel,
    sourceKey: legacyNovelSourceKey,
    itemId: normalizeItemId(novelId),
  );

  factory ContentIdentity.manga(String mangaId) => ContentIdentity(
    contentType: ContentType.manga,
    sourceKey: mangaSourceKey,
    itemId: normalizeItemId(mangaId),
  );

  factory ContentIdentity.anime(Object animeId) => ContentIdentity(
    contentType: ContentType.anime,
    sourceKey: animeSourceKey,
    itemId: normalizeItemId(animeId.toString()),
  );

  String get contentKey {
    final canonical =
        '${contentType.wireName}\u0000${normalizeSourceKey(sourceKey)}\u0000${normalizeItemId(itemId)}';
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static String normalizeSourceKey(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9._:-]'), '');

  static String normalizeItemId(String value) => value.trim();

  static String normalizeSubItemId(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\u3000]+'), ' ');
}

class ContentProgressRecord {
  const ContentProgressRecord({
    required this.identity,
    required this.contentKey,
    required this.subItemId,
    required this.payload,
    required this.metadata,
    required this.deviceId,
    required this.clientUpdatedAtMs,
    required this.deleted,
    required this.dirty,
    this.ownerUserId = ProgressOwner.guest,
  });

  final ContentIdentity identity;
  final String contentKey;
  final String subItemId;
  final Map<String, dynamic> payload;
  final Map<String, dynamic> metadata;
  final String deviceId;
  final int clientUpdatedAtMs;
  final bool deleted;
  final bool dirty;
  final String ownerUserId;

  ContentProgressRecord copyWith({
    ContentIdentity? identity,
    String? contentKey,
    String? subItemId,
    Map<String, dynamic>? payload,
    Map<String, dynamic>? metadata,
    String? deviceId,
    int? clientUpdatedAtMs,
    bool? deleted,
    bool? dirty,
    String? ownerUserId,
  }) {
    return ContentProgressRecord(
      identity: identity ?? this.identity,
      contentKey: contentKey ?? this.contentKey,
      subItemId: subItemId ?? this.subItemId,
      payload: payload ?? this.payload,
      metadata: metadata ?? this.metadata,
      deviceId: deviceId ?? this.deviceId,
      clientUpdatedAtMs: clientUpdatedAtMs ?? this.clientUpdatedAtMs,
      deleted: deleted ?? this.deleted,
      dirty: dirty ?? this.dirty,
      ownerUserId: ownerUserId ?? this.ownerUserId,
    );
  }

  Map<String, dynamic> toSyncJson() => {
    'contentType': identity.contentType.wireName,
    'contentKey': contentKey,
    'sourceKey': identity.sourceKey,
    'itemId': identity.itemId,
    'subItemId': subItemId,
    'payload': payload,
    'metadata': metadata,
    'deviceId': deviceId,
    'clientUpdatedAtMs': clientUpdatedAtMs,
    'deleted': deleted,
  };

  factory ContentProgressRecord.fromSyncJson(Map<String, dynamic> json) {
    final type = ContentType.fromWireName(_asString(json['contentType']));
    if (type == null) {
      throw const FormatException('Unknown progress content type');
    }
    final identity = ContentIdentity(
      contentType: type,
      sourceKey: _asString(json['sourceKey']),
      itemId: _asString(json['itemId']),
    );
    return ContentProgressRecord(
      identity: identity,
      contentKey: _asString(json['contentKey']).isEmpty
          ? identity.contentKey
          : _asString(json['contentKey']),
      subItemId: ContentIdentity.normalizeSubItemId(
        _asString(json['subItemId']),
      ),
      payload: _asMap(json['payload']),
      metadata: _asMap(json['metadata']),
      deviceId: _asString(json['deviceId']),
      clientUpdatedAtMs: _asInt(json['clientUpdatedAtMs']),
      deleted: json['deleted'] == true || json['deleted'] == 1,
      dirty: false,
    );
  }

  static String _asString(dynamic value) => value?.toString().trim() ?? '';

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return value.cast<String, dynamic>();
    return const {};
  }
}

abstract final class ProgressOwner {
  static const String guest = 'guest';
}
