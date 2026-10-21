import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'voice_call.dart';
import 'avatar_editor.dart';
import 'history_search.dart';
import 'call_window.dart';
import 'app_sounds.dart';
import 'file_io.dart';
import 'conversation_list.dart';
import 'room_members_dialog.dart';
import 'welcome_panel.dart';
import 'call_controller.dart';
import 'chat_actions.dart';
import 'chat_pane.dart';
import 'people_picker.dart';
import 'registration_screen.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'matrix_probe.dart';
import 'local_store.dart';
import 'theme.dart';
import 'user_action_error.dart';
import 'transport.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await cleanupRecordings();
  runApp(const VoiceChatApp());
}

class VoiceChatApp extends StatefulWidget {
  const VoiceChatApp({super.key});
  @override
  State<VoiceChatApp> createState() => _VoiceChatAppState();
}

class _VoiceChatAppState extends State<VoiceChatApp> {
  AppPalette palette = AppPalette.lavender;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final name = prefs.getString('palette');
      if (mounted) {
        setState(
          () => palette = AppPalette.values.firstWhere(
            (p) => p.name == name,
            orElse: () => AppPalette.lavender,
          ),
        );
      }
    });
  }

  Future<void> setPalette(AppPalette next) async {
    setState(() => palette = next);
    await (await SharedPreferences.getInstance()).setString(
      'palette',
      next.name,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'VoiceChat',
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
    theme: palette.theme,
    home: ProbeScreen(palette: palette, onPalette: setPalette),
  );
}

class ProbeScreen extends StatefulWidget {
  final AppPalette palette;
  final ValueChanged<AppPalette> onPalette;
  const ProbeScreen({
    super.key,
    required this.palette,
    required this.onPalette,
  });
  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final server = TextEditingController(text: 'http://localhost:8008');
  final tokenServer = TextEditingController(text: 'http://localhost:8090');
  final mediaServer = TextEditingController(text: 'ws://localhost:7880');
  final username = TextEditingController(text: 'alice');
  final password = TextEditingController();
  final vaultPassword = TextEditingController();
  final profile = TextEditingController(text: 'device-1');
  MatrixProbe? probe;
  mx.Room? selected;
  mx.Timeline? timeline;
  StreamSubscription<dynamic>? sync;
  CallController? calls;
  AppSounds? sounds;
  Uri? ownAvatar;
  ChatActions? actions;
  StreamSubscription<mx.SyncStatusUpdate>? connectionStatus;
  bool online = true;
  bool restoringSession = true;
  bool savedAccount = false;
  bool groupsTab = false;
  bool rememberTab = true;

  @override
  void initState() {
    super.initState();
    unawaited(restoreSession());
  }

