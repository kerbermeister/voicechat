import 'dart:async';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'image_source.dart';
import 'photo_viewer.dart';
import 'album_view.dart';
import 'waveform_view.dart';
import 'emoji_picker.dart';
import 'typing_indicator.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:record/record.dart';
import 'chat_actions.dart';
import 'voice_recording.dart';
import 'user_action_error.dart';
import 'file_source.dart';
import 'file_view.dart';
import 'video_note.dart';
import 'call_window.dart';
import 'history_window.dart';
import 'recording_activity.dart';

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
  final String? initialEventId;
  final bool completeHistory;
  final Future<void> Function(String?)? onJump;
  const ChatPane({
    super.key,
    required this.room,
    required this.timeline,
    required this.actions,
    required this.header,
    required this.report,
    this.initialEventId,
    this.completeHistory = false,
    this.onJump,
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
  final draftPhotos = <mx.MatrixImageFile>[];
  final draftFiles = <PickedFile>[];
  final heldVideo = ValueNotifier(false);
  PickedFile? get draftFile => draftFiles.firstOrNull;
  int? draftVideoDuration;
  bool draftIsVideoNote = false;
  double? fileProgress;
  bool cancelFile = false;
  String? focusedEvent;
  bool completeHistory = false;
  mx.MatrixAudioFile? unsentVoice;
  List<int>? unsentWave;
  mx.Event? voiceReply;
  final voicePreview = AudioPlayer();
  bool previewPlaying = false;
  final recordingClock = Stopwatch();
  Timer? recordingMeter;
  int latestLevel = 0;
  final liveLevels = <int>[];

  @override
  void initState() {
    super.initState();
    focusedEvent = widget.initialEventId;
    completeHistory = widget.completeHistory;
    WidgetsBinding.instance.addObserver(this);
    widget.actions.addListener(refresh);
    voicePreview.onPlayerComplete.listen((_) {
      if (mounted) setState(() => previewPlaying = false);
    });
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
        focusedEvent != null ||
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

  Future<void> calendar() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date == null) return;
    final result = await widget.room.client.getEventByTimestamp(
      widget.room.id,
      date.millisecondsSinceEpoch,
      mx.Direction.f,
    );
    final event = await widget.room.getEventById(result.eventId);
    if (event == null ||
        !DateUtils.isSameDay(event.originServerTs.toLocal(), date)) {
      widget.report('В выбранный день сообщений нет.');
      return;
    }
    final historyContext = await widget.room.getTimeline(
      eventContextId: result.eventId,
      limit: 100,
    );
    String? target;
    try {
      for (var page = 0; page < 10; page++) {
        final messages = visibleMessages(historyContext, '')
            .where((e) => DateUtils.isSameDay(e.originServerTs.toLocal(), date))
            .toList();
        if (messages.isNotEmpty) {
          target = messages.last.eventId;
          break;
        }
        if (!historyContext.canRequestFuture) break;
        await historyContext.requestFuture(historyCount: 100);
      }
    } finally {
      historyContext.cancelSubscriptions();
    }
    if (target == null) {
      widget.report(
        'За этот день в проверенном контексте сообщений нет. При недостающих ключах восстановите историю.',
      );
      return;
    }
    await widget.onJump?.call(target);
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
    if (unsentVoice != null) {
      await sendVoiceDraft();
    } else if (draftFile != null) {
      cancelFile = false;
      setState(() => fileProgress = 0);
      try {
        while (draftFiles.isNotEmpty) {
          await widget.actions.file(
            widget.room,
            draftFile!,
            input.text,
            reply: reply,
            videoNote: draftIsVideoNote,
            duration: draftVideoDuration,
            cancelled: () => cancelFile || !mounted,
            progress: (p) {
              if (mounted) setState(() => fileProgress = p);
            },
          );
          final sent = draftFiles.removeAt(0);
          input.clear();
          await sent.release();
        }
      } finally {
        if (mounted) setState(() => fileProgress = null);
      }
    } else if (draftPhotos.isNotEmpty) {
      await widget.actions.album(
        widget.room,
        List.of(draftPhotos),
        input.text,
        reply: reply,
      );
      draftPhotos.clear();
    } else {
      await widget.actions.text(
        widget.room,
        input.text,
        reply: reply,
        edit: edit?.eventId,
      );
    }
    input.clear();
    typing('');
    setState(() {
      reply = null;
      edit = null;
    });
  }

  Future<void> image() async {
    if (draftFile != null || unsentVoice != null) {
      throw UserActionError(
        'Сначала отправьте или удалите прикреплённый файл.',
      );
    }
    if (edit != null) {
      throw UserActionError('Сначала завершите редактирование сообщения.');
    }
    await widget.actions.refreshPolicy();
    final policy = widget.actions.policy;
    final remaining = policy.photoMaxCount - draftPhotos.length;
    if (remaining <= 0) {
      throw UserActionError('Максимум ${policy.photoMaxCount} фотографий.');
    }
    final photos = await chooseImages(policy, remaining);
    if (mounted) setState(() => draftPhotos.addAll(photos));
  }

  Future<void> attachFile(String kind, {bool hold = false}) async {
    if (draftPhotos.isNotEmpty ||
        unsentVoice != null ||
        draftIsVideoNote && draftFile != null ||
        kind == 'note' && draftFile != null) {
      throw UserActionError('Сначала отправьте или удалите текущие вложения.');
    }
    await widget.actions.refreshPolicy();
    final remaining = widget.actions.policy.fileMaxCount - draftFiles.length;
    if (remaining <= 0) {
      throw UserActionError(
        'Максимум ${widget.actions.policy.fileMaxCount} файлов.',
      );
    }
    List<PickedFile> sources;
    int? duration;
    if (kind == 'note') {
      if (!mounted) return;
      final result = await recordVideoNote(
        context,
        widget.actions.policy.videoNoteMaxSeconds,
        held: hold ? heldVideo : null,
        onRecording: (value) => RecordingActivity.of(
          widget.room.client,
        )?.set(widget.room, value ? 'video' : null),
      );
      sources = [?result?.file];
      duration = result?.duration;
    } else {
      sources = await chooseFiles(video: kind == 'video', maxCount: remaining);
    }
    if (sources.isEmpty) return;
    if (!mounted ||
        sources.length > remaining ||
        sources.any(
          (source) =>
              source.size <= 0 ||
              source.size >
                  (source.mime.startsWith('video/')
                      ? widget.actions.policy.videoMaxBytes
                      : widget.actions.policy.fileMaxBytes),
        )) {
      for (final source in sources) {
        await source.release();
      }
      if (mounted) {
        throw UserActionError(
          'Проверьте количество и размер файлов: максимум ${widget.actions.policy.fileMaxCount}, до ${(widget.actions.policy.fileMaxBytes / 1048576).floor()} МБ каждый.',
        );
      }
      return;
    }
    setState(() {
      draftFiles.addAll(sources);
      draftIsVideoNote = kind == 'note';
      draftVideoDuration = duration;
    });
    if (hold) {
      final caption = input.text;
      try {
        input.clear();
        await send();
      } finally {
        if (mounted) input.text = caption;
      }
    }
  }

  Future<void> emoji() async {
    final chosen = await pickEmoji(context);
    if (chosen == null || !mounted) return;
    final selection = input.selection;
    final start = selection.isValid ? selection.start : input.text.length;
    final end = selection.isValid ? selection.end : start;
    input.value = TextEditingValue(
      text: input.text.replaceRange(start, end, chosen),
      selection: TextSelection.collapsed(offset: start + chosen.length),
    );
    typing(input.text);
    setState(() {});
  }

  Future<void> startRecording() async {
    if (unsentVoice != null ||
        draftFile != null ||
        draftPhotos.isNotEmpty ||
        edit != null) {
      throw UserActionError(
        'Сначала отправьте или удалите текущие вложения и завершите редактирование.',
      );
    }
    if (!await recorder.hasPermission()) {
      throw UserActionError(
        'Для голосового сообщения разрешите доступ к микрофону.',
      );
    }
    await widget.actions.refreshPolicy();
    recordingFailed = false;
    liveLevels.clear();
    latestLevel = 0;
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
        if (pcm!.length + chunk.length <=
            16000 * 2 * widget.actions.policy.voiceMaxSeconds) {
          pcm!.add(chunk);
          latestLevel = pcmWaveform(
            Uint8List.sublistView(chunk, 0, chunk.length - chunk.length % 2),
            bins: 1,
          ).first;
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
      Duration(seconds: widget.actions.policy.voiceMaxSeconds),
      () => unawaited(finishRecording()),
    );
    recordingClock.reset();
    recordingClock.start();
    recordingMeter = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !recording) return;
      setState(() {
        liveLevels.add(latestLevel);
        if (liveLevels.length > 48) liveLevels.removeAt(0);
      });
    });
    if (mounted) {
      setState(() => recording = true);
      RecordingActivity.of(widget.room.client)?.set(widget.room, 'audio');
    }
  }

  Future<void> finishRecording({bool send = true}) async {
    if (!recording || stopping) return;
    stopping = true;
    RecordingActivity.of(widget.room.client)?.set(widget.room, null);
    recordingLimit?.cancel();
    recordingMeter?.cancel();
    recordingClock.stop();
    try {
      await recorder.stop();
      await recordingDone!.future;
      final bytes = pcm!.takeBytes();
      if (send && !recordingFailed && bytes.isNotEmpty) {
        unsentVoice = mx.MatrixAudioFile(
          bytes: voiceWav(bytes),
          name: 'Голосовое сообщение.wav',
          mimeType: 'audio/wav',
          duration: bytes.length * 1000 ~/ 32000,
        );
        unsentWave = pcmWaveform(bytes);
        voiceReply = reply;
      }
    } catch (_) {
      widget.report(
        'Не удалось сохранить запись. Она осталась в этом чате: повторите отправку.',
      );
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

  Future<void> sendVoiceDraft() async {
    final file = unsentVoice;
    if (file == null) return;
    await widget.actions.attachment(
      widget.room,
      file,
      reply: voiceReply,
      waveform: unsentWave,
      caption: input.text,
    );
    await voicePreview.stop();
    previewPlaying = false;
    unsentVoice = null;
    unsentWave = null;
    voiceReply = null;
    if (mounted) setState(() {});
  }

  Future<void> react(mx.Event event, String emoji) async {
    if (widget.actions.pending.any(
      (p) =>
          p['type'] == mx.EventTypes.Reaction &&
          (p['content']['m.relates_to'] as Map?)?['event_id'] == event.eventId,
    )) {
      throw UserActionError(
        'Предыдущая реакция ещё отправляется. Дождитесь подтверждения.',
      );
    }
    final all = event
        .aggregatedEvents(widget.timeline, mx.RelationshipTypes.reaction)
        .where((r) => !r.redacted && r.senderId == widget.room.client.userID)
        .toList();
    final current = latestReactions(all);
    final toggleOff =
        current.isNotEmpty && reactionEmoji(current.single) == emoji;
    for (final reaction in all) {
      await reaction.redactEvent();
    }
    if (toggleOff) return;
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
    if (action == 'react') {
      final chosen = await pickEmoji(context);
      if (chosen != null) await react(event, chosen);
      return;
    }
    await react(event, action);
  }

  Widget bubble(mx.Event event) {
    final own = event.senderId == widget.room.client.userID;
    final shown = event.getDisplayEvent(widget.timeline);
    final colors = Theme.of(context).colorScheme;
    final reactions = <String, List<String>>{};
    for (final reaction in latestReactions(
      event.aggregatedEvents(widget.timeline, mx.RelationshipTypes.reaction),
    )) {
      final emoji = reactionEmoji(reaction)!;
      (reactions[emoji] ??= []).add(
        reaction.senderId == widget.room.client.userID
            ? 'Вы'
            : widget.room
                      .unsafeGetUserFromMemoryOrFallback(reaction.senderId)
                      .displayName ??
                  reaction.senderId,
      );
    }
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
        decoration: BoxDecoration(
          color: own ? colors.primary : colors.surfaceContainerLowest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(24),
            topRight: const Radius.circular(24),
            bottomLeft: Radius.circular(own ? 24 : 6),
            bottomRight: Radius.circular(own ? 6 : 24),
          ),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: .035),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: own ? colors.onPrimary : colors.onSurface),
          child: IconTheme.merge(
            data: IconThemeData(
              color: own ? colors.onPrimary : colors.onSurfaceVariant,
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: own
                              ? colors.onPrimary.withValues(alpha: .8)
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (!event.redacted &&
                        event.type != mx.EventTypes.Encrypted)
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
                          const PopupMenuItem(
                            value: 'react',
                            child: Text('Реакция…'),
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
                else if ([
                  'dev.voicechat.call',
                  'dev.voicechat.call_summary',
                ].contains(shown.messageType))
                  CallEventCard(event: shown)
                else if (shown.messageType == 'dev.voicechat.album')
                  AlbumView(key: ValueKey(shown.eventId), event: shown)
                else if (shown.messageType == 'dev.voicechat.file')
                  FileView(key: ValueKey(shown.eventId), event: shown)
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
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: own
                        ? colors.onPrimary.withValues(alpha: .8)
                        : colors.onSurfaceVariant,
                  ),
                ),
                if (reactions.isNotEmpty)
                  Wrap(
                    spacing: 4,
                    children: reactions.entries
                        .map(
                          (r) => Tooltip(
                            message: r.value.join('\n'),
                            child: ActionChip(
                              label: Text('${r.key} ${r.value.length}'),
                              onPressed: () =>
                                  perform(() => react(event, r.key)),
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => markRead());
    var events = visibleMessages(widget.timeline, search.text);
    final focusedIndex = events.indexWhere(
      (event) => event.eventId == focusedEvent,
    );
    if (focusedIndex >= 0) events = events.sublist(focusedIndex);
    final pending = widget.actions.pending
        .where(
          (p) =>
              p['room'] == widget.room.id &&
              (p['error'] != null ||
                  p['type'] != mx.EventTypes.Reaction && p['edit'] == null),
        )
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
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск по загруженной истории',
              suffixIcon: IconButton(
                tooltip: 'Перейти к дате',
                onPressed: working ? null : () => perform(calendar),
                icon: const Icon(Icons.calendar_month_outlined),
              ),
            ),
          ),
        ),
        if (focusedEvent != null || widget.timeline.canRequestFuture)
          TextButton.icon(
            onPressed: () => widget.onJump?.call(null),
            icon: const Icon(Icons.arrow_downward),
            label: const Text('Вернуться к новым сообщениям'),
          ),
        if (widget.timeline.canRequestHistory &&
            !completeHistory &&
            !historyComplete(widget.timeline))
          TextButton.icon(
            onPressed: working
                ? null
                : () => perform(() async {
                    await widget.timeline.requestHistory(historyCount: 100);
                    if (widget.initialEventId == null) {
                      await rememberHistory(widget.timeline);
                    }
                    if (mounted) {
                      setState(
                        () =>
                            completeHistory = historyComplete(widget.timeline),
                      );
                    }
                  }),
            icon: const Icon(Icons.history),
            label: const Text('Показать более ранние сообщения'),
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
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final pendingIndex = pending.indexWhere(
                      (p) => 'pending:${p['id']}' == key.value,
                    );
                    if (pendingIndex >= 0) return pendingIndex;
                    final index = events.indexWhere(
                      (e) => e.eventId == key.value,
                    );
                    return index < 0 ? null : index + pending.length;
                  },
                  itemBuilder: (_, i) {
                    if (i < pending.length) {
                      final p = pending[i];
                      final c = p['content'] as Map;
                      return Align(
                        key: ValueKey('pending:${p['id']}'),
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
                    final index = i - pending.length;
                    final event = events[index];
                    final startsDay =
                        index == events.length - 1 ||
                        !DateUtils.isSameDay(
                          event.originServerTs.toLocal(),
                          events[index + 1].originServerTs.toLocal(),
                        );
                    return Column(
                      key: ValueKey(event.eventId),
                      children: [
                        if (startsDay)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Chip(
                              label: Text(
                                messageDay(
                                  event.originServerTs.toLocal(),
                                  DateTime.now(),
                                ),
                              ),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.tertiaryContainer,
                            ),
                          ),
                        bubble(event),
                      ],
                    );
                  },
                ),
        ),
        SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TypingIndicator(
                room: widget.room,
                ownDraft: input.text.isNotEmpty,
              ),
            ),
          ),
        ),
        if (draftFiles.isNotEmpty)
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: draftFiles.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => SizedBox(
                width: 260,
                child: ListTile(
                  leading: Icon(
                    draftIsVideoNote
                        ? Icons.video_camera_front
                        : Icons.attach_file,
                  ),
                  title: Text(
                    draftFiles[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: fileProgress != null && i == 0
                      ? LinearProgressIndicator(value: fileProgress)
                      : Text(
                          '${(draftFiles[i].size / 1048576).toStringAsFixed(1)} МБ · ${i + 1}/${widget.actions.policy.fileMaxCount}',
                        ),
                  trailing: IconButton(
                    tooltip: 'Убрать файл ${i + 1}',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      if (fileProgress != null) {
                        setState(() => cancelFile = true);
                        return;
                      }
                      final source = draftFiles.removeAt(i);
                      await source.release();
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ),
            ),
          ),
        if (draftPhotos.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Прикреплено фото: ${draftPhotos.length} / ${widget.actions.policy.photoMaxCount}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 84,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: draftPhotos.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => Stack(
                      children: [
                        InkWell(
                          onTap: () => showPhotos(context, [
                            for (final p in draftPhotos) () async => p.bytes,
                          ], i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              draftPhotos[i].bytes,
                              width: 84,
                              height: 84,
                              fit: BoxFit.cover,
                              cacheWidth: 170,
                              semanticLabel: 'Прикреплённое фото ${i + 1}',
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: IconButton.filled(
                            tooltip: 'Убрать фото ${i + 1}',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setState(() => draftPhotos.removeAt(i)),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 22, top: 4),
            child: Text(
              '${input.text.length} / ${widget.actions.policy.textMaxLength}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: input.text.length > widget.actions.policy.textMaxLength
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (unsentVoice != null && !recording)
          ListTile(
            leading: IconButton(
              tooltip: previewPlaying
                  ? 'Остановить предпросмотр'
                  : 'Прослушать запись',
              icon: Icon(previewPlaying ? Icons.stop : Icons.play_arrow),
              onPressed: () => perform(() async {
                if (previewPlaying) {
                  await voicePreview.stop();
                } else {
                  await voicePreview.play(
                    BytesSource(unsentVoice!.bytes, mimeType: 'audio/wav'),
                  );
                }
                if (mounted) setState(() => previewPlaying = !previewPlaying);
              }),
            ),
            title: Text(
              'Голосовое · ${mediaTime(Duration(milliseconds: unsentVoice!.duration ?? 0))}',
            ),
            subtitle: WaveformView(levels: unsentWave ?? [0]),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Удалить готовую запись',
                  onPressed: () => setState(() {
                    unawaited(voicePreview.stop());
                    previewPlaying = false;
                    unsentVoice = null;
                    unsentWave = null;
                    voiceReply = null;
                  }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        if (recording)
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.mic, color: Color(0xFFC64250)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Запись ${mediaTime(recordingClock.elapsed)} · осталось ${mediaTime(Duration(seconds: (widget.actions.policy.voiceMaxSeconds - recordingClock.elapsed.inSeconds).clamp(0, widget.actions.policy.voiceMaxSeconds)))}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Отменить запись',
                      onPressed: () => finishRecording(send: false),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    IconButton.filled(
                      tooltip: 'Остановить запись',
                      onPressed: () => finishRecording(),
                      icon: const Icon(Icons.stop),
                    ),
                  ],
                ),
                WaveformView(
                  levels: liveLevels.isEmpty ? [0] : List.of(liveLevels),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          )
        else
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(26),
            ),
            child: LayoutBuilder(
              builder: (_, box) {
                final photo = IconButton(
                  tooltip: 'Отправить изображение',
                  onPressed: working ? null : () => perform(image),
                  icon: const Icon(Icons.image_outlined),
                );
                final emojiButton = IconButton(
                  tooltip: 'Эмодзи',
                  onPressed: working ? null : emoji,
                  icon: const Icon(Icons.sentiment_satisfied_alt_outlined),
                );
                final files = PopupMenuButton<String>(
                  tooltip: 'Прикрепить файл или видео',
                  enabled: !working,
                  icon: const Icon(Icons.attach_file),
                  onSelected: (kind) => perform(() => attachFile(kind)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'video', child: Text('Видеофайл')),
                    PopupMenuItem(value: 'file', child: Text('Файл')),
                  ],
                );
                final field = Expanded(
                  child: TextField(
                    controller: input,
                    onChanged: (value) {
                      typing(value);
                      setState(() {});
                    },
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Написать сообщение…',
                    ),
                  ),
                );
                final voice = IconButton(
                  tooltip: 'Записать голосовое',
                  onPressed: working ? null : () => perform(startRecording),
                  icon: const Icon(Icons.mic_none),
                );
                final video = GestureDetector(
                  onLongPressStart: (_) {
                    if (working) return;
                    heldVideo.value = true;
                    unawaited(perform(() => attachFile('note', hold: true)));
                  },
                  onLongPressEnd: (_) => heldVideo.value = false,
                  onLongPressCancel: () => heldVideo.value = false,
                  child: IconButton(
                    tooltip: 'Видеокружок · удерживайте для записи',
                    onPressed: working
                        ? null
                        : () => perform(() => attachFile('note')),
                    icon: const Icon(Icons.videocam_outlined),
                  ),
                );
                final sendButton = IconButton.filled(
                  tooltip: 'Отправить',
                  onPressed: working ? null : () => perform(send),
                  icon: const Icon(Icons.arrow_upward),
                );
                return box.maxWidth < 500
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(children: [emojiButton, field]),
                          Row(
                            children: [
                              photo,
                              files,
                              voice,
                              video,
                              const Spacer(),
                              sendButton,
                            ],
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          photo,
                          emojiButton,
                          files,
                          field,
                          voice,
                          video,
                          sendButton,
                        ],
                      );
              },
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    RecordingActivity.of(widget.room.client)?.set(widget.room, null);
    heldVideo.value = false;
    heldVideo.dispose();
    cancelFile = true;
    if (fileProgress == null) {
      for (final source in draftFiles) {
        unawaited(source.release());
      }
    }
    WidgetsBinding.instance.removeObserver(this);
    widget.actions.removeListener(refresh);
    recordingLimit?.cancel();
    recordingMeter?.cancel();
    unawaited(recordingStream?.cancel());
    unawaited(recorder.dispose());
    unawaited(voicePreview.dispose());
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
  Duration position = Duration.zero;
  StreamSubscription<Duration>? positionUpdates;
  @override
  void initState() {
    super.initState();
    if (widget.event.messageType != mx.MessageTypes.Audio) return;
    positionUpdates = player.onPositionChanged.listen((value) {
      if (mounted) setState(() => position = value);
    });
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
      final duration = Duration(
        milliseconds: (widget.event.infoMap['duration'] as num? ?? 0).toInt(),
      );
      final raw = widget.event.content['dev.voicechat.waveform'];
      final wave =
          raw is List &&
              raw.isNotEmpty &&
              raw.length <= 128 &&
              raw.every((n) => n is int && n >= 0 && n <= 1024)
          ? raw.cast<int>()
          : <int>[];
      final colors = Theme.of(context).colorScheme;
      final own = widget.event.senderId == widget.event.room.client.userID;
      final background = own
          ? colors.primaryContainer
          : colors.secondaryContainer;
      final foreground = own
          ? colors.onPrimaryContainer
          : colors.onSecondaryContainer;
      final accent = own ? colors.primary : colors.secondary;
      final caption = widget.event.content['dev.voicechat.caption'];
      return Container(
        width: 320,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: playing ? 'Приостановить' : 'Прослушать',
                  onPressed: play,
                  style: IconButton.styleFrom(
                    backgroundColor: accent.withValues(alpha: .16),
                    foregroundColor: foreground,
                  ),
                  icon: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Голосовое сообщение',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: foreground),
                      ),
                      if (wave.isNotEmpty)
                        WaveformView(
                          levels: wave,
                          progress: duration.inMilliseconds <= 0
                              ? 0
                              : position.inMilliseconds /
                                    duration.inMilliseconds,
                          color: accent,
                        )
                      else
                        Icon(Icons.graphic_eq, color: accent),
                      Text(
                        '${mediaTime(position)} / ${mediaTime(duration)}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: foreground),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (caption is String && caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  caption,
                  style: TextStyle(color: foreground),
                ),
              ),
          ],
        ),
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
        return InkWell(
          onTap: () =>
              showPhotos(context, [() async => snapshot.data!.bytes], 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(
              snapshot.data!.bytes,
              cacheWidth: 1200,
              width: 300,
              height: 220,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Text('Не удалось прочитать изображение'),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    if (widget.event.messageType == mx.MessageTypes.Audio) {
      unawaited(positionUpdates?.cancel());
      unawaited(player.dispose());
    }
    super.dispose();
  }
}

String mediaTime(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
String messageDay(DateTime date, DateTime now) {
  if (DateUtils.isSameDay(date, now)) return 'Сегодня';
  if (DateUtils.isSameDay(date, DateTime(now.year, now.month, now.day - 1))) {
    return 'Вчера';
  }
  return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
}

List<mx.Event> latestReactions(Iterable<mx.Event> events) {
  final latest = <String, mx.Event>{};
  for (final event in events) {
    if (event.redacted || reactionEmoji(event) == null) continue;
    final previous = latest[event.senderId];
    if (previous == null ||
        event.originServerTs.isAfter(previous.originServerTs) ||
        (event.originServerTs == previous.originServerTs &&
            event.eventId.compareTo(previous.eventId) > 0)) {
      latest[event.senderId] = event;
    }
  }
  return latest.values.toList();
}
