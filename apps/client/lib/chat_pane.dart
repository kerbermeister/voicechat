import 'dart:async';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'image_source.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:record/record.dart';
import 'chat_actions.dart';
import 'voice_recording.dart';
import 'user_action_error.dart';

String? reactionEmoji(mx.Event event) {
  final relation = event.content['m.relates_to'];
  if (relation is! Map) return null;
  final key = relation['key'];
  return key is String && key.length <= 32 ? key : null;
}

const chatEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🎉', '😊'];

class ChatPane extends StatefulWidget {
  final mx.Room room;
  final mx.Timeline timeline;
  final ChatActions actions;
  final Widget header;
  final void Function(String) report;
  const ChatPane({
    super.key,
    required this.room,
    required this.timeline,
    required this.actions,
    required this.header,
    required this.report,
  });
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> with WidgetsBindingObserver {
  final input = TextEditingController();
  final search = TextEditingController();
  final scroll = ScrollController();
  final recorder = AudioRecorder();
  mx.Event? reply;
  mx.Event? edit;
  bool working = false;
  bool recording = false;
  bool stopping = false;
  bool recordingFailed = false;
  DateTime lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastRead;
  Timer? recordingLimit;
  BytesBuilder? pcm;
  Completer<void>? recordingDone;
  StreamSubscription<Uint8List>? recordingStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.actions.addListener(refresh);
    scroll.addListener(markRead);
    WidgetsBinding.instance.addPostFrameCallback((_) => markRead());
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> perform(Future<void> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
    } catch (error) {
      widget.report(
        error is UserActionError
            ? error.message
            : 'Не удалось выполнить действие. Проверьте соединение и доступ.',
      );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void markRead() {
    if (!mounted ||
        search.text.isNotEmpty ||
        (scroll.hasClients && scroll.offset > 48) ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final events = widget.timeline.events
        .where((e) => e.status.isSent)
        .toList();
    if (events.isEmpty || lastRead == events.first.eventId) return;
    lastRead = events.first.eventId;
    unawaited(
      widget.timeline.setReadMarker(eventId: lastRead, public: true).catchError(
        (Object _) {
          lastRead = null;
        },
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) markRead();
    if (state != AppLifecycleState.resumed && recording) {
      unawaited(finishRecording(send: false));
    }
  }

  void typing(String value) {
    final now = DateTime.now();
    if (value.isEmpty || now.difference(lastTyping).inSeconds >= 4) {
      lastTyping = now;
      unawaited(
        widget.room
            .setTyping(value.isNotEmpty, timeout: 8000)
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> send() async {
    await widget.actions.text(
      widget.room,
      input.text,
      reply: reply,
      edit: edit?.eventId,
    );
    input.clear();
    typing('');
    setState(() {
      reply = null;
      edit = null;
    });
  }

  Future<void> image() async {
    final media = await chooseImage();
    if (media == null) return;
    if (media is! mx.MatrixImageFile) {
      throw UserActionError('Выберите изображение.');
    }
    await widget.actions.attachment(widget.room, media, reply: reply);
    if (mounted) setState(() => reply = null);
  }

  Future<void> startRecording() async {
    if (!await recorder.hasPermission()) {
      throw UserActionError(
        'Для голосового сообщения разрешите доступ к микрофону.',
      );
    }
    recordingFailed = false;
    pcm = BytesBuilder(copy: false);
    recordingDone = Completer<void>();
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    recordingStream = stream.listen(
      (chunk) {
        if (pcm!.length + chunk.length <= 16000 * 2 * 180) {
          pcm!.add(chunk);
        } else if (!stopping) {
          unawaited(finishRecording());
        }
      },
      onDone: () {
        if (!recordingDone!.isCompleted) recordingDone!.complete();
      },
      onError: (Object _) {
        if (!recordingDone!.isCompleted) {
          recordingFailed = true;
          recordingDone!.complete();
          unawaited(finishRecording(send: false));
          widget.report(
            'Запись прервалась. Попробуйте записать сообщение снова.',
          );
        }
      },
    );
    recordingLimit = Timer(
      const Duration(minutes: 3),
      () => unawaited(finishRecording()),
    );
    if (mounted) setState(() => recording = true);
  }

  Future<void> finishRecording({bool send = true}) async {
    if (!recording || stopping) return;
    stopping = true;
    recordingLimit?.cancel();
    try {
      await recorder.stop();
      await recordingDone!.future;
      final bytes = pcm!.takeBytes();
      if (send && !recordingFailed && bytes.isNotEmpty) {
        await widget.actions.attachment(
          widget.room,
          mx.MatrixAudioFile(
            bytes: voiceWav(bytes),
            name: 'Голосовое сообщение.wav',
            mimeType: 'audio/wav',
            duration: bytes.length * 1000 ~/ 32000,
          ),
          reply: reply,
        );
      }
    } catch (_) {
      widget.report('Не удалось сохранить запись. Попробуйте ещё раз.');
    } finally {
      pcm = null;
      stopping = false;
      if (mounted) {
        setState(() {
          recording = false;
          reply = null;
        });
      }
    }
  }

  Future<void> react(mx.Event event, String emoji) async {
    final own = event
        .aggregatedEvents(widget.timeline, mx.RelationshipTypes.reaction)
        .where(
          (r) =>
              !r.redacted &&
              r.senderId == widget.room.client.userID &&
              reactionEmoji(r) == emoji,
        );
    if (own.isNotEmpty) {
      await own.first.redactEvent();
      return;
    }
    await widget.actions.enqueue(widget.room, {
      'm.relates_to': {
        'rel_type': mx.RelationshipTypes.reaction,
        'event_id': event.eventId,
        'key': emoji,
      },
    }, type: mx.EventTypes.Reaction);
  }

  Future<void> eventAction(mx.Event event, String action) async {
    if (action == 'reply') {
      setState(() {
        reply = event;
        edit = null;
      });
      return;
    }
    if (action == 'edit') {
      setState(() {
        edit = event;
        reply = null;
        input.text = event
            .getDisplayEvent(widget.timeline)
            .calcUnlocalizedBody(hideReply: true);
      });
      return;
    }
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить сообщение у всех?'),
          content: const Text(
            'У собеседника могут оставаться сохранённые копии.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (confirmed == true) await event.redactEvent(redactAllEdits: true);
      return;
    }
    await react(event, action);
  }

  Widget bubble(mx.Event event) {
    final own = event.senderId == widget.room.client.userID;
    final shown = event.getDisplayEvent(widget.timeline);
    final colors = Theme.of(context).colorScheme;
    final reactions = <String, int>{};
    for (final reaction
        in event
            .aggregatedEvents(widget.timeline, mx.RelationshipTypes.reaction)
            .where((r) => !r.redacted)) {
      final emoji = reactionEmoji(reaction);
      if (emoji is String) reactions[emoji] = (reactions[emoji] ?? 0) + 1;
    }
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
        decoration: BoxDecoration(
          color: own ? colors.primaryContainer : colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    own ? 'Вы' : event.senderId,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                if (!event.redacted && event.type != mx.EventTypes.Encrypted)
                  PopupMenuButton<String>(
                    tooltip: 'Действия с сообщением',
                    onSelected: (action) =>
                        perform(() => eventAction(event, action)),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'reply',
                        child: Text('Ответить'),
                      ),
                      if (own && shown.messageType == mx.MessageTypes.Text)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Редактировать'),
                        ),
                      if (event.canRedact)
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Удалить'),
                        ),
                      ...chatEmoji.map(
                        (emoji) =>
                            PopupMenuItem(value: emoji, child: Text(emoji)),
                      ),
                    ],
                  ),
              ],
            ),
            if (event.inReplyToEventId() != null)
              FutureBuilder<mx.Event?>(
                future: event.getReplyEvent(widget.timeline),
                builder: (_, snapshot) => Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.primary, width: 3),
                    ),
                  ),
                  child: Text(
                    snapshot.data?.redacted == true
                        ? 'Удалённое сообщение'
                        : snapshot.data
                                  ?.getDisplayEvent(widget.timeline)
                                  .body ??
                              'Ответ на сообщение',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            if (event.redacted)
              const Text('Сообщение удалено')
            else if (event.type == mx.EventTypes.Encrypted)
              const Text('Нет ключа. Восстановите историю.')
            else if ({
              mx.MessageTypes.Image,
              mx.MessageTypes.Audio,
            }.contains(shown.messageType))
              AttachmentView(key: ValueKey(shown.eventId), event: shown)
            else
              SelectableText(
                shown.calcUnlocalizedBody(hideReply: true),
                style: const TextStyle(fontSize: 16),
              ),
            const SizedBox(height: 4),
            Text(
              '${TimeOfDay.fromDateTime(event.originServerTs.toLocal()).format(context)}${shown.eventId != event.eventId ? ' · изменено' : ''}${own ? (messageIsRead(event, widget.timeline) ? ' · прочитано' : ' · отправлено') : ''}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (reactions.isNotEmpty)
              Wrap(
                spacing: 4,
                children: reactions.entries
                    .map(
                      (r) => ActionChip(
                        label: Text('${r.key} ${r.value}'),
                        onPressed: () => perform(() => react(event, r.key)),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => markRead());
    final events = visibleMessages(widget.timeline, search.text);
    final pending = widget.actions.pending
        .where((p) => p['room'] == widget.room.id)
        .toList()
        .reversed
        .toList();
    return Column(
      children: [
        widget.header,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск по загруженной истории',
            ),
          ),
        ),
        if (widget.timeline.canRequestHistory)
          TextButton.icon(
            onPressed: working
                ? null
                : () => perform(
                    () => widget.timeline.requestHistory(historyCount: 100),
                  ),
            icon: const Icon(Icons.history),
            label: const Text(
              'Загрузить более ранние сообщения · поиск пока неполный',
            ),
          ),
        Expanded(
          child: events.isEmpty && pending.isEmpty
              ? const Center(child: Text('Здесь начинается разговор'))
              : ListView.builder(
                  controller: scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: events.length + pending.length,
                  itemBuilder: (_, i) {
                    if (i < pending.length) {
                      final p = pending[i];
                      final c = p['content'] as Map;
                      return Align(
                        alignment: Alignment.centerRight,
                        child: Card(
                          child: ListTile(
                            title: Text(
                              c.containsKey('bytes')
                                  ? c['body'] as String
                                  : c['body'] as String? ?? 'Реакция',
                            ),
                            subtitle: Text(
                              p['error'] as String? ?? 'В очереди отправки',
                            ),
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Действия с очередью',
                              onSelected: (action) => perform(
                                () => action == 'retry'
                                    ? widget.actions.flush()
                                    : widget.actions.cancel(p['id'] as String),
                              ),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'retry',
                                  child: Text('Повторить отправку'),
                                ),
                                PopupMenuItem(
                                  value: 'cancel',
                                  child: Text('Отменить отправку'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    return bubble(events[i - pending.length]);
                  },
                ),
        ),
        if (widget.room.typingUsers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              '${widget.room.typingUsers.map((u) => u.displayName ?? u.id).join(', ')} печатает…',
            ),
          ),
        if (reply != null || edit != null)
          ListTile(
            dense: true,
            leading: Icon(edit == null ? Icons.reply : Icons.edit),
            title: Text(edit == null ? 'Ответ' : 'Редактирование'),
            subtitle: Text(
              (reply ?? edit)!.getDisplayEvent(widget.timeline).body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Отменить',
              onPressed: () => setState(() {
                reply = null;
                edit = null;
                input.clear();
              }),
              icon: const Icon(Icons.close),
            ),
          ),
        if (recording)
          ListTile(
            leading: const Icon(Icons.mic, color: Colors.red),
            title: const Text('Идёт запись · до 3 минут'),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Отменить запись',
                  onPressed: () => finishRecording(send: false),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: 'Отправить запись',
                  onPressed: () => finishRecording(),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Отправить изображение',
                  onPressed: working ? null : () => perform(image),
                  icon: const Icon(Icons.image_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Эмодзи',
                  onSelected: (emoji) {
                    input.text += emoji;
                    typing(input.text);
                  },
                  itemBuilder: (_) => chatEmoji
                      .map(
                        (emoji) =>
                            PopupMenuItem(value: emoji, child: Text(emoji)),
                      )
                      .toList(),
                ),
                Expanded(
                  child: TextField(
                    controller: input,
                    onChanged: typing,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Написать сообщение…',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Записать голосовое',
                  onPressed: working ? null : () => perform(startRecording),
                  icon: const Icon(Icons.mic_none),
                ),
                IconButton.filled(
                  tooltip: 'Отправить',
                  onPressed: working ? null : () => perform(send),
                  icon: const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.actions.removeListener(refresh);
    recordingLimit?.cancel();
    unawaited(recordingStream?.cancel());
    unawaited(recorder.dispose());
    unawaited(widget.room.setTyping(false).catchError((Object _) {}));
    input.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }
}

class AttachmentView extends StatefulWidget {
  final mx.Event event;
  const AttachmentView({super.key, required this.event});
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  late final player = AudioPlayer();
  Future<mx.MatrixFile>? download;
  bool playing = false;
  @override
  void initState() {
    super.initState();
    if (widget.event.messageType != mx.MessageTypes.Audio) return;
    player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => playing = false);
    });
  }

  Future<mx.MatrixFile> load() async {
    final size = widget.event.infoMap['size'];
    if (size is! num ||
        size > maxAttachmentBytes ||
        size <= 0 ||
        !widget.event.isAttachmentEncrypted) {
      throw StateError('Unencrypted or oversized attachment refused');
    }
    return widget.event.downloadAndDecryptAttachment();
  }

  Future<void> play() async {
    try {
      if (playing) {
        await player.pause();
      } else {
        final file = await (download ??= load());
        await player.play(BytesSource(file.bytes, mimeType: file.mimeType));
      }
      if (mounted) setState(() => playing = !playing);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть вложение. Проверьте сеть и ключи.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.event.messageType == mx.MessageTypes.Audio) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: playing ? 'Приостановить' : 'Прослушать',
            onPressed: play,
            icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
          ),
          Flexible(
            child: Text(
              'Голосовое сообщение · ${((widget.event.infoMap['duration'] as num? ?? 0) / 1000).round()} с',
            ),
          ),
        ],
      );
    }
    return FutureBuilder<mx.MatrixFile>(
      future: download ??= load(),
      builder: (_, snapshot) {
        if (snapshot.hasError) {
          return const Text('Изображение недоступно. Проверьте ключи и сеть.');
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: CircularProgressIndicator(),
          );
        }
        return Image.memory(
          snapshot.data!.bytes,
          cacheWidth: 1200,
          width: 300,
          height: 220,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const Text('Не удалось прочитать изображение'),
        );
      },
    );
  }

  @override
  void dispose() {
    if (widget.event.messageType == mx.MessageTypes.Audio) {
      unawaited(player.dispose());
    }
    super.dispose();
  }
}
