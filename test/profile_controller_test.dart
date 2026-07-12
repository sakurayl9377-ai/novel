import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/profile/controller/profile_controller.dart';
import 'package:novel_app/models/interaction_user.dart';

void main() {
  group('ProfileController', () {
    test(
      'ignores a stale profile response after the session changes',
      () async {
        final repository = _FakeProfileRepository();
        final firstProfile = Completer<UserProfile>();
        final secondProfile = Completer<UserProfile>();
        repository.profileResponses['token-1'] = firstProfile.future;
        repository.profileResponses['token-2'] = secondProfile.future;
        final controller = ProfileController(repository: repository);

        final firstLoad = controller.switchSession(
          user: _user(1),
          token: 'token-1',
        );
        await Future<void>.delayed(Duration.zero);
        final secondLoad = controller.switchSession(
          user: _user(2),
          token: 'token-2',
        );
        secondProfile.complete(UserProfile(user: _user(2)));
        await secondLoad;
        firstProfile.complete(UserProfile(user: _user(1)));
        await firstLoad;

        expect(controller.state.sessionUserId, 2);
        expect(controller.state.profile?.user.id, 2);
        expect(controller.profileFor(_user(1)), isNull);
        controller.dispose();
      },
    );

    test('retains the last profile and shop data when refresh fails', () async {
      final repository = _FakeProfileRepository()
        ..profileResponses['token'] = Future<UserProfile>.value(
          UserProfile(user: _user(7)),
        )
        ..shopItems = const <ShopItem>[ShopItem(id: 'frame', name: 'Frame')];
      final controller = ProfileController(repository: repository);
      await controller.switchSession(user: _user(7), token: 'token');

      repository.profileResponses['token'] = Future<UserProfile>.error(
        StateError('offline'),
      );
      repository.shopItems = const <ShopItem>[];
      await controller.refresh();

      expect(controller.state.profile?.user.id, 7);
      expect(controller.state.shopItems.single.id, 'frame');
      expect(controller.state.phase, ProfileLoadPhase.ready);
      expect(controller.state.hasError, isTrue);
      controller.dispose();
    });

    test('clears private state on logout', () async {
      final repository = _FakeProfileRepository()
        ..profileResponses['token'] = Future<UserProfile>.value(
          UserProfile(user: _user(5)),
        );
      final controller = ProfileController(repository: repository);
      await controller.switchSession(user: _user(5), token: 'token');

      await controller.switchSession(user: null, token: '');

      expect(controller.state, const TypeMatcher<ProfileViewState>());
      expect(controller.state.sessionUserId, isNull);
      expect(controller.state.profile, isNull);
      expect(controller.state.unreadCount, 0);
      controller.dispose();
    });

    test(
      'tracks history, favorites and downloads returning from child pages',
      () {
        final controller = ProfileController(
          repository: _FakeProfileRepository(),
        );

        controller
          ..markLibrarySectionRefreshed(ProfileLibrarySection.history)
          ..markLibrarySectionRefreshed(ProfileLibrarySection.favorites)
          ..markLibrarySectionRefreshed(ProfileLibrarySection.downloads);

        expect(controller.state.historyRevision, 1);
        expect(controller.state.favoritesRevision, 1);
        expect(controller.state.downloadsRevision, 1);
        controller.dispose();
      },
    );
  });

  group('ProfilePermissionPolicy', () {
    test('only exposes the administrator entry to privileged roles', () {
      expect(
        ProfilePermissionPolicy.canOpenAdminEntry(_user(1, role: 'admin')),
        isTrue,
      );
      expect(
        ProfilePermissionPolicy.canOpenAdminEntry(
          _user(2, role: 'super_admin'),
        ),
        isTrue,
      );
      expect(
        ProfilePermissionPolicy.canOpenAdminEntry(_user(3, role: 'user')),
        isFalse,
      );
      expect(ProfilePermissionPolicy.canOpenAdminEntry(null), isFalse);
    });
  });
}

InteractionUser _user(int id, {String role = 'user'}) {
  return InteractionUser(
    id: id,
    email: 'user$id@example.com',
    nickname: 'User $id',
    role: role,
  );
}

class _FakeProfileRepository implements ProfileRepository {
  final Map<String, Future<UserProfile>> profileResponses =
      <String, Future<UserProfile>>{};
  List<ShopItem> shopItems = const <ShopItem>[];
  int unreadCount = 0;

  @override
  Future<UserProfile> dailySignIn({required String token}) {
    return fetchProfile(token: token);
  }

  @override
  Future<UserProfile> fetchProfile({required String token}) {
    return profileResponses[token] ??
        Future<UserProfile>.error(StateError('Missing response for $token'));
  }

  @override
  Future<List<ShopItem>> fetchShopItems() async => shopItems;

  @override
  Future<int> fetchUnreadCount({required String token}) async => unreadCount;
}
