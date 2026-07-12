import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/interaction_user.dart';
import '../../../services/interaction_service.dart';

enum ProfileLoadPhase { idle, loading, ready, failure }

enum ProfileLibrarySection { history, favorites, downloads }

@immutable
class ProfileViewState {
  const ProfileViewState({
    this.sessionUserId,
    this.profile,
    this.shopItems = const <ShopItem>[],
    this.unreadCount = 0,
    this.phase = ProfileLoadPhase.idle,
    this.errorMessage,
    this.historyRevision = 0,
    this.favoritesRevision = 0,
    this.downloadsRevision = 0,
  });

  final int? sessionUserId;
  final UserProfile? profile;
  final List<ShopItem> shopItems;
  final int unreadCount;
  final ProfileLoadPhase phase;
  final String? errorMessage;
  final int historyRevision;
  final int favoritesRevision;
  final int downloadsRevision;

  bool get isLoading => phase == ProfileLoadPhase.loading;
  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;

  ProfileViewState copyWith({
    Object? sessionUserId = _unset,
    Object? profile = _unset,
    List<ShopItem>? shopItems,
    int? unreadCount,
    ProfileLoadPhase? phase,
    Object? errorMessage = _unset,
    int? historyRevision,
    int? favoritesRevision,
    int? downloadsRevision,
  }) {
    return ProfileViewState(
      sessionUserId: identical(sessionUserId, _unset)
          ? this.sessionUserId
          : sessionUserId as int?,
      profile: identical(profile, _unset)
          ? this.profile
          : profile as UserProfile?,
      shopItems: shopItems ?? this.shopItems,
      unreadCount: unreadCount ?? this.unreadCount,
      phase: phase ?? this.phase,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      historyRevision: historyRevision ?? this.historyRevision,
      favoritesRevision: favoritesRevision ?? this.favoritesRevision,
      downloadsRevision: downloadsRevision ?? this.downloadsRevision,
    );
  }
}

const Object _unset = Object();

abstract interface class ProfileRepository {
  Future<UserProfile> fetchProfile({required String token});

  Future<List<ShopItem>> fetchShopItems();

  Future<int> fetchUnreadCount({required String token});

  Future<UserProfile> dailySignIn({required String token});
}

class InteractionProfileRepository implements ProfileRepository {
  InteractionProfileRepository(this._service);

  final InteractionService _service;

  @override
  Future<UserProfile> fetchProfile({required String token}) {
    return _service.fetchMyProfile(token: token);
  }

  @override
  Future<List<ShopItem>> fetchShopItems() => _service.fetchShopItems();

  @override
  Future<int> fetchUnreadCount({required String token}) async {
    final summary = await _service.fetchMessageUnreadSummary(token: token);
    return summary.total;
  }

  @override
  Future<UserProfile> dailySignIn({required String token}) {
    return _service.dailySignIn(token: token);
  }
}

typedef ProfileCachedUserUpdater = Future<void> Function(InteractionUser user);

class ProfilePermissionPolicy {
  const ProfilePermissionPolicy._();

  static bool canOpenAdminEntry(InteractionUser? user) {
    final role = user?.role.trim().toLowerCase() ?? '';
    return role == 'admin' ||
        role == 'super_admin' ||
        role == 'moderator' ||
        role.endsWith('_admin');
  }
}

class ProfileController extends ChangeNotifier {
  ProfileController({required this._repository});

  final ProfileRepository _repository;
  ProfileViewState _state = const ProfileViewState();
  String _token = '';
  int _sessionGeneration = 0;
  int _profileRequestGeneration = 0;
  int _unreadRequestGeneration = 0;
  ProfileCachedUserUpdater? _updateCachedUser;

  ProfileViewState get state => _state;

  UserProfile? profileFor(InteractionUser? user) {
    final profile = _state.profile;
    if (user == null ||
        profile == null ||
        profile.user.id != user.id ||
        _state.sessionUserId != user.id) {
      return null;
    }
    return profile;
  }

  bool get canOpenAdminEntry =>
      ProfilePermissionPolicy.canOpenAdminEntry(_state.profile?.user);

  Future<void> switchSession({
    required InteractionUser? user,
    required String token,
    ProfileCachedUserUpdater? updateCachedUser,
    bool forceRefresh = false,
  }) async {
    final userId = user?.id;
    final normalizedToken = token.trim();
    final sameSession =
        _state.sessionUserId == userId && _token == normalizedToken;
    _updateCachedUser = updateCachedUser;
    if (sameSession && !forceRefresh) return;

    _sessionGeneration++;
    _profileRequestGeneration++;
    _unreadRequestGeneration++;
    _token = normalizedToken;

    if (userId == null || normalizedToken.isEmpty) {
      _setState(const ProfileViewState());
      return;
    }

    _setState(
      ProfileViewState(sessionUserId: userId, phase: ProfileLoadPhase.loading),
    );
    await Future.wait<void>(<Future<void>>[
      refresh(showLoading: false),
      refreshUnread(),
    ]);
  }

