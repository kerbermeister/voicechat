import 'package:matrix/matrix.dart';

class GroupInvitation {
  final String roomId, userId, inviter, name, state;
  const GroupInvitation(
    this.roomId,
    this.userId,
    this.inviter,
    this.name,
    this.state,
  );
  factory GroupInvitation.fromJson(Map<String, dynamic> data) {
    final value = GroupInvitation(
      data['room'] as String,
      data['user'] as String,
      data['inviter'] as String,
      data['name'] as String,
      data['state'] as String,
    );
    if (!value.roomId.startsWith('!') ||
        !value.userId.startsWith('@') ||
        !value.inviter.startsWith('@') ||
        ![
          'pending',
          'accepted',
          'declined',
          'cancelled',
        ].contains(value.state)) {
      throw const FormatException('Invalid group invitation');
    }
    return value;
  }
  Map<String, dynamic> toJson() => {
    'room': roomId,
    'user': userId,
    'inviter': inviter,
    'name': name,
    'state': state,
  };
}

List<GroupInvitation> groupInvitations(
  Client client,
  List<GroupInvitation> previous, {
  Iterable<({String roomId, StrippedStateEvent state})> updates = const [],
}) {
  final entries = {
    for (final item in previous) '${item.roomId}\u0000${item.userId}': item,
  };
  for (final room in client.rooms) {
    if (room.isDirectChat ||
        room.getState('dev.voicechat.kind')?.content['kind'] == 'direct') {
      continue;
    }
    for (final event
        in room.states[EventTypes.RoomMember]?.values ?? <Event>[]) {
      final user = event.stateKey;
      if (user == null) continue;
      final key = '${room.id}\u0000$user';
      final old = entries[key];
      final membership = event.content['membership'];
      if (membership == 'invite' &&
          (user == client.userID || event.senderId == client.userID)) {
        entries[key] = GroupInvitation(
          room.id,
          user,
          event.senderId,
          room.getLocalizedDisplayname(),
          'pending',
        );
      } else if (old != null) {
        entries[key] = _outcome(old, event);
      }
    }
  }
  // Left rooms can be absent from client.rooms by the time sync is announced.
  for (final update in updates) {
    final key = '${update.roomId}\u0000${update.state.stateKey}';
    final old = entries[key];
    if (old != null) entries[key] = _outcome(old, update.state);
  }
  return entries.values.toList();
}

GroupInvitation _outcome(GroupInvitation old, StrippedStateEvent event) {
  if (old.state != 'pending') return old;
  final state = switch (event.content['membership']) {
    'join' => 'accepted',
    'leave' || 'ban' => event.senderId == old.userId ? 'declined' : 'cancelled',
    _ => 'pending',
  };
  return GroupInvitation(old.roomId, old.userId, old.inviter, old.name, state);
}
