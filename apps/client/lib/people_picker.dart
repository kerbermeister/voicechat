import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'avatar_editor.dart';
import 'conversation_list.dart';

typedef GroupDraft = ({
  String name,
  List<String> users,
  mx.MatrixFile? avatar,
  bool personal,
});

/// Normal selection returns user IDs; the group form returns a GroupDraft.
class PeoplePicker extends StatefulWidget {
  final mx.Client client;
  final bool multiple, creatingGroup;
  final String? title;
  final Set<String>? allowedUsers;
  const PeoplePicker({
    super.key,
    required this.client,
    this.multiple = false,
    this.title,
    this.allowedUsers,
  }) : creatingGroup = false;
  const PeoplePicker.group({
    super.key,
    required this.client,
    required this.allowedUsers,
  }) : multiple = true,
       creatingGroup = true,
       title = 'Новая группа';
  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  final search = TextEditingController(), name = TextEditingController();
  final form = GlobalKey<FormState>();
  final selected = <String>{};
  final people = <String, mx.Profile>{};
  List<mx.Profile> results = [];
  mx.MatrixFile? avatar;
  bool busy = false, personal = false;
  String? status;
  bool eligible(String id) =>
      id != widget.client.userID &&
      (widget.allowedUsers == null || widget.allowedUsers!.contains(id));

  @override
  void initState() {
    super.initState();
    for (final id in widget.allowedUsers ?? <String>{}) {
      if (!eligible(id)) continue;
      mx.Room? direct;
      for (final room in widget.client.rooms) {
        if (room.isDirectChat && room.directChatMatrixID == id) {
          direct = room;
          break;
        }
      }
      final display = direct
          ?.getState(mx.EventTypes.RoomMember, id)
          ?.content['displayname'];
      people[id] = mx.Profile(
        userId: id,
        displayName: display is String
            ? display
            : id.split(':').first.replaceFirst('@', ''),
        avatarUrl: direct == null ? null : roomAvatar(direct),
      );
    }
  }

