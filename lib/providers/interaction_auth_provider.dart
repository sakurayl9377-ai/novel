import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/interaction_user.dart';
import '../services/app_install_report_service.dart';
import '../services/app_telemetry_service.dart';
import '../services/auth_session_storage.dart';
import '../services/interaction_auth_service.dart';
import '../services/progress_sync_service.dart';
import '../services/storage_service.dart';

class InteractionAuthProvider extends ChangeNotifier {
  InteractionAuthProvider({
    InteractionAuthService? authService,
    AppInstallReportService? appInstallReportService,
    AuthSessionStorage? sessionStorage,
    bool? betaTestAccountEnabled,
  }) : _authService = authService ?? InteractionAuthService(),
       _appInstallReportService =
           appInstallReportService ?? AppInstallReportService(),
       _sessionStorage = sessionStorage ?? SecureAuthSessionStorage(),
       _betaTestAccountEnabled =
           betaTestAccountEnabled ??
           InteractionAuthService.betaTestSessionBuildEnabled;

  static const String _tokenKey = 'interaction_auth_token';
  static const String _userKey = 'interaction_auth_user';
  static const String _accountsKey = 'interaction_auth_accounts';
  static const String _sessionKey = 'interaction_auth_session_v2';
  static const String _kdjxRevocationQueueKey =
      'interaction_auth_kdjx_revocation_queue_v1';

  final InteractionAuthService _authService;
  final AppInstallReportService _appInstallReportService;
  final AuthSessionStorage _sessionStorage;
  final bool _betaTestAccountEnabled;
  final StorageService _storage = StorageService();

  bool _isLoading = false;
  bool _isDisposed = false;
  int _sessionLoadGeneration = 0;
  String _token = '';
  InteractionUser? _user;
  List<InteractionAccountSession> _accounts = const [];
  List<_PendingKdjxRevocation> _pendingKdjxRevocations = const [];
  bool _pendingKdjxRevocationsLoaded = false;
  Future<void>? _kdjxRevocationDrain;

  bool get isLoading => _isLoading;
  bool get betaTestAccountEnabled => _betaTestAccountEnabled;
  bool get isLoggedIn => _token.isNotEmpty && _user != null;
  String get token => _token;
  InteractionUser? get user => _user;
  List<InteractionAccountSession> get accounts => _accounts;

  Future<void> loadSession() async {
    final generation = ++_sessionLoadGeneration;
    bool isCurrent() => !_isDisposed && generation == _sessionLoadGeneration;
    _setLoading(true);
    try {
      final persisted = await _loadPersistedSession();
      if (!isCurrent()) return;
      _token = persisted.token;
      _user = persisted.user;
      _accounts = persisted.accounts;
      await _loadPendingKdjxRevocations();
      if (!isCurrent()) return;
      _restoreCachedAppSession();
      if (_token.isNotEmpty) {
        try {
          final refreshedUser = await _authService.me(_token);
          if (!isCurrent()) return;
          _user = refreshedUser;
          await _saveSession();
          if (!isCurrent()) return;
        } on InteractionAuthException catch (error) {
          if (!isCurrent()) return;
          if (error.statusCode == 401 || error.statusCode == 403) {
            await clearSession();
          }
        } catch (_) {
          if (!isCurrent()) return;
          // Keep the cached session when startup verification fails offline.
        }
      }
      if (_token.isEmpty && _betaTestAccountEnabled) {
        try {
          final result = await _authService.createBetaTestSession();
          if (!isCurrent()) return;
          await _acceptAuthResult(result);
          if (!isCurrent()) return;
        } catch (_) {
          if (!isCurrent()) return;
          // The beta can still open offline and expose a one-tap retry on the
          // login screen when its local/test backend is not yet reachable.
        }
      }
      if (!isCurrent()) return;
      await _drainPendingKdjxRevocations();
      if (!isCurrent()) return;
      _scheduleAppInstallReport();
    } finally {
      if (isCurrent()) _setLoading(false);
    }
  }

  Future<CaptchaInfo> fetchCaptcha() => _authService.fetchCaptcha();

  Future<int> sendEmailCode({
    required String email,
    required String captchaId,
    required String captchaCode,
    String purpose = 'register',
  }) {
    return _authService.sendEmailCode(
      email: email,
      captchaId: captchaId,
      captchaCode: captchaCode,
      purpose: purpose,
    );
  }

  Future<EmailAvailability> checkEmailStatus({
    required String email,
    String purpose = 'register',
  }) {
    return _authService.checkEmailStatus(email: email, purpose: purpose);
  }

