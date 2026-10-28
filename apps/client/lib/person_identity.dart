import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'conversation_list.dart';
import 'presence_tracker.dart';
import 'theme.dart';

mx.Profile? cachedPersonProfile(mx.Client client, String id) {
  for (final room in client.rooms) {
    final member = room.getState(mx.EventTypes.RoomMember, id)?.content;
    if (member == null) continue;
    return mx.Profile(
      userId: id,
      displayName: member['displayname'] is String
          ? member['displayname'] as String
          : null,
      avatarUrl:
          member['avatar_url'] is String &&
              (member['avatar_url'] as String).isNotEmpty
          ? Uri.tryParse(member['avatar_url'] as String)
          : null,
    );
  }
  return null;
}

/// The same identity in a picker, selected recipients and transfer cards.
class PersonIdentity extends StatefulWidget {
  final mx.Client client;
  final String userId;
  final mx.Profile? profile;
  const PersonIdentity({
    super.key,
    required this.client,
    required this.userId,
    this.profile,
  });

  @override
  State<PersonIdentity> createState() => _PersonIdentityState();
}

class _PersonIdentityState extends State<PersonIdentity> {
  mx.Profile? profile;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(PersonIdentity old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client ||
        old.userId != widget.userId ||
        old.profile != widget.profile) {
      load();
    }
  }

  void load() {
    profile =
        widget.profile ?? cachedPersonProfile(widget.client, widget.userId);
    if (profile != null) return;
    final client = widget.client;
    final id = widget.userId;
    unawaited(() async {
      try {
        final next = await client.getProfileFromUserId(id);
        if (mounted && client == widget.client && id == widget.userId) {
          setState(() => profile = next);
        }
      } catch (_) {
        // Keep the username visible when a profile cannot be fetched.
      }
    }());
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<mx.CachedPresence>(
    stream: widget.client.onPresenceChanged.stream,
    builder: (context, _) {
      // ignore: deprecated_member_use
      final presence = widget.client.presences[widget.userId];
      final online = presence?.presence == mx.PresenceType.online;
      final colors = Theme.of(context).colorScheme;
      final name = profile?.displayName?.trim();
      final display = name == null || name.isEmpty
          ? widget.userId.split(':').first.replaceFirst('@', '')
          : name;
      return Row(
        children: [
          PersonAvatar(
            name: display,
            client: widget.client,
            url: profile?.avatarUrl,
            size: 40,
            online: online,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(display, style: Theme.of(context).textTheme.titleSmall),
                Text(
                  widget.userId,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  presenceLabel(presence),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: online
                        ? onlinePresenceColor(colors)
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