  Future<void> refresh({bool showLoading = true}) async {
    final userId = _state.sessionUserId;
    final token = _token;
    if (userId == null || token.isEmpty) return;
    final sessionGeneration = _sessionGeneration;
    final requestGeneration = ++_profileRequestGeneration;
    if (showLoading) {
      _setState(
        _state.copyWith(phase: ProfileLoadPhase.loading, errorMessage: null),
      );
    }
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.fetchProfile(token: token),
        _repository.fetchShopItems(),
      ]);
      if (!_isCurrentProfileRequest(
        sessionGeneration,
        requestGeneration,
        userId,
        token,
      )) {
        return;
      }
      final profile = results[0] as UserProfile;
      if (profile.user.id != userId) return;
      _setState(
        _state.copyWith(
          profile: profile,
          shopItems: List<ShopItem>.unmodifiable(results[1] as List<ShopItem>),
          phase: ProfileLoadPhase.ready,
          errorMessage: null,
        ),
      );
      final updater = _updateCachedUser;
      if (updater != null) {
        unawaited(updater(profile.user));
      }
    } catch (_) {
      if (!_isCurrentProfileRequest(
        sessionGeneration,
        requestGeneration,
        userId,
        token,
      )) {
        return;
      }
      _setState(
        _state.copyWith(
          phase: _state.profile == null
              ? ProfileLoadPhase.failure
              : ProfileLoadPhase.ready,
          errorMessage: '个人资料加载失败，请稍后重试',
        ),
      );
    }
  }

  Future<void> refreshUnread() async {
    final userId = _state.sessionUserId;
    final token = _token;
    if (userId == null || token.isEmpty) return;
    final sessionGeneration = _sessionGeneration;
    final requestGeneration = ++_unreadRequestGeneration;
    try {
      final count = await _repository.fetchUnreadCount(token: token);
      if (sessionGeneration != _sessionGeneration ||
          requestGeneration != _unreadRequestGeneration ||
          userId != _state.sessionUserId ||
          token != _token) {
        return;
      }
      _setState(_state.copyWith(unreadCount: count < 0 ? 0 : count));
    } catch (_) {
      // Keep the last valid badge count; unread failure must not blank the page.
    }
  }

  Future<UserProfile> signIn() async {
    final userId = _state.sessionUserId;
    final token = _token;
    if (userId == null || token.isEmpty) {
      throw StateError('A signed-in session is required.');
    }
    final sessionGeneration = _sessionGeneration;
    final profile = await _repository.dailySignIn(token: token);
    if (sessionGeneration == _sessionGeneration &&
        userId == _state.sessionUserId &&
        token == _token &&
        profile.user.id == userId) {
      replaceProfile(profile);
    }
    return profile;
  }

  void replaceProfile(UserProfile profile) {
    if (profile.user.id != _state.sessionUserId) return;
    _setState(
      _state.copyWith(
        profile: profile,
        phase: ProfileLoadPhase.ready,
        errorMessage: null,
      ),
    );
    final updater = _updateCachedUser;
    if (updater != null) unawaited(updater(profile.user));
  }

  void replaceShopItems(List<ShopItem> items) {
    _setState(_state.copyWith(shopItems: List<ShopItem>.unmodifiable(items)));
  }

  void markLibrarySectionRefreshed(ProfileLibrarySection section) {
    switch (section) {
      case ProfileLibrarySection.history:
        _setState(_state.copyWith(historyRevision: _state.historyRevision + 1));
      case ProfileLibrarySection.favorites:
        _setState(
          _state.copyWith(favoritesRevision: _state.favoritesRevision + 1),
        );
      case ProfileLibrarySection.downloads:
        _setState(
          _state.copyWith(downloadsRevision: _state.downloadsRevision + 1),
        );
    }
  }

  bool _isCurrentProfileRequest(
    int sessionGeneration,
    int requestGeneration,
    int userId,
    String token,
  ) {
    return sessionGeneration == _sessionGeneration &&
        requestGeneration == _profileRequestGeneration &&
        userId == _state.sessionUserId &&
        token == _token;
  }

  void _setState(ProfileViewState next) {
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }
}
