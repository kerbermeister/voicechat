import 'dart:io';

/// flutter_tester runs from the active SDK's engine cache on both CI and local.
File materialFontFile(String name) {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final font = File(
      '${directory.path}/bin/cache/artifacts/material_fonts/$name',
    );
    if (font.existsSync()) return font;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'Material font $name not found in the active Flutter SDK',
      );
    }
    directory = parent;
  }
}
