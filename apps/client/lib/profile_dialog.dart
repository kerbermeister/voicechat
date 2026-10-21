import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'contact_service.dart';
import 'conversation_list.dart';
import 'presence_tracker.dart';
import 'theme.dart';

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
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(own ? 'Мой профиль' : 'Профиль'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PersonAvatar(
                name: name,
                size: 96,
                online: online,
                client: widget.client,
                url: own ? widget.ownAvatar : profile?.avatarUrl,
              ),
              const SizedBox(height: 16),
              Text(name, style: Theme.of(context).textTheme.titleLarge),
              SelectableText(widget.userId),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    online ? Icons.circle : Icons.radio_button_unchecked,
                    size: 14,
                    color: online
                        ? onlinePresenceColor(Theme.of(context).colorScheme)
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(status),
                ],
              ),
              if (!online)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    lastSeen(current, DateTime.now()),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (!own && contact?.state == 'pending')
                const Text('Запрос ожидает подтверждения'),
              if (!own && contact?.state == 'declined')
                const Text('Запрос отклонён'),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
      actions: [
        if (own)
          TextButton.icon(
            onPressed: () => Navigator.pop(context, 'avatar'),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Изменить аватар'),
          ),
        if (!own && contact?.state != 'pending' && contact?.state != 'declined')
          FilledButton(
            onPressed: !widget.contacts.available
                ? null
                : () => Navigator.pop(context, 'contact'),
            child: Text(
              contact?.state == 'accepted' || openMessages == true
                  ? 'Написать'
                  : 'Пригласить в контакты',
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.contacts.removeListener(refresh);
    presence?.cancel();
    super.dispose();
  }
}
