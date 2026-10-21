import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'chat_actions.dart';

Future<({mx.Room room, String? event})?> searchHistory(
  BuildContext context,
  mx.Client client,
) => showDialog<({mx.Room room, String? event})>(
  context: context,
  builder: (_) => _HistorySearch(client: client),
);

class _HistorySearch extends StatefulWidget {
  final mx.Client client;
  const _HistorySearch({required this.client});
  @override
  State<_HistorySearch> createState() => _HistorySearchState();
}

class _HistorySearchState extends State<_HistorySearch> {
  final input = TextEditingController();
  final messages = <({mx.Event event, mx.Event shown})>[];
  bool busy = false;
  int checked = 0;
  int limit = 1000;
  String? error;
  List<mx.Room> get rooms => widget.client.rooms
      .where((r) => r.membership == mx.Membership.join)
      .toList();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      checked = 0;
      messages.clear();
      error = null;
    });
    try {
      for (final room in rooms) {
        if (!mounted) return;
        final timeline = await room.getTimeline(limit: limit);
        try {
          messages.addAll(
            visibleMessages(timeline, '')
                .where((e) => e.type == mx.EventTypes.Message && !e.redacted)
                .map((e) => (event: e, shown: e.getDisplayEvent(timeline))),
          );
        } finally {
          timeline.cancelSubscriptions();
        }
        if (mounted) setState(() => checked++);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Часть локальной истории недоступна.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = input.text.trim().toLowerCase();
    final foundRooms = rooms
        .where(
          (r) =>
              query.isNotEmpty &&
              r.getLocalizedDisplayname().toLowerCase().contains(query),
        )
        .toList();
    final foundMessages =
        messages
            .where(
              (e) =>
                  query.isNotEmpty &&
                  '${e.shown.calcUnlocalizedBody(hideReply: true)} ${e.shown.content['caption'] ?? ''} ${e.shown.content['dev.voicechat.caption'] ?? ''}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort(
            (a, b) => b.event.originServerTs.compareTo(a.event.originServerTs),
          );
    return AlertDialog(
      title: const Text('Поиск'),
      content: SizedBox(
        width: 620,
        height: 510,
        child: Column(
          children: [
            TextField(
              controller: input,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Чат или фраза из сообщения',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Только расшифрованная локальная история: до $limit событий на чат. Проверено чатов: $checked / ${rooms.length}.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) Text(error!),
            Expanded(
              child: query.isEmpty
                  ? const Center(child: Text('Введите имя чата или фразу'))
                  : foundRooms.isEmpty && foundMessages.isEmpty
                  ? const Center(
                      child: Text('В проверенной истории совпадений нет'),
                    )
                  : ListView(
                      children: [
                        if (foundRooms.isNotEmpty)
                          const ListTile(title: Text('Чаты')),
                        for (final room in foundRooms)
                          ListTile(
                            leading: Icon(
                              room.isDirectChat
                                  ? Icons.person_outline
                                  : Icons.group_outlined,
                            ),
                            title: Text(room.getLocalizedDisplayname()),
                            onTap: () => Navigator.pop(context, (
                              room: room,
                              event: null,
                            )),
                          ),
                        if (foundMessages.isNotEmpty)
                          const ListTile(title: Text('Сообщения')),
                        for (final event in foundMessages.take(200))
                          ListTile(
                            title: Text(
                              event.shown.calcUnlocalizedBody(hideReply: true),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${event.event.room.getLocalizedDisplayname()} · ${event.event.originServerTs.toLocal()}',
                            ),
                            onTap: () => Navigator.pop(context, (
                              room: event.event.room,
                              event: event.event.eventId,
                            )),
                          ),
                      ],
                    ),
            ),
            TextButton(
              onPressed: busy || limit >= 10000
                  ? null
                  : () {
                      limit += 1000;
                      load();
                    },
              child: const Text('Проверить больше локальной истории'),
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
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}