  Future<void> register({
    required String email,
    required String password,
    required String emailCode,
    String nickname = '',
  }) async {
    _setLoading(true);
    try {
      final result = await _authService.register(
        email: email,
        password: password,
        emailCode: emailCode,
        nickname: nickname,
      );
      _token = result.token;
      _user = result.user;
      _upsertCurrentAccount();
      await _saveSession();
      await _drainPendingKdjxRevocations();
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> login({required String email, required String password}) async {
    _setLoading(true);
    try {
      final result = await _authService.login(email: email, password: password);
      _token = result.token;
      _user = result.user;
      _upsertCurrentAccount();
      await _saveSession();
      await _drainPendingKdjxRevocations();
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> enterBetaTestAccount() async {
    if (!_betaTestAccountEnabled) {
      throw StateError('Beta test account is disabled for this build.');
    }
    _setLoading(true);
    try {
      await _acceptAuthResult(await _authService.createBetaTestSession());
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> resetPassword({
    required String email,
    required String password,
    required String emailCode,
  }) async {
    _setLoading(true);
    try {
      final result = await _authService.resetPassword(
        email: email,
        password: password,
        emailCode: emailCode,
      );
      _token = result.token;
      _user = result.user;
      _upsertCurrentAccount();
      await _saveSession();
      await _drainPendingKdjxRevocations();
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> switchAccount(InteractionAccountSession account) async {
    _setLoading(true);
    try {
      final user = await _authService.me(account.token);
      final previousToken = _token;
      final previousUserId = _user?.id;
      if (previousToken.isNotEmpty &&
          previousUserId != null &&
          previousUserId != user.id) {
        await _enqueueKdjxRevocation(previousUserId, previousToken);
      }
      _token = account.token;
      _user = user;
      _upsertCurrentAccount();
      await _saveSession();
      await _drainPendingKdjxRevocations();
      _scheduleAppInstallReport();
    } on InteractionAuthException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        _accounts = _accounts
            .where(
              (item) =>
                  item.token != account.token &&
                  item.user.id != account.user.id,
            )
            .toList();
        await _saveAccounts();
      }
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> removeAccount(InteractionAccountSession account) async {
    final isCurrentAccount = _user?.id == account.user.id;
    final token = isCurrentAccount && _token.isNotEmpty
        ? _token
        : account.token;
    await _enqueueKdjxRevocation(account.user.id, token);
    _accounts = _accounts
        .where((item) => item.user.id != account.user.id)
        .toList();
    await _saveAccounts();
    if (!_isDisposed) {
      if (isCurrentAccount) {
        await clearSession();
      } else {
        notifyListeners();
      }
    }
    await _drainPendingKdjxRevocations();
  }

  Future<void> updateCachedUser(InteractionUser user) async {
    if (_user?.id == user.id) {
      _user = user;
      _upsertCurrentAccount();
      await _saveSession();
    }
  }

  Future<void> logout() async {
    final token = _token;
    final userId = _user?.id;
    if (userId != null && token.isNotEmpty) {
      await _enqueueKdjxRevocation(userId, token);
    }
    if (userId != null) {
      _accounts = _accounts.where((item) => item.user.id != userId).toList();
    }
    _token = '';
    _user = null;
    await _persistClearedSession();
    if (token.isNotEmpty) {
      try {
        await _authService.logout(token);
        if (userId != null) await _removePendingKdjxRevocation(userId);
      } catch (_) {
        // The encrypted queue retries revocation on later app starts.
      }
    }
  }

  Future<void> clearSession() async {
    _token = '';
    _user = null;
    await _persistClearedSession();
  }

  Future<void> _acceptAuthResult(InteractionAuthResult result) async {
    _token = result.token;
    _user = result.user;
    _upsertCurrentAccount();
    await _saveSession();
    await _drainPendingKdjxRevocations();
  }

  Future<void> _persistClearedSession() async {
    ProgressSyncService.instance.clearSession();
    AppTelemetryService.instance.setAuthToken('');
    try {
      await _writeSessionEnvelope();
    } catch (_) {
      // A logout must not resurrect an old token on the next launch. If the
      // updated envelope cannot be written, remove it even though this also
      // discards the saved account switcher list.
      await _sessionStorage.delete(_sessionKey);
    }
    await _removeLegacySessionValues();
    if (!_isDisposed) notifyListeners();
  }

  Future<void> _saveSession() async {
    await _writeSessionEnvelope();
    await _removeLegacySessionValues();
    if (!_isDisposed) notifyListeners();
  }

  InteractionUser? _readUser(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return InteractionUser.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  List<InteractionAccountSession>? _readAccounts(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? _decodeAccounts(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  List<InteractionAccountSession>? _decodeAccounts(List<dynamic> decoded) {
    final accounts = <InteractionAccountSession>[];
    for (final item in decoded) {
      if (item is! Map) return null;
      try {
        final account = InteractionAccountSession.fromJson(
          item.cast<String, dynamic>(),
        );
        if (account.token.isEmpty || account.user.id <= 0) return null;
        accounts.add(account);
      } catch (_) {
        return null;
      }
    }
    return accounts;
  }

  void _upsertCurrentAccount() {
    final user = _user;
    if (user == null || _token.isEmpty) return;
    final next = InteractionAccountSession(token: _token, user: user);
    _accounts = [
      next,
      ..._accounts.where((item) => item.user.id != user.id),
    ].take(5).toList();
  }

  Future<void> _saveAccounts() async {
    await _writeSessionEnvelope();
    await _removeLegacySessionValues();
  }

  Future<_PersistedAuthSession> _loadPersistedSession() async {
    final envelopeRaw = await _sessionStorage.read(_sessionKey);
    final envelope = _decodeSessionEnvelope(envelopeRaw);

    final secureToken = await _sessionStorage.read(_tokenKey);
    final secureUserJson = await _sessionStorage.read(_userKey);
    final secureAccountsJson = await _sessionStorage.read(_accountsKey);
    final legacyToken = _storage.getString(_tokenKey);
    final legacyUserJson = _storage.getString(_userKey);
    final legacyAccountsJson = _storage.getString(_accountsKey);
    final hasOldValues =
        secureToken != null ||
        secureUserJson != null ||
        secureAccountsJson != null ||
        legacyToken != null ||
        legacyUserJson != null ||
        legacyAccountsJson != null;
    if (envelope != null) {
      if (hasOldValues) await _removeLegacySessionValues();
      return envelope;
    }

    final token = secureToken?.isNotEmpty == true
        ? secureToken!
        : legacyToken ?? '';
    final user = _readUser(secureUserJson) ?? _readUser(legacyUserJson);
    final accounts =
        _readAccounts(secureAccountsJson) ??
        _readAccounts(legacyAccountsJson) ??
        const <InteractionAccountSession>[];
    final migrated = _PersistedAuthSession(
      token: token,
      user: user,
      accounts: accounts,
    );
    if (envelopeRaw != null || hasOldValues) {
      await _writeSessionEnvelope(migrated);
      await _removeLegacySessionValues();
    }
    return migrated;
  }

  _PersistedAuthSession? _decodeSessionEnvelope(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 2) return null;
      final token = decoded['token'];
      final rawUser = decoded['user'];
      final rawAccounts = decoded['accounts'];
      if (token is! String || rawAccounts is! List) return null;
      final user = rawUser == null
          ? null
          : rawUser is Map
          ? InteractionUser.fromJson(rawUser.cast<String, dynamic>())
          : throw const FormatException('Invalid saved user');
      final accounts = _decodeAccounts(rawAccounts);
      if (accounts == null) throw const FormatException('Invalid accounts');
      return _PersistedAuthSession(
        token: token,
        user: user,
        accounts: accounts,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSessionEnvelope([_PersistedAuthSession? value]) {
    final session =
        value ??
        _PersistedAuthSession(token: _token, user: _user, accounts: _accounts);
    return _sessionStorage.write(
      _sessionKey,
      jsonEncode({
        'version': 2,
        'token': session.token,
        'user': session.user?.toJson(),
        'accounts': session.accounts.map((item) => item.toJson()).toList(),
      }),
    );
  }

  Future<void> _removeLegacySessionValues() async {
    await _sessionStorage.delete(_tokenKey);
    await _sessionStorage.delete(_userKey);
    await _sessionStorage.delete(_accountsKey);
    await _storage.remove(_tokenKey);
    await _storage.remove(_userKey);
    await _storage.remove(_accountsKey);
  }

  void _restoreCachedAppSession() {
    final token = _token;
    AppTelemetryService.instance.setAuthToken(token);
    final user = _user;
    if (token.isEmpty || user == null) {
      if (ProgressSyncService.instance.activeUserId != null) {
        ProgressSyncService.instance.clearSession();
      }
      return;
    }
    ProgressSyncService.instance.restoreCachedSession(
      token: token,
      userId: user.id.toString(),
    );
  }

  void _scheduleAppInstallReport() {
    final token = _token;
    AppTelemetryService.instance.setAuthToken(token);
    final user = _user;
    if (token.isEmpty || user == null) {
      if (ProgressSyncService.instance.activeUserId != null) {
        ProgressSyncService.instance.clearSession();
      }
      return;
    }
    ProgressSyncService.instance.bindSession(
      token: token,
      userId: user.id.toString(),
    );
    unawaited(_reportAppInstallSafely(token));
  }

  Future<void> _reportAppInstallSafely(String token) async {
    try {
      await _appInstallReportService.report(token);
    } catch (_) {
      // Version reporting is best-effort and must never block account usage.
    }
  }

  Future<void> _loadPendingKdjxRevocations() async {
    if (_pendingKdjxRevocationsLoaded) return;
    _pendingKdjxRevocationsLoaded = true;
    final raw = await _sessionStorage.read(_kdjxRevocationQueueKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1) {
        throw const FormatException('Invalid KDJX revocation queue');
      }
      final items = decoded['items'];
      if (items is! List) {
        throw const FormatException('Invalid KDJX revocation queue');
      }
      final pending = <_PendingKdjxRevocation>[];
      for (final item in items) {
        if (item is! Map) {
          throw const FormatException('Invalid KDJX revocation entry');
        }
        pending.add(
          _PendingKdjxRevocation.fromJson(item.cast<String, dynamic>()),
        );
      }
      _pendingKdjxRevocations = pending.take(5).toList();
    } catch (_) {
      _pendingKdjxRevocations = const [];
      await _sessionStorage.delete(_kdjxRevocationQueueKey);
    }
  }

  Future<void> _enqueueKdjxRevocation(int userId, String token) async {
    if (userId <= 0 || token.isEmpty) return;
    await _loadPendingKdjxRevocations();
    _pendingKdjxRevocations = [
      _PendingKdjxRevocation(userId: userId, token: token),
      ..._pendingKdjxRevocations.where((item) => item.userId != userId),
    ].take(5).toList();
    await _persistPendingKdjxRevocations();
  }

  Future<void> _removePendingKdjxRevocation(int userId) async {
    await _loadPendingKdjxRevocations();
    final next = _pendingKdjxRevocations
        .where((item) => item.userId != userId)
        .toList();
    if (next.length == _pendingKdjxRevocations.length) return;
    _pendingKdjxRevocations = next;
    await _persistPendingKdjxRevocations();
  }

  Future<void> _persistPendingKdjxRevocations() {
    if (_pendingKdjxRevocations.isEmpty) {
      return _sessionStorage.delete(_kdjxRevocationQueueKey);
    }
    return _sessionStorage.write(
      _kdjxRevocationQueueKey,
      jsonEncode({
        'version': 1,
        'items': _pendingKdjxRevocations.map((item) => item.toJson()).toList(),
      }),
    );
  }

  Future<void> _drainPendingKdjxRevocations() {
    final inFlight = _kdjxRevocationDrain;
    if (inFlight != null) return inFlight;
    final drain = _drainPendingKdjxRevocationsImpl();
    _kdjxRevocationDrain = drain;
    return drain.whenComplete(() {
      if (identical(_kdjxRevocationDrain, drain)) {
        _kdjxRevocationDrain = null;
      }
    });
  }

  Future<void> _drainPendingKdjxRevocationsImpl() async {
    await _loadPendingKdjxRevocations();
    final currentUser = _user;
    if (currentUser != null && _token.isNotEmpty) {
      final index = _pendingKdjxRevocations.indexWhere(
        (item) => item.userId == currentUser.id,
      );
      if (index >= 0 && _pendingKdjxRevocations[index].token != _token) {
        final next = [..._pendingKdjxRevocations];
        next[index] = _PendingKdjxRevocation(
          userId: currentUser.id,
          token: _token,
        );
        _pendingKdjxRevocations = next;
        await _persistPendingKdjxRevocations();
      }
    }
    for (final pending in [..._pendingKdjxRevocations]) {
      try {
        await _authService.revokeKdjxSessions(pending.token);
      } catch (_) {
        continue;
      }
      await _removePendingKdjxRevocation(pending.userId);
    }
  }

  void _setLoading(bool value) {
    if (_isDisposed) return;
    if (_isLoading == value) return;
    _isLoading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _sessionLoadGeneration += 1;
    super.dispose();
  }
}

class _PersistedAuthSession {
  const _PersistedAuthSession({
    required this.token,
    required this.user,
    required this.accounts,
  });

  final String token;
  final InteractionUser? user;
  final List<InteractionAccountSession> accounts;
}

class _PendingKdjxRevocation {
  const _PendingKdjxRevocation({required this.userId, required this.token});

  factory _PendingKdjxRevocation.fromJson(Map<String, dynamic> json) {
    final userId = json['userId'];
    final token = json['token'];
    if (userId is! int || userId <= 0 || token is! String || token.isEmpty) {
      throw const FormatException('Invalid KDJX revocation entry');
    }
    return _PendingKdjxRevocation(userId: userId, token: token);
  }

  final int userId;
  final String token;

  Map<String, dynamic> toJson() => {'userId': userId, 'token': token};
}
