import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'screen_capture.dart';
import 'screen_controller.dart';
import 'screen_state.dart';

/// Окно может сворачиваться: состояние и capture остаются у контроллера звонка.
class ScreenPanel extends StatelessWidget {
  final ScreenShareController controller;
  const ScreenPanel({super.key, required this.controller});

  String get ownerLabel {
    final owner = controller.snapshot?.owner;
    if (owner == controller.identity) return 'Вы';
    final user = owner?.split('/').first;
    return controller.call.chat
            .getParticipants()
            .where((p) => p.id == user)
            .firstOrNull
            ?.displayName ??
        user ??
        'Участник';
  }

  Widget picture({bool expanded = false}) {
    final track = controller.displayTrack;
    return ColoredBox(
      color: Colors.black,
      child: track == null
          ? Center(
              child: Semantics(
                label: 'Ожидаем защищённое изображение',
                child: const Icon(
                  Icons.lock_outline,
                  color: Colors.white70,
                  size: 32,
                ),
              ),
            )
          : lk.VideoTrackRenderer(
              track,
              key: ValueKey(
                '${controller.snapshot?.generation}:${track.mediaStreamTrack.id}:$expanded',
              ),
              fit: lk.VideoViewFit.contain,
              mirrorMode: lk.VideoViewMirrorMode.off,
            ),
    );
  }

  Future<void> expand(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Вернуться в звонок',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.fullscreen_exit),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => picture(expanded: true),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.snapshot;
      final mine = state?.owner == controller.identity;
      final active = state?.state == 'active';
      final waiting =
          controller.busy ||
          {
            ScreenPhase.connecting,
            ScreenPhase.reconnecting,
          }.contains(controller.phase);
      final label = switch (controller.phase) {
        ScreenPhase.selecting => 'Выберите экран для показа',
        ScreenPhase.preparing => 'Готовим демонстрацию',
        ScreenPhase.connecting => 'Подключаем защищённый экран',
        ScreenPhase.reconnecting => 'Восстанавливаем демонстрацию',
        ScreenPhase.closed => 'Демонстрация недоступна до следующего звонка',
        _ => active ? 'Экран показывает: $ownerLabel' : 'Демонстрация экрана',
      };
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(label, textAlign: TextAlign.center),
          ),
          if (active) ...[
            const SizedBox(height: 8),
            AspectRatio(aspectRatio: 16 / 9, child: picture()),
          ],
          if (controller.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(controller.notice!, textAlign: TextAlign.center),
            ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              if (mine)
                TextButton.icon(
                  onPressed: controller.isClosed ? null : controller.stop,
                  icon: const Icon(Icons.stop_screen_share_outlined),
                  label: const Text('Остановить показ'),
                )
              else if (ScreenCapture.supported)
                TextButton.icon(
                  onPressed:
                      controller.isClosed ||
                          waiting ||
                          state == null ||
                          state.roster.isEmpty
                      ? null
                      : controller.share,
                  icon: const Icon(Icons.screen_share_outlined),
                  label: Text(active ? 'Перехватить экран' : 'Показать экран'),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'В этом браузере доступен только просмотр экрана.',
                    textAlign: TextAlign.center,
                  ),
                ),
              if (active)
                IconButton(
                  tooltip: 'Развернуть экран',
                  onPressed: () => expand(context),
                  icon: const Icon(Icons.fullscreen),
                ),
            ],
          ),
        ],
      );
    },
  );
}
