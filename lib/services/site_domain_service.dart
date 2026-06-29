import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

    add(preferredOrigin);
    add(await currentOrigin(config));
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
  }) async {
    final candidates = await originCandidates(
      config,
      preferredOrigin: originOf(uri),
    );
    http.Response? lastResponse;
    Object? lastError;

    for (final origin in candidates) {
      final requestUri = replaceOrigin(uri, origin);
      try {
        final response = await _getFollowingRedirects(
          config,
          requestUri,
          headers: headers,
          timeout: timeout,
        );
        lastResponse = response;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final finalUri = response.request?.url ?? requestUri;
          await rememberOrigin(config, finalUri);
          return response;
        }
      } catch (error) {
        lastError = error;
      }
    }

    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('Request failed: $uri');
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
    SiteDomainConfig config,
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      var current = uri;
      for (var redirects = 0; redirects <= 5; redirects++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers.addAll(headers);
        final streamed = await client.send(request).timeout(timeout);
        final bodyBytes = await streamed.stream.toBytes().timeout(timeout);

        final location = streamed.headers['location'];
        final isRedirect =
            streamed.statusCode >= 300 &&
            streamed.statusCode < 400 &&
            location != null &&
            location.isNotEmpty;
        if (isRedirect) {
          final next = current.resolve(location);
          await rememberOrigin(config, next);
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
    } finally {
      client.close();
    }
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
}
