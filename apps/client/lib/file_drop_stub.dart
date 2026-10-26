import 'package:flutter/widgets.dart';
import 'picked_file.dart';

class FileDrop extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final void Function(List<PickedFile>) onDrop;
  const FileDrop({
    super.key,
    required this.child,
    required this.enabled,
    required this.onDrop,
  });
  @override
  Widget build(BuildContext context) => child;
}