  Future<void> find() async {
    final query = search.text.trim();
    if (query.isEmpty || busy) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final response = await widget.client.searchUserDirectory(
        query,
        limit: 30,
      );
      final profiles = response.results.toList();
      if (query.startsWith('@') &&
          query.contains(':') &&
          eligible(query) &&
          profiles.every((p) => p.userId != query)) {
        profiles.add(await widget.client.getProfileFromUserId(query));
      }
      if (mounted && search.text.trim() == query) {
        setState(() {
          results = profiles.where((p) => eligible(p.userId)).toList();
          for (final p in results) {
            people[p.userId] = p;
          }
          status = results.isEmpty ? 'Никого не найдено' : null;
        });
      }
    } catch (_) {
      if (mounted && search.text.trim() == query) {
        setState(
          () => status = 'Поиск недоступен. Проверьте имя и соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void toggle(mx.Profile person) {
    if (!eligible(person.userId) || busy) return;
    if (!widget.multiple) {
      Navigator.pop(context, [person.userId]);
      return;
    }
    setState(() {
      if (!selected.add(person.userId)) selected.remove(person.userId);
    });
  }

  void confirm() {
    final users = selected.where(eligible).toList();
    if (users.isEmpty && !personal) return;
    if (widget.creatingGroup) {
      if (!form.currentState!.validate()) return;
      Navigator.pop<GroupDraft>(context, (
        name: name.text.trim(),
        users: personal ? <String>[] : users,
        personal: personal,
        avatar: avatar,
      ));
    } else {
      Navigator.pop(context, users);
    }
  }

  Widget panel(String title, Widget body) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      1.0,
      double.infinity,
    );
    final query = search.text.trim().toLowerCase();
    final visible =
        <String, mx.Profile>{
          for (final p in people.values)
            if (eligible(p.userId) &&
                (query.isEmpty ||
                    '${p.displayName ?? ''} ${p.userId}'.toLowerCase().contains(
                      query,
                    )))
              p.userId: p,
          if (query.isNotEmpty)
            for (final p in results)
              if (eligible(p.userId)) p.userId: p,
        }.values.toList()..sort(
          (a, b) =>
              (a.displayName ?? a.userId).compareTo(b.displayName ?? b.userId),
        );
    final friends = visible.isEmpty
        ? Center(
            child: Text(
              widget.allowedUsers?.isEmpty == true
                  ? 'Сначала добавьте людей в контакты'
                  : query.isEmpty
                  ? 'Введите имя или полный адрес пользователя'
                  : 'Совпадений нет',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        : ListView.builder(
            itemCount: visible.length,
            itemBuilder: (_, i) {
              final p = visible[i];
              return CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 2,
                ),
                value: selected.contains(p.userId),
                secondary: PersonAvatar(
                  name: p.displayName ?? p.userId,
                  size: 32,
                  client: widget.client,
                  url: p.avatarUrl,
                  showPresence: false,
                ),
                title: Text(
                  p.displayName ?? p.userId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  p.userId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: busy ? null : (_) => toggle(p),
              );
            },
          );
    Widget chosen(bool compact) => selected.isEmpty
        ? Center(
            child: Text(
              'Добавьте людей из контактов',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          )
        : compact
        ? SingleChildScrollView(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final id in selected)
                  InputChip(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    avatarBoxConstraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 24,
                    ),
                    avatar: PersonAvatar(
                      name: people[id]?.displayName ?? id,
                      size: 24,
                      client: widget.client,
                      url: people[id]?.avatarUrl,
                      showPresence: false,
                    ),
                    label: Text(people[id]?.displayName ?? id),
                    onDeleted: busy
                        ? null
                        : () => setState(() => selected.remove(id)),
                    deleteButtonTooltipMessage: 'Убрать участника',
                  ),
              ],
            ),
          )
        : ListView(
            children: [
              for (final id in selected)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: PersonAvatar(
                    name: people[id]?.displayName ?? id,
                    size: 32,
                    client: widget.client,
                    url: people[id]?.avatarUrl,
                    showPresence: false,
                  ),
                  title: Text(people[id]?.displayName ?? id, maxLines: 2),
                  subtitle: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Убрать участника',
                    onPressed: busy
                        ? null
                        : () => setState(() => selected.remove(id)),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
            ],
          );
    return AlertDialog(
      scrollable: true,
      title: AppDialogTitle(
        child: Text(
          widget.title ??
              (widget.multiple ? 'Добавить участников' : 'Найти человека'),
          textAlign: TextAlign.center,
        ),
      ),
      insetPadding: const EdgeInsets.all(16),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      content: SizedBox(
        width: widget.multiple ? 860 : 480,
        // The outer dialog scrolls on short screens; both participant panes
        // still need enough intrinsic room for their headings and lists.
        height: (MediaQuery.sizeOf(context).height - 210).clamp(
          (widget.creatingGroup
                  ? 620
                  : widget.multiple
                  ? 240
                  : 180) *
              textScale,
          760 * textScale,
        ),
        child: Form(
          key: form,
          child: Column(
            children: [
              if (widget.creatingGroup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: IconButton.filledTonal(
                          tooltip: 'Выбрать аватар группы',
                          onPressed: () async {
                            final next = await editAvatar(context);
                            if (mounted && next != null) {
                              setState(() => avatar = next);
                            }
                          },
                          padding: EdgeInsets.zero,
                          icon: avatar == null
                              ? const Icon(Icons.add_a_photo_outlined, size: 28)
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.memory(
                                    avatar!.bytes,
                                    width: 64,
                                    height: 64,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: name,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: 'Название группы',
                            hintText: 'Например, Семья',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Введите название группы'
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.creatingGroup)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Личная комната только для меня'),
                  subtitle: const Text('Без приглашений и звонков'),
                  value: personal,
                  onChanged: (value) => setState(() => personal = value),
                ),
              if (!personal)
                TextField(
                  controller: search,
                  autofocus: !widget.multiple,
                  onChanged: (_) => setState(() {
                    results = [];
                    status = null;
                  }),
                  onSubmitted: (_) => find(),
                  decoration: InputDecoration(
                    labelText: widget.allowedUsers == null
                        ? 'Поиск пользователей'
                        : 'Поиск среди контактов',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Найти',
                      onPressed: busy ? null : find,
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ),
                ),
              SizedBox(
                height: 3,
                child: busy ? const LinearProgressIndicator() : null,
              ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      status!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Expanded(
                child: personal
                    ? const Center(
                        child: Text(
                          'Сообщения и файлы доступны только вам на ваших устройствах.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : widget.multiple
                    ? LayoutBuilder(
                        builder: (context, box) {
                          if (box.maxWidth >= 600) {
                            return Row(
                              children: [
                                Expanded(
                                  child: panel('Ваши контакты', friends),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: panel(
                                    'Выбрано · ${selected.length}',
                                    chosen(false),
                                  ),
                                ),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              Expanded(child: panel('Ваши контакты', friends)),
                              const SizedBox(height: 8),
                              SizedBox(
                                height:
                                    (box.maxHeight > 260 ? 104 : 80) *
                                    textScale,
                                child: panel(
                                  'Выбрано · ${selected.length}',
                                  chosen(true),
                                ),
                              ),
                            ],
                          );
                        },
                      )
                    : friends,
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.all(16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (widget.multiple)
          FilledButton(
            onPressed: (selected.isEmpty && !personal) || busy ? null : confirm,
            child: Text(widget.creatingGroup ? 'Создать' : 'Добавить'),
          ),
      ],
    );
  }

  @override
  void dispose() {
    search.dispose();
    name.dispose();
    super.dispose();
  }
}
