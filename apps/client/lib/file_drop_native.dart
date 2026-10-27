import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'file_source_native.dart';
import 'picked_file.dart';

/// Native hosts exchange opaque selections through the existing files channel.
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

class _FileDropState extends State<FileDrop> with WidgetsBindingObserver {
  static const channel = MethodChannel('voicechat/file-drop');
  static final targets = <_FileDropState>[];
  static _FileDropState? get activeTarget {
    for (final target in targets.reversed) {
      if (target.mounted && target.enabled && target.supported) return target;
    }
    return null;
  }

  bool hovering = false;
  bool get supported => switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };
  bool get enabled =>
      widget.enabled && (ModalRoute.of(context)?.isCurrent ?? true);
  Rect? get bounds {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    targets.add(this);
    channel.setMethodCallHandler(
      (call) async => await activeTarget?.handle(call) ?? false,
    );
  }

  Future<dynamic> handle(MethodCall call) async {
    if (call.method == 'hover') {
      if (mounted) setState(() => hovering = call.arguments == true);
      return null;
    }
    if (call.method != 'drop') {
      throw MissingPluginException();
    }
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final position = Offset(
      (args['x'] as num).toDouble(),
      (args['y'] as num).toDouble(),
    );
    if (!mounted || !enabled || !(bounds?.contains(position) ?? false)) {
      return false;
    }
    final files = (args['files'] as List)
        .map((file) => fileSource(Map<String, dynamic>.from(file as Map)))
        .toList();
    setState(() => hovering = false);
    widget.onDrop(files);
    return true;
  }

  void updateTarget() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !supported ||
          (activeTarget != null && activeTarget != this)) {
        return;
      }
      final rect = bounds;
      try {
        await channel.invokeMethod<void>(
          'target',
          !enabled || rect == null
              ? null
              : {
                  'x': rect.left,
                  'y': rect.top,
                  'width': rect.width,
                  'height': rect.height,
                },
        );
      } on MissingPluginException {
        // Hosts without a desktop adapter remain inert until their platform ships.
      }
    });
  }

  @override
  void didChangeMetrics() => updateTarget();
  @override
  Widget build(BuildContext context) {
    updateTarget();
    return Stack(
      children: [
        widget.child,
        if (hovering && enabled)
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    targets.remove(this);
    if (targets.isEmpty) {
      channel.setMethodCallHandler(null);
      unawaited(channel.invokeMethod<void>('target').catchError((Object _) {}));
    } else {
      targets.last.updateTarget();
    }
    super.dispose();
  }
}
