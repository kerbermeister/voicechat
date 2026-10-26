@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:voicechat_probe/file_drop.dart';
import 'package:voicechat_probe/picked_file.dart';

void main() {
  testWidgets(
    'Browser drops preserve files, prevent navigation and respect chat bounds',
    (tester) async {
      List<PickedFile>? received;
      final key = GlobalKey();
      Future<void> mount(bool enabled) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 300,
                child: FileDrop(
                  key: key,
                  enabled: enabled,
                  onDrop: (files) => received = files,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      await mount(true);
      final data = web.DataTransfer();
      data.items.add(
        web.File(
          ['photo-data'.toJS].toJS,
          'photo.png',
          web.FilePropertyBag(type: 'image/png'),
        ),
      );
      data.items.add(
        web.File(
          ['document-data'.toJS].toJS,
          'report.pdf',
          web.FilePropertyBag(type: 'application/pdf'),
        ),
      );
      bool dispatch(String type, {int x = 100, web.DataTransfer? transfer}) =>
          web.document.dispatchEvent(
            web.DragEvent(
              type,
              web.DragEventInit(
                dataTransfer: transfer ?? data,
                clientX: x,
                clientY: 100,
                bubbles: true,
                cancelable: true,
              ),
            ),
          );
      expect(dispatch('dragover'), false);
      await tester.pump();
      expect(
        find.text('Отпустите файлы, чтобы прикрепить к чату'),
        findsOneWidget,
      );
      expect(dispatch('drop'), false);
      await tester.pump();
      expect(received!.map((file) => file.name), ['photo.png', 'report.pdf']);
      expect(
        await tester.runAsync(
          () async => String.fromCharCodes(
            await received![1].read(0, received![1].size),
          ),
        ),
        'document-data',
      );
      expect(
        find.text('Отпустите файлы, чтобы прикрепить к чату'),
        findsNothing,
      );
      received = null;
      expect(dispatch('drop', x: 600), false);
      expect(received, isNull);
      await mount(false);
      expect(dispatch('drop'), false);
      expect(received, isNull);
      final text = web.DataTransfer()
        ..setData('text/plain', 'keep normal text dragging');
      expect(dispatch('drop', transfer: text), true);
      await tester.pumpWidget(const SizedBox());
      expect(dispatch('drop'), true);
    },
  );
}
