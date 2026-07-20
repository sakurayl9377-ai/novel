import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/site_domain_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('fallback origins race after the remembered origin times out', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final slowPrimary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final slowFallback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fastFallback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await Future.wait([
        slowPrimary.close(force: true),
        slowFallback.close(force: true),
        fastFallback.close(force: true),
      ]);
    });
    unawaited(
      _serve(slowPrimary, const Duration(milliseconds: 500), 'primary'),
    );
    unawaited(_serve(slowFallback, const Duration(milliseconds: 450), 'slow'));
    unawaited(_serve(fastFallback, const Duration(milliseconds: 20), 'fast'));

    final config = SiteDomainConfig(
      key: 'race_${DateTime.now().microsecondsSinceEpoch}',
      primaryOrigin: 'http://127.0.0.1:${slowPrimary.port}',
      fallbackOrigins: [
        'http://127.0.0.1:${slowFallback.port}',
        'http://127.0.0.1:${fastFallback.port}',
      ],
    );
    final stopwatch = Stopwatch()..start();
    final response = await SiteDomainService.instance.get(
      config,
      Uri.parse('${config.primaryOrigin}/home'),
      timeout: const Duration(milliseconds: 180),
    );
    stopwatch.stop();

    expect(response.body, 'fast');
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 360)));
    final candidates = await SiteDomainService.instance.originCandidates(
      config,
    );
    expect(candidates.first, 'http://127.0.0.1:${fastFallback.port}');
  });

  test('skips a remembered 200 response when its content is invalid', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final invalid = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final valid = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await Future.wait([invalid.close(force: true), valid.close(force: true)]);
    });
    unawaited(_serve(invalid, Duration.zero, '<html>blocked</html>'));
    unawaited(_serve(valid, Duration.zero, '<main>anime-list</main>'));

    final config = SiteDomainConfig(
      key: 'validator_${DateTime.now().microsecondsSinceEpoch}',
      primaryOrigin: 'http://127.0.0.1:${valid.port}',
    );
    await SiteDomainService.instance.rememberOrigin(
      config,
      Uri.parse('http://127.0.0.1:${invalid.port}/'),
    );

    final response = await SiteDomainService.instance.get(
      config,
      Uri.parse('${config.primaryOrigin}/home'),
      responseValidator: (response) => response.body.contains('anime-list'),
    );

    expect(response.body, contains('anime-list'));
    expect(
      await SiteDomainService.instance.currentOrigin(config),
      config.primaryOrigin,
    );
  });
}

Future<void> _serve(HttpServer server, Duration delay, String body) async {
  await for (final request in server) {
    await Future<void>.delayed(delay);
    request.response
      ..statusCode = HttpStatus.ok
      ..write(body);
    await request.response.close();
  }
}
