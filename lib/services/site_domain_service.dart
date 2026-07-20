import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

typedef SiteResponseValidator = bool Function(http.Response response);

class SiteDomainConfig {
  const SiteDomainConfig({
    required this.key,
    required this.primaryOrigin,
    this.fallbackOrigins = const [],
  });

  final String key;
  final String primaryOrigin;
  final List<String> fallbackOrigins;

  String get storageKey => 'site_current_origin_$key';
}

class SiteDomainService {
  SiteDomainService._();

  static final SiteDomainService instance = SiteDomainService._();

  final Map<String, String> _memoryOrigins = {};
  final http.Client _client = http.Client();

  Future<String> currentOrigin(SiteDomainConfig config) async {
    final memory = _memoryOrigins[config.key];
    if (_isValidOrigin(memory)) return _normalizeOrigin(memory!);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(config.storageKey);
    if (_isValidOrigin(saved)) {
      final normalized = _normalizeOrigin(saved!);
      _memoryOrigins[config.key] = normalized;
      return normalized;
    }
    return _normalizeOrigin(config.primaryOrigin);
  }

  Future<List<String>> originCandidates(
    SiteDomainConfig config, {
    String preferredOrigin = '',
  }) async {
    final origins = <String>[];

    void add(String origin) {
      if (!_isValidOrigin(origin)) return;
      final normalized = _normalizeOrigin(origin);
      if (!origins.contains(normalized)) origins.add(normalized);
    }

    add(await currentOrigin(config));
    add(preferredOrigin);
    add(config.primaryOrigin);
    for (final origin in config.fallbackOrigins) {
      add(origin);
    }
    return origins;
  }

  Future<void> rememberOrigin(SiteDomainConfig config, Uri uri) async {
    if (!uri.hasScheme || uri.host.isEmpty) return;
    if (uri.scheme != 'http' && uri.scheme != 'https') return;

    final origin = originOf(uri);
    if (!_isValidOrigin(origin)) return;

    final normalized = _normalizeOrigin(origin);
    if (_memoryOrigins[config.key] == normalized) return;

    _memoryOrigins[config.key] = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(config.storageKey, normalized);
  }

  Future<http.Response> get(
    SiteDomainConfig config,
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
    SiteResponseValidator? responseValidator,
  }) async {
    final candidates = await originCandidates(
      config,
      preferredOrigin: originOf(uri),
    );
    if (candidates.isEmpty) throw Exception('Request failed: $uri');

    final preferred = await _attempt(
      uri,
      candidates.first,
      headers: headers,
      timeout: _boundedTimeout(timeout, const Duration(seconds: 3)),
      responseValidator: responseValidator,
    );
    if (preferred.isSuccess) {
      await rememberOrigin(
        config,
        preferred.response!.request?.url ??
            replaceOrigin(uri, candidates.first),
      );
      return preferred.response!;
    }

    final remaining = candidates.skip(1).toList(growable: false);
    if (remaining.isEmpty) {
      if (preferred.response != null) return preferred.response!;
      throw preferred.error ?? Exception('Request failed: $uri');
    }

    final completer = Completer<http.Response>();
    http.Response? lastResponse = preferred.response;
    Object? lastError = preferred.error;
    var completed = 0;
    for (final origin in remaining) {
      _attempt(
        uri,
        origin,
        headers: headers,
        timeout: _boundedTimeout(timeout, const Duration(seconds: 4)),
        responseValidator: responseValidator,
      ).then((attempt) {
        completed += 1;
        lastResponse = attempt.response ?? lastResponse;
        lastError = attempt.error ?? lastError;
        if (attempt.isSuccess && !completer.isCompleted) {
          completer.complete(attempt.response!);
          unawaited(
            rememberOrigin(
              config,
              attempt.response!.request?.url ?? replaceOrigin(uri, origin),
            ),
          );
          return;
        }
        if (completed == remaining.length && !completer.isCompleted) {
          if (lastResponse != null) {
            completer.complete(lastResponse!);
          } else {
            completer.completeError(
              lastError ?? Exception('Request failed: $uri'),
            );
          }
        }
      });
    }
    return completer.future;
  }

  Future<_DomainAttempt> _attempt(
    Uri uri,
    String origin, {
    required Map<String, String> headers,
    required Duration timeout,
    SiteResponseValidator? responseValidator,
  }) async {
    final requestUri = replaceOrigin(uri, origin);
    try {
      final response = await _getFollowingRedirects(
        requestUri,
        headers: headers,
        timeout: timeout,
      ).timeout(timeout);
      var isUsable = response.statusCode >= 200 && response.statusCode < 300;
      if (isUsable && responseValidator != null) {
        try {
          isUsable = responseValidator(response);
        } catch (_) {
          isUsable = false;
        }
      }
      return _DomainAttempt(response: response, isUsable: isUsable);
    } catch (error) {
      return _DomainAttempt(error: error);
    }
  }

  static String originOf(Uri uri) {
    if (!uri.hasScheme || uri.host.isEmpty) return '';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  static Uri replaceOrigin(Uri uri, String origin) {
    final originUri = Uri.parse(_normalizeOrigin(origin));
    return uri.replace(
      scheme: originUri.scheme,
      host: originUri.host,
      port: originUri.hasPort ? originUri.port : null,
    );
  }

  Future<http.Response> _getFollowingRedirects(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    var current = uri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final streamed = await _client.send(request).timeout(timeout);
      final bodyBytes = await streamed.stream.toBytes().timeout(timeout);

      final location = streamed.headers['location'];
      final isRedirect =
          streamed.statusCode >= 300 &&
          streamed.statusCode < 400 &&
          location != null &&
          location.isNotEmpty;
      if (isRedirect) {
        final next = current.resolve(location);
        current = next;
        continue;
      }

      return http.Response.bytes(
        bodyBytes,
        streamed.statusCode,
        request: request,
        headers: streamed.headers,
        reasonPhrase: streamed.reasonPhrase,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
      );
    }
    throw Exception('Too many redirects: $uri');
  }

  static bool _isValidOrigin(String? origin) {
    if (origin == null || origin.trim().isEmpty) return false;
    final uri = Uri.tryParse(origin.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String _normalizeOrigin(String origin) {
    final uri = Uri.parse(origin.trim());
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  static Duration _boundedTimeout(Duration requested, Duration maximum) {
    return requested < maximum ? requested : maximum;
  }
}

class _DomainAttempt {
  const _DomainAttempt({this.response, this.error, this.isUsable = false});

  final http.Response? response;
  final Object? error;
  final bool isUsable;

  bool get isSuccess => response != null && isUsable;
}
