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
import 'package:novel_app/services/progress_sync_service.dart';
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
    ProgressSyncService.instance.clearSession();
    addTearDown(ProgressSyncService.instance.clearSession);
    sessionStorage = _MemoryAuthSessionStorage();
    final storage = StorageService();
    await storage.remove('interaction_auth_token');
    await storage.remove('interaction_auth_user');
    await storage.setString(
      'interaction_auth_accounts',
      jsonEncode([account.toJson()]),
    );
  });

  test(
    'cached session binds the progress owner before remote verification',
    () async {
      sessionStorage.values['interaction_auth_session_v2'] = jsonEncode({
        'version': 2,
        'token': account.token,
        'user': account.user.toJson(),
        'accounts': [account.toJson()],
      });
      final authService = _BlockingMeInteractionAuthService();
      final provider = InteractionAuthProvider(
        authService: authService,
        appInstallReportService: _NoopAppInstallReportService(),
        sessionStorage: sessionStorage,
      );
      addTearDown(provider.dispose);

      final load = provider.loadSession();
      await authService.meStarted.future;

      try {
        expect(
          ProgressSyncService.instance.activeOwnerUserId,
          account.user.id.toString(),
        );
      } finally {
        authService.complete(account.user);
        await load;
      }
    },
  );

  test('disposed session load cannot replace a newer progress owner', () async {
    sessionStorage.values['interaction_auth_session_v2'] = jsonEncode({
      'version': 2,
      'token': account.token,
      'user': account.user.toJson(),
      'accounts': [account.toJson()],
    });
    final authService = _BlockingMeInteractionAuthService();
    final provider = InteractionAuthProvider(
      authService: authService,
      appInstallReportService: _NoopAppInstallReportService(),
      sessionStorage: sessionStorage,
    );

    final load = provider.loadSession();
    await authService.meStarted.future;
    provider.dispose();
    ProgressSyncService.instance.restoreCachedSession(
      token: 'new-token',
      userId: '99',
    );
    authService.complete(account.user);
    await load;

    expect(ProgressSyncService.instance.activeOwnerUserId, '99');
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
    expect(authService.revokeTokens, isEmpty);
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

  test(
    'switchAccount revokes the outgoing game sessions without blocking locally',
    () async {
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
      final authService = _LifecycleInteractionAuthService(
        usersByToken: {
          account.token: account.user,
          otherAccount.token: otherAccount.user,
        },
        revokeFailure: const SocketException('offline'),
      );
      final provider = InteractionAuthProvider(
        authService: authService,
        appInstallReportService: _NoopAppInstallReportService(),
        sessionStorage: sessionStorage,
      );
      addTearDown(provider.dispose);
      await provider.loadSession();

      await provider.switchAccount(otherAccount);

      expect(authService.revokeTokens, [account.token]);
      expect(provider.token, otherAccount.token);
      expect(provider.user?.id, otherAccount.user.id);
      final envelope =
          jsonDecode(sessionStorage.values['interaction_auth_session_v2']!)
              as Map<String, dynamic>;
      expect(envelope['token'], otherAccount.token);
    },
  );

  test(
    'removeAccount revokes the removed game sessions without blocking locally',
    () async {
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
      final authService = _LifecycleInteractionAuthService(
        usersByToken: {
          account.token: account.user,
          otherAccount.token: otherAccount.user,
        },
        revokeFailure: const SocketException('offline'),
      );
      final provider = InteractionAuthProvider(
        authService: authService,
        appInstallReportService: _NoopAppInstallReportService(),
        sessionStorage: sessionStorage,
      );
      addTearDown(provider.dispose);
      await provider.loadSession();

      await provider.removeAccount(otherAccount);

      expect(authService.revokeTokens, [otherAccount.token]);
      expect(provider.token, account.token);
      expect(provider.accounts.map((item) => item.user.id), [account.user.id]);
      final envelope =
          jsonDecode(sessionStorage.values['interaction_auth_session_v2']!)
              as Map<String, dynamic>;
      expect(
        (envelope['accounts'] as List)
            .map((item) => (item as Map<String, dynamic>)['user'])
            .map((item) => (item as Map<String, dynamic>)['id']),
        [account.user.id],
      );
    },
  );

  test('removeAccount clears and revokes the current account', () async {
    sessionStorage.values['interaction_auth_session_v2'] = jsonEncode({
      'version': 2,
      'token': account.token,
      'user': account.user.toJson(),
      'accounts': [account.toJson()],
    });
    final authService = _LifecycleInteractionAuthService(
      usersByToken: {account.token: account.user},
    );
    final provider = InteractionAuthProvider(
      authService: authService,
      appInstallReportService: _NoopAppInstallReportService(),
      sessionStorage: sessionStorage,
    );
    addTearDown(provider.dispose);
    await provider.loadSession();

    await provider.removeAccount(account);

    expect(authService.revokeTokens, [account.token]);
    expect(provider.isLoggedIn, isFalse);
    expect(provider.accounts, isEmpty);
  });

  test(
    'beta build automatically creates and securely saves its test session',
    () async {
      const betaAccount = InteractionAccountSession(
        token: 'beta-session-token',
        user: InteractionUser(
          id: 909,
          email: 'reader-beta-session@local.invalid',
          nickname: 'Sakura Beta 测试员',
        ),
      );
      final authService = _BetaInteractionAuthService(betaAccount);
      final provider = InteractionAuthProvider(
        authService: authService,
        appInstallReportService: _NoopAppInstallReportService(),
        sessionStorage: sessionStorage,
        betaTestAccountEnabled: true,
      );

      await provider.loadSession();

      expect(authService.createCalls, 1);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.token, betaAccount.token);
      expect(provider.user?.id, betaAccount.user.id);
      final envelope =
          jsonDecode(sessionStorage.values['interaction_auth_session_v2']!)
              as Map<String, dynamic>;
      expect(envelope['token'], betaAccount.token);
      final savedAccounts = envelope['accounts'] as List;
      expect(savedAccounts, hasLength(2));
      expect(
        ((savedAccounts.first as Map<String, dynamic>)['user']
            as Map<String, dynamic>)['id'],
        betaAccount.user.id,
      );
    },
  );

  test('formal build cannot enter the beta test account', () async {
    final authService = _BetaInteractionAuthService(account);
    final provider = InteractionAuthProvider(
      authService: authService,
      appInstallReportService: _NoopAppInstallReportService(),
      sessionStorage: sessionStorage,
      betaTestAccountEnabled: false,
    );

    await expectLater(provider.enterBetaTestAccount(), throwsStateError);
    expect(authService.createCalls, 0);
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

class _BlockingMeInteractionAuthService extends InteractionAuthService {
  final Completer<void> meStarted = Completer<void>();
  final Completer<InteractionUser> _result = Completer<InteractionUser>();

  @override
  Future<InteractionUser> me(String token) {
    meStarted.complete();
    return _result.future;
  }

  void complete(InteractionUser user) => _result.complete(user);
}

class _BlockingLogoutInteractionAuthService extends InteractionAuthService {
  _BlockingLogoutInteractionAuthService(this.savedUser);

  final InteractionUser savedUser;
  final Completer<void> logoutStarted = Completer<void>();
  final Completer<void> finishLogout = Completer<void>();
  String logoutToken = '';
  final List<String> revokeTokens = [];

  @override
  Future<InteractionUser> me(String token) async => savedUser;

  @override
  Future<void> logout(String token) async {
    logoutToken = token;
    logoutStarted.complete();
    await finishLogout.future;
  }

  @override
  Future<void> revokeKdjxSessions(String token) async {
    revokeTokens.add(token);
  }
}

class _LifecycleInteractionAuthService extends InteractionAuthService {
  _LifecycleInteractionAuthService({
    required this.usersByToken,
    this.revokeFailure,
  });

  final Map<String, InteractionUser> usersByToken;
  final Object? revokeFailure;
  final List<String> revokeTokens = [];

  @override
  Future<InteractionUser> me(String token) async => usersByToken[token]!;

  @override
  Future<void> revokeKdjxSessions(String token) async {
    revokeTokens.add(token);
    final failure = revokeFailure;
    if (failure != null) throw failure;
  }
}

class _BetaInteractionAuthService extends InteractionAuthService {
  _BetaInteractionAuthService(this.account);

  final InteractionAccountSession account;
  int createCalls = 0;

  @override
  Future<InteractionAuthResult> createBetaTestSession() async {
    createCalls += 1;
    return InteractionAuthResult(token: account.token, user: account.user);
  }
}

class _NoopAppInstallReportService extends AppInstallReportService {
  @override
  Future<void> report(String token) async {}
}
