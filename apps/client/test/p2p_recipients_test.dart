import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/people_picker.dart';
import 'package:voicechat_probe/p2p/file_icon.dart';
import 'p2p_service_test.dart' show P2pClient;

class ProfileClient extends P2pClient {
  @override
  Future<mx.Profile> getProfileFromUserId(
    String id, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => mx.Profile(
    userId: id,
    displayName: id == '@anna:local' ? 'Анна Лис' : 'Борис',
  );
}

void main() {
  test('file pictures distinguish MIME types and extension fallbacks', () {
    for (final (name, mime, label) in [
      ('photo.HEIC', 'application/octet-stream', 'Изображение'),
      ('clip', 'video/mp4', 'Видео'),
      ('song.FLAC', '', 'Аудио'),
      ('report.pdf', '', 'PDF'),
      ('data.xlsx', '', 'Таблица'),
      ('source.dart', '', 'Код'),
      ('backup.tar.gz', '', 'Архив'),
      ('notes.txt', 'text/plain', 'Документ'),
      ('unknown', 'application/octet-stream', 'Файл'),
    ]) {
      expect(p2pFileAppearance(name, mime).label, label);
    }
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'recipient identities, live presence and selection cap at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final client = ProfileClient();
        client.presences['@anna:local'] = mx.CachedPresence(
          mx.PresenceType.online,
          0,
          null,
          true,
          '@anna:local',
        );
        client.presences['@boris:local'] = mx.CachedPresence(
          mx.PresenceType.offline,
          0,
          null,
          false,
          '@boris:local',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(width == 320 ? 1.5 : 1),
              ),
              child: Scaffold(
                body: PeoplePicker(
                  client: client,
                  multiple: true,
                  allowedUsers: const {'@anna:local', '@boris:local'},
                  initialUsers: const ['@anna:local'],
                  maxSelected: 1,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Получатели: 1 из 1'), findsOneWidget);
        expect(find.text('Анна Лис'), findsWidgets);
        expect(find.text('@anna:local'), findsWidgets);
        expect(find.text('В сети'), findsWidgets);
        final anna = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Анна Лис'),
        );
        final boris = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Борис'),
        );
        expect(anna.value, true);
        expect(anna.onChanged, isNotNull);
        expect(boris.onChanged, isNull);
        expect(
          tester
              .widgetList<PersonAvatar>(find.byType(PersonAvatar))
              .where((a) => a.name == 'Анна Лис')
              .every((a) => a.online),
          true,
        );
        final offline = mx.CachedPresence(
          mx.PresenceType.offline,
          0,
          null,
          false,
          '@anna:local',
        );
        client.presences['@anna:local'] = offline;
        client.onPresenceChanged.add(offline);
        await tester.pumpAndSettle();
        expect(find.text('В сети'), findsNothing);
        expect(find.text('Не в сети'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await client.onPresenceChanged.close();
        await client.onToDeviceEvent.close();
      },
    );
  }
}
