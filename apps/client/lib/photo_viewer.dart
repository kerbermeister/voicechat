import 'package:flutter/material.dart';
import 'app_motion.dart';
import 'package:flutter/services.dart';

Future<void> showPhotos(
  BuildContext context,
  List<Future<Uint8List> Function()> photos,
  int initial,
) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => PhotoViewer(photos: photos, initial: initial),
  ),
);

class PhotoViewer extends StatefulWidget {
  final List<Future<Uint8List> Function()> photos;
  final int initial;
  const PhotoViewer({super.key, required this.photos, required this.initial});
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
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
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(1),
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.pop(context),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: Stack(
            children: [
              PageView.builder(
                controller: controller,
                itemCount: widget.photos.length,
                onPageChanged: (value) => setState(() => index = value),
                itemBuilder: (_, i) => FutureBuilder<Uint8List>(
                  future: loaded.putIfAbsent(i, widget.photos[i]),
                  builder: (_, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Фото недоступно. Проверьте соединение и ключи.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
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
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh.withValues(alpha: .9),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Semantics(
                      liveRegion: true,
                      label: 'Фото ${index + 1} из ${widget.photos.length}',
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
    controller.dispose();
    super.dispose();
  }
}
