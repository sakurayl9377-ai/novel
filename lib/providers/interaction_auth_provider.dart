import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/interaction_user.dart';
import '../services/app_install_report_service.dart';
import '../services/app_telemetry_service.dart';
import '../services/interaction_auth_service.dart';
import '../services/progress_sync_service.dart';
import '../services/storage_service.dart';

class InteractionAuthProvider extends ChangeNotifier {
  InteractionAuthProvider({
    InteractionAuthService? authService,
    AppInstallReportService? appInstallReportService,
  }) : _authService = authService ?? InteractionAuthService(),
       _appInstallReportService =
           appInstallReportService ?? AppInstallReportService();

  static const String _tokenKey = 'interaction_auth_token';
  static const String _userKey = 'interaction_auth_user';
  static const String _accountsKey = 'interaction_auth_accounts';

  final InteractionAuthService _authService;
  final AppInstallReportService _appInstallReportService;
  final StorageService _storage = StorageService();

  bool _isLoading = false;
  String _token = '';
  InteractionUser? _user;
  List<InteractionAccountSession> _accounts = const [];

  bool get isLoading => _isLoading;
  bool get isLoggedIn => _token.isNotEmpty && _user != null;
  String get token => _token;
  InteractionUser? get user => _user;
  List<InteractionAccountSession> get accounts => _accounts;

  Future<void> loadSession() async {
    _setLoading(true);
    try {
      _token = _storage.getString(_tokenKey) ?? '';
      final userJson = _storage.getString(_userKey);
      if (userJson != null) {
        final decoded = jsonDecode(userJson);
        if (decoded is Map) {
          _user = InteractionUser.fromJson(decoded.cast<String, dynamic>());
        }
      }
      _accounts = _readAccounts();
      if (_token.isNotEmpty) {
        try {
          _user = await _authService.me(_token);
          await _saveSession();
        } on InteractionAuthException catch (error) {
          if (error.statusCode == 401 || error.statusCode == 403) {
            await clearSession();
          }
        } catch (_) {
          // Keep the cached session when startup verification fails offline.
        }
      }
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
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
      _scheduleAppInstallReport();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> switchAccount(InteractionAccountSession account) async {
    _setLoading(true);
    try {
      final user = await _authService.me(account.token);
      _token = account.token;
      _user = user;
      _upsertCurrentAccount();
      await _saveSession();
      _scheduleAppInstallReport();
    } catch (_) {
      _accounts = _accounts
          .where(
            (item) =>
                item.token != account.token && item.user.id != account.user.id,
          )
          .toList();
      await _saveAccounts();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> removeAccount(InteractionAccountSession account) async {
    _accounts = _accounts
        .where((item) => item.user.id != account.user.id)
        .toList();
    await _saveAccounts();
    if (_user?.id == account.user.id) {
      await clearSession();
    } else {
      notifyListeners();
    }
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
    if (userId != null) {
      _accounts = _accounts.where((item) => item.user.id != userId).toList();
      await _saveAccounts();
    }
    await clearSession();
    if (token.isNotEmpty) {
      try {
        await _authService.logout(token);
      } catch (_) {
        // Local logout should still complete if the network is unavailable.
      }
    }
  }

  Future<void> clearSession() async {
    _token = '';
    _user = null;
    ProgressSyncService.instance.clearSession();
    AppTelemetryService.instance.setAuthToken('');
    await _storage.remove(_tokenKey);
    await _storage.remove(_userKey);
    notifyListeners();
  }

  Future<void> _saveSession() async {
    await _storage.setString(_tokenKey, _token);
    final user = _user;
    if (user != null) {
      await _storage.setString(_userKey, jsonEncode(user.toJson()));
    }
    await _saveAccounts();
    notifyListeners();
  }

  List<InteractionAccountSession> _readAccounts() {
    final raw = _storage.getString(_accountsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => InteractionAccountSession.fromJson(
              item.cast<String, dynamic>(),
            ),
          )
          .where((item) => item.token.isNotEmpty && item.user.id > 0)
          .toList();
    } catch (_) {
      return const [];
    }
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
    await _storage.setString(
      _accountsKey,
      jsonEncode(_accounts.map((item) => item.toJson()).toList()),
    );
  }

  void _scheduleAppInstallReport() {
    final token = _token;
    AppTelemetryService.instance.setAuthToken(token);
    final user = _user;
    if (token.isEmpty || user == null) {
      ProgressSyncService.instance.clearSession();
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

  void _setLoading(bool value) {
    if (_isLoading == value) return;
    _isLoading = value;
    notifyListeners();
  }
}
