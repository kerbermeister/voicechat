import 'app_motion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'contact_service.dart';
import 'conversation_list.dart';
import 'presence_tracker.dart';
import 'theme.dart';
import 'identity_field.dart';

class ProfileDialog extends StatefulWidget {
  final mx.Client client;
  final ContactService contacts;
  final String userId;
  final Uri? ownAvatar;
  const ProfileDialog({
    super.key,
    required this.client,
    required this.contacts,
    required this.userId,
    this.ownAvatar,
  });
  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  mx.Profile? profile;
  bool? openMessages;
  String? error;
  StreamSubscription<mx.CachedPresence>? presence;
  bool get own => widget.userId == widget.client.userID;
  @override
  void initState() {
    super.initState();
    widget.contacts.addListener(refresh);
    presence = widget.client.onPresenceChanged.stream.listen((p) {
      if (p.userid == widget.userId) refresh();
    });
    load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    try {
      profile = await widget.client.getProfileFromUserId(widget.userId);
      if (!own) openMessages = await widget.contacts.policyFor(widget.userId);
    } catch (_) {
      error = 'Часть данных профиля сейчас недоступна';
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    final current = widget.client.presences[widget.userId];
    final online = current?.presence == mx.PresenceType.online;
    final status = presenceLabel(current);
    final name =
        profile?.displayName ?? widget.userId.split(':').first.substring(1);
    final contact = widget.contacts.requests
        .where((r) => r.peer(widget.client.userID!) == widget.userId)
        .firstOrNull;
    final colors = Theme.of(context).colorScheme;
    final waiting = !own && contact?.state == 'pending';
    final declined = !own && contact?.state == 'declined';
    return AlertDialog(
      scrollable: true,
      backgroundColor: colors.surfaceContainerLowest,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      title: AppDialogTitle(child: Text(own ? 'Мой профиль' : 'Профиль')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.surfaceContainerHigh,
                    colors.surfaceContainerLowest,
                  ],
                ),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PersonAvatar(
                    name: name,
                    size: 88,
                    online: online,
                    client: widget.client,
                    url: own ? widget.ownAvatar : profile?.avatarUrl,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: .65),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          online ? Icons.circle : Icons.radio_button_unchecked,
                          size: 10,
                          color: online
                              ? onlinePresenceColor(colors)
                              : colors.outline,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            status,
                            style: TextStyle(
                              color: online
                                  ? onlinePresenceColor(colors)
                                  : colors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!online)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        lastSeen(current, DateTime.now()),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            IdentityField(label: 'Адрес в VoiceChat', value: widget.userId),
            if (waiting || declined || error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (waiting) const Text('Запрос ожидает подтверждения'),
                        if (declined) const Text('Запрос отклонён'),
                        if (error != null) Text(error!),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            if (own)
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'create-link'),
                icon: const Icon(Icons.add_link),
                label: const Text('Пригласить по ссылке'),
              ),
            if (own)
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'avatar'),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Изменить аватар'),
              ),
            if (!own && !waiting && !declined)
              FilledButton.icon(
                onPressed: !widget.contacts.available
                    ? null
                    : () => Navigator.pop(context, 'contact'),
                icon: Icon(
                  contact?.state == 'accepted' || openMessages == true
                      ? Icons.chat_bubble_outline_rounded
                      : Icons.person_add_outlined,
                ),
                label: Text(
                  contact?.state == 'accepted' || openMessages == true
                      ? 'Написать'
                      : 'Пригласить в контакты',
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.contacts.removeListener(refresh);
    presence?.cancel();
    super.dispose();
  }
}
