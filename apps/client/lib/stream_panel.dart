import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_quality.dart';
import 'camera_capture.dart';
import 'stream_controller.dart';
import 'stream_api.dart';
import 'stream_state.dart';
import 'user_action_error.dart';

String streamTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 1000000);
  return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class LiveStreamPanel extends StatefulWidget {
  final LiveStreamController controller;
  final Set<String> friends;
  final String? initialStream;
  const LiveStreamPanel({
    super.key,
    required this.controller,
    required this.friends,
    this.initialStream,
  });
  @override
  State<LiveStreamPanel> createState() => _LiveStreamPanelState();
}

class _LiveStreamPanelState extends State<LiveStreamPanel> {
  final title = TextEditingController(), description = TextEditingController();
  final duration = TextEditingController(), comment = TextEditingController();
  final form = GlobalKey<FormState>();
  final selectedFriends = <String>{};
  bool comments = true, selectedOnly = false, busy = false, _leaving = false;
  String? error;
  Timer? _timer;
  rtc.RTCVideoRenderer? _preview;
  rtc.MediaStream? _previewStream;
  LiveStreamController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(update);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial = controller.directory
          .where((s) => s.id == widget.initialStream)
          .firstOrNull;
      if (initial != null && !controller.active && mounted) {
        unawaited(run(() => info(initial)));
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => update());
  }

  void update() {
    if (mounted) setState(() {});
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on UserActionError catch (value) {
      error = value.message;
    } on LiveStreamError catch (value) {
      error = switch (value.code) {
        'stream_already_active' =>
          'У вас уже идёт эфир. Дождитесь его завершения.',
        'stream_full' => 'Все места заняты. Попробуйте войти позже.',
        'stream_on_other_device' => 'Эфир уже открыт на другом устройстве.',
        'comment_rate_limited' =>
          'Слишком быстро. Повторите отправку через секунду.',
        'stream_key_pending' => 'Ожидаем защищённое подключение.',
        'stream_revision_conflict' =>
          'Состояние эфира изменилось. Повторите действие.',
        _ => 'Действие недоступно. Проверьте соединение и состояние эфира.',
      };
    } catch (_) {
      error =
          'Не удалось выполнить действие. Проверьте сеть и разрешения камеры/микрофона.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stopPreview() async {
    final stream = _previewStream;
    _previewStream = null;
    if (_preview != null) _preview!.srcObject = null;
    for (final track in stream?.getTracks() ?? <rtc.MediaStreamTrack>[]) {
      await track.stop();
    }
    await stream?.dispose();
  }

  Future<void> preview() async {
    await stopPreview();
    if (_preview == null) {
      _preview = rtc.RTCVideoRenderer();
      await _preview!.initialize();
    }
    final stream = await captureCamera(
      controller.backCamera ? 'environment' : 'user',
      controller.quality,
    );
    if (!mounted) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      return;
    }
    _previewStream = stream;
    _preview!.srcObject = stream;
  }

  Future<void> start() async {
    if (!form.currentState!.validate()) return;
    if (selectedOnly && selectedFriends.isEmpty) {
      setState(() => error = 'Выберите хотя бы одного друга.');
      return;
    }
    await stopPreview();
    await controller.start({
      'title': title.text.trim(),
      'description': description.text,
      'audience': selectedOnly ? selectedFriends.toList() : null,
      'comments': comments,
      'duration': duration.text.trim().isEmpty
          ? null
          : int.parse(duration.text.trim()) * 60,
    });
  }

  Future<void> leavePage() async {
    if (_leaving || busy) return;
    _leaving = true;
    try {
      if (controller.active) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              controller.owner ? 'Завершить стрим?' : 'Выйти из просмотра?',
            ),
            content: Text(
              controller.owner
                  ? 'Эфир завершится для всех, чат исчезнет.'
                  : 'Вы сможете вернуться, пока эфир продолжается.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Остаться'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Выйти'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await controller.leave();
      }
      await stopPreview();
      if (mounted) Navigator.pop(context);
    } finally {
      _leaving = false;
    }
  }

  Widget qualityMenu() => DropdownButtonFormField<VideoQuality>(
    initialValue: controller.quality,
    decoration: const InputDecoration(labelText: 'Качество'),
    items: [
      for (final quality in VideoQuality.values)
        DropdownMenuItem(value: quality, child: Text(quality.label)),
    ],
    onChanged: busy
        ? null
        : (value) {
            if (value != null) {
              unawaited(
                run(() async {
                  if (controller.active) {
                    await controller.setQuality(value);
                  } else {
                    controller.quality = value;
                    if (_previewStream != null) await preview();
                  }
                }),
              );
            }
          },
  );

  Widget setup() => Form(
    key: form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Начать стрим', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        TextFormField(
          controller: title,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Название'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? 'Введите название' : null,
        ),
        TextFormField(
          controller: description,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Описание'),
        ),
        qualityMenu(),
        const SizedBox(height: 12),
        if (_previewStream != null && _preview != null)
          SizedBox(
            height: 200,
            child: rtc.RTCVideoView(_preview!, mirror: !controller.backCamera),
          ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : () => run(preview),
              icon: const Icon(Icons.videocam),
              label: const Text('Предпросмотр'),
            ),
            IconButton(
              tooltip: 'Переключить камеру',
              onPressed: busy
                  ? null
                  : () => run(() async {
                      controller.backCamera = !controller.backCamera;
                      if (_previewStream != null) await preview();
                    }),
              icon: const Icon(Icons.cameraswitch),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('Комментарии'),
          value: comments,
          onChanged: busy ? null : (v) => setState(() => comments = v),
        ),
        DropdownButtonFormField<bool>(
          initialValue: selectedOnly,
          decoration: const InputDecoration(
            labelText: 'Кто видит эфир и может войти',
          ),
          items: const [
            DropdownMenuItem(value: false, child: Text('Все друзья')),
            DropdownMenuItem(value: true, child: Text('Выбранные друзья')),
          ],
          onChanged: busy
              ? null
              : (v) => setState(() => selectedOnly = v ?? false),
        ),
        if (selectedOnly) ...[
          if (widget.friends.isEmpty) const Text('Нет доступных друзей.'),
          for (final user in widget.friends)
            CheckboxListTile(
              title: Text(user),
              value: selectedFriends.contains(user),
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      v == true
                          ? selectedFriends.add(user)
                          : selectedFriends.remove(user);
                    }),
            ),
        ],
        const SizedBox(height: 12),
        TextFormField(
          controller: duration,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Длительность в минутах (необязательно)',
            helperText:
                'Максимум ${streamTime(Duration(seconds: controller.maxDuration))}',
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) return null;
            final minutes = int.tryParse(value.trim());
            return minutes == null ||
                    minutes <= 0 ||
                    minutes * 60 > controller.maxDuration
                ? 'Укажите время в пределах максимума'
                : null;
          },
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy ? null : () => run(start),
          icon: const Icon(Icons.sensors),
          label: const Text('Начать стрим'),
        ),
        const SizedBox(height: 24),
        Text('Эфиры друзей', style: Theme.of(context).textTheme.titleLarge),
        if (controller.directory.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Сейчас доступных эфиров нет.'),
          ),
        for (final stream in controller.directory)
          ListTile(
            leading: const Icon(Icons.sensors),
            title: Text(stream.title),
            subtitle: Text('${stream.owner} · ${stream.viewers}/10'),
            onTap: busy ? null : () => run(() => info(stream)),
          ),
      ],
    ),
  );

  Future<void> info(LiveStreamSnapshot stream) async {
    stream = LiveStreamSnapshot.parse(
      await controller.api.command('info', {'stream_id': stream.id}),
    );
    if (!mounted) return;
    final enter = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(stream.title),
        content: Text(
          '${stream.description}\n${stream.owner}\nНачало: ${stream.startedAt.toLocal()}\nДлительность: ${streamTime(stream.endsAt.difference(stream.startedAt))}\nЗрителей: ${stream.viewers}/10',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Смотреть'),
          ),
        ],
      ),
    );
    if (enter == true) {
      await stopPreview();
      await controller.join(stream.id);
    }
  }

  Widget video() {
    if (controller.paused) {
      return const Center(
        child: Text('Стрим на паузе', style: TextStyle(color: Colors.white)),
      );
    }
    lk.VideoTrack? track;
    String? sid;
    if (controller.owner) {
      final publication = controller
          .media
          ?.localParticipant
          ?.videoTrackPublications
          .where((p) => !p.muted)
          .firstOrNull;
      if (publication?.track is lk.VideoTrack) track = publication!.track;
    } else {
      for (final participant
          in controller.media?.remoteParticipants.values ??
              <lk.RemoteParticipant>[]) {
        final publication = participant.videoTrackPublications
            .where((p) => !p.muted)
            .firstOrNull;
        if (publication?.track is lk.VideoTrack) {
          track = publication!.track;
          sid = publication.sid;
        }
      }
    }
    if (track == null) {
      return const Center(
        child: Text(
          'Камера выключена или подключается',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        lk.VideoTrackRenderer(
          track,
          mirrorMode: controller.owner && !controller.backCamera
              ? lk.VideoViewMirrorMode.mirror
              : lk.VideoViewMirrorMode.off,
          fit: lk.VideoViewFit.contain,
        ),
        if (!controller.owner && !controller.decryptedVideo.contains(sid))
          const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Text(
                'Ожидаем защищённое видео',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  Widget watching() {
    final current = controller.snapshot!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(current.title, style: Theme.of(context).textTheme.titleLarge),
        if (current.description.isNotEmpty) Text(current.description),
        Text('Начало: ${current.startedAt.toLocal()}'),
        Text(
          '${streamTime(current.remaining(controller.elapsed.elapsed))} осталось · ${current.viewers}/10 зрителей',
        ),
        LinearProgressIndicator(
          value: current.progress(controller.elapsed.elapsed),
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(color: Colors.black, child: video()),
        ),
        Text(controller.status),
        Wrap(
          spacing: 8,
          children: [
            if (controller.owner) ...[
              IconButton(
                tooltip: controller.microphoneOn
                    ? 'Выключить микрофон'
                    : 'Включить микрофон',
                icon: Icon(controller.microphoneOn ? Icons.mic : Icons.mic_off),
                onPressed: busy
                    ? null
                    : () => run(
                        () => controller.microphone(!controller.microphoneOn),
                      ),
              ),
              IconButton(
                tooltip: controller.cameraOn
                    ? 'Выключить камеру'
                    : 'Включить камеру',
                icon: Icon(
                  controller.cameraOn ? Icons.videocam : Icons.videocam_off,
                ),
                onPressed: busy
                    ? null
                    : () => run(() => controller.camera(!controller.cameraOn)),
              ),
              IconButton(
                tooltip: 'Переключить камеру',
                icon: const Icon(Icons.cameraswitch),
                onPressed: busy ? null : () => run(controller.switchCamera),
              ),
              if (controller.paused)
                FilledButton(
                  onPressed: busy ? null : () => run(controller.resume),
                  child: const Text('Продолжить стрим'),
                ),
            ] else
              IconButton(
                tooltip: controller.speakerOn
                    ? 'Выключить звук у себя'
                    : 'Включить звук',
                icon: Icon(
                  controller.speakerOn ? Icons.volume_up : Icons.volume_off,
                ),
                onPressed: busy
                    ? null
                    : () => run(() => controller.sound(!controller.speakerOn)),
              ),
            OutlinedButton(
              onPressed: busy ? null : () => run(controller.leave),
              child: Text(
                controller.owner ? 'Завершить стрим' : 'Выйти из просмотра',
              ),
            ),
          ],
        ),
        qualityMenu(),
        if (controller.owner)
          ExpansionTile(
            title: const Text('Зрители'),
            children: [
              for (final user in current.viewerUsers ?? <String>[])
                ListTile(title: Text(user)),
            ],
          ),
        const SizedBox(height: 12),
        Text('Чат эфира', style: Theme.of(context).textTheme.titleMedium),
        const Text('После завершения эфира чат исчезнет.'),
        SizedBox(
          height: 240,
          child: ListView.builder(
            itemCount: controller.comments.length,
            itemBuilder: (context, index) {
              final entry = controller.comments[index];
              return ListTile(
                dense: true,
                title: Text(entry.text),
                subtitle: Text(entry.author),
              );
            },
          ),
        ),
        if (current.comments)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: comment,
                  maxLength: 1000,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Комментарий'),
                ),
              ),
              IconButton(
                tooltip: 'Отправить комментарий',
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await controller.sendComment(comment.text);
                        comment.clear();
                      }),
                icon: const Icon(Icons.send),
              ),
            ],
          )
        else
          const Text('Комментарии отключены'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !controller.active,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) unawaited(leavePage());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Стримы'),
        leading: IconButton(
          tooltip: 'Назад',
          icon: const Icon(Icons.arrow_back),
          onPressed: leavePage,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (busy) const LinearProgressIndicator(),
                  controller.active ? watching() : setup(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    controller.removeListener(update);
    _timer?.cancel();
    unawaited(stopPreview().whenComplete(() => _preview?.dispose()));
    title.dispose();
    description.dispose();
    duration.dispose();
    comment.dispose();
    super.dispose();
  }
}
