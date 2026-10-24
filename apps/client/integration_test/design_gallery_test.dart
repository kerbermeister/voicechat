import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart' as app;
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/first_keys.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:voicechat_probe/lab_messaging.dart' show testVoice;

// Uses disposable local accounts only. Never opens a real camera or microphone.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Mobile screen inventory for the design comparison', (
    tester,
  ) async {
    const username = String.fromEnvironment('UI_USERNAME');
    const password = String.fromEnvironment('UI_PASSWORD');
    const phrase = 'Design gallery local vault phrase';
    const onlyScreens = String.fromEnvironment('UI_SCREENS');
    expect(username.startsWith('ui_'), true);
    expect(password.isNotEmpty, true);
    final prefs = await SharedPreferences.getInstance();
    final oldAccount = prefs.getString('lastAccount');
    final oldPalette = prefs.getString('palette');
    final oldRemember = prefs.getBool('rememberTab');
    await prefs.remove('lastAccount');
    await prefs.setString('palette', 'lavender');
    addTearDown(() async {
      if (oldRemember == null) {
        await prefs.remove('rememberTab');
      } else {
        await prefs.setBool('rememberTab', oldRemember);
      }
      if (oldAccount == null) {
        await prefs.remove('lastAccount');
      } else {
        await prefs.setString('lastAccount', oldAccount);
      }
      if (oldPalette == null) {
        await prefs.remove('palette');
      } else {
        await prefs.setString('palette', oldPalette);
      }
    });

    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 600 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      if (finder.evaluate().isEmpty) {
        debugPrint('GALLERY missing: ${finder.toString()}');
        debugPrint(
          tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join(' | '),
        );
        await binding.takeScreenshot('error-state');
      }
      expect(finder, findsWidgets);
    }

    void dismissNotice() {
      final messenger = find.byType(ScaffoldMessenger);
      if (messenger.evaluate().isNotEmpty) {
        tester
            .state<ScaffoldMessengerState>(messenger.first)
            .removeCurrentSnackBar();
      }
    }

    Future<void> tap(Finder finder) async {
      dismissNotice();
      await tester.pump();
      final tools = find.byTooltip('Дополнительные действия');
      if (finder.evaluate().isEmpty && tools.evaluate().isNotEmpty) {
        await tester.tap(tools);
        await tester.pump(const Duration(milliseconds: 300));
      }
      await waitFor(finder);
      for (
        var i = 0;
        i < 600 &&
            find
                .ancestor(
                  of: finder.first,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is AbsorbPointer && widget.absorbing,
                  ),
                )
                .evaluate()
                .isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await tester.ensureVisible(finder.first);
      await tester.tap(finder.first);
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> hideKeyboard() async {
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await tester.pump(const Duration(milliseconds: 400));
    }

    var nativeSurface = false;
    Future<void> shot(String name) async {
      dismissNotice();
      final dialogScreens = {
        '06',
        '07',
        '08',
        '09',
        '10',
        '11',
        '12',
        '13',
        '14',
        '15',
        '17',
        '19',
        '20',
        '23',
        '24',
        '25',
        '26',
      };
      if (dialogScreens.contains(name.substring(0, 2))) {
        await waitFor(find.byType(AlertDialog));
      }
      if (name == '27-calendar') await waitFor(find.byType(DatePickerDialog));
      await hideKeyboard();
      if (!kIsWeb && !nativeSurface) {
        await binding.convertFlutterSurfaceToImage();
        nativeSurface = true;
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: name);
      if (onlyScreens.isNotEmpty && !onlyScreens.split(',').contains(name)) {
        return;
      }
      var done = false;
      final capture = binding
          .takeScreenshot(name)
          .whenComplete(() => done = true);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(done, true, reason: 'Screenshot timed out: $name');
      await capture;
      debugPrint('GALLERY: $name');
    }

    await app.main();
    await waitFor(find.text('Добро пожаловать'));
    await shot('01-welcome');
    for (final reset in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppPalette.lavender.theme,
          home: RegistrationScreen(openClient: (_) async => _FormClient(), resetPassword: reset),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await shot(reset ? '03-reset-password' : '02-registration');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await app.main();
    await waitFor(find.text('Добро пожаловать'));
    await tap(find.text('Параметры подключения'));
    await shot('04-connection');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final profile = 'design-${DateTime.now().microsecondsSinceEpoch}';
    final probe = await tester.runAsync(() async {
      final p = await MatrixProbe.open(
        profile,
        passphrase: kIsWeb ? phrase : null,
      );
      await p.login('http://localhost:8008', username, password);
      enableFirstContactTrust(p.client);
      await p.client.setProfileField(p.client.userID!, 'displayname', {
        'displayname': 'Антон',
      });
      await p.room(await p.createRoom([], name: 'Семья'));
      await prefs.setBool('rememberTab', false);
      await prefs.setString(
        'lastAccount',
        jsonEncode({
          'profile': profile,
          'username': p.client.userID,
          'server': 'http://localhost:8008',
          'tokenServer': 'http://localhost:8090',
          'mediaServer': 'ws://localhost:7880',
        }),
      );
      await p.close();
      return p;
    });
    expect(probe, isNotNull);
    await app.main();
    await waitFor(find.text('Открыть переписку'));
    if (kIsWeb) {
      tester
              .widget<TextField>(
                find.widgetWithText(
                  TextField,
                  'Отдельная локальная фраза (от 12 символов)',
                ),
              )
              .controller!
              .text =
          phrase;
      await tester.pump();
    }
    await tap(find.text('Открыть переписку'));
    await waitFor(find.text('Найти человека'));
    for (
      var i = 0;
      i < 600 &&
          tester
              .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
              .any((widget) => widget.absorbing);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    // Send through the client currently shown by the app, without reopening its vault.
    final liveClient = tester
        .widget<ConversationList>(find.byType(ConversationList))
        .client;
    await tester.runAsync(() async {
      final room = liveClient.rooms.singleWhere(
        (room) => roomDisplayName(room) == 'Семья',
      );
      final actions = ChatActions(liveClient);
      await actions.open();
      await actions.text(room, 'В воскресенье собираемся у нас?');
      await actions.attachment(
        room,
        mx.MatrixAudioFile(
          bytes: testVoice,
          name: 'voice.wav',
          mimeType: 'audio/wav',
          duration: 18000,
        ),
        waveform: [
          80,
          220,
          700,
          420,
          900,
          180,
          620,
          330,
          820,
          500,
          100,
          700,
          400,
          900,
        ],
      );
      await actions.text(room, 'Конечно! Давайте в пять. Я привезу десерт ❤️');
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (actions.pending.isNotEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(actions.pending, isEmpty);
      await actions.close();
    });
    await tester.pump();
    await shot('05-people');
    await tap(find.text('Найти человека'));
    await shot('06-find-person');
    await tap(find.text('Отмена'));
    await tap(find.byTooltip('Приглашения'));
    await shot('07-invitations');
    await tap(find.text('Закрыть'));
    await tap(find.byTooltip('Поиск по чатам и сообщениям'));
    await shot('08-history-search');
    await tap(find.text('Закрыть'));
    await tap(find.byType(PersonAvatar).first);
    await waitFor(find.text('Мой профиль'));
    await shot('09-profile');
    await tap(find.text('Закрыть'));

    Future<void> settingsItem(String text, String screenshot) async {
      await tap(find.byTooltip('Настройки'));
      await tap(find.text(text));
      await shot(screenshot);
      await tap(find.text('Закрыть').last);
    }

    await tap(find.byTooltip('Настройки'));
    await shot('10-settings');
    await tester.ensureVisible(find.text('Выйти'));
    await shot('11-settings-security');
    await tap(find.text('Закрыть'));
    await settingsItem('Локальное хранилище', '12-storage');
    await settingsItem('Устройства', '13-devices');
    await settingsItem('Проверить устройства', '14-verification');
    await settingsItem('Запросы истории', '15-history-requests');
    await tap(find.text('Группы'));
    await shot('16-groups');
    await tap(find.text('Создать группу'));
    await shot('17-new-group');
    await tap(find.text('Отмена'));
    await tap(find.text('Семья').first);
    await waitFor(find.byTooltip('Отправить'));
    await shot('18-chat');
    await tap(find.byTooltip('Участники и настройки чата'));
    await shot('19-members');
    await tap(find.textContaining('Приглашены ·'));
    await shot('20-members-invited');
    await tap(find.text('Закрыть').last);
    await tap(find.byTooltip('Действия с сообщением').first);
    await shot('21-message-menu');
    await tap(find.text('Ответить'));
    await shot('22-reply');
    await tap(find.byTooltip('Отменить'));
    await tap(find.byTooltip('Эмодзи'));
    await shot('23-emoji');
    await tap(find.text('Закрыть'));
    await tap(find.byTooltip('Временное сообщение'));
    await shot('24-temporary');
    await tap(find.text('Без таймера'));
    await tap(find.byTooltip('Отложенные сообщения'));
    await tap(find.text('Запланированные сообщения'));
    await shot('25-scheduled');
    await tap(find.text('Закрыть'));
    await tap(find.byTooltip('Отложенные сообщения'));
    await tap(find.text('Выбрать время отправки'));
    await shot('26-schedule-time');
    await tap(find.text('Отмена'));
    await tap(find.byTooltip('Перейти к дате'));
    await shot('27-calendar');
    await tap(find.text('Отмена'));
    final tools = find.byTooltip('Дополнительные действия');
    if (tools.evaluate().isNotEmpty &&
        find.byTooltip('Эмодзи').evaluate().isEmpty) {
      await tap(tools);
    }
    await shot('28-composer-tools');
    await tap(find.byTooltip('Прикрепить файл или видео'));
    await shot('29-attachment-menu');
    await tester.tapAt(const Offset(5, 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tap(find.byTooltip('Действия с сообщением').first);
    await tap(find.text('Редактировать'));
    await shot('30-edit-message');
    await tap(find.byTooltip('Отменить'));
    await tap(find.byTooltip('Действия с сообщением').first);
    await tap(find.text('Удалить'));
    await waitFor(find.text('Удалить сообщение у всех?'));
    await shot('31-delete-confirmation');
    await tap(find.text('Отмена'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Call window visual fixtures without camera or microphone', (
    tester,
  ) async {
    final client = _GalleryClient();
    final room = _GalleryCallRoom(client);
    var nativeConverted = false;
    final calls = CallController(
      client,
      'http://localhost:8090',
      'ws://localhost:7880',
      (_) {},
    );
    for (final state in ['incoming', 'voice', 'video', 'error']) {
      calls.active = null;
      calls.invitations.clear();
      calls.dialError = null;
      if (state == 'incoming') {
        calls.invitations['visual-fixture'] = CallInvitation(
          room,
          'visual-fixture',
          '@mama:local',
          DateTime.now(),
        );
      } else if (state == 'error') {
        calls.dialingRoom = room;
        calls.dialError = 'Не удалось подключиться. Проверьте соединение.';
      } else {
        calls.active = _GalleryCall(room, video: state == 'video');
      }
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppPalette.lavender.theme,
          home: Scaffold(
            body: CallWindow(calls: calls, audioOutput: () async {}),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      if (!kIsWeb && !nativeConverted) {
        await binding.convertFlutterSurfaceToImage();
        nativeConverted = true;
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      var done = false;
      final capture = binding
          .takeScreenshot('32-call-$state-fixture')
          .whenComplete(() => done = true);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await capture;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    calls.active = null;
    await tester.runAsync(calls.close);
    await client.dispose();
  });
}

// Rendering empty forms does not need a database or a server connection.
class _FormClient implements mx.Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GalleryDatabase implements mx.MatrixSdkDatabase {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GalleryCallRoom extends mx.Room {
  @override
  bool get isDirectChat => true;
  @override
  String get directChatMatrixID => '@mama:local';
  _GalleryCallRoom(mx.Client client)
    : super(id: '!visual-call:local', client: client) {
    states[mx.EventTypes.RoomName] = {
      '': mx.StrippedStateEvent(
        type: mx.EventTypes.RoomName,
        stateKey: '',
        senderId: '@mama:local',
        content: {'name': 'Мама'},
      ),
    };
  }
  @override
  Future<List<mx.User>> requestParticipants([
    List<mx.Membership> membershipFilter = const [
      mx.Membership.join,
      mx.Membership.invite,
      mx.Membership.knock,
    ],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async => [];
}

class _GallerySession implements mx.CallSession {
  @override
  mx.CallState get state => mx.CallState.kConnected;
  @override
  String get remoteUserId => '@mama:local';
  @override
  mx.WrappedMediaStream? get remoteUserMediaStream => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Visual fixtures only: no connection, capture, encryption or media is claimed.
class _GalleryCall implements DirectCall {
  @override
  final mx.Room chat;
  @override
  final bool video;
  _GalleryCall(this.chat, {required this.video});
  @override
  final call = _GallerySession();
  @override
  String get session => 'visual-fixture';
  @override
  String get connection => 'Разговор';
  @override
  bool cameraEnabled = false, muted = false, isClosed = false;
  @override
  rtc.RTCVideoRenderer? get localVideo => null;
  @override
  rtc.RTCVideoRenderer? get remoteVideo => null;
  @override
  VideoQuality videoQuality = VideoQuality.auto;
  @override
  CallQuality get quality => CallQuality.good;
  @override
  List<String> get participants => ['@me:local', '@mama:local'];
  @override
  Duration get duration => const Duration(seconds: 42);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GalleryClient extends mx.Client {
  _GalleryClient() : super('design-calls', database: _GalleryDatabase());
  @override
  String get userID => '@me:local';
}
