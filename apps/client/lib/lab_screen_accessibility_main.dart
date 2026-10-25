import 'app_motion.dart';
// Local accessibility fixture. Real production widgets, synthetic call state, no media/network.
// Never publish this entrypoint as the application.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'call_controller.dart';
import 'call_quality.dart';
import 'call_window.dart';
import 'direct_call.dart';
import 'screen_api.dart';
import 'screen_controller.dart';
import 'screen_quality.dart';
import 'screen_state.dart';
import 'theme.dart';
import 'voice_call.dart';

class PreviewDatabase implements mx.DatabaseApi {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PreviewRoom extends mx.Room {
  PreviewRoom(mx.Client client) : super(id: '!a11y:fixture', client: client);
  @override
  Future<List<mx.User>> requestParticipants([
    List<mx.Membership> membershipFilter = const [mx.Membership.join],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async => [];
}

class PreviewCall implements VoiceCall {
  @override
  final mx.Room chat;
  PreviewCall(this.chat);
  @override
  String get session => 'a11y-fixture';
  @override
  String get connection => 'Проверочный звонок без медиапотоков';
  @override
  bool get video => false;
  @override
  bool cameraEnabled = false, muted = false, isClosed = false;
  @override
  VideoQuality videoQuality = VideoQuality.auto;
  @override
  CallQuality get quality => CallQuality.good;
  @override
  List<String> get participants => [];
  @override
  Duration get duration => const Duration(seconds: 42);
  @override
  Future<void> camera(bool enabled) async => cameraEnabled = enabled;
  @override
  Future<void> mute(bool value) async => muted = value;
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setVideoQuality(VideoQuality value) async =>
      videoQuality = value;
  @override
  Future<void> close() async => isClosed = true;
}

class PreviewScreen extends ScreenShareController {
  PreviewScreen(VoiceCall call)
    : super(call, ScreenApi('http://localhost', () => ''), 'ws://localhost');
  @override
  String get identity => '@viewer:fixture/V';
  void scenario(String name) {
    final owner = name == 'Ведущий' ? identity : '@speaker:fixture/S';
    snapshot = ScreenSnapshot.parse({
      'protocol_version': 1,
      'binding_id': '22222222-2222-4222-8222-222222222222',
      'state': 'active',
      'revision': 1,
      'roster_version': 1,
      'owner_identity': owner,
      'generation': 'screen-${'b' * 48}',
      'roster': [
        {
          'identity': owner,
          'curve': base64Encode(List.filled(32, 12)).replaceAll('=', ''),
          'ed': base64Encode(List.filled(32, 13)).replaceAll('=', ''),
        },
      ],
    });
    phase = name == 'Восстановление'
        ? ScreenPhase.reconnecting
        : ScreenPhase.viewing;
    notice = name == 'Отказ'
        ? 'Показ не начат. Проверьте разрешение на захват экрана.'
        : null;
    notifyListeners();
  }

  @override
  Future<void> share() async {
    notice = 'Показ не начат. Проверьте разрешение на захват экрана.';
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    notice = 'Показ остановлен.';
    notifyListeners();
  }

  @override
  Future<void> setQuality(ScreenQuality value) async {
    quality = value;
    notifyListeners();
  }
}

class PreviewCalls extends ChangeNotifier implements CallController {
  @override
  final mx.Client client;
  @override
  VoiceCall? active;
  @override
  ScreenShareController? screen;
  PreviewCalls(this.client) {
    active = PreviewCall(PreviewRoom(client));
    screen = PreviewScreen(active!);
  }
  @override
  bool get starting => false;
  @override
  String? get dialError => null;
  @override
  mx.Room? get dialingRoom => null;
  @override
  List<DirectCall> get directInvitations => [];
  @override
  Map<String, CallInvitation> get invitations => {};
  @override
  Future<void> end() async {
    await active?.close();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  runApp(const Preview());
}

class Preview extends StatefulWidget {
  const Preview({super.key});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  AppPalette palette = AppPalette.lavender;
  String scenario = 'Зритель';
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: palette.theme,
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Проверка доступности screen share')),
        body: Column(
          children: [
            const Text('Тестовые состояния. Медиа и сеть не используются.'),
            DropdownButton<String>(
              value: scenario,
              items: [
                for (final name in [
                  'Зритель',
                  'Ведущий',
                  'Отказ',
                  'Восстановление',
                ])
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: (value) => setState(() => scenario = value!),
            ),
            DropdownButton<AppPalette>(
              value: palette,
              items: [
                for (final p in AppPalette.values)
                  DropdownMenuItem(value: p, child: Text(p.label)),
              ],
              onChanged: (value) => setState(() => palette = value!),
            ),
            FilledButton(
              onPressed: () async {
                final calls = PreviewCalls(
                  mx.Client('a11y-preview', database: PreviewDatabase()),
                );
                final screen = calls.screen! as PreviewScreen;
                screen.scenario(scenario);
                await showAppDialog<void>(
                  context: context,
                  builder: (_) =>
                      CallWindow(calls: calls, audioOutput: () async {}),
                );
                await screen.close();
                screen.dispose();
                calls.dispose();
                await calls.client.dispose();
              },
              child: const Text('Открыть проверочный звонок'),
            ),
          ],
        ),
      ),
    ),
  );
}
