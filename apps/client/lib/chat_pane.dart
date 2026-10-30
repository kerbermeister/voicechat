import 'personal_room.dart';
import 'message_motion.dart';
import 'message_media_cache.dart';
import 'animated_message_border.dart';
import 'chat_scale.dart';
import 'delete_message_dialog.dart';
import 'transient_notice.dart';
import 'message_playback.dart';
import 'copy_feedback.dart';
import 'message_clipboard.dart';
import 'hidden_messages.dart';
import 'participant_colors.dart';
import 'forward_message.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'forward_picker.dart';
import 'message_metadata.dart';
import 'app_motion.dart';
import 'animated_emoji.dart';
import 'pinned_message.dart';
import 'composer_focus.dart';
import 'read_after.dart';
import 'pending_message.dart';
import 'theme.dart';
import 'conversation_list.dart'
    show roomDisplayName, roomPresence, PersonAvatar, roomAvatar;
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
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:record/record.dart';
import 'chat_actions.dart';
import 'voice_recording.dart';
import 'user_action_error.dart';
import 'file_source.dart';
import 'file_drop.dart';
import 'dropped_attachments.dart';
import 'file_view.dart';
import 'video_note.dart';
import 'call_window.dart';
import 'history_window.dart';
import 'recording_activity.dart';
import 'active_capture.dart';
import 'update_safety.dart';
import 'link_preview.dart';
import 'link_cards.dart';
import 'history_recovery.dart';
import 'temporary_message.dart';
import 'scheduled_messages.dart';
import 'scheduled_view.dart';

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
  final VoidCallback? onVoiceCall, onVideoCall, onRoomInfo;
  final void Function(String) report;
  final String? initialEventId;
  final bool completeHistory;
  final Future<void> Function(String?)? onJump;
  final Future<void> Function(mx.Room)? onForward;
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
    this.onForward,
    this.onVoiceCall,
    this.onVideoCall,
    this.onRoomInfo,
  });
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  Map<String, int> nameColorSlots = {};
  final input = TextEditingController();
  final search = TextEditingController();
  final searchFocus = FocusNode();
  late final composerFocus = FocusNode(onKeyEvent: composerKey);
  final scroll = ScrollController();
  AudioRecorder recorder = AudioRecorder();
  Future<void>? voiceOpening;
  late final Future<void> Function() voiceCancellation = cancelVoiceCapture;
  mx.Event? reply;
  int? temporarySeconds, readAfterDelay;
  late final readAfter = ReadAfterState.of(widget.room.client);
  Timer? readAfterPoll;
  DateTime? scheduledFor;
  mx.Event? edit;
  bool working = false;
  bool preserveDraft = false;
  final forwarded = <String, String>{};
  bool detailsOpen = true;
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
  final linkPreviews = <Uri, LinkPreview>{};
  bool loadingPreview = false;
  bool videoRecordMode = false;
  final heldVideo = ValueNotifier(false);
  final cancelledVideo = ValueNotifier(false);
  PickedFile? get draftFile => draftFiles.firstOrNull;
  int? draftVideoDuration;
  bool draftIsVideoNote = false;
  double? fileProgress;
  bool cancelFile = false;
  String? focusedEvent;
  String? highlightedEvent;
  final viewportKey = GlobalKey();
  final messageKeys = <String, GlobalKey>{};
  bool jumping = false;
  final copyPulses = <String, int>{};
  bool completeHistory = false;
  mx.MatrixAudioFile? unsentVoice;
  List<int>? unsentWave;
  mx.Event? voiceReply;
  final voicePreview = AudioPlayer();
  bool previewPlaying = false;
  bool voiceSending = false;
  String? voiceTransaction;
  final voicePreviewKey = GlobalKey();
  final textPreviewKey = GlobalKey(),
      filesPreviewKey = GlobalKey(),
      photosPreviewKey = GlobalKey();
  final motionControllers = <AnimationController>{};
  String? menuEvent;
  bool selecting = false;
  final selectedMessages = <String>{};
  Timer? selectionTimer;
  final recordingClock = Stopwatch();
  Timer? recordingMeter;
  PcmLevelMeter liveMeter = PcmLevelMeter();

  @override
  void initState() {
    super.initState();
    input.text = widget.actions.drafts[widget.room.id] ?? '';
    final draft = widget.actions.composerDrafts.remove(widget.room.id);
    if (draft != null) {
      draftFiles.addAll(draft.files);
      draftPhotos.addAll(draft.photos);
      unsentVoice = draft.voice;
      voiceTransaction = draft.voiceTransaction;
      unsentWave = draft.wave;
      reply = draft.reply;
      edit = draft.edit;
      voiceReply = draft.voiceReply;
      draftIsVideoNote = draft.videoNote;
      draftVideoDuration = draft.videoDuration;
      temporarySeconds = draft.temporarySeconds;
      readAfterDelay = draft.readAfterSeconds;
      scheduledFor = draft.scheduledFor;
    }
    unawaited(
      widget.actions.reactionUsage
          .load()
          .then((_) {
            if (mounted) setState(() {});
          })
          .catchError((Object _) {}),
    );
    input.selection = TextSelection.collapsed(offset: input.text.length);
    readAfter.addListener(refresh);
    readAfterPoll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        unawaited(
          readAfter
              .syncRoom(
                widget.room,
                widget.timeline.events,
                read: shouldMarkRead,
              )
              .catchError((Object _) {}),
        );
      }
    });
    input.addListener(saveDraft);
    updateGuards.add(prepareUpdate);
    focusedEvent = widget.initialEventId;
    highlightedEvent = focusedEvent;
    if (focusedEvent != null) messageKeys[focusedEvent!] = GlobalKey();
    completeHistory = widget.completeHistory;
    WidgetsBinding.instance.addObserver(this);
    widget.actions.addListener(refresh);
    voicePreview.onPlayerComplete.listen((_) {
      if (mounted) setState(() => previewPlaying = false);
    });
    scroll.addListener(markRead);
    WidgetsBinding.instance.addPostFrameCallback((_) => markRead());
  }

  void saveDraft() {
    unawaited(
      widget.actions.saveDraft(widget.room.id, input.text).catchError((
        Object _,
      ) {
        if (mounted) {
          widget.report(
            'Не удалось сохранить черновик. Обновление пока недоступно.',
          );
        }
      }),
    );
  }

  Future<String?> prepareUpdate() async {
    if (working ||
        recording ||
        stopping ||
        voiceOpening != null ||
        heldVideo.value ||
        draftFiles.isNotEmpty ||
        draftPhotos.isNotEmpty ||
        unsentVoice != null ||
        reply != null ||
        edit != null ||
        scheduledFor != null ||
        temporarySeconds != null ||
        readAfterDelay != null) {
      return 'Сначала отправьте или отмените вложение, запись, ответ или редактирование сообщения.';
    }
    await widget.actions.saveDraft(widget.room.id, input.text);
    return null;
  }

  @override
  void didUpdateWidget(covariant ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions) {
      oldWidget.actions.removeListener(refresh);
      widget.actions.addListener(refresh);
    }
    if (oldWidget.initialEventId != widget.initialEventId ||
        oldWidget.timeline != widget.timeline) {
      focusedEvent = widget.initialEventId;
      highlightedEvent = focusedEvent;
      if (focusedEvent != null) {
        messageKeys.putIfAbsent(focusedEvent!, GlobalKey.new);
      }
      completeHistory = widget.completeHistory;
      lastRead = null;
      if (scroll.hasClients) scroll.jumpTo(0);
    }
  }

  void clearHighlight() {
    if (highlightedEvent != null) setState(() => highlightedEvent = null);
  }

  void clearOffscreenHighlight() {
    if (!mounted || jumping || highlightedEvent == null) return;
    final target = messageKeys[highlightedEvent]?.currentContext
        ?.findRenderObject();
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (target is! RenderBox || viewport is! RenderBox || !target.attached) {
      clearHighlight();
      return;
    }
    final targetRect = target.localToGlobal(Offset.zero) & target.size;
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    if (!targetRect.overlaps(viewportRect)) clearHighlight();
  }

  Future<void> jumpToQuote(String? eventId) async {
    if (hiddenMessages(widget.room).contains(eventId)) {
      throw UserActionError('Сообщение удалено у вас.');
    }
    if (eventId != null && eventId == focusedEvent && scroll.hasClients) {
      jumping = true;
      try {
        final duration = motionDuration(context);
        if (duration == Duration.zero) {
          scroll.jumpTo(0);
        } else {
          await scroll.animateTo(
            0,
            duration: duration,
            curve: Curves.easeOutCubic,
          );
        }
        if (mounted) setState(() => highlightedEvent = eventId);
      } finally {
        jumping = false;
      }
    } else {
      await widget.onJump?.call(eventId);
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> animateSnapshot(
    MessageSnapshot snapshot, {
    GlobalKey? destination,
    bool deleting = false,
  }) async {
    if (!mounted) {
      snapshot.dispose();
      return;
    }
    final controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: deleting ? 320 : 420),
    );
    motionControllers.add(controller);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        await snapshot.animate(
          context,
          controller,
          destination: destination,
          deleting: deleting,
        );
      }
    } finally {
      snapshot.dispose();
      if (motionControllers.remove(controller)) controller.dispose();
    }
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

  bool get shouldMarkRead =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      focusedEvent == null &&
      search.text.isEmpty &&
      (!scroll.hasClients || scroll.offset <= 48) &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void markRead() {
    if (shouldMarkRead) {
      unawaited(
        readAfter
            .syncRoom(widget.room, widget.timeline.events, read: true)
            .catchError((Object _) {}),
      );
    }
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

  bool loadingFuture = false;
  Future<void> loadFuture() async {
    if (loadingFuture || !widget.timeline.canRequestFuture) return;
    loadingFuture = true;
    try {
      await widget.timeline.requestFuture(historyCount: 100);
    } catch (_) {
      widget.report(
        'Не удалось загрузить более новые сообщения. Повторите прокрутку при восстановлении связи.',
      );
    } finally {
      loadingFuture = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> calendar() async {
    final date = await showDatePicker(
      context: context,
      cancelText: 'Назад',
      builder: (context, child) => AppModalBackdrop(child: child!),
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Дата переписки',
      confirmText: 'Перейти',
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
      unawaited(finishRecording());
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

  KeyEventResult composerKey(FocusNode node, KeyEvent event) {
    if (!{
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform) ||
        event is! KeyDownEvent ||
        !{
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
        }.contains(event.logicalKey) ||
        !input.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final newline = defaultTargetPlatform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (newline) {
      final selection = input.selection;
      final start = selection.isValid ? selection.start : input.text.length;
      final end = selection.isValid ? selection.end : start;
      input.value = TextEditingValue(
        text: input.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
      typing(input.text);
      setState(() {});
    } else if (!keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      unawaited(perform(send));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> send() => sendContents();

  Future<void> sendContents() async {
    if (edit != null && messageExpired(edit!)) {
      throw UserActionError(
        'Временное сообщение уже исчезло. Отправьте новое сообщение.',
      );
    }
    // Mixed drops share one caption; completed photos must not resend if a file fails.
    if (draftPhotos.isNotEmpty && draftFiles.isNotEmpty) {
      final caption = input.text;
      await widget.actions.album(
        widget.room,
        List.of(draftPhotos),
        caption,
        ttlSeconds: temporarySeconds,
        readAfterSeconds: readAfterDelay,
        scheduledFor: scheduledFor,
        reply: reply,
      );
      draftPhotos.clear();
      if (input.text == caption) input.clear();
      if (mounted) setState(() {});
    }
    final text = input.text;
    if (unsentVoice != null) {
      await sendVoiceDraft();
    } else if (draftFile != null) {
      cancelFile = false;
      setState(() => fileProgress = 0);
      var caption = text;
      try {
        while (draftFiles.isNotEmpty) {
          await widget.actions.file(
            widget.room,
            draftFile!,
            caption,
            reply: reply,
            ttlSeconds: temporarySeconds,
            readAfterSeconds: readAfterDelay,
            scheduledFor: scheduledFor,
            videoNote: draftIsVideoNote,
            duration: draftVideoDuration,
            cancelled: () => cancelFile || !mounted,
            progress: (p) {
              if (mounted) setState(() => fileProgress = p);
            },
          );
          final sent = draftFiles.removeAt(0);
          caption = '';
          if (input.text == text) input.clear();
          if (mounted) {
            setState(() {});
            await WidgetsBinding.instance.endOfFrame;
          }
          await sent.release();
        }
      } finally {
        if (mounted) setState(() => fileProgress = null);
      }
    } else if (draftPhotos.isNotEmpty) {
      await widget.actions.album(
        widget.room,
        List.of(draftPhotos),
        text,
        ttlSeconds: temporarySeconds,
        readAfterSeconds: readAfterDelay,
        scheduledFor: scheduledFor,
        reply: reply,
      );
      draftPhotos.clear();
    } else {
      await widget.actions.text(
        widget.room,
        text,
        reply: reply,
        edit: edit?.eventId,
        previews: linkPreviews.values.toList(),
        scheduledFor: scheduledFor,
        readAfterSeconds: readAfterDelay,
        ttlSeconds: edit == null
            ? temporarySeconds
            : edit!.content['dev.voicechat.ttl_seconds'] as int?,
      );
    }
    if (input.text == text) {
      input.clear();
      linkPreviews.clear();
      temporarySeconds = null;
      readAfterDelay = null;
      scheduledFor = null;
    }
    typing(input.text);
    setState(() {
      reply = null;
      edit = null;
    });
  }

  Future<void> chooseSchedule({String? pendingId}) async {
    await widget.actions.refreshPolicy();
    if (!mounted) return;
    final chosen = await chooseScheduledTime(
      context,
      widget.actions.policy.scheduleMaxSeconds,
      initial: scheduledFor,
    );
    if (chosen == null || !mounted) return;
    if (pendingId != null) {
      await widget.actions.reschedulePending(pendingId, chosen);
    } else {
      setState(() {
        scheduledFor = chosen;
        readAfterDelay = null;
      });
    }
  }

  Future<void> chooseReadAfter() async {
    var delay = readAfterDelay ?? 5;
    final result = await showAppDialog<int>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const AppDialogTitle(child: Text('Исчезнуть после прочтения')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Только для личного чата. По умолчанию — 5 секунд после прочтения получателем.',
              ),
              DropdownButton<int>(
                value: delay,
                items: [
                  for (final seconds in [1, 3, 5, 10, 15, 30, 60])
                    DropdownMenuItem(value: seconds, child: Text('$seconds с')),
                ],
                onChanged: (value) {
                  if (value != null) setDialog(() => delay = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 0),
              child: const Text('Отключить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, delay),
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        readAfterDelay = result == 0 ? null : result;
        if (readAfterDelay != null) {
          temporarySeconds = null;
          scheduledFor = null;
        }
      });
    }
  }

  Future<void> chooseTemporaryDuration() async {
    await widget.actions.refreshPolicy();
    if (!mounted) return;
    final policy = widget.actions.policy;
    final low = policy.temporaryMinSeconds, high = policy.temporaryMaxSeconds;
    final step = policy.temporaryStepSeconds;
    var selected = temporarySeconds ?? low;
    if (selected < low || selected > high || (selected - low) % step != 0) {
      selected = low;
    }
    final chosen = await showAppDialog<int>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: AppDialogTitle(
            child: const Text(
              'Временное сообщение',
              textAlign: TextAlign.center,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Исчезнет через $selected с'),
              Slider(
                min: low.toDouble(),
                max: high.toDouble(),
                value: selected.toDouble(),
                divisions: high == low ? null : (high - low) ~/ step,
                label: '$selected с',
                onChanged: high == low
                    ? null
                    : (value) => update(
                        () => selected =
                            low + ((value - low) / step).round() * step,
                      ),
              ),
              Text(
                'От $low до $high с · шаг $step с. Срок начинается после отправки на сервер. Полученные копии и снимки экрана не удаляются.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 0),
              child: const Text('Без таймера'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    if (mounted && chosen != null) {
      setState(() {
        temporarySeconds = chosen == 0 ? null : chosen;
        if (chosen != 0) readAfterDelay = null;
      });
    }
  }

  Future<void> dropFiles(List<PickedFile> sources) async {
    final retained = <PickedFile>{};
    final room = widget.room;
    try {
      if (edit != null ||
          unsentVoice != null ||
          recording ||
          stopping ||
          voiceOpening != null ||
          heldVideo.value ||
          (draftIsVideoNote && draftFile != null)) {
        throw UserActionError(
          'Сначала завершите запись или редактирование сообщения.',
        );
      }
      await widget.actions.refreshPolicy();
      final prepared = await prepareDroppedFiles(
        sources,
        widget.actions.policy,
        photoCount: draftPhotos.length,
        fileCount: draftFiles.length,
      );
      if (!mounted || widget.room != room) return;
      setState(() {
        draftPhotos.addAll(prepared.photos);
        draftFiles.addAll(prepared.files);
        retained.addAll(prepared.files);
        draftIsVideoNote = false;
        draftVideoDuration = null;
      });
    } finally {
      for (final source in sources) {
        if (!retained.contains(source)) await source.release();
      }
    }
  }

  Future<void> image({bool camera = false}) async {
    if (draftFile != null || unsentVoice != null) {
      throw UserActionError(
        'Сначала отправьте или удалите прикреплённый файл.',
      );
    }
    if (edit != null) {
      throw UserActionError('Сначала завершите редактирование сообщения.');
    }
    final policy = widget.actions.policy;
    final remaining = policy.photoMaxCount - draftPhotos.length;
    if (remaining <= 0) {
      throw UserActionError('Максимум ${policy.photoMaxCount} фотографий.');
    }
    final room = widget.room;
    // Open the system picker within the tap; network awaits lose iOS activation.
    final selection = chooseImages(policy, remaining, camera: camera);
    unawaited(widget.actions.refreshPolicy());
    final photos = await selection;
    if (mounted && widget.room == room) {
      setState(() => draftPhotos.addAll(photos));
    }
  }

  Future<void> attachFile(String kind, {bool hold = false}) async {
    if (draftPhotos.isNotEmpty ||
        unsentVoice != null ||
        draftIsVideoNote && draftFile != null ||
        kind == 'note' && draftFile != null) {
      throw UserActionError('Сначала отправьте или удалите текущие вложения.');
    }
    if (kind == 'note') {
      // Begin capture on press with cached limits; uploading validates policy again.
      unawaited(widget.actions.refreshPolicy());
    } else {
      await widget.actions.refreshPolicy();
    }
    final remaining = widget.actions.policy.fileMaxCount - draftFiles.length;
    if (remaining <= 0) {
      throw UserActionError(
        'Максимум ${widget.actions.policy.fileMaxCount} файлов.',
      );
    }
    List<PickedFile> sources;
    int? duration;
    var interrupted = false;
    if (kind == 'note') {
      if (!mounted) return;
      final result = await recordVideoNote(
        context,
        widget.actions.policy.videoNoteMaxSeconds,
        held: hold ? heldVideo : null,
        cancelled: hold ? cancelledVideo : null,
        onRecording: (value) => RecordingActivity.of(
          widget.room.client,
        )?.set(widget.room, value ? 'video' : null),
      );
      sources = [?result?.file];
      duration = result?.duration;
      interrupted = result?.interrupted ?? false;
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
    if (kind == 'note' && !interrupted) {
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

  Future<void> cancelVoiceCapture() async {
    try {
      await voiceOpening;
    } catch (_) {}
    await finishRecording();
    if (recordingFailed) {
      await recorder.dispose();
      recorder = AudioRecorder();
      recordingFailed = false;
      releaseCapture(voiceCancellation);
    }
  }

  Future<void> startRecording() async {
    await stopActiveCapture();
    voiceOpening = () async {
      try {
        await openVoiceRecording();
      } catch (_) {
        await recorder.dispose();
        recorder = AudioRecorder();
        rethrow;
      }
    }();
    registerCapture(voiceCancellation);
    try {
      await voiceOpening;
    } finally {
      if (!recording) releaseCapture(voiceCancellation);
    }
  }

  Future<void> openVoiceRecording() async {
    if (unsentVoice != null ||
        draftFile != null ||
        draftPhotos.isNotEmpty ||
        edit != null) {
      throw UserActionError(
        'Сначала отправьте или удалите текущие вложения и завершите редактирование.',
      );
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (!kIsWeb && !await recorder.hasPermission()) {
      throw UserActionError(
        'Для голосового сообщения разрешите доступ к микрофону.',
      );
    }
    await widget.actions.refreshPolicy();
    recordingFailed = false;
    liveMeter = PcmLevelMeter();
    pcm = BytesBuilder(copy: false);
    recordingDone = Completer<void>();
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
      ),
    );
    recordingStream = stream.listen(
      (chunk) {
        if (pcm!.length + chunk.length <=
            16000 * 2 * widget.actions.policy.voiceMaxSeconds) {
          pcm!.add(chunk);
          liveMeter.add(chunk);
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
          unawaited(finishRecording());
        }
      },
    );
    recordingLimit = Timer(
      Duration(seconds: widget.actions.policy.voiceMaxSeconds),
      () => unawaited(finishRecording()),
    );
    recordingClock.reset();
    recordingClock.start();
    recordingMeter = Timer.periodic(PcmLevelMeter.interval, (_) {
      if (!mounted || !recording) return;
      setState(() {});
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
      await recorder.stop().timeout(const Duration(seconds: 10));
      await recordingDone!.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      recordingFailed = true;
    } finally {
      try {
        await recordingStream?.cancel();
      } catch (_) {
        recordingFailed = true;
      }
      final raw = pcm?.takeBytes() ?? Uint8List(0);
      final bytes = Uint8List.sublistView(raw, 0, raw.length - raw.length % 2);
      if (send && bytes.isNotEmpty) {
        unsentVoice = mx.MatrixAudioFile(
          bytes: voiceWav(bytes),
          name: 'Голосовое сообщение.wav',
          mimeType: 'audio/wav',
          duration: bytes.length * 1000 ~/ 32000,
        );
        unsentWave = pcmWaveform(bytes);
        voiceReply = reply;
      }
      if (recordingFailed) {
        widget.report(
          send && bytes.isNotEmpty
              ? 'Запись прервалась. Доступная часть сохранена в черновике.'
              : 'Запись прервалась. Попробуйте записать снова.',
        );
      }
      pcm = null;
      stopping = false;
      if (!recordingFailed) releaseCapture(voiceCancellation);
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
    setState(() => voiceSending = true);
    try {
      await messagePlayback.pause(voicePreview);
      voiceTransaction ??= await widget.actions.attachment(
        widget.room,
        file,
        reply: voiceReply,
        waveform: unsentWave,
        ttlSeconds: temporarySeconds,
        readAfterSeconds: readAfterDelay,
        scheduledFor: scheduledFor,
        caption: input.text,
      );
      if (!mounted) return;
      setState(() {
        previewPlaying = false;
        unsentVoice = null;
        unsentWave = null;
        voiceReply = null;
        voiceTransaction = null;
      });
    } finally {
      if (mounted) setState(() => voiceSending = false);
    }
  }

  Future<void> showSendFailure(Map<String, dynamic> item) async {
    final failure = item['failure'] as Map?;
    final retry = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          'Сообщение не отправлено',
          style: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                failure?['reason'] as String? ??
                    item['error'] as String? ??
                    'Нет подтверждения отправки.',
              ),
              const SizedBox(height: 16),
              Text(
                failure?['recommendation'] as String? ??
                    'Проверьте соединение и права на отправку, затем повторите. Сообщение сохранено в очереди.',
              ),
              if (failure?['code'] is String) ...[
                const SizedBox(height: 12),
                SelectableText('Код: ${failure!['code']}'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Закрыть'),
          ),
          if (item['schedule_rejected'] != true)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Повторить сейчас'),
            ),
        ],
      ),
    );
    if (retry == true && mounted) {
      await widget.actions.retryPending(item['id'] as String);
    }
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

  List<mx.Event> get selectedItems =>
      widget.timeline.events
          .where(
            (event) =>
                selectedMessages.contains(event.eventId) &&
                !messageExpired(event) &&
                !event.redacted &&
                !messageHidden(event),
          )
          .toList()
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

  void selectMessage(mx.Event event) {
    if (!selecting) {
      composerFocus.unfocus();
      selectionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final available = selectedItems.map((event) => event.eventId).toSet();
        if (available.length != selectedMessages.length) {
          setState(() => selectedMessages.retainAll(available));
        }
      });
    }
    setState(() {
      selecting = true;
      if (!selectedMessages.add(event.eventId)) {
        selectedMessages.remove(event.eventId);
      }
    });
  }

  void endSelection() {
    selectionTimer?.cancel();
    setState(() {
      selecting = false;
      selectedMessages.clear();
    });
  }

  Future<void> deleteSelection() async {
    final events = selectedItems;
    if (events.isEmpty) return;
    final allowAll = events.every((event) => event.canRedact);
    final choice = await showAppDialog<String>(
      context: context,
      builder: (_) =>
          DeleteMessageDialog(allowAll: allowAll, count: events.length),
    );
    if (choice != 'mine' && !(choice == 'all' && allowAll)) return;
    for (final event in events) {
      if (messageExpired(event) || event.redacted || messageHidden(event)) {
        continue;
      }
      if (choice == 'all') {
        if (!event.canRedact) {
          throw UserActionError('Права на удаление изменились.');
        }
        await event.redactEvent(redactAllEdits: true);
      } else {
        await widget.actions.hideMessage(event);
      }
      MessageMediaCache.of(
        event.room.client,
      ).removeFrame('${event.room.id}/${event.eventId}');
      if (!mounted) return;
      setState(() => selectedMessages.remove(event.eventId));
    }
    widget.actions.onDeleted?.call();
    if (mounted) endSelection();
  }

  Future<void> forwardSelection() async {
    final events = selectedItems;
    if (events.isEmpty || events.any((event) => !canForwardMessage(event))) {
      return;
    }
    final target = await showAppDialog<mx.Room>(
      context: context,
      builder: (_) => ForwardPicker(currentRoom: widget.room),
    );
    if (target == null) return;
    if (!target.canSendDefaultMessages) {
      throw UserActionError('Отправка в этот чат недоступна.');
    }
    for (final event in events) {
      final content = forwardMessageContent(
        event.getDisplayEvent(widget.timeline),
      );
      final key = '${event.eventId}/${target.id}';
      final transaction = forwarded[key] ??= await widget.actions.enqueue(
        target,
        content,
      );
      await widget.actions.waitForDelivery(transaction);
      if (!mounted) return;
      setState(() => selectedMessages.remove(event.eventId));
    }
    endSelection();
    if (target.id != widget.room.id && widget.onForward != null) {
      await widget.actions.saveDraft(widget.room.id, input.text);
      await widget.onForward!(target);
    }
  }

  Widget selectionToolbar() => SafeArea(
    top: false,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Удалить выбранные сообщения',
            icon: const Icon(Icons.delete_outline),
            onPressed: working || selectedItems.isEmpty
                ? null
                : () => perform(deleteSelection),
          ),
          Expanded(
            child: Text(
              'Выбрано: ${selectedItems.length}',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Отменить выбор',
            icon: const Icon(Icons.close),
            onPressed: working ? null : endSelection,
          ),
          IconButton(
            tooltip: 'Переслать выбранные сообщения',
            icon: const Icon(Icons.forward),
            onPressed:
                working ||
                    selectedItems.isEmpty ||
                    selectedItems.any((event) => !canForwardMessage(event))
                ? null
                : () => perform(forwardSelection),
          ),
        ],
      ),
    ),
  );

  Future<void> eventAction(mx.Event event, String action) async {
    if (action == 'pin') {
      await togglePinnedMessage(event);
      setState(() {});
      return;
    }
    if (action == 'select') {
      selectMessage(event);
      return;
    }
    if (action.startsWith('react:')) {
      await react(event, action.substring(6));
      return;
    }
    if (action == 'forward') {
      final target = await showAppDialog<mx.Room>(
        context: context,
        builder: (_) => ForwardPicker(currentRoom: widget.room),
      );
      if (target != null) {
        if (!target.canSendDefaultMessages) {
          throw UserActionError('Отправка в этот чат недоступна.');
        }
        final key = '${event.eventId}/${target.id}';
        final transaction = forwarded[key] ??= await widget.actions.enqueue(
          target,
          forwardMessageContent(event.getDisplayEvent(widget.timeline)),
        );
        await widget.actions.waitForDelivery(transaction);
        if (!mounted ||
            target.id == widget.room.id ||
            widget.onForward == null) {
          return;
        }
        await widget.actions.saveDraft(widget.room.id, input.text);
        widget.actions.composerDrafts[widget.room.id] = ComposerDraft(
          files: List.of(draftFiles),
          photos: List.of(draftPhotos),
          voice: unsentVoice,
          voiceTransaction: voiceTransaction,
          wave: unsentWave,
          reply: reply,
          edit: edit,
          voiceReply: voiceReply,
          videoNote: draftIsVideoNote,
          videoDuration: draftVideoDuration,
          temporarySeconds: temporarySeconds,
          readAfterSeconds: readAfterDelay,
          scheduledFor: scheduledFor,
        );
        preserveDraft = true;
        try {
          await widget.onForward!(target);
        } catch (_) {
          preserveDraft = false;
          widget.actions.composerDrafts.remove(widget.room.id);
          rethrow;
        }
      }
      return;
    }
    if (action == 'info') {
      await showFileInfo(context, event.getDisplayEvent(widget.timeline));
      return;
    }
    if (action == 'copy') {
      await copyMessage(event.getDisplayEvent(widget.timeline));
      if (mounted) {
        setState(
          () =>
              copyPulses[event.eventId] = (copyPulses[event.eventId] ?? 0) + 1,
        );
      }
      if (mounted) showTransientNotice(context, 'Скопировано в буфер обмена');
      return;
    }
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
      final choice = await showAppDialog<String>(
        context: context,
        builder: (_) => DeleteMessageDialog(allowAll: event.canRedact),
      );
      if (choice != 'mine' && !(choice == 'all' && event.canRedact)) return;
      messageKeys.putIfAbsent(event.eventId, GlobalKey.new);
      if (!mounted) return;
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final snapshot =
          MediaQuery.disableAnimationsOf(context) || messageExpired(event)
          ? null
          : await MessageSnapshot.capture(messageKeys[event.eventId]!);
      snapshot?.expiresAt = messageExpiry(event);
      try {
        if (choice == 'mine') {
          await widget.actions.hideMessage(event);
        } else {
          await event.redactEvent(redactAllEdits: true);
        }
      } catch (_) {
        snapshot?.dispose();
        rethrow;
      }
      widget.actions.onDeleted?.call();
      if (snapshot != null) {
        unawaited(animateSnapshot(snapshot, deleting: true));
      }
      if (choice == 'mine' || choice == 'all' && event.canRedact) {
        MessageMediaCache.of(
          event.room.client,
        ).removeFrame('${event.room.id}/${event.eventId}');
        MessageMediaCache.of(event.room.client).removeFrame(
          '${event.room.id}/${event.getDisplayEvent(widget.timeline).eventId}',
        );
      }
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
    if (isGroupJoin(event)) {
      final displayName = event.content['displayname'];
      final name = displayName is String && displayName.isNotEmpty
          ? displayName
          : event.stateKey!;
      final text = event.stateKey == widget.room.client.userID
          ? 'Вы вступили в группу'
          : '$name вступил(а) в группу';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Chip(
            avatar: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: Text(
              '$text · ${TimeOfDay.fromDateTime(event.originServerTs.toLocal()).format(context)}',
            ),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
        ),
      );
    }
    final own = event.senderId == widget.room.client.userID;
    final shown = event.getDisplayEvent(widget.timeline);
    final videoNote =
        shown.messageType == 'dev.voicechat.file' &&
        shown.content['video_note'] == true;
    final mediaVolume = widget.actions.mediaVolume(widget.room.id);
    final theme = Theme.of(context);
    final messageColors = theme.extension<MessageColors>();
    final baseColors = theme.colorScheme;
    final colors = own && messageColors != null
        ? baseColors.copyWith(
            primary: messageColors.start,
            onPrimary: messageColors.foreground,
          )
        : baseColors;
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
    PopupMenuItem<String> menuItem(String value, String label, IconData icon) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Text(label),
            ],
          ),
        );
    final frequent = widget.actions.reactionUsage.frequent;
    final quickReactions = frequent.isEmpty
        ? ['👍', '❤️', '😂', '🎉', '😮', '🙏']
        : frequent;
    final menuItems = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        enabled: false,
        padding: EdgeInsets.zero,
        child: EmojiMotion(
          child: SizedBox(
            width: 264,
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final emoji in quickReactions)
                  SizedBox(
                    width: 44,
                    child: IconButton(
                      padding: const EdgeInsets.all(4),
                      tooltip: 'Реакция $emoji',
                      onPressed: () => Navigator.pop(context, 'react:$emoji'),
                      icon: AnimatedEmoji(emoji),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      if (!recording && !working)
        menuItem('select', 'Выбрать', Icons.check_circle_outline),
      if (canPinMessages(widget.room))
        menuItem(
          'pin',
          widget.room.pinnedEventIds.contains(event.eventId)
              ? 'Открепить'
              : 'Закрепить',
          Icons.push_pin_outlined,
        ),
      menuItem('reply', 'Ответить', Icons.reply),
      if (shown.messageType == 'dev.voicechat.file' ||
          shown.messageType == mx.MessageTypes.Audio)
        menuItem('info', 'Информация', Icons.info_outline),
      if (!event.redacted && event.type != mx.EventTypes.Encrypted)
        menuItem('copy', 'Скопировать', Icons.copy_outlined),
      if (canForwardMessage(shown))
        menuItem('forward', 'Переслать', Icons.forward),
      if (own &&
          shown.messageType == mx.MessageTypes.Text &&
          shown.content[readAfterKey] == null)
        menuItem('edit', 'Редактировать', Icons.edit_outlined),
      menuItem('delete', 'Удалить', Icons.delete_outline),
      menuItem('react', 'Реакция…', Icons.add_reaction_outlined),
    ];
    Future<void> openMenu(Offset position) async {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final local = overlay.globalToLocal(position);
      setState(() => menuEvent = event.eventId);
      String? action;
      try {
        action = await showMenu<String>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromLTWH(local.dx, local.dy, 0, 0),
            Offset.zero & overlay.size,
          ),
          items: menuItems,
        );
      } finally {
        if (mounted) setState(() => menuEvent = null);
      }
      if (action != null && mounted) {
        await perform(() => eventAction(event, action!));
      }
    }

    final menu = !event.redacted && event.type != mx.EventTypes.Encrypted
        ? PopupMenuButton<String>(
            popUpAnimationStyle: appAnimationStyle(context),
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            tooltip: 'Действия с сообщением',
            onOpened: () => setState(() => menuEvent = event.eventId),
            onCanceled: () {
              if (mounted) setState(() => menuEvent = null);
            },
            onSelected: (action) {
              setState(() => menuEvent = null);
              perform(() => eventAction(event, action));
            },
            itemBuilder: (_) => menuItems,
          )
        : null;
    final content = Container(
      foregroundDecoration: event.eventId == highlightedEvent
          ? BoxDecoration(
              border: Border.all(color: baseColors.tertiary, width: 2),
              borderRadius: BorderRadius.circular(18),
            )
          : null,
      constraints: BoxConstraints(maxWidth: videoNote ? 240 : 520),
      margin: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: own ? colors.primary : colors.surfaceContainerLowest,
        gradient: own && messageColors != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [messageColors.start, messageColors.end],
              )
            : null,

        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(own ? 18 : 6),
          bottomRight: Radius.circular(own ? 6 : 18),
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
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        right: menu == null || videoNote ? 0 : 36,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(
                              right: videoNote && menu != null ? 36 : 0,
                            ),
                            child: Text(
                              '${own ? 'Вы · ' : ''}${event.senderFromMemoryOrFallback.displayName ?? event.senderId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontSize: 14,
                                    height: 1.25,
                                    color: participantNameColor(
                                      nameColorSlots[event.senderId] ?? 0,
                                      own
                                          ? messageColors?.start ??
                                                colors.primary
                                          : colors.surfaceContainerLowest,
                                    ),
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ),
                          if (forwardedAuthor(shown) case final author?)
                            Text(
                              'Переслано от $author',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (event.inReplyToEventId() != null)
                            FutureBuilder<mx.Event?>(
                              future: event.getReplyEvent(widget.timeline),
                              builder: (_, snapshot) => Semantics(
                                button: true,
                                label: 'Перейти к исходному сообщению',
                                child: InkWell(
                                  onTap: widget.onJump == null
                                      ? null
                                      : () => perform(
                                          () => jumpToQuote(
                                            event.inReplyToEventId(),
                                          ),
                                        ),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(
                                      color: baseColors.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border(
                                        left: BorderSide(
                                          color: baseColors.primary,
                                          width: 4,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          snapshot
                                                  .data
                                                  ?.senderFromMemoryOrFallback
                                                  .displayName ??
                                              'Цитата',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: snapshot.data != null
                                                ? participantNameColor(
                                                    nameColorSlots[snapshot
                                                            .data!
                                                            .senderId] ??
                                                        0,
                                                    baseColors
                                                        .surfaceContainerHigh,
                                                  )
                                                : baseColors.onSurface,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          snapshot.data != null &&
                                                  (messageExpiry(
                                                            snapshot.data!,
                                                          ) !=
                                                          null ||
                                                      snapshot
                                                              .data!
                                                              .content[readAfterKey] !=
                                                          null)
                                              ? 'Временное сообщение'
                                              : snapshot.data != null &&
                                                    messageHidden(
                                                      snapshot.data!,
                                                    )
                                              ? 'Сообщение удалено у вас'
                                              : snapshot.data?.redacted == true
                                              ? 'Удалённое сообщение'
                                              : snapshot.data
                                                        ?.getDisplayEvent(
                                                          widget.timeline,
                                                        )
                                                        .calcUnlocalizedBody(
                                                          hideReply: true,
                                                        ) ??
                                                    'Загрузка исходного сообщения…',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: baseColors.onSurface,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (event.redacted)
                            const Text('Сообщение удалено')
                          else if (event.type == mx.EventTypes.Encrypted)
                            const Text(
                              'Ключ этого сообщения недоступен на данном устройстве. Для доступа к истории нужно прежнее устройство или ключ восстановления.',
                            )
                          else if (shown.type == mx.EventTypes.CallInvite ||
                              [
                                'dev.voicechat.call',
                                'dev.voicechat.call_summary',
                              ].contains(shown.messageType))
                            CallEventCard(
                              event: shown,
                              history: widget.timeline.events,
                            )
                          else if (shown.messageType == 'dev.voicechat.album')
                            AlbumView(
                              key: ValueKey(shown.eventId),
                              event: shown,
                            )
                          else if (shown.messageType == 'dev.voicechat.file')
                            FileView(
                              key: ValueKey(shown.eventId),
                              event: shown,
                              originalEvent: event,
                              volume: mediaVolume,
                            )
                          else if ({
                            mx.MessageTypes.Image,
                            mx.MessageTypes.Audio,
                          }.contains(shown.messageType))
                            AttachmentView(
                              key: ValueKey(shown.eventId),
                              event: shown,
                              volume: mediaVolume,
                            )
                          else
                            LinkedText(
                              selectable: !{
                                TargetPlatform.iOS,
                                TargetPlatform.android,
                              }.contains(defaultTargetPlatform),
                              text: shown.calcUnlocalizedBody(hideReply: true),
                              style: TextStyle(
                                fontSize: shown.onlyEmotes ? 26 : 14,
                                height: 1.25,
                              ),
                            ),
                          if (!event.redacted &&
                              event.type != mx.EventTypes.Encrypted)
                            LinkCards(
                              text: messageSearchText(shown),
                              previews: shown.content['dev.voicechat.links'],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: MessageMetadata.minimumWidth,
                      height: MessageMetadata.rowHeight(context),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 4,
                child: MessageMetadata(
                  key: ValueKey('message-meta-${event.eventId}'),
                  time: TimeOfDay.fromDateTime(
                    event.originServerTs.toLocal(),
                  ).format(context),
                  status:
                      '${TimeOfDay.fromDateTime(event.originServerTs.toLocal()).format(context)}${shown.eventId != event.eventId ? ' · изменено' : ''}${own ? (messageIsRead(event, widget.timeline) ? ' · прочитано' : ' · отправлено') : ''}',
                  read: own ? messageIsRead(event, widget.timeline) : null,
                  edited: shown.eventId != event.eventId,
                  color: own
                      ? colors.onPrimary.withValues(alpha: .8)
                      : colors.onSurfaceVariant,
                  reactions: reactions,
                  onReaction: (emoji) => perform(() => react(event, emoji)),
                  saveButton: videoNote && !event.redacted
                      ? SaveMessageFile(
                          event: shown,
                          compact: true,
                          color: own
                              ? colors.onPrimary
                              : colors.onSurfaceVariant,
                        )
                      : null,
                  onCopy:
                      event.redacted || event.type == mx.EventTypes.Encrypted
                      ? null
                      : () => perform(() => eventAction(event, 'copy')),
                ),
              ),
              if (menu != null) Positioned(top: 0, right: 0, child: menu),
            ],
          ),
        ),
      ),
    );
    final message = Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .9,
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: Align(
          alignment: own ? Alignment.centerRight : Alignment.centerLeft,
          child: Theme(
            data: theme.copyWith(colorScheme: colors),
            child: Listener(
              onPointerDown: menu == null
                  ? null
                  : (details) {
                      if (details.buttons == kSecondaryMouseButton) {
                        openMenu(details.position);
                      }
                    },
              child: GestureDetector(
                onLongPressStart: menu == null
                    ? null
                    : (details) => openMenu(details.globalPosition),
                child: RepaintBoundary(
                  key: messageKeys[event.eventId],
                  child: MessageMenuHighlight(
                    selected: menuEvent == event.eventId,
                    child: CopyFeedback(
                      color: own ? colors.onPrimary : colors.primary,
                      pulse: copyPulses[event.eventId] ?? 0,
                      child:
                          messageExpiry(event) == null &&
                              shown.content[readAfterKey] == null &&
                              event.originalSource?.content[readAfterKey] ==
                                  null
                          ? content
                          : ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 526),
                              child: TemporaryMessage(
                                event: event,
                                child: content,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!selecting) return message;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: 'Выбрать сообщение',
          child: Checkbox(
            shape: const CircleBorder(),
            value: selectedMessages.contains(event.eventId),
            onChanged: working ? null : (_) => selectMessage(event),
          ),
        ),
        Expanded(
          child: InkWell(
            onTap: working ? null : () => selectMessage(event),
            child: IgnorePointer(child: message),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.timeline.room.id == widget.room.id);
    final keyboardOpen = View.of(context).viewInsets.bottom > 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => markRead());
    final events = visibleMessages(
      widget.timeline,
      search.text,
      includeExpiring: true,
    );
    nameColorSlots = participantColorSlots([
      ...widget.room.states[mx.EventTypes.RoomMember]?.keys ?? <String>[],
      ...widget.timeline.events.map((event) => event.senderId),
    ]);
    final focusedIndex = events.indexWhere(
      (event) => event.eventId == focusedEvent,
    );
    final pending = widget.actions
        .outgoing(widget.room, widget.timeline)
        .reversed
        .toList();
    int? childIndex(Key key) {
      if (key is! ValueKey<String>) return null;
      final pendingIndex = pending.indexWhere(
        (p) => 'pending:${p['id']}' == key.value,
      );
      if (pendingIndex >= 0) return pendingIndex;
      final index = events.indexWhere((e) => e.eventId == key.value);
      return index < 0 ? null : index + pending.length;
    }

    Widget buildItem(BuildContext _, int i) {
      if (i < pending.length) {
        final p = pending[i];
        final c = p['content'] as Map;
        return Align(
          key: ValueKey('pending:${p['id']}'),
          alignment: Alignment.centerRight,
          child: AnimatedMessageBorder(
            active:
                p['confirmed'] != true &&
                p['error'] == null &&
                p['scheduled_at'] == null,
            child: Card(
              child: ListTile(
                leading: p['confirmed'] == true
                    ? const Icon(Icons.done)
                    : p['error'] == null
                    ? SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          key: ValueKey('sending:${p['id']}'),
                          strokeWidth: 2,
                          semanticsLabel: 'Сообщение отправляется',
                        ),
                      )
                    : IconButton(
                        tooltip: 'Ошибка отправки: подробности',
                        icon: Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => perform(() => showSendFailure(p)),
                      ),
                title: PendingMessageContent(
                  key: ValueKey('pending-content:${p['id']}'),
                  content: c,
                ),
                subtitle: Text(
                  p['confirmed'] == true
                      ? 'Отправлено'
                      : widget.actions.pendingStatus(p),
                ),
                trailing: p['confirmed'] == true
                    ? null
                    : PopupMenuButton<String>(
                        popUpAnimationStyle: appAnimationStyle(context),
                        tooltip: 'Действия с очередью',
                        onSelected: (action) => perform(() async {
                          if (action == 'schedule') {
                            await chooseSchedule(pendingId: p['id'] as String);
                          } else if (action == 'retry') {
                            unawaited(
                              widget.actions.retryPending(p['id'] as String),
                            );
                          } else {
                            await widget.actions.cancel(p['id'] as String);
                          }
                        }),
                        itemBuilder: (_) => [
                          if (p['schedule_rejected'] == true)
                            const PopupMenuItem(
                              value: 'schedule',
                              child: Text('Выбрать новое время'),
                            ),
                          const PopupMenuItem(
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
                  messageDay(event.originServerTs.toLocal(), DateTime.now()),
                ),
                visualDensity: VisualDensity.compact,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.tertiaryContainer,
              ),
            ),
          TweenAnimationBuilder<double>(
            duration: motionDuration(context),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: 1),
            builder: (_, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: ChatScaled(
              percent: ChatScaleScope.of(context)?.messages ?? 80,
              child: bubble(event),
            ),
          ),
        ],
      );
    }

    final pivot = focusedIndex < 0 ? 0 : pending.length + focusedIndex;
    const anchor = ValueKey('history-anchor');
    final shownFiles = List<PickedFile>.of(draftFiles);
    final shownPhotos = List<mx.MatrixImageFile>.of(draftPhotos);
    final body = Column(
      children: [
        if (readAfter.failedRooms.contains(widget.room.id))
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const ListTile(
              leading: Icon(Icons.cloud_off),
              dense: true,
              title: Text(
                'Удаление после прочтения ожидает соединения с сервером',
              ),
            ),
          ),
        PinnedMessageBar(
          room: widget.room,
          timeline: widget.timeline,
          onJump: (id) => perform(() => jumpToQuote(id)),
          onError: widget.report,
        ),
        if (!keyboardOpen || searchFocus.hasFocus)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: TextField(
              controller: search,
              focusNode: searchFocus,
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
        if (widget.actions.policyUrl case final String url)
          ScheduledQueueBar(
            key: ValueKey(widget.room.id),
            service: ScheduledMessages(widget.room.client, url),
            roomId: widget.room.id,
            changes: widget.actions,
          ),
        if (focusedEvent != null || widget.timeline.canRequestFuture)
          TextButton.icon(
            onPressed: () => widget.onJump?.call(null),
            icon: const Icon(Icons.arrow_downward),
            label: const Text('Вернуться к новым сообщениям'),
          ),
        if (widget.timeline.events.any(
          (event) =>
              event.type == mx.EventTypes.Encrypted &&
              event.content['can_request_session'] == true,
        ))
          TextButton.icon(
            onPressed: working
                ? null
                : () => perform(() async {
                    final count = await requestMissingHistory(widget.timeline);
                    widget.report(
                      'Запрошены ключи: $count. На прежнем устройстве или у собеседника откройте «Настройки → Запросы истории». Для передачи нужна независимая сверка устройства.',
                    );
                  }),
            icon: const Icon(Icons.key_outlined),
            label: const Text('Запросить недоступные ключи истории'),
          ),
        if (widget.timeline.canRequestHistory &&
            !completeHistory &&
            !historyComplete(widget.timeline))
          TextButton.icon(
            onPressed: working
                ? null
                : () => perform(() async {
                    await widget.timeline.requestHistory(historyCount: 100);
                    if (!widget.room.isDirectChat &&
                        widget.room.historyVisibility ==
                            mx.HistoryVisibility.shared) {
                      await requestMissingHistory(widget.timeline);
                    }
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
              : NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0 &&
                        notification is ScrollUpdateNotification &&
                        (notification.scrollDelta ?? 0) < 0 &&
                        !jumping) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => clearOffscreenHighlight(),
                      );
                    }
                    if (notification is ScrollEndNotification &&
                        notification.depth == 0 &&
                        notification.metrics.extentBefore < 240 &&
                        focusedEvent != null &&
                        widget.timeline.canRequestFuture) {
                      unawaited(loadFuture());
                    }
                    return false;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: clearHighlight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: CustomScrollView(
                        key: viewportKey,
                        controller: scroll,
                        reverse: true,
                        center: anchor,
                        slivers: [
                          if (pivot > 0)
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, i) =>
                                    buildItem(context, pivot - 1 - i),
                                childCount: pivot,
                                findChildIndexCallback: (key) {
                                  final i = childIndex(key);
                                  return i != null && i < pivot
                                      ? pivot - 1 - i
                                      : null;
                                },
                              ),
                            ),
                          SliverList(
                            key: anchor,
                            delegate: SliverChildBuilderDelegate(
                              (context, i) => buildItem(context, pivot + i),
                              childCount:
                                  events.length + pending.length - pivot,
                              findChildIndexCallback: (key) {
                                final i = childIndex(key);
                                return i != null && i >= pivot
                                    ? i - pivot
                                    : null;
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        if (selecting)
          selectionToolbar()
        else ...[
          AnimatedPanel(
            child: scheduledFor != null
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: InputChip(
                        avatar: const Icon(Icons.schedule, size: 18),
                        label: Text(
                          'Отправить ${scheduledTime(scheduledFor!)}',
                        ),
                        onPressed: () => perform(chooseSchedule),
                        onDeleted: () => setState(() => scheduledFor = null),
                      ),
                    ),
                  )
                : null,
          ),
          if (draftFiles.isEmpty &&
              draftPhotos.isEmpty &&
              unsentVoice == null &&
              widget.actions.policyUrl != null &&
              messageLinks(input.text).isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final url in messageLinks(input.text))
                    TextButton.icon(
                      onPressed: loadingPreview
                          ? null
                          : () => perform(() async {
                              setState(() => loadingPreview = true);
                              try {
                                final preview = await LinkPreview.fetch(
                                  widget.room.client,
                                  widget.actions.policyUrl!,
                                  url,
                                );
                                if (mounted) {
                                  setState(() => linkPreviews[url] = preview);
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => loadingPreview = false);
                                }
                              }
                            }),
                      icon: Icon(
                        linkPreviews.containsKey(url)
                            ? Icons.check_circle_outline
                            : Icons.link,
                        size: 18,
                      ),
                      label: Text(
                        linkPreviews.containsKey(url)
                            ? 'Превью добавлено · ${url.host}'
                            : 'Добавить превью · ${url.host}',
                      ),
                    ),
                  const Text(
                    'Сервис превью получит ссылку. Карточка будет зашифрована вместе с сообщением.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          AnimatedPanel(
            child: draftFiles.isNotEmpty
                ? RepaintBoundary(
                    key: filesPreviewKey,
                    child: AnimatedMessageBorder(
                      active: false,
                      padding: 0,
                      child: SizedBox(
                        height: keyboardOpen ? 64 : 76,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: shownFiles.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (_, i) => SizedBox(
                            width: 260,
                            child: Material(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                titleTextStyle: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                subtitleTextStyle: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                                iconColor: Theme.of(
                                  context,
                                ).colorScheme.onSurface,
                                onTap: shownFiles[i].mime.startsWith('video/')
                                    ? () => showAppDialog<void>(
                                        context: context,
                                        animationStyle: appAnimationStyle(
                                          context,
                                        ),
                                        builder: (_) => MessageVideo.draft(
                                          file: shownFiles[i],
                                          videoNote: draftIsVideoNote,
                                          thumbnail: false,
                                        ),
                                      )
                                    : null,
                                leading: shownFiles[i].mime.startsWith('video/')
                                    ? MessageVideo.draft(
                                        key: ObjectKey(shownFiles[i]),
                                        file: shownFiles[i],
                                        videoNote: draftIsVideoNote,
                                      )
                                    : Icon(
                                        draftIsVideoNote
                                            ? Icons.video_camera_front
                                            : Icons.attach_file,
                                      ),
                                title: Text(
                                  shownFiles[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: fileProgress != null && i == 0
                                    ? LinearProgressIndicator(
                                        value: fileProgress,
                                      )
                                    : Text(
                                        '${(shownFiles[i].size / 1048576).toStringAsFixed(1)} МБ · ${i + 1}/${widget.actions.policy.fileMaxCount}',
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
                      ),
                    ),
                  )
                : null,
          ),
          AnimatedPanel(
            child: draftPhotos.isNotEmpty
                ? RepaintBoundary(
                    key: photosPreviewKey,
                    child: AnimatedMessageBorder(
                      active: false,
                      padding: 0,
                      child: Container(
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
                              height: keyboardOpen ? 48 : 84,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: shownPhotos.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (_, i) => Stack(
                                  children: [
                                    InkWell(
                                      onTap: () => showPhotos(context, [
                                        for (final p in draftPhotos)
                                          () async => p.bytes,
                                      ], i),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.memory(
                                          shownPhotos[i].bytes,
                                          width: 84,
                                          height: keyboardOpen ? 48 : 84,
                                          fit: BoxFit.cover,
                                          cacheWidth: 170,
                                          semanticLabel:
                                              'Прикреплённое фото ${i + 1}',
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: IconButton.filled(
                                        tooltip: 'Убрать фото ${i + 1}',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => setState(
                                          () => draftPhotos.removeAt(i),
                                        ),
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
                    ),
                  )
                : null,
          ),
          AnimatedPanel(
            child: reply != null || edit != null
                ? Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: ListTile(
                      textColor: Theme.of(context).colorScheme.onSurface,
                      iconColor: Theme.of(context).colorScheme.primary,
                      dense: true,
                      leading: Icon(edit == null ? Icons.reply : Icons.edit),
                      title: Text(edit == null ? 'Ответ' : 'Редактирование'),
                      subtitle: Text(
                        (messageExpiry((reply ?? edit)!) != null ||
                                (reply ?? edit)!.content[readAfterKey] != null)
                            ? 'Временное сообщение'
                            : (reply ?? edit)!
                                  .getDisplayEvent(widget.timeline)
                                  .calcUnlocalizedBody(hideReply: true),
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
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 22, 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 20),
              child: Row(
                children: [
                  Expanded(
                    child: TypingIndicator(
                      room: widget.room,
                      ownDraft: input.text.isNotEmpty,
                      compact: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${input.text.length} / ${widget.actions.policy.textMaxLength}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color:
                          input.text.length >
                              widget.actions.policy.textMaxLength
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedPanel(
            child: unsentVoice != null && !recording
                ? RepaintBoundary(
                    key: voicePreviewKey,
                    child: AnimatedMessageBorder(
                      active: voiceSending,
                      padding: 6,
                      child: ListTile(
                        leading: IconButton(
                          tooltip: previewPlaying
                              ? 'Остановить предпросмотр'
                              : 'Прослушать запись',
                          icon: Icon(
                            previewPlaying ? Icons.stop : Icons.play_arrow,
                          ),
                          onPressed: working
                              ? null
                              : () => perform(() async {
                                  if (previewPlaying) {
                                    await messagePlayback.pause(voicePreview);
                                  } else {
                                    final request = messagePlayback.request(
                                      voicePreview,
                                    );
                                    await messagePlayback.start(
                                      voicePreview,
                                      request,
                                      () async {
                                        await voicePreview.setVolume(
                                          widget.actions.mediaVolume(
                                            widget.room.id,
                                          ),
                                        );
                                        await voicePreview.play(
                                          BytesSource(
                                            unsentVoice!.bytes,
                                            mimeType: 'audio/wav',
                                          ),
                                        );
                                        if (mounted) {
                                          setState(() => previewPlaying = true);
                                        }
                                      },
                                      () async {
                                        await voicePreview.pause();
                                        if (mounted) {
                                          setState(
                                            () => previewPlaying = false,
                                          );
                                        }
                                      },
                                    );
                                  }
                                }),
                        ),
                        title: Text(
                          'Голосовое · ${mediaTime(Duration(milliseconds: unsentVoice!.duration ?? 0))}',
                        ),
                        subtitle: keyboardOpen
                            ? null
                            : WaveformView(levels: unsentWave ?? [0]),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Удалить готовую запись',
                              onPressed: working
                                  ? null
                                  : () => perform(() async {
                                      if (voiceTransaction != null) {
                                        await widget.actions.cancel(
                                          voiceTransaction!,
                                        );
                                      }
                                      await messagePlayback.pause(voicePreview);
                                      await voicePreview.stop();
                                      if (!mounted) return;
                                      setState(() {
                                        voiceTransaction = null;
                                        previewPlaying = false;
                                        unsentVoice = null;
                                        unsentWave = null;
                                        voiceReply = null;
                                      });
                                    }),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          AnimatedPanel(
            child: KeyedSubtree(
              key: ValueKey(recording),
              child: recording
                  ? RecordingWaveformPanel(
                      levels: List.of(liveMeter.levels),
                      label:
                          'Запись ${mediaTime(recordingClock.elapsed)} · осталось ${mediaTime(Duration(seconds: (widget.actions.policy.voiceMaxSeconds - recordingClock.elapsed.inSeconds).clamp(0, widget.actions.policy.voiceMaxSeconds)))}',
                      onCancel: () => finishRecording(send: false),
                      onStop: () => finishRecording(),
                    )
                  : Container(
                      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: LayoutBuilder(
                        builder: (_, box) {
                          final mobilePhoto =
                              defaultTargetPlatform == TargetPlatform.iOS ||
                              defaultTargetPlatform == TargetPlatform.android;
                          final emojiButton = IconButton(
                            tooltip: 'Эмодзи',
                            onPressed: working ? null : emoji,
                            icon: const Icon(
                              Icons.sentiment_satisfied_alt_outlined,
                            ),
                          );
                          final field = Expanded(
                            child: RepaintBoundary(
                              key: textPreviewKey,
                              child: AnimatedMessageBorder(
                                active: false,
                                padding: 0,
                                child: TextField(
                                  readOnly: voiceTransaction != null,
                                  controller: input,
                                  focusNode: composerFocus,
                                  onChanged: (value) {
                                    typing(value);
                                    final urls = messageLinks(value);
                                    linkPreviews.removeWhere(
                                      (url, _) => !urls.contains(url),
                                    );
                                    setState(() {});
                                  },
                                  minLines: 1,
                                  maxLines: keyboardOpen ? 2 : 4,
                                  decoration: const InputDecoration(
                                    hintText: 'Написать сообщение…',
                                    hintMaxLines: 1,
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                          final voice = CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.enter,
                                control: true,
                              ): () {
                                if (!working) {
                                  perform(
                                    videoRecordMode
                                        ? () => attachFile('note')
                                        : startRecording,
                                  );
                                }
                              },
                            },
                            child: GestureDetector(
                              excludeFromSemantics: true,
                              onTap: working
                                  ? null
                                  : () => setState(
                                      () => videoRecordMode = !videoRecordMode,
                                    ),
                              onLongPressStart: working
                                  ? null
                                  : (_) {
                                      if (videoRecordMode) {
                                        cancelledVideo.value = false;
                                        heldVideo.value = true;
                                        unawaited(
                                          perform(
                                            () =>
                                                attachFile('note', hold: true),
                                          ),
                                        );
                                      } else {
                                        unawaited(perform(startRecording));
                                      }
                                    },
                              onLongPressEnd: (_) => heldVideo.value = false,
                              onLongPressMoveUpdate: (details) {
                                if (details.offsetFromOrigin.dx < -80) {
                                  cancelledVideo.value = true;
                                  heldVideo.value = false;
                                }
                              },
                              onLongPressCancel: () {
                                cancelledVideo.value = true;
                                heldVideo.value = false;
                              },
                              child: Semantics(
                                button: true,
                                enabled: !working,
                                label: videoRecordMode
                                    ? 'Видеокружок'
                                    : 'Голосовое сообщение',
                                onTap: working
                                    ? null
                                    : () => setState(
                                        () =>
                                            videoRecordMode = !videoRecordMode,
                                      ),
                                hint: 'Ctrl+Enter начинает запись',
                                onLongPress: working
                                    ? null
                                    : () => perform(
                                        videoRecordMode
                                            ? () => attachFile('note')
                                            : startRecording,
                                      ),
                                child: Tooltip(
                                  triggerMode: TooltipTriggerMode.manual,
                                  message: videoRecordMode
                                      ? 'Видеокружок · нажмите для аудио, удерживайте для записи'
                                      : 'Голосовое · нажмите для видео, удерживайте для записи',
                                  child: IgnorePointer(
                                    child: IconButton.filledTonal(
                                      onPressed: working
                                          ? null
                                          : () => setState(
                                              () => videoRecordMode =
                                                  !videoRecordMode,
                                            ),
                                      icon: Icon(
                                        videoRecordMode
                                            ? Icons.videocam_outlined
                                            : Icons.mic_none,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                          final sendButton = IconButton.filled(
                            tooltip: scheduledFor == null
                                ? 'Отправить'
                                : 'Запланировать',
                            onPressed: working ? null : () => perform(send),
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.onSurface,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.surface,
                            ),
                            icon: const Icon(Icons.arrow_upward),
                          );
                          PopupMenuItem<String> action(
                            String value,
                            String label,
                            IconData icon, {
                            bool enabled = true,
                          }) => PopupMenuItem(
                            value: value,
                            enabled: enabled,
                            child: Row(
                              children: [
                                Icon(icon, size: 20),
                                const SizedBox(width: 12),
                                Flexible(child: Text(label)),
                              ],
                            ),
                          );
                          final attachments = PopupMenuButton<String>(
                            popUpAnimationStyle: appAnimationStyle(context),
                            tooltip: 'Вложения и отправка',
                            enabled: !working,
                            icon: Icon(
                              Icons.attach_file,
                              color:
                                  temporarySeconds != null ||
                                      scheduledFor != null
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            onSelected: (value) => perform(() async {
                              switch (value) {
                                case 'image':
                                  await image();
                                case 'camera':
                                  await image(camera: true);
                                case 'file':
                                case 'video':
                                  await attachFile(value);
                                case 'read-after':
                                  await chooseReadAfter();
                                case 'temporary':
                                  await chooseTemporaryDuration();
                                case 'schedule':
                                  await chooseSchedule();
                                case 'scheduled':
                                  await showAppDialog<void>(
                                    context: context,
                                    animationStyle: appAnimationStyle(context),
                                    builder: (_) => ScheduledView(
                                      service: ScheduledMessages(
                                        widget.room.client,
                                        widget.actions.policyUrl!,
                                      ),
                                      roomId: widget.room.id,
                                    ),
                                  );
                              }
                            }),
                            itemBuilder: (_) => [
                              action(
                                'image',
                                mobilePhoto
                                    ? 'Изображение из библиотеки'
                                    : 'Отправить изображение',
                                Icons.photo_library_outlined,
                              ),
                              if (mobilePhoto)
                                action(
                                  'camera',
                                  'Сделать фото',
                                  Icons.photo_camera_outlined,
                                ),
                              action(
                                'file',
                                'Прикрепить файл',
                                Icons.insert_drive_file_outlined,
                              ),
                              action(
                                'video',
                                'Прикрепить видео',
                                Icons.video_file_outlined,
                              ),
                              const PopupMenuDivider(),
                              if (widget.room.isDirectChat &&
                                  !isPersonalRoom(widget.room))
                                action(
                                  'read-after',
                                  readAfterDelay == null
                                      ? 'Исчезнуть после прочтения'
                                      : 'После прочтения · $readAfterDelay с',
                                  Icons.visibility_off_outlined,
                                  enabled: edit == null,
                                ),
                              action(
                                'temporary',
                                temporarySeconds == null
                                    ? 'Временное сообщение'
                                    : 'Временное сообщение · $temporarySeconds с',
                                Icons.timer_outlined,
                                enabled: edit == null,
                              ),
                              action(
                                'schedule',
                                scheduledFor == null
                                    ? 'Отложить отправку'
                                    : 'Изменить время отправки',
                                Icons.schedule,
                                enabled:
                                    edit == null &&
                                    widget.actions.policyUrl != null,
                              ),
                              action(
                                'scheduled',
                                'Запланированные сообщения',
                                Icons.event_note_outlined,
                                enabled: widget.actions.policyUrl != null,
                              ),
                            ],
                          );
                          return Row(
                            children: [
                              attachments,
                              emojiButton,
                              field,
                              voice,
                              sendButton,
                            ],
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ],
    );
    final colors = Theme.of(context).colorScheme;
    final chat = FileDrop(
      enabled: !working && widget.room.canSendDefaultMessages,
      onDrop: (files) => unawaited(perform(() => dropFiles(files))),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 850 &&
              MediaQuery.textScalerOf(context).scale(16) <= 24;
          return Row(
            children: [
              Expanded(
                child: ColoredBox(
                  color: colors.surface,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: widget.header),
                          if (wide)
                            Semantics(
                              expanded: detailsOpen,
                              child: IconButton.filledTonal(
                                key: const ValueKey('chat-details-toggle'),
                                tooltip: detailsOpen
                                    ? 'Свернуть панель чата'
                                    : 'Открыть панель чата',
                                isSelected: detailsOpen,
                                onPressed: () =>
                                    setState(() => detailsOpen = !detailsOpen),
                                icon: const Icon(Icons.view_sidebar_outlined),
                                selectedIcon: const Icon(
                                  Icons.view_sidebar_rounded,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ),
              if (wide)
                AnimatedPanel(
                  axis: Axis.horizontal,
                  child: detailsOpen
                      ? SizedBox(
                          key: const ValueKey('chat-details-panel'),
                          width: 264,
                          child: Material(
                            color: colors.surfaceContainerLowest,
                            shape: Border(
                              left: BorderSide(color: colors.outlineVariant),
                            ),
                            child: ListView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 24,
                              ),
                              children: [
                                InkWell(
                                  onTap: widget.onRoomInfo,
                                  borderRadius: BorderRadius.circular(16),
                                  child: Semantics(
                                    button: true,
                                    label: widget.room.isDirectChat
                                        ? 'Открыть профиль'
                                        : 'Открыть информацию о группе',
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Center(
                                          child: PersonAvatar(
                                            name: roomDisplayName(widget.room),
                                            client: widget.room.client,
                                            url: roomAvatar(widget.room),
                                            group: !widget.room.isDirectChat,
                                            online:
                                                roomPresence(widget.room) ==
                                                'В сети',
                                            size: 64,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          roomDisplayName(widget.room),
                                          textAlign: TextAlign.center,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        Text(
                                          roomPresence(widget.room),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color:
                                                roomPresence(widget.room) ==
                                                    'В сети'
                                                ? onlinePresenceColor(colors)
                                                : colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                if (!isPersonalRoom(widget.room))
                                  ListTile(
                                    leading: const Icon(Icons.call_outlined),
                                    title: const Text('Голосовой звонок'),
                                    onTap: widget.onVoiceCall,
                                  ),
                                if (!isPersonalRoom(widget.room))
                                  ListTile(
                                    leading: const Icon(
                                      Icons.videocam_outlined,
                                    ),
                                    title: const Text('Видеозвонок'),
                                    onTap: widget.onVideoCall,
                                  ),
                                const Divider(),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.volume_up_outlined,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Громкость сообщений · ${(widget.actions.mediaVolume(widget.room.id) * 100).round()}%',
                                            ),
                                          ),
                                        ],
                                      ),
                                      Slider(
                                        label: 'Аудио- и видеосообщения',
                                        value: widget.actions.mediaVolume(
                                          widget.room.id,
                                        ),
                                        divisions: 20,
                                        onChanged: (value) => unawaited(
                                          widget.actions
                                              .setMediaVolume(
                                                widget.room.id,
                                                value,
                                              )
                                              .catchError((Object e) {
                                                widget.report(
                                                  'Не удалось сохранить громкость сообщений.',
                                                );
                                              }),
                                        ),
                                      ),
                                      Text(
                                        'Только аудио- и видеосообщения. Громкость аудио- и видеозвонков регулируется отдельно во время звонка.',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                ListTile(
                                  leading: const Icon(Icons.search),
                                  title: const Text('Поиск в переписке'),
                                  onTap: searchFocus.requestFocus,
                                ),
                                ListTile(
                                  leading: const Icon(
                                    Icons.calendar_month_outlined,
                                  ),
                                  title: const Text('Перейти к дате'),
                                  onTap: working
                                      ? null
                                      : () => perform(calendar),
                                ),
                                ListTile(
                                  leading: const Icon(Icons.info_outline),
                                  title: Text(
                                    widget.room.isDirectChat
                                        ? 'Информация о чате'
                                        : 'Участники и настройки',
                                  ),
                                  onTap: widget.onRoomInfo,
                                ),
                                if (widget.actions.policyUrl
                                    case final String url) ...[
                                  const Divider(),
                                  ListTile(
                                    leading: const Icon(
                                      Icons.schedule_send_outlined,
                                    ),
                                    title: const Text(
                                      'Запланированные сообщения',
                                    ),
                                    subtitle: const Text(
                                      'Время отправки и состояние очереди',
                                    ),
                                    onTap: () => showAppDialog<void>(
                                      context: context,
                                      animationStyle: appAnimationStyle(
                                        context,
                                      ),
                                      builder: (_) => ScheduledView(
                                        service: ScheduledMessages(
                                          widget.room.client,
                                          url,
                                        ),
                                        roomId: widget.room.id,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
    return ComposerFocusRegion(
      focus: composerFocus,
      controller: input,
      enabled: !selecting && !recording && !working,
      child: chat,
    );
  }

  @override
  void dispose() {
    selectionTimer?.cancel();
    readAfterPoll?.cancel();
    readAfter.removeListener(refresh);
    for (final controller in motionControllers) {
      controller.dispose();
    }
    motionControllers.clear();
    updateGuards.remove(prepareUpdate);
    input.removeListener(saveDraft);
    releaseCapture(voiceCancellation);
    RecordingActivity.of(widget.room.client)?.set(widget.room, null);
    heldVideo.value = false;
    heldVideo.dispose();
    cancelledVideo.dispose();
    cancelFile = true;
    if (fileProgress == null && !preserveDraft) {
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
    unawaited(
      messagePlayback
          .pause(voicePreview)
          .whenComplete(() async {
            await voicePreview.dispose();
            messagePlayback.closed(voicePreview);
          })
          .catchError((Object _) {}),
    );
    unawaited(widget.room.setTyping(false).catchError((Object _) {}));
    input.dispose();
    searchFocus.dispose();
    composerFocus.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }
}

class AttachmentView extends StatefulWidget {
  final mx.Event event;
  final double volume;
  const AttachmentView({super.key, required this.event, this.volume = 1});
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  late final player = AudioPlayer();
  Future<mx.MatrixFile>? download;
  Uint8List? playbackBytes;
  bool playing = false, loading = false;
  double playbackRate = 1;
  Duration position = Duration.zero;
  StreamSubscription<Duration>? positionUpdates;
  Duration get duration {
    final value = widget.event.infoMap['duration'];
    return Duration(
      milliseconds: value is num && value.isFinite && value > 0
          ? value.toInt()
          : 0,
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.event.messageType != mx.MessageTypes.Audio) return;
    positionUpdates = player.onPositionChanged.listen((value) {
      if (mounted) {
        setState(
          () => position = player.state == PlayerState.completed
              ? duration
              : value,
        );
      }
    });
    player.onPlayerComplete.listen((_) {
      messagePlayback.closed(this);
      if (mounted) {
        setState(() {
          playing = false;
          position = duration;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant AttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.volume != oldWidget.volume &&
        widget.event.messageType == mx.MessageTypes.Audio) {
      unawaited(player.setVolume(widget.volume));
    }
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

  Future<void> pause() async {
    await player.pause();
    if (mounted) setState(() => playing = false);
  }

  Future<void> play({Duration? at, bool pauseAfter = false}) async {
    if (loading) return;
    setState(() => loading = true);
    try {
      if (playing && at == null) {
        await messagePlayback.pause(this);
        return;
      }
      final request = messagePlayback.request(this);
      final file = await (download ??= load());
      if (!mounted) return;
      playbackBytes ??= normalizedVoice(file.bytes);
      await messagePlayback.start(this, request, () async {
        await player.setVolume(widget.volume);
        if (player.source != null && player.state == PlayerState.paused) {
          if (at != null) await player.seek(at);
          if (!pauseAfter) await player.resume();
        } else if (pauseAfter) {
          await player.setSource(
            BytesSource(playbackBytes!, mimeType: file.mimeType),
          );
          await player.seek(at ?? Duration.zero);
          await player.pause();
        } else {
          await player.play(
            BytesSource(playbackBytes!, mimeType: file.mimeType),
            position: at,
          );
        }
        await player.setPlaybackRate(playbackRate);
        if (mounted) setState(() => playing = !pauseAfter);
      }, pause);
    } catch (_) {
      download = null; // Allow a transient failed download to be retried.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть вложение. Проверьте сеть и ключи.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> changeRate(double rate) async {
    try {
      await player.setPlaybackRate(rate);
      if (mounted) setState(() => playbackRate = rate);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось изменить скорость воспроизведения.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.event.messageType == mx.MessageTypes.Audio) {
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
          ? Color.lerp(colors.primary, colors.onSurface, .2)!
          : colors.secondaryContainer;
      final foreground = own ? colors.onPrimary : colors.onSecondaryContainer;
      final waveAccent = colors.brightness == Brightness.dark
          ? Color.lerp(colors.onSurface, Colors.white, .5)!
          : colors.primary;
      final caption = widget.event.content['dev.voicechat.caption'];
      return Container(
        width: 280,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [background, Color.lerp(background, colors.primary, .08)!],
          ),
          border: Border.all(color: foreground.withValues(alpha: .18)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: playing ? 'Приостановить' : 'Прослушать',
                  onPressed: loading ? null : () => play(),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surfaceContainerLowest.withValues(
                      alpha: .8,
                    ),
                    foregroundColor: waveAccent,
                  ),
                  icon: loading
                      ? SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: waveAccent,
                          ),
                        )
                      : Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          color: waveAccent,
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
                      WaveformView(
                        levels: wave.isEmpty ? List.filled(32, 96) : wave,
                        onSeek: loading || duration.inMilliseconds <= 0
                            ? null
                            : (fraction) {
                                final target = Duration(
                                  milliseconds:
                                      (duration.inMilliseconds * fraction)
                                          .round(),
                                );
                                setState(() => position = target);
                                unawaited(
                                  play(at: target, pauseAfter: !playing),
                                );
                              },
                        color: waveAccent,
                        progress: duration.inMilliseconds <= 0
                            ? 0
                            : position.inMilliseconds / duration.inMilliseconds,
                      ),
                      Text(
                        '${mediaTime(position)} / ${mediaTime(duration)}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: foreground),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<double>(
                  tooltip: 'Скорость воспроизведения',
                  initialValue: playbackRate,
                  onSelected: changeRate,
                  itemBuilder: (_) => [
                    for (final rate in [1.0, 1.25, 1.5, 1.75, 2.0])
                      PopupMenuItem(
                        value: rate,
                        child: Text(
                          '${rate.toString().replaceFirst(RegExp(r"\.0$"), "")}×',
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    child: Text(
                      '${playbackRate.toString().replaceFirst(RegExp(r"\.0$"), "")}×',
                      style: TextStyle(color: foreground),
                    ),
                  ),
                ),
              ],
            ),
            if (caption is String && caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  caption,
                  semanticsLabel: caption,
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
              width: 260,
              height: 180,
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
      unawaited(
        messagePlayback
            .pause(this)
            .whenComplete(() async {
              try {
                await player.dispose();
              } finally {
                messagePlayback.closed(this);
              }
            })
            .catchError((Object _) {}),
      );
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
