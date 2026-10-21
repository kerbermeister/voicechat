import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;

class PeoplePicker extends StatefulWidget {
  final mx.Client client;
  final bool multiple;
  const PeoplePicker({super.key, required this.client, this.multiple = false});
  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  final search = TextEditingController();
  final selected = <String>{};
  List<mx.Profile> results = [];
  bool busy = false;
  String status = 'Введите имя пользователя или полный @username:server';
  Future<void> find() async {
    final query = search.text.trim();
    if (query.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      final response = await widget.client.searchUserDirectory(
        query,
        limit: 30,
      );
      final profiles = response.results;
      if (query.startsWith('@') &&
          query.contains(':') &&
          profiles.every((p) => p.userId != query)) {
        final p = await widget.client.getProfileFromUserId(query);
        profiles.add(
          mx.Profile(
            userId: query,
            displayName: p.displayName,
            avatarUrl: p.avatarUrl,
          ),
        );
      }
      if (mounted) {
        setState(() {
          results = profiles
              .where((p) => p.userId != widget.client.userID)
              .toList();
          status = results.isEmpty
              ? 'Никого не найдено'
              : 'Выберите собеседников';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status = 'Поиск недоступен. Проверьте имя и соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.multiple ? 'Добавить участников' : 'Новая переписка'),
    content: SizedBox(
      width: 480,
      height: 400,
      child: Column(
        children: [
          TextField(
            controller: search,
            autofocus: true,
            onSubmitted: (_) => find(),
            decoration: InputDecoration(
              labelText: 'Поиск пользователей',
              suffixIcon: IconButton(
                tooltip: 'Найти',
                onPressed: find,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Padding(padding: const EdgeInsets.all(8), child: Text(status)),
          if (selected.isNotEmpty) Text('Выбрано: ${selected.length}'),
          Expanded(
            child: ListView(
              children: results
                  .map(
                    (p) => CheckboxListTile(
                      value: selected.contains(p.userId),
                      title: Text(p.displayName ?? p.userId),
                      subtitle: Text(p.userId),
                      onChanged: busy
                          ? null
                          : (value) {
                              if (!widget.multiple) {
                                Navigator.pop(context, [p.userId]);
                                return;
                              }
                              setState(() {
                                if (value == true) {
                                  selected.add(p.userId);
                                } else {
                                  selected.remove(p.userId);
                                }
                              });
                            },
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      if (widget.multiple)
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected.toList()),
          child: const Text('Добавить'),
        ),
    ],
  );
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }
}
