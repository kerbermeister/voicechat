import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'file_source_web.dart';
import 'picked_file.dart';

class FileDrop extends StatefulWidget {
  final Widget child;
  final String label;
  final bool enabled;
  final void Function(List<PickedFile>) onDrop;
  const FileDrop({
    super.key,
    this.label = 'Отпустите файлы, чтобы прикрепить к чату',
    required this.child,
    required this.enabled,
    required this.onDrop,
  });
  @override
  State<FileDrop> createState() => _FileDropState();
}

class _FileDropState extends State<FileDrop> {
  bool hovering = false;
  final handlers = <String, JSFunction>{};
  bool contains(web.DragEvent event) {
    final box = context.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        (box.localToGlobal(Offset.zero) & box.size).contains(
          Offset(event.clientX.toDouble(), event.clientY.toDouble()),
        );
  }

  bool files(web.DragEvent event) =>
      event.dataTransfer?.types.toDart.any((type) => type.toDart == 'Files') ==
      true;
  void hover(bool value) {
    if (hovering != value) setState(() => hovering = value);
  }

  @override
  void initState() {
    super.initState();
    for (final type in [
      'dragenter',
      'dragover',
      'dragleave',
      'drop',
      'dragend',
    ]) {
      final handler = ((web.DragEvent event) {
        if (type == 'dragend' || type == 'dragleave') {
          hover(false);
          return;
        }
        if (!files(event)) return;
        // Prevent navigation even outside the chat or while an action is busy.
        event.preventDefault();
        final accepted =
            widget.enabled &&
            ModalRoute.of(context)?.isCurrent != false &&
            contains(event);
        if (type != 'drop') {
          event.dataTransfer?.dropEffect = accepted ? 'copy' : 'none';
          hover(accepted);
          return;
        }
        hover(false);
        if (!accepted) return;
        final list = event.dataTransfer?.files;
        if (list != null && list.length > 0) {
          widget.onDrop([
            for (var i = 0; i < list.length; i++) fileSource(list.item(i)!),
          ]);
        }
      }).toJS;
      handlers[type] = handler;
      web.document.addEventListener(type, handler);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (hovering && widget.enabled)
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: .94),
              child: Center(
                child: Semantics(liveRegion: true, child: Text(widget.label)),
              ),
            ),
          ),
        ),
    ],
  );
  @override
  void dispose() {
    for (final entry in handlers.entries) {
      web.document.removeEventListener(entry.key, entry.value);
    }
    super.dispose();
  }
}
