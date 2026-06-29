import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.notes,
    this.sha256 = '',
    this.force = false,
  });

  final String versionName;
  final int versionCode;
  final String apkUrl;
  final String sha256;
  final bool force;
  final List<String> notes;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      versionName: _asString(json['versionName'] ?? json['version']),
      versionCode: _asInt(json['versionCode'] ?? json['buildNumber']),
      apkUrl: _asString(json['apkUrl'] ?? json['url']),
      sha256: _asString(json['sha256']).toLowerCase(),
      force: json['force'] == true,
      notes: _asStringList(json['notes'] ?? json['changelog']),
    );
  }
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.currentVersionName,
    required this.currentVersionCode,
    required this.hasUpdate,
    this.update,
  });

  final String currentVersionName;
  final int currentVersionCode;
  final bool hasUpdate;
  final AppUpdateInfo? update;
}

class AppUpdateService {
  AppUpdateService({
    this.httpClient,
    Future<Directory> Function()? temporaryDirectoryProvider,
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  static const String updateJsonUrl = 'http://49.232.137.85/app/version.json';
  static const MethodChannel _channel = MethodChannel(
    'com.novel.novel_app/app_update',
  );

  final http.Client? httpClient;
  final Future<Directory> Function() _temporaryDirectoryProvider;

  Future<AppUpdateCheckResult> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    final response = await _get(
      Uri.parse(updateJsonUrl),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Update check failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(_decodeBody(response));
    if (decoded is! Map) {
      throw Exception('Invalid update config');
    }
    final update = AppUpdateInfo.fromJson(decoded.cast<String, dynamic>());
    if (update.apkUrl.isEmpty || update.versionCode <= 0) {
      throw Exception('Invalid update config');
    }

    return AppUpdateCheckResult(
      currentVersionName: packageInfo.version,
      currentVersionCode: currentCode,
      hasUpdate: update.versionCode > currentCode,
      update: update,
    );
  }

  Future<File> downloadApk(
    AppUpdateInfo update, {
    void Function(int received, int total)? onProgress,
  }) async {
    final file = await _apkFileFor(update);
    if (await _isValidApk(file, update)) {
      final length = await file.length();
      onProgress?.call(length, length);
      return file;
    }

    final partialFile = File('${file.path}.download');
    if (await _isValidApk(partialFile, update)) {
      await _replaceFile(partialFile, file);
      final length = await file.length();
      onProgress?.call(length, length);
      return file;
    }

    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      var resumeFrom = 0;
      if (await partialFile.exists()) {
        resumeFrom = await partialFile.length();
      }

      final request = http.Request('GET', Uri.parse(update.apkUrl));
      request.headers.addAll({
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
            'Chrome/125.0 Mobile Safari/537.36',
      });
      if (resumeFrom > 0) {
        request.headers['Range'] = 'bytes=$resumeFrom-';
      }
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 416 &&
          await _isValidApk(partialFile, update)) {
        await _replaceFile(partialFile, file);
        final length = await file.length();
        onProgress?.call(length, length);
        return file;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('APK download failed: ${response.statusCode}');
      }

      if (response.statusCode == 200 && resumeFrom > 0) {
        try {
          await partialFile.delete();
        } catch (_) {
          // A fresh 200 response means the server ignored Range; overwrite.
        }
        resumeFrom = 0;
      }

      final append = response.statusCode == 206 && resumeFrom > 0;
      final sink = partialFile.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = resumeFrom;
      final contentLength = response.contentLength ?? -1;
      final total = contentLength > 0 && append
          ? resumeFrom + contentLength
          : contentLength;
      if (received > 0 && total > 0) {
        onProgress?.call(received, total);
      }
      try {
        await for (final chunk in response.stream) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }

      if (!await _isValidApk(partialFile, update)) {
        if (update.sha256.isNotEmpty) {
          try {
            await partialFile.delete();
          } catch (_) {
            // Ignore cleanup failures; the checksum error is the useful one.
          }
        }
        throw Exception('APK checksum mismatch');
      }

      await _replaceFile(partialFile, file);
      return file;
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<void> installApk(File apkFile) async {
    await _channel.invokeMethod<void>('installApk', {
      'path': apkFile.absolute.path,
    });
  }

  Future<http.Response> _get(Uri uri) {
    final client = httpClient;
    if (client != null) return client.get(uri);
    return http.get(uri);
  }

  String _decodeBody(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
  }

  Future<File> _apkFileFor(AppUpdateInfo update) async {
    final dir = await _temporaryDirectoryProvider();
    final hashLength = update.sha256.length < 12 ? update.sha256.length : 12;
    final hashPart = update.sha256.isNotEmpty
        ? '-${update.sha256.substring(0, hashLength)}'
        : '';
    return File('${dir.path}/sakura-${update.versionCode}$hashPart.apk');
  }

  Future<bool> _isValidApk(File file, AppUpdateInfo update) async {
    if (!await file.exists()) return false;
    if (await file.length() <= 0) return false;
    if (update.sha256.isEmpty) return false;
    final digest = crypto.sha256.convert(await file.readAsBytes());
    return digest.toString().toLowerCase() == update.sha256;
  }

  Future<void> _replaceFile(File source, File destination) async {
    if (await destination.exists()) {
      await destination.delete();
    }
    await source.rename(destination.path);
  }
}

String _asString(dynamic value) => value?.toString().trim() ?? '';

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  final text = _asString(value);
  if (text.isEmpty) return const [];
  return text
      .split(RegExp(r'[\r\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
