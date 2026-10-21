import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'voice_call.dart';
import 'call_controller.dart';
import 'chat_actions.dart';
import 'chat_pane.dart';
import 'people_picker.dart';
import 'registration_screen.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'matrix_probe.dart';
import 'theme.dart';
import 'user_action_error.dart';
import 'transport.dart';

void main() => runApp(const VoiceChatApp());

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
  ChatActions? actions;
  StreamSubscription<mx.SyncStatusUpdate>? connectionStatus;
  bool online = true;
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

  Future<void> login() async {
    final next = await MatrixProbe.open(
      profile.text.trim(),
      passphrase: kIsWeb ? vaultPassword.text : null,
    );
    try {
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
    username.text = next.client.userID!;
    actions = ChatActions(next.client);
    await actions!.open();
    calls = CallController(
      next.client,
      tokenServer.text.trim(),
      mediaServer.text.trim(),
      report,
    );
    calls!.addListener(() {
      if (mounted) setState(() {});
    });
    sync = next.client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
    connectionStatus = next.client.onSyncStatus.stream.listen((value) {
      if (mounted) setState(() => online = value.status != mx.SyncStatus.error);
    });
    report(
      'Подключено. Создайте или восстановите ключ восстановления в настройках.',
    );
  }

  Future<void> registration({bool reset = false}) async {
    final next = await MatrixProbe.open(
      profile.text.trim(),
      passphrase: kIsWeb ? vaultPassword.text : null,
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
      builder: (_) => PeoplePicker(client: probe!.client, multiple: group),
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

  Future<void> roomSettings() async {
    final room = selected!;
    final members = await room.requestParticipants();
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(room.getLocalizedDisplayname()),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Участники и приглашения'),
                ...members
                    .where(
                      (u) =>
                          u.membership == mx.Membership.join ||
                          u.membership == mx.Membership.invite,
                    )
                    .map(
                      (user) => ListTile(
                        title: Text(user.displayName ?? user.id),
                        subtitle: Text('${user.id} · ${user.membership}'),
                        trailing: room.canKick && user.id != room.client.userID
                            ? IconButton(
                                tooltip: 'Исключить участника',
                                onPressed: () =>
                                    Navigator.pop(context, 'kick:${user.id}'),
                                icon: const Icon(Icons.person_remove_outlined),
                              )
                            : null,
                      ),
                    ),
                if (room.canInvite)
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, 'invite'),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Пригласить'),
                  ),
                if (room.canChangeStateEvent(mx.EventTypes.RoomName))
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'rename'),
                    child: const Text('Изменить название'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'leave'),
                  child: const Text('Покинуть чат'),
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
    if (action == 'invite' && mounted) {
      final users = await showDialog<List<String>>(
        context: context,
        builder: (_) => PeoplePicker(client: room.client, multiple: true),
      );
      for (final user in users ?? <String>[]) {
        await room.invite(user);
      }
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

  Future<void> select(mx.Room room) async {
    if (room.membership == mx.Membership.invite) await room.join();
    selected = await probe!.room(room.id);
    timeline?.cancelSubscriptions();
    timeline = await selected!.getTimeline(
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
    report('Комната со сквозным шифрованием');
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
    await calls?.close();
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
          decoration: InputDecoration(labelText: label),
        ),
      );
  Widget action(
    String label,
    Future<void> Function() fn, {
    IconData icon = Icons.arrow_forward_rounded,
  }) => FilledButton.tonalIcon(
    onPressed: busy ? null : () => run(fn),
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
  Widget connection() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Хороший день для разговора',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      const Text(
        'Проверяем защищённую связь. Этот прототип ещё не предназначен для личных переписок.',
      ),
      const SizedBox(height: 24),
      field(username, 'Имя пользователя'),
      field(password, 'Пароль аккаунта', secret: true),
      field(profile, 'Профиль устройства'),
      if (kIsWeb)
        field(
          vaultPassword,
          'Отдельная локальная фраза (от 12 символов)',
          secret: true,
        ),
      if (kIsWeb)
        const Text(
          'Первый вход в этот профиль: придумайте свою отдельную фразу и сохраните её. Повторный вход: введите ту же фразу. Для alice/bob/carol готовой локальной фразы нет. Она защищает данные браузера и не отправляется на сервер.',
        ),
      ExpansionTile(
        title: const Text('Подключение к стенду'),
        children: [
          field(server, 'Matrix URL'),
          field(tokenServer, 'Token API URL'),
          field(mediaServer, 'LiveKit URL'),
        ],
      ),
      const SizedBox(height: 20),
      action('Войти', login, icon: Icons.login_rounded),
      const SizedBox(height: 8),
      action(
        'Создать аккаунт',
        () => registration(),
        icon: Icons.person_add_outlined,
      ),
      TextButton(
        onPressed: busy ? null : () => run(() => registration(reset: true)),
        child: const Text('Забыли пароль?'),
      ),
    ],
  );
  Widget rooms() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Ваши разговоры', style: Theme.of(context).textTheme.titleLarge),
      SelectableText(
        probe!.client.userID!,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      ...probe!.client.rooms
          .where(
            (r) =>
                r.membership == mx.Membership.join ||
                r.membership == mx.Membership.invite,
          )
          .map(
            (r) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Icon(
                    r.membership == mx.Membership.invite
                        ? Icons.mail_outline
                        : Icons.forum_outlined,
                  ),
                ),
                title: Text(r.getLocalizedDisplayname()),
                subtitle: Text(
                  r.membership == mx.Membership.invite
                      ? 'Приглашение · нажмите, чтобы войти'
                      : 'Зашифрованная комната',
                ),
                selected: r.id == selected?.id,
                trailing: r.notificationCount > 0
                    ? Badge(
                        label: Text('${r.notificationCount}'),
                        child: const Icon(Icons.mark_chat_unread_outlined),
                      )
                    : null,
                onTap: busy ? null : () => run(() => select(r)),
              ),
            ),
          ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          action(
            'Найти человека',
            () => newChat(),
            icon: Icons.person_search_outlined,
          ),
          action(
            'Создать группу',
            () => newChat(group: true),
            icon: Icons.group_add_outlined,
          ),
        ],
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 8,
        children: [
          action('Устройства', devices, icon: Icons.devices),
          action(
            'Проверить устройства',
            verifyDevices,
            icon: Icons.verified_user_outlined,
          ),
          if (kIsWeb) action('Заблокировать', lock, icon: Icons.lock_outline),
          action('Выйти', logout, icon: Icons.logout),
        ],
      ),
      const SizedBox(height: 16),
      Text('Доступ к истории', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          action('Создать ключ', setupRecovery, icon: Icons.key),
          action('Восстановить', restore, icon: Icons.restore),
          action('Обновить backup', () async {
            await probe!.backup();
            report('Загрузка ключей в резервную копию завершена');
          }, icon: Icons.cloud_upload_outlined),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        'Устройство: ${probe!.client.deviceID}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
  Widget conversation() {
    final room = selected;
    if (room == null || timeline == null) {
      return const Center(
        child: Text('Найдите собеседника или выберите разговор'),
      );
    }
    return ChatPane(
      key: ValueKey(room.id),
      room: room,
      timeline: timeline!,
      actions: actions!,
      report: report,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                room.getLocalizedDisplayname(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Проверить устройства',
              onPressed: busy ? null : () => run(verifyDevices),
              icon: const Icon(Icons.verified_user_outlined),
            ),
            IconButton(
              tooltip: 'Участники и настройки чата',
              onPressed: busy ? null : () => run(roomSettings),
              icon: const Icon(Icons.group_outlined),
            ),
            IconButton(
              tooltip: 'Голосовой звонок',
              onPressed: busy || (call != null && !call!.isClosed)
                  ? null
                  : () => run(startCall),
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'Закрыть чат',
              onPressed: () => setState(() {
                selected = null;
              }),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget callBanner() {
    final current = call;
    if (current != null && !current.isClosed) {
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(
          title: Text(
            '${current.chat.getLocalizedDisplayname()} · ${current.connection}',
          ),
          subtitle: Text(
            'Участники: ${current.participants.map((p) => p.split('/').first).join(', ')}',
          ),
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: current.muted
                    ? 'Включить микрофон'
                    : 'Выключить микрофон',
                onPressed: () => run(() => current.mute(!current.muted)),
                icon: Icon(current.muted ? Icons.mic_off : Icons.mic),
              ),
              IconButton(
                tooltip: 'Аудиовыход',
                onPressed: () => run(audioOutput),
                icon: const Icon(Icons.speaker),
              ),
              IconButton(
                tooltip: 'Завершить звонок',
                onPressed: () => run(calls!.end),
                icon: const Icon(Icons.call_end, color: Colors.red),
              ),
            ],
          ),
        ),
      );
    }
    if (calls?.directInvitations.isNotEmpty ?? false) {
      final incoming = calls!.directInvitations.first;
      return Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(
          title: Text(
            'Личный звонок · ${incoming.chat.getLocalizedDisplayname()}',
          ),
          subtitle: const Text('Защищённый WebRTC'),
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: 'Отклонить',
                onPressed: busy
                    ? null
                    : () => run(() => calls!.declineDirect(incoming)),
                icon: const Icon(Icons.call_end, color: Colors.red),
              ),
              IconButton(
                tooltip: 'Принять',
                onPressed: busy
                    ? null
                    : () => run(() => calls!.acceptDirect(incoming)),
                icon: const Icon(Icons.call, color: Colors.green),
              ),
            ],
          ),
        ),
      );
    }
    if (calls?.invitations.isEmpty ?? true) return const SizedBox.shrink();
    final invitation = calls!.invitations.values.first;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        title: Text(
          'Входящий звонок · ${invitation.room.getLocalizedDisplayname()}',
        ),
        subtitle: Text(invitation.sender),
        trailing: Wrap(
          children: [
            IconButton(
              tooltip: 'Отклонить',
              onPressed: busy
                  ? null
                  : () => run(() => calls!.decline(invitation)),
              icon: const Icon(Icons.call_end, color: Colors.red),
            ),
            IconButton(
              tooltip: 'Принять',
              onPressed: busy
                  ? null
                  : () => run(
                      () =>
                          calls!.start(invitation.room, invitation: invitation),
                    ),
              icon: const Icon(Icons.call, color: Colors.green),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              color: colors.primary,
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    color: colors.onPrimary,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'VoiceChat',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: colors.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  PopupMenuButton<AppPalette>(
                    tooltip: 'Цветовая схема',
                    initialValue: widget.palette,
                    onSelected: widget.onPalette,
                    icon: Icon(Icons.palette_outlined, color: colors.onPrimary),
                    itemBuilder: (_) => AppPalette.values
                        .map(
                          (p) => PopupMenuItem(value: p, child: Text(p.label)),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (probe != null) callBanner(),
            if (probe != null && !online)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Нет связи · сообщения сохраняются в зашифрованной очереди',
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(status, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
              child: AbsorbPointer(
                absorbing: busy,
                child: LayoutBuilder(
                  builder: (context, box) {
                    if (probe == null) {
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: connection(),
                        ),
                      );
                    }
                    if (box.maxWidth < 800) {
                      return selected == null ? rooms() : conversation();
                    }
                    return Row(
                      children: [
                        SizedBox(width: 350, child: rooms()),
                        const VerticalDivider(width: 1),
                        Expanded(child: conversation()),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