  Future<void> restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = readTabAccount() ?? prefs.getString('lastAccount');
      rememberTab = prefs.getBool('rememberTab') ?? true;
      if (stored == null) return;
      final data = jsonDecode(stored) as Map<String, dynamic>;
      if (data['rememberTab'] is bool) {
        rememberTab = data['rememberTab'] as bool;
      }
      for (final entry in {
        'profile': profile,
        'username': username,
        'server': server,
        'tokenServer': tokenServer,
        'mediaServer': mediaServer,
      }.entries) {
        final value = data[entry.key];
        if (value is! String || value.isEmpty || value.length > 2048) {
          throw const FormatException();
        }
        entry.value.text = value;
      }
      savedAccount = true;
      if (kIsWeb && rememberTab) {
        try {
          await login(resume: true);
        } catch (_) {
          status =
              'Введите локальную фразу, чтобы открыть сохранённую переписку.';
        }
      }
    } catch (_) {
      status = 'Откройте свой профиль. Локальные данные сохранены.';
    } finally {
      if (mounted) setState(() => restoringSession = false);
    }
  }

  Future<void> saveAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final account = jsonEncode({
      'profile': profile.text.trim(),
      'username': probe!.client.userID!,
      'server': server.text.trim(),
      'tokenServer': tokenServer.text.trim(),
      'mediaServer': mediaServer.text.trim(),
      'rememberTab': rememberTab,
    });
    writeTabAccount(account);
    await prefs.setString('lastAccount', account);
    await prefs.setBool('rememberTab', rememberTab);
    savedAccount = true;
  }

  VoiceCall? get call => calls?.active;
  bool busy = false;
  String status = 'Локальный стенд · тестовые данные';

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => status = e is UserActionError
              ? e.message
              : 'Не удалось выполнить действие: ${e.runtimeType}. Проверьте подключение и ключ.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void report(String value) {
    if (mounted) setState(() => status = value);
  }

  Future<void> login({bool resume = false}) async {
    final next = await MatrixProbe.open(
      profile.text.trim(),
      passphrase: kIsWeb && !resume ? vaultPassword.text : null,
      remember: kIsWeb && rememberTab,
    );
    try {
      if (!next.client.isLogged() && savedAccount) {
        savedAccount = false;
        throw UserActionError(
          'Серверная сессия завершена. Введите пароль аккаунта для нового входа.',
        );
      }
      await next.login(server.text.trim(), username.text.trim(), password.text);
    } catch (_) {
      await next.close();
      rethrow;
    }
    await connected(next);
  }

  Future<void> connected(MatrixProbe next) async {
    password.clear();
    vaultPassword.clear();
    probe = next;
    try {
      ownAvatar = (await next.client.fetchOwnProfile()).avatarUrl;
    } catch (_) {
      ownAvatar = null;
    }
    username.text = next.client.userID!;
    sounds = AppSounds(next.client);
    await sounds!.open();
    actions = ChatActions(
      next.client,
      policyUrl: tokenServer.text.trim(),
      onSent: sounds!.sent,
    );
    await actions!.open();
    calls = CallController(
      next.client,
      tokenServer.text.trim(),
      mediaServer.text.trim(),
      report,
    );
    calls!.addListener(() {
      if (mounted) {
        setState(() {});
        sounds?.updateCall(calls!);
        maybeShowCall();
      }
    });
    sync = next.client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
    connectionStatus = next.client.onSyncStatus.stream.listen((value) {
      if (mounted) setState(() => online = value.status != mx.SyncStatus.error);
    });
    await saveAccount();
    final roomId = (await SharedPreferences.getInstance()).getString(
      'lastRoom:${profile.text.trim()}',
    );
    final room = next.client.getRoomById(roomId ?? '');
    if (room?.membership == mx.Membership.join) await select(room!);
    report('Локальный стенд · сквозное шифрование');
  }

  Future<void> registration({bool reset = false}) async {
    final next = await MatrixProbe.open(
      profile.text.trim(),
      passphrase: kIsWeb ? vaultPassword.text : null,
      remember: kIsWeb && rememberTab,
    );
    var adopted = false;
    try {
      if (next.client.isLogged()) {
        throw UserActionError(
          'Этот локальный профиль уже связан с аккаунтом. Используйте другое имя профиля для регистрации.',
        );
      }
      await next.client.checkHomeserver(
        secureEndpoint(server.text.trim()),
        checkWellKnown: false,
      );
      if (!mounted) return;
      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              RegistrationScreen(client: next.client, resetPassword: reset),
        ),
      );
      if (completed == true && !reset) {
        await connected(next);
        adopted = true;
      }
      if (completed == true && reset) {
        report('Пароль изменён. Войдите снова и восстановите историю ключом.');
      }
    } finally {
      if (!adopted) await next.close();
    }
  }

  Future<String?> askText(String title, {String initial = ''}) async {
    final input = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: input, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    input.dispose();
    return value;
  }

  Future<void> newChat({bool group = false}) async {
    final people = await showDialog<List<String>>(
      context: context,
      builder: (_) => PeoplePicker(
        client: probe!.client,
        multiple: group,
        title: group ? 'Новая группа' : 'Найти человека',
      ),
    );
    if (people == null || people.isEmpty) return;
    String id;
    if (group) {
      final name = await askText('Название группы');
      if (name == null || name.isEmpty) return;
      id = await probe!.createRoom(people, name: name);
    } else {
      id = await probe!.startDirectChat(people.single);
    }
    await select(await probe!.room(id));
  }

  Future<void> invitations() async {
    final rooms = probe!.client.rooms
        .where((r) => r.membership == mx.Membership.invite)
        .toList();
    final result = await showDialog<(mx.Room, bool)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Приглашения · ${rooms.length}'),
        content: SizedBox(
          width: 480,
          height: 350,
          child: rooms.isEmpty
              ? const Center(child: Text('Пока нет приглашений'))
              : ListView.separated(
                  itemCount: rooms.length,
                  separatorBuilder: (_, _) => const Divider(height: 20),
                  itemBuilder: (_, i) {
                    final room = rooms[i];
                    final inviter = room
                        .getState(
                          mx.EventTypes.RoomMember,
                          probe!.client.userID!,
                        )
                        ?.senderId;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PersonAvatar(
                            name: room.getLocalizedDisplayname(),
                            group: !room.isDirectChat,
                          ),
                          title: Text(
                            room.getLocalizedDisplayname(),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'Пригласил: ${inviter ?? 'неизвестно'}',
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.tonal(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, (room, true)),
                              child: const Text('Принять'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, (room, false)),
                              child: const Text('Отклонить'),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await run(() async {
      if (result.$2) {
        await select(result.$1);
      } else {
        await result.$1.leave();
        report('Приглашение отклонено.');
      }
    });
  }

  Future<void> roomSettings() async {
    final room = selected!;
    final members = await room.requestParticipants();
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (_) => RoomMembersDialog(room: room, members: members),
    );
    if (action == 'invite' && mounted) {
      final users = await showDialog<List<String>>(
        context: context,
        builder: (_) => PeoplePicker(client: room.client, multiple: true),
      );
      for (final user in users ?? <String>[]) {
        await room.invite(user);
      }
    } else if (action == 'avatar') {
      if (!room.canChangeStateEvent(mx.EventTypes.RoomAvatar)) {
        throw UserActionError('Недостаточно прав для изменения аватара.');
      }
      if (!mounted) return;
      final file = await editAvatar(context);
      if (file != null) await room.setAvatar(file);
    } else if (action == 'rename') {
      final name = await askText(
        'Название',
        initial: room.getLocalizedDisplayname(),
      );
      if (name != null && name.isNotEmpty) await room.setName(name);
    } else if (action == 'leave' || action?.startsWith('kick:') == true) {
      final confirmed = await askText(
        action == 'leave'
            ? 'Введите ДА, чтобы покинуть чат'
            : 'Введите ДА, чтобы исключить участника',
      );
      if (confirmed != 'ДА') return;
      await calls?.end();
      if (action == 'leave') {
        await room.leave();
        timeline?.cancelSubscriptions();
        if (mounted) {
          setState(() {
            selected = null;
            timeline = null;
          });
        }
      } else {
        await room.kick(action!.substring(5));
      }
    }
  }

  String? focusedEvent;
  Future<void> globalSearch() async {
    final result = await searchHistory(context, probe!.client);
    if (result != null) {
      await run(() => select(result.room, eventId: result.event));
    }
  }

  Future<void> select(mx.Room room, {String? eventId}) async {
    focusedEvent = eventId;
    if (room.membership == mx.Membership.invite) await room.join();
    selected = await probe!.room(room.id);
    groupsTab = !selected!.isDirectChat;
    timeline?.cancelSubscriptions();
    timeline = await selected!.getTimeline(
      eventContextId: eventId,
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
    await (await SharedPreferences.getInstance()).setString(
      'lastRoom:${profile.text.trim()}',
      room.id,
    );
    report('Локальный стенд · сквозное шифрование');
  }

  Future<void> setupRecovery() async {
    final secret = await askPassword();
    if (secret == null) return;
    final key = await probe!.initializeRecovery(secret);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сохраните ключ восстановления'),
        content: SelectableText(
          'Сохраните отдельно от этого устройства. Не отправляйте в чат.\n\n$key',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Я сохранил ключ'),
          ),
        ],
      ),
    );
    report('Ключи созданы. Резервную копию можно обновить после переписки.');
  }

  Future<void> restore() async {
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вернуть историю'),
        content: TextField(
          controller: input,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Ваш ключ восстановления',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value == null) return;
    await probe!.restore(value);
    report('Ключи восстановлены. Откройте чат для загрузки истории.');
  }

  Future<void> startCall() async {
    if (selected == null) return;
    await calls!.start(selected!);
  }

  Future<void> audioOutput() async {
    if (!kIsWeb) {
      await lk.AudioManager.instance.setSpeakerOutputPreferred(
        !lk.AudioManager.instance.isSpeakerOutputPreferred,
      );
      report(
        'Переключён динамик/обычный аудиомаршрут. Гарнитурой управляет система.',
      );
      return;
    }
    report(
      'В браузере аудиовыход выбирается в настройках браузера или операционной системы.',
    );
  }

  Future<String?> askPassword() async {
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Подтвердите паролем аккаунта'),
        content: TextField(
          controller: input,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Пароль'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    input.clear();
    input.dispose();
    return value;
  }

  Future<void> lock() async {
    probe!.client.httpClient
        .close(); // Abort network operations before closing local keys.
    try {
      await Future.wait([
        if (calls != null) calls!.close(),
        if (sounds != null) sounds!.close(),
        if (actions != null) actions!.close(),
      ]);
    } finally {
      await connectionStatus?.cancel();
      await sync?.cancel();
      timeline?.cancelSubscriptions();
      try {
        await probe!.close();
      } finally {
        if (mounted) {
          setState(() {
            probe = null;
            selected = null;
            timeline = null;
            calls = null;
            actions = null;
          });
        }
      }
    }
    report('Хранилище заблокировано. Для открытия введите локальную фразу.');
  }

  Future<void> verifyDevices() async {
    final client = probe!.client;
    final users = selected == null
        ? <String>{client.userID!}
        : (await client.getJoinedMembersByRoom(selected!.id))!.keys.toSet();
    await refreshDevices(client, users);
    final devices = users
        .expand((user) => client.userDeviceKeys[user]!.deviceKeys.values)
        .toList();
    if (!mounted) return;
    final chosen = await showDialog<mx.DeviceKeys>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Проверка личности устройств'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  'Это устройство: ${client.userID} / ${client.deviceID}\nВаш отпечаток:\n${client.fingerprintKey}',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Сверьте отпечаток лично или по независимому доверенному каналу. Для устройств собеседника сначала откройте его чат. Проверка взаимная: повторите её на втором устройстве.',
                ),
                ...devices.map(
                  (device) => ListTile(
                    title: Text('${device.userId} / ${device.deviceId}'),
                    subtitle: Text(
                      device.directVerified
                          ? 'Проверено на этом устройстве'
                          : 'Не проверено',
                    ),
                    trailing: Icon(
                      device.directVerified
                          ? Icons.verified_user
                          : Icons.help_outline,
                    ),
                    onTap: device.blocked
                        ? null
                        : () => Navigator.pop(context, device),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final input = TextEditingController();
    final fingerprint = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Введите отпечаток со второго устройства'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${chosen.userId} / ${chosen.deviceId}'),
            TextField(
              controller: input,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Полный отпечаток Ed25519',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Сверить'),
          ),
        ],
      ),
    );
    input.dispose();
    if (fingerprint == null) return;
    await verifyDevice(client, chosen.userId, chosen.deviceId!, fingerprint);
    report('Отпечаток совпал. Устройство проверено локально.');
  }

  Future<void> devices() async {
    final items = await probe!.client.getDevices();
    if (!mounted) return;
    final device = await showDialog<mx.Device>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Устройства аккаунта'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Text(
                'Отзыв завершает сеанс. Уже полученные сообщения и скопированные ключи удалить удалённо нельзя.',
              ),
              ...?items?.map(
                (device) => ListTile(
                  title: Text(device.displayName ?? device.deviceId),
                  subtitle: Text(
                    device.deviceId == probe!.client.deviceID
                        ? 'Это устройство'
                        : device.deviceId,
                  ),
                  trailing: device.deviceId == probe!.client.deviceID
                      ? null
                      : IconButton(
                          tooltip: 'Отозвать доступ',
                          icon: const Icon(Icons.no_accounts_outlined),
                          onPressed: () => Navigator.pop(context, device),
                        ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (device == null) return;
    final secret = await askPassword();
    if (secret == null) return;
    await call?.close();
    await probe!.revokeDevice(device.deviceId, secret);
    report(
      'Доступ устройства отозван. Старую скопированную историю это не удаляет.',
    );
  }

  Future<void> logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти и удалить локальные ключи?'),
        content: const Text(
          'Для возвращения истории потребуется ключ восстановления или другое устройство. Убедитесь, что сохранили ключ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await calls?.end();
    if (actions!.pending.isNotEmpty) {
      throw UserActionError(
        'В очереди есть неотправленные сообщения. Отправьте или отмените их перед выходом.',
      );
    }
    await probe!.backup();
    await probe!.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastAccount');
    await prefs.remove('lastRoom:${profile.text.trim()}');
    writeTabAccount(null);
    savedAccount = false;
    await calls?.close();
    await sounds?.close();
    await actions?.close();
    await connectionStatus?.cancel();
    await sync?.cancel();
    timeline?.cancelSubscriptions();
    if (!mounted) return;
    setState(() {
      probe = null;
      selected = null;
      timeline = null;
      calls = null;
      actions = null;
    });
    report('Вы вышли из аккаунта');
  }

  @override
  void dispose() {
    unawaited(sync?.cancel());
    timeline?.cancelSubscriptions();
    unawaited(calls?.close());
    unawaited(sounds?.close());
    unawaited(actions?.close());
    unawaited(connectionStatus?.cancel());
    unawaited(probe?.close());
    for (final c in [
      server,
      tokenServer,
      mediaServer,
      username,
      password,
      profile,
      vaultPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(TextEditingController c, String label, {bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: secret,
          autocorrect: !secret,
          enableSuggestions: !secret,
          decoration: InputDecoration(labelText: label),
        ),
      );
  Widget paletteMenu() => PopupMenuButton<AppPalette>(
    tooltip: 'Цветовая схема',
    initialValue: widget.palette,
    onSelected: widget.onPalette,
    icon: const Icon(Icons.palette_outlined),
    itemBuilder: (_) => AppPalette.values
        .map((p) => PopupMenuItem(value: p, child: Text(p.label)))
        .toList(),
  );

  Widget connection() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  savedAccount ? 'С возвращением' : 'Добро пожаловать',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.8,
                  ),
                ),
              ),
              paletteMenu(),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            savedAccount
                ? username.text
                : 'Войдите, чтобы быть на связи с близкими.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          if (!savedAccount) ...[
            field(username, 'Имя пользователя'),
            field(password, 'Пароль аккаунта', secret: true),
          ],
          if (kIsWeb)
            field(
              vaultPassword,
              'Отдельная локальная фраза (от 12 символов)',
              secret: true,
            ),
          if (kIsWeb)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                savedAccount
                    ? 'Это фраза, которую вы придумали при первом входе. Пароль аккаунта повторно не нужен.'
                    : 'Придумайте отдельную фразу для защиты переписки в браузере. Для этого профиля её потребуется помнить.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (kIsWeb)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: rememberTab,
              onChanged: (value) => setState(() => rememberTab = value!),
              title: const Text('Сохранять вход в этой вкладке'),
              subtitle: const Text(
                'Обновление страницы без повторного пароля. «Заблокировать» завершит разблокировку.',
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : () => run(login),
            icon: Icon(
              savedAccount
                  ? Icons.lock_open_rounded
                  : Icons.arrow_forward_rounded,
            ),
            label: Text(savedAccount ? 'Открыть переписку' : 'Войти'),
          ),
          const SizedBox(height: 12),
          if (savedAccount)
            TextButton(
              onPressed: () => setState(() => savedAccount = false),
              child: const Text('Другой аккаунт или профиль'),
            )
          else ...[
            OutlinedButton(
              onPressed: busy ? null : () => run(() => registration()),
              child: const Text('Создать аккаунт'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => run(() => registration(reset: true)),
              child: const Text('Забыли пароль?'),
            ),
          ],
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Параметры подключения'),
            children: [
              field(profile, 'Профиль устройства'),
              field(server, 'Matrix URL'),
              field(tokenServer, 'Token API URL'),
              field(mediaServer, 'LiveKit URL'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Локальная версия · проверка безопасности ещё не завершена',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> settings() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Настройки'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: PersonAvatar(
                    name: username.text.replaceFirst('@', ''),
                    client: probe!.client,
                    url: ownAvatar,
                  ),
                  title: Text(probe!.client.userID!),
                  subtitle: Text('Устройство: ${probe!.client.deviceID}'),
                ),
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: const Text('Изменить аватар'),
                  onTap: () => Navigator.pop(dialogContext, 'avatar'),
                ),
                const Divider(height: 28),
                Row(
                  children: [
                    const Expanded(child: Text('Цветовая схема')),
                    paletteMenu(),
                  ],
                ),
                ListTile(
                  leading: Icon(
                    sounds?.enabled == true
                        ? Icons.volume_up_outlined
                        : Icons.volume_off_outlined,
                  ),
                  title: Text(
                    sounds?.enabled == true
                        ? 'Звуки включены'
                        : 'Звуки выключены',
                  ),
                  subtitle: Text(
                    sounds?.blocked == true
                        ? 'Браузер заблокировал звук. Разрешите воспроизведение для сайта.'
                        : 'Сообщения и входящие / исходящие вызовы',
                  ),
                  onTap: () => Navigator.pop(dialogContext, 'sounds'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Устройства и безопасность',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: const Text('Устройства'),
                  subtitle: const Text('Сеансы и отзыв доступа'),
                  onTap: () => Navigator.pop(dialogContext, 'devices'),
                ),
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Проверить устройства'),
                  subtitle: const Text('Сверка отпечатков для выбранного чата'),
                  onTap: () => Navigator.pop(dialogContext, 'verify'),
                ),
                const Divider(height: 24),
                Text(
                  'Доступ к истории',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('Создать ключ'),
                  onTap: () => Navigator.pop(dialogContext, 'recovery'),
                ),
                ListTile(
                  leading: const Icon(Icons.restore_rounded),
                  title: const Text('Восстановить'),
                  onTap: () => Navigator.pop(dialogContext, 'restore'),
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('Обновить backup'),
                  onTap: () => Navigator.pop(dialogContext, 'backup'),
                ),
                const Divider(height: 24),
                if (kIsWeb)
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Заблокировать'),
                    subtitle: const Text(
                      'Закрыть локальные ключи в этой вкладке',
                    ),
                    onTap: () => Navigator.pop(dialogContext, 'lock'),
                  ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded),
                  title: const Text('Выйти'),
                  subtitle: const Text(
                    'Завершить сеанс и удалить локальные ключи',
                  ),
                  onTap: () => Navigator.pop(dialogContext, 'logout'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await run(() async {
      switch (chosen) {
        case 'sounds':
          await sounds!.setEnabled(!sounds!.enabled);
          sounds!.updateCall(calls!);
        case 'avatar':
          final file = await editAvatar(context);
          if (file != null) {
            final url = await probe!.client.uploadContent(
              file.bytes,
              filename: file.name,
              contentType: file.mimeType,
            );
            await probe!.client.setProfileField(
              probe!.client.userID!,
              'avatar_url',
              {'avatar_url': url.toString()},
            );
            ownAvatar = url;
          }
        case 'devices':
          await devices();
        case 'verify':
          await verifyDevices();
        case 'recovery':
          await setupRecovery();
        case 'restore':
          await restore();
        case 'backup':
          await probe!.backup();
          report('Резервная копия ключей обновлена.');
        case 'lock':
          await lock();
        case 'logout':
          await logout();
      }
    });
  }

  Widget rooms() => ConversationList(
    client: probe!.client,
    selected: selected,
    onSelect: (room) => run(() => select(room)),
    onNewPerson: () => run(() => newChat()),
    onNewGroup: () => run(() => newChat(group: true)),
    onSettings: settings,
    onInvitations: invitations,
    onSearch: globalSearch,
    ownAvatar: ownAvatar,
    groups: groupsTab,
    onTabChanged: (value) => setState(() => groupsTab = value),
  );
  Widget conversation() {
    final room = selected;
    if (room == null || timeline == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(36),
                ),
                child: Icon(
                  Icons.forum_outlined,
                  size: 54,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Ваши люди — рядом',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Выберите разговор слева или найдите близкого человека.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => run(() => newChat()),
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('Начать разговор'),
              ),
            ],
          ),
        ),
      );
    }
    return ChatPane(
      key: ValueKey('${room.id}:$focusedEvent'),
      room: room,
      timeline: timeline!,
      actions: actions!,
      report: report,
      initialEventId: focusedEvent,
      onJump: (event) => run(() => select(room, eventId: event)),
      header: Container(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Закрыть чат',
              onPressed: () => setState(() => selected = null),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            PersonAvatar(
              name: room.getLocalizedDisplayname(),
              client: room.client,
              url: roomAvatar(room),
              group: !room.isDirectChat,
              size: 42,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.getLocalizedDisplayname(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    roomPresence(room),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Участники и настройки чата',
              onPressed: busy ? null : () => run(roomSettings),
              icon: const Icon(Icons.more_horiz_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Голосовой звонок',
              onPressed: busy || (call != null && !call!.isClosed)
                  ? null
                  : () => run(startCall),
              icon: const Icon(Icons.call_outlined),
            ),
          ],
        ),
      ),
    );
  }

  bool callWindowOpen = false;
  String? presentedCall;
  void maybeShowCall() {
    if (calls == null || callWindowOpen || !mounted) return;
    final controller = calls!;
    final id = controller.active?.isClosed == false
        ? controller.active!.session
        : controller.starting || controller.dialError != null
        ? controller.dialingRoom?.id
        : controller.directInvitations.firstOrNull?.session ??
              controller.invitations.keys.firstOrNull;
    if (id == null) {
      presentedCall = null;
      return;
    }
    if (presentedCall == id) return;
    presentedCall = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && calls == controller) showCallWindow();
    });
  }

  Future<void> showCallWindow() async {
    if (callWindowOpen || calls == null) return;
    callWindowOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CallWindow(calls: calls!, audioOutput: audioOutput),
      );
    } finally {
      callWindowOpen = false;
    }
  }

  Widget callBanner() {
    final available =
        calls != null &&
        (calls!.starting ||
            calls!.dialError != null ||
            calls!.active?.isClosed == false ||
            calls!.directInvitations.isNotEmpty ||
            calls!.invitations.isNotEmpty);
    return SizedBox(
      height: 36,
      child: available
          ? TextButton.icon(
              onPressed: showCallWindow,
              icon: const Icon(Icons.call),
              label: const Text('Открыть окно звонка'),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 840;
            return Padding(
              padding: EdgeInsets.all(wide ? 24 : 0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1480),
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(wide ? 30 : 0),
                      border: wide
                          ? Border.all(
                              color: colors.outlineVariant.withValues(
                                alpha: .5,
                              ),
                            )
                          : null,
                      boxShadow: wide
                          ? [
                              BoxShadow(
                                color: colors.primary.withValues(alpha: .06),
                                blurRadius: 35,
                                offset: const Offset(0, 14),
                              ),
                            ]
                          : null,
                    ),
                    child: Material(
                      color: colors.surface,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 2,
                            child: busy || restoringSession
                                ? const LinearProgressIndicator(minHeight: 2)
                                : null,
                          ),
                          if (probe != null) callBanner(),
                          if (probe != null && !online)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              color: colors.secondaryContainer,
                              child: const Text(
                                'Нет связи · сообщения сохраняются в зашифрованной очереди',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          Expanded(
                            child: AbsorbPointer(
                              absorbing: busy,
                              child: restoringSession
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : AnimatedSwitcher(
                                      duration:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? Duration.zero
                                          : const Duration(milliseconds: 240),
                                      child: probe == null
                                          ? (wide
                                                ? Row(
                                                    key: const ValueKey(
                                                      'welcome-wide',
                                                    ),
                                                    children: [
                                                      const Expanded(
                                                        child: WelcomePanel(),
                                                      ),
                                                      Expanded(
                                                        child: Center(
                                                          child: ConstrainedBox(
                                                            constraints:
                                                                const BoxConstraints(
                                                                  maxWidth: 500,
                                                                ),
                                                            child: connection(),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : SingleChildScrollView(
                                                    key: const ValueKey(
                                                      'welcome-small',
                                                    ),
                                                    child: Column(
                                                      children: [
                                                        const SizedBox(
                                                          width:
                                                              double.infinity,
                                                          child: WelcomePanel(
                                                            compact: true,
                                                          ),
                                                        ),
                                                        connection(),
                                                      ],
                                                    ),
                                                  ))
                                          : wide
                                          ? Row(
                                              key: const ValueKey(
                                                'messenger-wide',
                                              ),
                                              children: [
                                                SizedBox(
                                                  width: 350,
                                                  child: rooms(),
                                                ),
                                                VerticalDivider(
                                                  width: 1,
                                                  color: colors.outlineVariant
                                                      .withValues(alpha: .5),
                                                ),
                                                Expanded(child: conversation()),
                                              ],
                                            )
                                          : selected == null
                                          ? KeyedSubtree(
                                              key: const ValueKey('contacts'),
                                              child: rooms(),
                                            )
                                          : KeyedSubtree(
                                              key: const ValueKey(
                                                'conversation',
                                              ),
                                              child: conversation(),
                                            ),
                                    ),
                            ),
                          ),
                          Container(
                            width: double.infinity,
                            height: 48,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: colors.outlineVariant.withValues(
                                    alpha: .4,
                                  ),
                                ),
                              ),
                            ),
                            child: Text(
                              status,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
