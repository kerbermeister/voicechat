import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/voice_recording.dart';
import 'package:voicechat_probe/waveform_view.dart';
import 'mobile_layout_test.dart' show LayoutClient, EmptyTimeline;

Uint8List pcmWindows(List<int> amplitudes) {
  final data = ByteData(amplitudes.length * 1600);
  for (var i = 0; i < amplitudes.length * 800; i++) {
    data.setInt16(
      i * 2,
      amplitudes[i ~/ 800] * (i.isEven ? 1 : -1),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

class VoiceTimeline extends EmptyTimeline {
  VoiceTimeline(super.room);
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
}

class VoiceClient extends LayoutClient {
  @override
  final rooms = <mx.Room>[];
  @override
  mx.PushRuleSet? globalPushRules;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final channel in [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'com.llfbandit.record/messages',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channel), (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  MethodChannel('xyz.luan/audioplayers/events/$id'),
                  (_) async => null,
                );
          }
          return null;
        });
  }
  setUpAll(() async {
    final path = Platform.environment['VOICECHAT_PREVIEW_FONT'];
    if (path != null) {
      final font = FontLoader('VoicePreview')
        ..addFont(
          Future.value(ByteData.sublistView(await File(path).readAsBytes())),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '${File(path).parent.path}/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['VOICECHAT_PREVIEW_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  test('50 ms RMS retains short peaks, silence and odd chunk boundaries', () {
    final pcm = pcmWindows([0, 1024, 16384, 0, 32767, 0]);
    final whole = PcmLevelMeter()..add(pcm);
    final split = PcmLevelMeter();
    for (var i = 0; i < pcm.length; i += 113) {
      split.add(Uint8List.sublistView(pcm, i, (i + 113).clamp(0, pcm.length)));
    }
    expect(whole.levels, [0, 32, 512, 0, 1024, 0]);
    expect(split.levels, whole.levels);
    split.add(pcmWindows(List.filled(100, 0)));
    expect(split.levels, List.filled(PcmLevelMeter.historySize, 0));
    expect(waveLevel(32), greaterThan(.45));
    expect(waveLevel(32), lessThan(waveLevel(512)));
  });

  testWidgets(
    'Voice messages keep time inset; recording panel renders consecutive PCM levels',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final client = VoiceClient();
      final room = mx.Room(id: '!voice:local', client: client);
      client.rooms.add(room);
      room.states[mx.EventTypes.RoomName] = {
        '': mx.StrippedStateEvent(
          type: mx.EventTypes.RoomName,
          stateKey: '',
          senderId: client.userID,
          content: {'name': 'Семья'},
        ),
      };
      room.states[mx.EventTypes.RoomMember] = {
        for (final id in ['@user:local', '@friend:local'])
          id: mx.StrippedStateEvent(
            type: mx.EventTypes.RoomMember,
            stateKey: id,
            senderId: id,
            content: {
              'membership': 'join',
              'displayname': id == '@user:local' ? 'Элис' : 'Боб',
            },
          ),
      };
      final timeline = VoiceTimeline(room);
      for (final (id, sender, text) in [
        ('short', '@user:local', 'Короткое сообщение'),
        (
          'long',
          '@friend:local',
          'Да, я всё услышала. Давай созвонимся вечером и обсудим подробности.',
        ),
      ]) {
        timeline.events.add(
          mx.Event.fromJson({
            'event_id': '\$$id',
            'type': mx.EventTypes.Message,
            'sender': sender,
            'origin_server_ts': 1792758000000,
            'content': {'msgtype': mx.MessageTypes.Text, 'body': text},
          }, room),
        );
      }
      timeline.events.insert(
        0,
        mx.Event.fromJson({
          'event_id': r'$audio',
          'type': mx.EventTypes.Message,
          'sender': '@user:local',
          'origin_server_ts': 1792758000000,
          'content': {
            'msgtype': mx.MessageTypes.Audio,
            'body': 'Голосовое',
            'info': {'duration': 12000},
            'dev.voicechat.waveform': [
              0,
              10,
              60,
              180,
              300,
              120,
              30,
              0,
              80,
              500,
              250,
              40,
              10,
              0,
            ],
          },
        }, room),
      );
      final actions = ChatActions(room.client);
      room.lastEvent = timeline.events.first;
      for (final width in [320.0, 390.0, 1000.0]) {
        tester.view.physicalSize = Size(width, 900);
        final theme = AppPalette.lavender.theme;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(alwaysUse24HourFormat: true),
              child: child!,
            ),
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(
                fontFamily:
                    Platform.environment.containsKey('VOICECHAT_PREVIEW_FONT')
                    ? 'VoicePreview'
                    : null,
              ),
            ),
            home: RepaintBoundary(
              key: const ValueKey('preview'),
              child: Scaffold(
                body: Row(
                  children: [
                    if (width >= 840)
                      SizedBox(
                        width: 350,
                        child: ConversationList(
                          client: client,
                          selected: room,
                          groups: true,
                          onTabChanged: (_) {},
                          onSelect: (_) {},
                          onNewPerson: () {},
                          onNewGroup: () {},
                          onSettings: () {},
                        ),
                      ),
                    Expanded(
                      child: ChatPane(
                        room: room,
                        timeline: timeline,
                        actions: actions,
                        report: (_) {},
                        header: Container(
                          height: 96,
                          color: theme.colorScheme.tertiaryContainer,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.all(20),
                          child: const Text('Семья · голосовые сообщения'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        for (final time in find.textContaining('отправлено').evaluate()) {
          final finder = find.byElementPredicate((element) => element == time);
          final bubble = find
              .ancestor(
                of: finder,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.margin == const EdgeInsets.symmetric(vertical: 2),
                ),
              )
              .first;
          expect(
            tester.getRect(bubble).right - tester.getRect(finder).right,
            closeTo(12, .1),
          );
          expect(
            tester.getRect(bubble).bottom - tester.getRect(finder).bottom,
            greaterThanOrEqualTo(12),
          );
        }
        expect(tester.takeException(), isNull);
        for (final target
            in find.byTooltip('Действия с сообщением').evaluate()) {
          final menu = find.byElementPredicate((element) => element == target);
          final bubble = find
              .ancestor(
                of: menu,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.margin == const EdgeInsets.symmetric(vertical: 2),
                ),
              )
              .first;
          final rect = tester.getRect(menu);
          expect(rect.size, const Size(48, 48));
          expect(tester.getRect(bubble).contains(rect.topLeft), true);
          expect(
            tester
                .getRect(bubble)
                .contains(rect.bottomRight - const Offset(.1, .1)),
            true,
          );
        }
        await capture(tester, 'messages-${width.toInt()}');
      }
      tester.view.physicalSize = const Size(390, 900);
      final meter = PcmLevelMeter()
        ..add(
          pcmWindows(
            List.generate(
              56,
              (i) => [0, 512, 2048, 8192, 16384, 4096, 1024, 0][i % 8],
            ),
          ),
        );
      var stopped = false;
      final theme = AppPalette.lavender.theme;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(
              fontFamily:
                  Platform.environment.containsKey('VOICECHAT_PREVIEW_FONT')
                  ? 'VoicePreview'
                  : null,
            ),
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('preview'),
                child: RecordingWaveformPanel(
                  label: 'Запись 0:03 · осталось 2:57',
                  levels: List.of(meter.levels),
                  onCancel: () {},
                  onStop: () => stopped = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final live = tester.widget<WaveformView>(
        find.byWidgetPredicate((w) => w is WaveformView && w.recording),
      );
      expect(
        live.levels,
        containsAllInOrder([0, 16, 64, 256, 512, 128, 32, 0]),
      );
      expect(tester.takeException(), isNull);
      await capture(tester, 'recording-390');
      await tester.tap(find.byTooltip('Остановить запись'));
      expect(stopped, true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      actions.dispose();
    },
  );
}
