import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/services/app_install_report_service.dart';
import 'package:novel_app/services/auth_session_storage.dart';
import 'package:novel_app/services/interaction_auth_service.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory testDirectory;
  late _MemoryAuthSessionStorage sessionStorage;
  const account = InteractionAccountSession(
    token: 'saved-token',
    user: InteractionUser(
      id: 42,
      email: 'reader@example.com',
      nickname: 'Reader',
    ),
  );

  setUpAll(() async {
    testDirectory = Directory.systemTemp.createTempSync(
      'interaction_auth_provider_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? testDirectory.path
              : null,
        );
    SharedPreferences.setMockInitialValues({});
    await StorageService().init();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (testDirectory.existsSync()) testDirectory.deleteSync(recursive: true);
  });

  setUp(() async {
    sessionStorage = _MemoryAuthSessionStorage();
    final storage = StorageService();
    await storage.remove('interaction_auth_token');
    await storage.remove('interaction_auth_user');
    await storage.setString(
      'interaction_auth_accounts',
      jsonEncode([account.toJson()]),
    );
  });

  test('migrates legacy plaintext accounts into secure storage', () async {
    final provider = await _loadedProvider(
      const SocketException('offline'),
      sessionStorage,
    );

    expect(provider.accounts.map((item) => item.token), ['saved-token']);
    final envelope =
        jsonDecode(sessionStorage.values['interaction_auth_session_v2']!)
            as Map<String, dynamic>;
    expect(envelope['version'], 2);
    expect((envelope['accounts'] as List), hasLength(1));
    expect(sessionStorage.values['interaction_auth_accounts'], isNull);
    expect(StorageService().getString('interaction_auth_accounts'), isNull);
  });

  test(
    'migrates a legacy token and user without logging out offline',
    () async {
      final storage = StorageService();
      await storage.setString('interaction_auth_token', account.token);
      await storage.setString(
        'interaction_auth_user',
        jsonEncode(account.user.toJson()),
      );

      final provider = await _loadedProvider(
        const SocketException('offline'),
        sessionStorage,
      );

      expect(provider.isLoggedIn, isTrue);
      expect(provider.user?.id, account.user.id);
      expect(storage.getString('interaction_auth_token'), isNull);
      expect(storage.getString('interaction_auth_user'), isNull);
    },
  );

  test(
    'falls back to valid legacy JSON after a partial secure migration',
    () async {
      sessionStorage.values['interaction_auth_token'] = account.token;
      sessionStorage.values['interaction_auth_user'] = '{damaged';
      await StorageService().setString(
        'interaction_auth_user',
        jsonEncode(account.user.toJson()),
      );

      final provider = await _loadedProvider(
        const SocketException('offline'),
        sessionStorage,
      );

      expect(provider.isLoggedIn, isTrue);
      expect(provider.user?.id, account.user.id);
      expect(sessionStorage.values['interaction_auth_user'], isNull);
      expect(sessionStorage.values['interaction_auth_session_v2'], isNotEmpty);
    },
  );

  test(
    'keeps legacy plaintext when the secure migration write fails',
    () async {
      sessionStorage.failWrites = true;

      await expectLater(
        _loadedProvider(const SocketException('offline'), sessionStorage),
        throwsA(isA<StateError>()),
      );

      expect(
        StorageService().getString('interaction_auth_accounts'),
        isNotNull,
      );
      expect(sessionStorage.values['interaction_auth_session_v2'], isNull);
    },
  );

  test('falls back from a damaged secure account list', () async {
    sessionStorage.values['interaction_auth_accounts'] = '[null]';

    final provider = await _loadedProvider(
      const SocketException('offline'),
      sessionStorage,
    );

    expect(provider.accounts.map((item) => item.token), ['saved-token']);
    expect(sessionStorage.values['interaction_auth_accounts'], isNull);
  });

  test('failed logout writes delete the old secure token envelope', () async {
    final storage = StorageService();
    await storage.setString('interaction_auth_token', account.token);
    await storage.setString(
      'interaction_auth_user',
      jsonEncode(account.user.toJson()),
    );
    final provider = await _loadedProvider(
      const SocketException('offline'),
      sessionStorage,
    );
    expect(provider.isLoggedIn, isTrue);
    sessionStorage.failWrites = true;

    await provider.clearSession();

    expect(provider.isLoggedIn, isFalse);
    expect(sessionStorage.values['interaction_auth_session_v2'], isNull);
  });

  test('logout persists one cleared envelope before remote logout', () async {
    const otherAccount = InteractionAccountSession(
      token: 'other-token',
      user: InteractionUser(
        id: 77,
        email: 'other@example.com',
        nickname: 'Other',
      ),
    );
    sessionStorage.values['interaction_auth_session_v2'] = jsonEncode({
      'version': 2,
      'token': account.token,
      'user': account.user.toJson(),
      'accounts': [account.toJson(), otherAccount.toJson()],
    });
    final authService = _BlockingLogoutInteractionAuthService(account.user);
    final provider = InteractionAuthProvider(
      authService: authService,
      appInstallReportService: _NoopAppInstallReportService(),
      sessionStorage: sessionStorage,
    );
    await provider.loadSession();
    sessionStorage.sessionEnvelopeWrites = 0;

    final logout = provider.logout();
    await authService.logoutStarted.future;

    expect(provider.isLoggedIn, isFalse);
    expect(provider.accounts.map((item) => item.user.id), [
      otherAccount.user.id,
    ]);
    expect(authService.logoutToken, account.token);
    expect(sessionStorage.sessionEnvelopeWrites, 1);
    final envelope =
        jsonDecode(sessionStorage.values['interaction_auth_session_v2']!)
            as Map<String, dynamic>;
    expect(envelope['token'], '');
    expect(envelope['user'], isNull);
    expect(
      (envelope['accounts'] as List)
          .map((item) => (item as Map<String, dynamic>)['user'])
          .map((item) => (item as Map<String, dynamic>)['id']),
      [otherAccount.user.id],
    );

    authService.finishLogout.complete();
    await logout;
  });

  for (final statusCode in [401, 403]) {
    test(
      'switchAccount removes a definitively rejected $statusCode session',
      () async {
        final provider = await _loadedProvider(
          InteractionAuthException('session rejected', statusCode: statusCode),
          sessionStorage,
        );
        final savedAccount = provider.accounts.single;

        await expectLater(
          provider.switchAccount(savedAccount),
          throwsA(
            isA<InteractionAuthException>().having(
              (error) => error.statusCode,
              'statusCode',
              statusCode,
            ),
          ),
        );

        expect(provider.accounts, isEmpty);
        final reloaded = await _loadedProvider(
          const InteractionAuthException('unused'),
          sessionStorage,
        );
        expect(reloaded.accounts, isEmpty);
      },
    );
  }

  final transientFailures = <String, Object>{
    'network error': const SocketException('offline'),
    'timeout': TimeoutException('request timed out'),
    'server error': const InteractionAuthException(
      'server unavailable',
      statusCode: 503,
    ),
  };
  for (final entry in transientFailures.entries) {
    test('switchAccount keeps the saved session after ${entry.key}', () async {
      final provider = await _loadedProvider(entry.value, sessionStorage);
      final savedAccount = provider.accounts.single;

      await expectLater(
        provider.switchAccount(savedAccount),
        throwsA(isA<Object>()),
      );

      expect(provider.accounts.map((item) => item.token), ['saved-token']);
      final reloaded = await _loadedProvider(
        const InteractionAuthException('unused'),
        sessionStorage,
      );
      expect(reloaded.accounts.map((item) => item.token), ['saved-token']);
    });
  }
}

