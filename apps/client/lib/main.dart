import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'call_probe.dart';
import 'matrix_probe.dart';
import 'theme.dart';
import 'user_action_error.dart';

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
    title: 'VoiceChat · прототип',
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
  final invites = TextEditingController(
    text: '@bob:voicechat.local, @carol:voicechat.local',
  );
  final message = TextEditingController();
  final session = TextEditingController(text: 'lab-1');
  MatrixProbe? probe;
  mx.Room? selected;
  mx.Timeline? timeline;
  StreamSubscription<dynamic>? sync;
  CallProbe? call;
  bool busy = false;
  String status = 'Тестовый стенд · только одноразовые аккаунты';

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
    password.clear();
    vaultPassword.clear();
    probe = next;
    sync = next.client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
    report('Подключено. Настройте или восстановите ключи перед общением.');
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
    if ((call != null && !call!.isClosed) || selected == null) return;
    final next = CallProbe(
      chat: selected!,
      session: session.text.trim(),
      tokenUrl: tokenServer.text.trim(),
      livekitUrl: mediaServer.text.trim(),
      status: report,
    );
    await next.connect();
    setState(() => call = next);
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
    await call?.close();
    await sync?.cancel();
    timeline?.cancelSubscriptions();
    await probe!.close();
    if (!mounted) return;
    setState(() {
      probe = null;
      selected = null;
      timeline = null;
      call = null;
    });
    message.clear();
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
    await call?.close();
    await probe!.logout();
    await sync?.cancel();
    timeline?.cancelSubscriptions();
    if (!mounted) return;
    setState(() {
      probe = null;
      selected = null;
      timeline = null;
      call = null;
    });
    report('Вы вышли из аккаунта');
  }

  @override
  void dispose() {
    unawaited(sync?.cancel());
    timeline?.cancelSubscriptions();
    unawaited(call?.close());
    unawaited(probe?.close());
    for (final c in [
      server,
      tokenServer,
      mediaServer,
      username,
      password,
      profile,
      vaultPassword,
      invites,
      message,
      session,
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
      field(password, 'Пароль тестового аккаунта', secret: true),
      field(profile, 'Профиль устройства'),
      if (kIsWeb)
        field(
          vaultPassword,
          'Отдельная локальная фраза (от 12 символов)',
          secret: true,
        ),
      if (kIsWeb)
        const Text(
          'Эта фраза открывает хранилище в данном браузере. Она не отправляется на сервер. При её потере понадобится восстановление истории.',
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
    ],
  );
  Widget rooms() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Ваши разговоры', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      ...probe!.client.rooms.map(
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
            onTap: busy ? null : () => run(() => select(r)),
          ),
        ),
      ),
      const SizedBox(height: 16),
      field(invites, 'Кого пригласить (Matrix ID через запятую)'),
      action('Создать круг', () async {
        final id = await probe!.createRoom(
          invites.text
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        );
        await select(await probe!.room(id));
      }, icon: Icons.add_rounded),
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
    final colors = Theme.of(context).colorScheme;
    if (selected == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56),
            SizedBox(height: 20),
            Text('Начните с тёплого круга'),
            SizedBox(height: 8),
            Text('Выберите или создайте зашифрованную комнату'),
          ],
        ),
      );
    }
    final events =
        timeline?.events
            .where(
              (e) =>
                  e.type == mx.EventTypes.Message ||
                  e.type == mx.EventTypes.Encrypted,
            )
            .toList() ??
        [];
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selected!.getLocalizedDisplayname(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть чат',
                    onPressed: call == null || call!.isClosed
                        ? () => setState(() {
                            selected = null;
                          })
                        : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: session,
                      decoration: const InputDecoration(
                        labelText: 'Сеанс звонка',
                      ),
                    ),
                  ),
                  (call == null || call!.isClosed)
                      ? action(
                          'Позвонить',
                          startCall,
                          icon: Icons.call_outlined,
                        )
                      : action('Завершить', () async {
                          await call!.close();
                          setState(() => call = null);
                          report('Звонок завершён');
                        }, icon: Icons.call_end),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(20),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final event = events[i];
              final own = event.senderId == probe!.client.userID;
              return Align(
                alignment: own ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: own ? colors.primary : colors.surfaceContainerLowest,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(22),
                      topRight: const Radius.circular(22),
                      bottomLeft: Radius.circular(own ? 22 : 6),
                      bottomRight: Radius.circular(own ? 6 : 22),
                    ),
                  ),
                  child: Text(
                    event.type == mx.EventTypes.Encrypted
                        ? 'Нет ключа для этого сообщения'
                        : event.body,
                    style: TextStyle(
                      color: own ? colors.onPrimary : colors.onSurface,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: message,
                  decoration: const InputDecoration(hintText: 'Написать…'),
                  minLines: 1,
                  maxLines: 4,
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filled(
                tooltip: 'Отправить',
                onPressed: busy
                    ? null
                    : () => run(() async {
                        if (message.text.trim().isEmpty) return;
                        await MatrixProbe.sendText(
                          selected!,
                          message.text.trim(),
                        );
                        message.clear();
                      }),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ),
      ],
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(status, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
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
          ],
        ),
      ),
    );
  }
}
