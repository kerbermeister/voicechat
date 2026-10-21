import 'package:flutter/material.dart';
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
    controller.animateToPage(
      next,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
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
        backgroundColor: const Color(0xFF17131E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF17131E),
          foregroundColor: Colors.white,
          title: Text('${index + 1} / ${widget.photos.length}'),
          leading: IconButton(
            tooltip: 'Закрыть просмотр',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: widget.photos.length,
              onPageChanged: (value) => setState(() => index = value),
              itemBuilder: (_, i) => FutureBuilder<Uint8List>(
                future: loaded.putIfAbsent(i, widget.photos[i]),
                builder: (_, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text(
                        'Фото недоступно. Проверьте соединение и ключи.',
                        style: TextStyle(color: Colors.white),
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
            if (index > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton.filled(
                  tooltip: 'Предыдущее фото',
                  onPressed: () => move(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
            if (index + 1 < widget.photos.length)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton.filled(
                  tooltip: 'Следующее фото',
                  onPressed: () => move(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
          ],
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