Future<InteractionAuthProvider> _loadedProvider(
  Object failure,
  AuthSessionStorage sessionStorage,
) async {
  final provider = InteractionAuthProvider(
    authService: _FailingInteractionAuthService(failure),
    sessionStorage: sessionStorage,
  );
  await provider.loadSession();
  return provider;
}

class _MemoryAuthSessionStorage implements AuthSessionStorage {
  final Map<String, String> values = {};
  bool failWrites = false;
  int sessionEnvelopeWrites = 0;

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == 'interaction_auth_session_v2') sessionEnvelopeWrites += 1;
    if (failWrites) throw StateError('secure storage write failed');
    values[key] = value;
  }
}

class _FailingInteractionAuthService extends InteractionAuthService {
  _FailingInteractionAuthService(this.failure);

  final Object failure;

  @override
  Future<InteractionUser> me(String token) => Future.error(failure);
}

class _BlockingLogoutInteractionAuthService extends InteractionAuthService {
  _BlockingLogoutInteractionAuthService(this.savedUser);

  final InteractionUser savedUser;
  final Completer<void> logoutStarted = Completer<void>();
  final Completer<void> finishLogout = Completer<void>();
  String logoutToken = '';

  @override
  Future<InteractionUser> me(String token) async => savedUser;

  @override
  Future<void> logout(String token) async {
    logoutToken = token;
    logoutStarted.complete();
    await finishLogout.future;
  }
}

class _NoopAppInstallReportService extends AppInstallReportService {
  @override
  Future<void> report(String token) async {}
}
