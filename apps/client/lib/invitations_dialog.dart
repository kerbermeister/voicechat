import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'contact_service.dart';
import 'conversation_list.dart';
import 'user_action_error.dart';

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
      final groups = client.rooms
          .where(
            (r) =>
                !r.isDirectChat &&
                (r.membership == mx.Membership.invite ||
                    r.getParticipants().any(
                      (u) =>
                          u.membership == mx.Membership.invite &&
                          r
                                  .getState(mx.EventTypes.RoomMember, u.id)
                                  ?.senderId ==
                              client.userID,
                    )),
          )
          .toList();
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
          title: const Text('Приглашения'),
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
                                final state = switch (request.state) {
                                  'accepted' => 'Принято',
                                  'declined' => 'Отклонено',
                                  'cancelled' => 'Отменено',
                                  _ => 'Ожидает ответа',
                                };
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      title: Text(request.peer(client.userID!)),
                                      subtitle: Text(
                                        '${incoming ? "Входящее" : "Исходящее"} · $state',
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
                                final room = groups[i];
                                final incoming =
                                    room.membership == mx.Membership.invite;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      title: Text(roomDisplayName(room)),
                                      subtitle: Text(
                                        incoming
                                            ? 'Входящее · ${room.getState(mx.EventTypes.RoomMember, client.userID!)?.senderId ?? ""}'
                                            : 'Исходящие · ${room.getParticipants().where((u) => u.membership == mx.Membership.invite).map((u) => u.displayName ?? u.id).join(", ")}',
                                      ),
                                    ),
                                    if (incoming)
                                      buttons(
                                        () => act(() async {
                                          await room.join();
                                          await service.refresh();
                                        }),
                                        () => act(() async {
                                          await room.leave();
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
