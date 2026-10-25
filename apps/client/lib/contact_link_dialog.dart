import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'app_motion.dart';
import 'contact_link.dart';
import 'identity_field.dart';
import 'link_platform.dart';
import 'user_action_error.dart';

class ContactLinkDialog extends StatefulWidget {
  final ContactLinks links;
  final bool create;
  final String? initialLink;
  const ContactLinkDialog({
    super.key,
    required this.links,
    this.create = false,
    this.initialLink,
  });
  @override
  State<ContactLinkDialog> createState() => _ContactLinkDialogState();
}

class _ContactLinkDialogState extends State<ContactLinkDialog> {
  late final input = TextEditingController(text: widget.initialLink);
  String? token, shared, error;
  Map<String, dynamic>? preview;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialLink != null) inspect();
  }

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
          : 'Не удалось завершить действие. Проверьте связь и повторите.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> inspect() => act(() async {
    preview = null;
    token = contactLinkToken(input.text, widget.links.origin);
    preview = await widget.links.inspect(token!);
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: AppDialogTitle(
        child: Text(
          widget.create ? 'Пригласить по ссылке' : 'Приглашение в контакты',
        ),
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.create) ...[
              const Text(
                'Ссылка для одного человека. После подтверждения вы станете контактами, и он отправит вам «Привет», даже если у вас закрыты входящие.',
              ),
              const SizedBox(height: 12),
              if (shared != null)
                IdentityField(label: 'Одноразовое приглашение', value: shared!),
            ] else if (preview == null) ...[
              const Text(
                'Вставьте ссылку, чтобы узнать, кто вас приглашает. Проверка ссылки не расходует приглашение.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: input,
                enabled: !busy,
                maxLines: 3,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Ссылка-приглашение',
                ),
              ),
            ] else ...[
              IdentityField(
                label: 'Вас приглашает',
                value: preview!['owner'] as String,
              ),
              const SizedBox(height: 12),
              Text(
                preview!['owner'] == widget.links.client.userID
                    ? 'Это ваше приглашение. Передайте ссылку другому человеку.'
                    : preview!['event_id'] != null
                    ? 'Вы уже приняли это приглашение. Приветствие отправлено.'
                    : 'Вы добавите этого человека в контакты и отправите ему «Привет». Ваши общие настройки приватности сохранятся.',
              ),
            ],
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Обработка приглашения',
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        if (widget.create && shared == null)
          FilledButton(
            onPressed: busy
                ? null
                : () => act(() async {
                    shared = (await widget.links.create()).toString();
                  }),
            child: const Text('Создать ссылку'),
          ),
        if (widget.create && shared != null)
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => act(() => shareLink(Uri.parse(shared!))),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Поделиться'),
          ),
        if (!widget.create && preview == null)
          FilledButton(
            onPressed: busy ? null : inspect,
            child: const Text('Проверить ссылку'),
          ),
        if (!widget.create &&
            preview != null &&
            preview!['owner'] != widget.links.client.userID)
          FilledButton(
            onPressed: busy
                ? null
                : () => act(() async {
                    final room = await widget.links.accept(token!);
                    if (context.mounted) Navigator.pop<Room>(context, room);
                  }),
            child: Text(
              preview!['event_id'] != null
                  ? 'Открыть чат'
                  : 'Добавить и отправить «Привет»',
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}
