import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat sockets only run while the user is a room member', () {
    final connection = File(
      'lib/screens/chat_room_state_connection.dart',
    ).readAsStringSync();
    final room = File(
      'lib/screens/chat_room_state_room.dart',
    ).readAsStringSync();

    expect(connection, contains('await _loadRoomSnapshot(showError: false);'));
    expect(connection, contains('if (!_isJoinedRoom) return;'));
    expect(
      connection,
      matches(
        RegExp(
          r'if\s*\(\s*!mounted\s*\|\|\s*!_isJoinedRoom\s*\|\|\s*serial\s*!=\s*_connectionSerial',
        ),
      ),
    );
    expect(connection, contains('_disconnectChat();'));
    expect(room, contains('unawaited(_connect(announceEntrance: true));'));
    expect(room, contains('_disconnectChat();'));
    expect(connection, contains('int _roomMembershipRevision = 0;'));
    expect(
      room,
      contains('final membershipRevision = _roomMembershipRevision;'),
    );
    expect(room, contains('membershipRevision != _roomMembershipRevision'));
    expect(
      RegExp(r'_roomMembershipRevision\s*\+=\s*1;').allMatches(room),
      hasLength(2),
    );
  });
}
