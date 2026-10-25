import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'contact_service.dart';
import 'user_action_error.dart';
import 'theme.dart';

class InvitationStateBadge extends StatelessWidget {
  final String state;
  const InvitationStateBadge({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, icon, background, foreground) = switch (state) {
      'accepted' => (
        'Принято',
        Icons.check_circle_outline,
        onlinePresenceColor(colors).withValues(alpha: .12),
        onlinePresenceColor(colors),
      ),
      'declined' => (
        'Отклонено',
        Icons.highlight_off,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      'cancelled' => (
        'Отменено',
        Icons.block,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      _ => (
        'Ожидает ответа',
        Icons.schedule,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
    };
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: foreground, fontSize: 12)),
        ],
      ),
    );
  }
}

class InvitationsDialog extends StatefulWidget {
  final ContactService contacts;
  const InvitationsDialog({super.key, required this.contacts});
  @override
  State<InvitationsDialog> createState() => _InvitationsDialogState();
}

class _InvitationsDialogState extends State<InvitationsDialog> {
  bool busy = false;
  String? error;
  Future<void> act(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      error = e is UserActionError
          ? e.message
          : 'Не удалось выполнить действие. Повторите попытку.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.contacts,
    builder: (_, _) {
      final service = widget.contacts;
      final client = service.client;
      final groups = service.groups.reversed.toList();
      Widget buttons(VoidCallback accept, VoidCallback decline) => Wrap(
        children: [
          TextButton(
            onPressed: busy ? null : accept,
            child: const Text('Принять'),
          ),
          TextButton(
            onPressed: busy ? null : decline,
            child: const Text('Отклонить'),
          ),
        ],
      );
      return DefaultTabController(
        length: 2,
        child: AlertDialog(
          title: AppDialogTitle(child: const Text('Приглашения')),
          content: SizedBox(
            width: 500,
            height: 420,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Люди'),
                    Tab(text: 'Группы'),
                  ],
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!service.available)
                  const Text('Нет связи с сервисом контактов'),
                Expanded(
                  child: TabBarView(
                    children: [
                      service.requests.isEmpty
                          ? const Center(child: Text('Пока нет приглашений'))
                          : ListView.separated(
                              itemCount: service.requests.length,
                              separatorBuilder: (_, _) => const Divider(),
                              itemBuilder: (_, i) {
                                final request = service.requests[i];
                                final incoming =
                                    request.recipient == client.userID;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      title: Text(request.peer(client.userID!)),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            incoming ? 'Входящее' : 'Исходящее',
                                          ),
                                          InvitationStateBadge(
                                            state: request.state,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (request.state == 'pending')
                                      incoming
                                          ? buttons(
                                              () => act(
                                                () => service.decide(
                                                  request,
                                                  'accept',
                                                ),
                                              ),
                                              () => act(
                                                () => service.decide(
                                                  request,
                                                  'decline',
                                                ),
                                              ),
                                            )
                                          : TextButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => act(
                                                      () => service.decide(
                                                        request,
                                                        'cancel',
                                                      ),
                                                    ),
                                              child: const Text(
                                                'Отменить запрос',
                                              ),
                                            ),
                                  ],
                                );
                              },
                            ),
                      groups.isEmpty
                          ? const Center(
                              child: Text('Нет приглашений в группы'),
                            )
                          : ListView.separated(
                              itemCount: groups.length,
                              separatorBuilder: (_, _) => const Divider(),
                              itemBuilder: (_, i) {
                                final invitation = groups[i];
                                final room = client.getRoomById(
                                  invitation.roomId,
                                );
                                final incoming =
                                    invitation.userId == client.userID;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      title: Text(invitation.name),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            incoming
                                                ? 'Входящее · ${invitation.inviter}'
                                                : 'Исходящее · ${invitation.userId}',
                                          ),
                                          InvitationStateBadge(
                                            state: invitation.state,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (incoming &&
                                        invitation.state == 'pending' &&
                                        room?.membership ==
                                            mx.Membership.invite)
                                      buttons(
                                        () => act(() async {
                                          await room!.join();
                                          await service.refresh();
                                        }),
                                        () => act(() async {
                                          await room!.leave();
                                          await service.refresh();
                                        }),
                                      ),
                                  ],
                                );
                              },
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    },
  );
}
