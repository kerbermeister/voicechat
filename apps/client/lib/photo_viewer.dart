import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'temporary_message.dart';
import 'read_after.dart';
import 'app_motion.dart';
import 'package:flutter/services.dart';

Future<void> showPhotos(
  BuildContext context,
  List<Future<Uint8List> Function()> photos,
  int initial, {
  mx.Event? event,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: EdgeInsets.zero,
    child: PhotoViewer(photos: photos, initial: initial, event: event),
  ),
);

class PhotoViewer extends StatefulWidget {
  final List<Future<Uint8List> Function()> photos;
  final int initial;
  final mx.Event? event;
  const PhotoViewer({
    super.key,
    required this.photos,
    required this.initial,
    this.event,
  });
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> with WidgetsBindingObserver {
  Timer? deadline;
  ReadAfterState? readAfter;
  bool expired = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final event = widget.event;
    if (event != null) {
      readAfter = ReadAfterState.of(event.room.client)
        ..addListener(scheduleExpiry);
      scheduleExpiry();
    }
  }

  void scheduleExpiry() {
    deadline?.cancel();
    final event = widget.event;
    if (event == null || expired) return;
    if (messageExpired(event)) {
      expire();
      return;
    }
    final expiry = messageExpiry(event);
    if (expiry != null) {
      deadline = Timer(expiry.difference(DateTime.now()), expire);
    }
  }

  void expire() {
    if (!mounted || expired) return;
    expired = true;
    loaded.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route is PopupRoute) Navigator.of(context).removeRoute(route);
    });
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) scheduleExpiry();
  }

  late final controller = PageController(initialPage: widget.initial);
  late int index = widget.initial;
  final loaded = <int, Future<Uint8List>>{};
  void move(int delta) {
    final next = index + delta;
    if (next < 0 || next >= widget.photos.length) return;
    final duration = motionDuration(context);
    if (duration == Duration.zero) {
      controller.jumpToPage(next);
    } else {
      controller.animateToPage(
        next,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget control(IconData icon, String label, VoidCallback action) {
    final colors = Theme.of(context).colorScheme;
    return IconButton.filledTonal(
      tooltip: label,
      onPressed: action,
      style: IconButton.styleFrom(
        minimumSize: const Size(56, 56),
        maximumSize: const Size(56, 56),
        backgroundColor: colors.surfaceContainerHigh.withValues(alpha: .94),
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outline.withValues(alpha: .65)),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 30),
    );
  }

  Widget navigation(bool previous) {
    final enabled = previous ? index > 0 : index + 1 < widget.photos.length;
    return Align(
      alignment: previous ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: IgnorePointer(
          ignoring: !enabled,
          child: ExcludeFocus(
            excluding: !enabled,
            child: ExcludeSemantics(
              excluding: !enabled,
              child: AnimatedSwitcher(
                duration: motionDuration(context),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: animation.drive(Tween(begin: .92, end: 1.0)),
                    child: child,
                  ),
                ),
                child: enabled
                    ? control(
                        previous
                            ? Icons.chevron_left_rounded
                            : Icons.chevron_right_rounded,
                        previous ? 'Предыдущее фото' : 'Следующее фото',
                        () => move(previous ? -1 : 1),
                      )
                    : const SizedBox(width: 56, height: 56),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => expired
      ? const SizedBox.shrink()
      : CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(1),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.pop(context),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Stack(
                  children: [
                    LayoutBuilder(
                      builder: (_, box) => GestureDetector(
                        key: const ValueKey('photo-navigation-surface'),
                        behavior: HitTestBehavior.translucent,
                        excludeFromSemantics: true,
                        onTapUp: (details) {
                          final zone = (box.maxWidth * .2).clamp(80.0, 160.0);
                          if (details.localPosition.dx <= zone) {
                            move(-1);
                          } else if (details.localPosition.dx >=
                              box.maxWidth - zone) {
                            move(1);
                          }
                        },
                        child: PageView.builder(
                          controller: controller,
                          itemCount: widget.photos.length,
                          onPageChanged: (value) =>
                              setState(() => index = value),
                          itemBuilder: (_, i) => FutureBuilder<Uint8List>(
                            future: loaded.putIfAbsent(i, widget.photos[i]),
                            builder: (_, snapshot) {
                              if (snapshot.hasError) {
                                return Center(
                                  child: Text(
                                    'Фото недоступно. Проверьте соединение и ключи.',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                  ),
                                );
                              }
                              if (!snapshot.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              return InteractiveViewer(
                                minScale: 1,
                                maxScale: 5,
                                child: Center(
                                  child: Image.memory(
                                    snapshot.data!,
                                    semanticLabel: 'Фото ${i + 1}',
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    navigation(true),
                    navigation(false),
                    Positioned(
                      top: 16,
                      left: 80,
                      right: 80,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh
                                .withValues(alpha: .9),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Semantics(
                            liveRegion: true,
                            label:
                                'Фото ${index + 1} из ${widget.photos.length}',
                            excludeSemantics: true,
                            child: Text(
                              '${index + 1} / ${widget.photos.length}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: control(
                        Icons.close_rounded,
                        'Закрыть просмотр',
                        () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    deadline?.cancel();
    readAfter?.removeListener(scheduleExpiry);
    controller.dispose();
    super.dispose();
  }
}
