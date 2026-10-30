import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keep the desktop composer ready without opening a phone's soft keyboard.
class ComposerFocusRegion extends StatefulWidget {
  const ComposerFocusRegion({
    super.key,
    required this.focus,
    required this.controller,
    required this.child,
    this.enabled = true,
  });
  final FocusNode focus;
  final TextEditingController controller;
  final Widget child;
  final bool enabled;
  @override
  State<ComposerFocusRegion> createState() => _ComposerFocusRegionState();
}

class _ComposerFocusRegionState extends State<ComposerFocusRegion> {
  bool keyboardNavigation = false;
  bool scheduled = false;
  bool get desktop => const {
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  }.contains(defaultTargetPlatform);
  EditableText? get editable => FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>()
      ?.widget;
  bool get current =>
      widget.enabled && (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(restore);
    restore();
  }

  @override
  void didUpdateWidget(ComposerFocusRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) restore();
  }

  void restore() {
    if (!desktop || scheduled || keyboardNavigation || !mounted) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (!mounted || !current || widget.focus.hasFocus || keyboardNavigation) {
        return;
      }
      final field = editable;
      if (field != null && field.focusNode != widget.focus) {
        if (!field.readOnly || !field.controller.selection.isCollapsed) return;
      }
      widget.focus.requestFocus();
    });
  }

  KeyEventResult key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || !current) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      keyboardNavigation = true;
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        widget.focus.hasFocus) {
      return KeyEventResult.ignored;
    }
    final field = editable;
    if (field != null && !field.readOnly) return KeyEventResult.ignored;
    final character = event.character;
    if (character == null ||
        character.isEmpty ||
        character.codeUnits.any((unit) => unit < 32)) {
      return KeyEventResult.ignored;
    }
    // Forward this hardware character once; native IME continues in the real field.
    keyboardNavigation = false;
    widget.focus.requestFocus();
    final value = widget.controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : start;
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, character),
      selection: TextSelection.collapsed(offset: start + character.length),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: key,
    child: Listener(
      onPointerUp: (_) {
        keyboardNavigation = false;
        restore();
      },
      child: widget.child,
    ),
  );
  @override
  void dispose() {
    FocusManager.instance.removeListener(restore);
    super.dispose();
  }
}
