import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/room_members_dialog.dart';
import 'rich_media_test.dart' show RichClient;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/identity_field.dart';
import 'package:voicechat_probe/storage_dialog.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/waveform_view.dart';

void main() {
  test('Voice waveform preserves silence and relative peaks', () {
    expect(waveLevel(0), 0);
    expect(waveLevel(256), closeTo(.7993, .001));
    expect(waveLevel(1024), 1);
    expect(waveLevel(80), lessThan(waveLevel(700)));
    expect(waveLevel(-1), 0);
    expect(waveLevel(2048), 1);
  });
  testWidgets('Each public identifier copies its own exact value', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              IdentityField(label: 'Устройство', value: 'DEVICE-123'),
              IdentityField(label: 'Отпечаток', value: 'aB+/123EXACT'),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('DEVICE-123'));
    await tester.pump();
    await tester.tap(find.text('aB+/123EXACT'));
    await tester.pump();
    expect(copied, ['DEVICE-123', 'aB+/123EXACT']);
  });

  testWidgets('Unknown and lost signal never show good connection bars', (
    tester,
  ) async {
    for (final entry in {
      CallQuality.unknown: 0,
      CallQuality.lost: 0,
      CallQuality.poor: 1,
      CallQuality.good: 3,
      CallQuality.excellent: 5,
    }.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CallQualityIndicator(quality: entry.key)),
        ),
      );
      for (var i = 0; i < 5; i++) {
        expect(
          find.byKey(ValueKey('signal-$i-${i < entry.value}')),
          findsOneWidget,
        );
      }
    }
  });

  testWidgets('Storage chart handles counting, empty, half and excess use', (
    tester,
  ) async {
    for (final used in <int?>[null, 0, 8 * 1048576, 20 * 1048576]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StorageUsageChart(usedBytes: used, limitMiB: 16),
          ),
        ),
      );
      final chart = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(
        chart.value,
        used == null ? null : (used / (16 * 1048576)).clamp(0, 1),
      );
      expect(
        find.text('Лимит превышен'),
        used == 20 * 1048576 ? findsOneWidget : findsNothing,
      );
      if (used == 20 * 1048576) {
        expect(find.textContaining('Осталось: 0.0 МиБ'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('History date picker uses Russian month and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppPalette.lavender.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDatePicker(
                context: context,
                initialDate: DateTime(2026, 10, 23),
                firstDate: DateTime(2020),
                lastDate: DateTime(2027),
              ),
              child: const Text('Календарь'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Календарь'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(RegExp('октябр', caseSensitive: false)),
      findsOneWidget,
    );
    expect(
      find.textContaining(RegExp('отмена', caseSensitive: false)),
      findsOneWidget,
    );
    expect(find.textContaining('October'), findsNothing);
  });
  testWidgets(
    'Group action tray fits narrow, rotated, large-text and desktop screens',
    (tester) async {
      final client = RichClient();
      final room = mx.Room(id: '!tray:local', client: client);
      room.states[mx.EventTypes.RoomPowerLevels] = {
        '': mx.StrippedStateEvent(
          type: mx.EventTypes.RoomPowerLevels,
          stateKey: '',
          senderId: '@user:local',
          content: {
            'users': {'@user:local': 100},
          },
        ),
      };
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(320, 640),
        const Size(640, 320),
        const Size(1440, 900),
      ]) {
        for (final scale in [1.0, 1.5]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppPalette.lavender.theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: RoomMembersDialog(room: room, members: const []),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final label in [
            'Аватар',
            'Пригласить',
            'Название',
            'Покинуть',
            'Закрыть',
          ]) {
            expect(find.text(label), findsOneWidget);
            expect(
              tester.getRect(find.text(label)).bottom,
              lessThan(size.height),
            );
          }
          expect(tester.takeException(), isNull, reason: "$size, scale $scale");
        }
      }
    },
  );
}
