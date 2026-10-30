import 'resizable_chat_layout.dart';
import 'chat_scale.dart';
import 'message_media_cache.dart';
import 'transient_notice.dart';
import 'active_call_banner.dart';
import 'personal_room.dart';
import 'p2p/service.dart';
import 'p2p/panel.dart';
import 'recovery_key_dialog.dart';
import 'macos_camera.dart';
import 'macos_notifications.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'device_name.dart';
import 'scheduled_view.dart' show scheduledTime;
import 'device_added.dart';
import 'conversation_header.dart';
import 'app_motion.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_update.dart' show updateOrigin;
import 'route_transport.dart';
import 'route_coordinator.dart';
import 'connection_diagnostics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'identity_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'voice_call.dart';
import 'avatar_editor.dart';
import 'history_search.dart';
import 'call_window.dart';
import 'app_sounds.dart';
import 'browser_audio.dart';
import 'push_notifications.dart';
import 'call_probe.dart';
import 'file_io.dart';
import 'presence_tracker.dart';
import 'recording_activity.dart';
import 'active_capture.dart';
import 'app_update_dialog.dart';
import 'update_safety.dart';
import 'first_keys.dart';
import 'history_window.dart';
import 'contact_service.dart';
import 'contact_link.dart';
import 'contact_link_dialog.dart';
import 'invitations_dialog.dart';
import 'storage_policy.dart';
import 'storage_dialog.dart';
import 'profile_dialog.dart';
import 'conversation_list.dart';
import 'room_members_dialog.dart';
import 'auth_layout.dart';
import 'call_controller.dart';
import 'chat_actions.dart';
import 'chat_pane.dart';
import 'people_picker.dart';
import 'registration_screen.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'matrix_probe.dart';
import 'route_status_banner.dart';
import 'local_store.dart';
import 'theme.dart';
import 'user_action_error.dart';
import 'transport.dart';
import 'device_verification.dart';
import 'device_link.dart';
import 'dart:math';
import 'device_verification_dialog.dart';
import 'history_recovery.dart';
import 'history_recovery_dialog.dart';
import 'package:matrix/encryption.dart' as crypto;

mx.CachedPresence? _roomPresenceSnapshot(mx.Room room) =>
    // ignore: deprecated_member_use
    room.client.presences[room.directChatMatrixID];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    CameraPlatform.instance = MacOSCamera();
  }
  await cleanupRecordings();
  runApp(const VoiceChatApp());
}

String newDeviceProfile() => List.generate(
  24,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class VoiceChatApp extends StatefulWidget {
  const VoiceChatApp({super.key});
  @override
  State<VoiceChatApp> createState() => _VoiceChatAppState();
}

class _VoiceChatAppState extends State<VoiceChatApp>
    with WidgetsBindingObserver {
  AppPalette palette = AppPalette.halo;
  final chatScale = ChatScale();
  String? invitation = kIsWeb && Uri.base.fragment.startsWith('/contact/')
      ? Uri.base.toString()
      : null;
  int invitationRevision = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((prefs) {
      final name = prefs.getString('palette');
      if (mounted) chatScale.load(prefs);
      if (mounted) {
        setState(
          () => palette = AppPalette.values.firstWhere(
            (p) => p.name == name,
            orElse: () => AppPalette.halo,
          ),
        );
      }
    });
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation information) async {
    // Hash navigation back to the app must not open a second copy of its local vault.
    if (kIsWeb && information.uri.path == '/') return true;
    if (!kIsWeb || !information.uri.path.startsWith('/contact/')) return false;
    setState(() {
      invitation = Uri.base
          .replace(fragment: information.uri.toString())
          .toString();
      invitationRevision++;
    });
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatScale.dispose();
    super.dispose();
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
    initialRoute: '/',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: ChatScaleScope(scale: chatScale, child: child!),
    ),
    theme: palette.theme,
    themeAnimationDuration: appMotionDuration,
    themeAnimationCurve: Curves.easeOutCubic,
    home: ProbeScreen(
      palette: palette,
      onPalette: setPalette,
      invitation: invitation,
      invitationRevision: invitationRevision,
    ),
  );
}

class ProbeScreen extends StatefulWidget {
  final String? invitation;
  final int invitationRevision;
  final AppPalette palette;
  final ValueChanged<AppPalette> onPalette;
  const ProbeScreen({
    super.key,
    required this.palette,
    required this.onPalette,
    this.invitation,
    this.invitationRevision = 0,
  });
  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final server = TextEditingController(
    text: const String.fromEnvironment(
      'MATRIX_URL',
      defaultValue: 'http://localhost:8008',
    ),
  );
  final tokenServer = TextEditingController(
    text: const String.fromEnvironment(
      'TOKEN_URL',
      defaultValue: 'http://localhost:8090',
    ),
  );
  final mediaServer = TextEditingController(
    text: const String.fromEnvironment(
      'LIVEKIT_URL',
      defaultValue: 'ws://localhost:7880',
    ),
  );
  final username = TextEditingController();
  final password = TextEditingController();
  final profile = TextEditingController(text: newDeviceProfile());
  MatrixProbe? probe;
  mx.Room? selected;
  mx.Timeline? timeline;
  StreamSubscription<dynamic>? sync;
  CallController? calls;
  AppSounds? sounds;
  MacOSNotifications? desktopNotifications;
  Uri? ownAvatar;
  PresenceTracker? presenceTracker;
  RecordingActivity? recordingActivity;
  ContactService? contacts;
  P2pService? p2p;
  StoragePolicy? storagePolicy;
  ChatActions? actions;
  DeviceVerifications? verifications;
  HistoryRecovery? historyRecovery;
  StreamSubscription<mx.SyncStatusUpdate>? connectionStatus;
  bool online = true;
  bool restoringSession = true;
  bool savedAccount = false;
  bool linked = false;
  bool groupsTab = false;
  String? incomingContactLink;
  bool contactLinkOpen = false;
  bool autoOpenContactLink = false;

  ContactLinks get contactLinks => ContactLinks(
    probe!,
    contacts!,
    kIsWeb ? Uri.base : Uri.parse(server.text.trim()),
  );

  http.Client _pushClient() {
    final network = probe!.client.httpClient;
    return network is RouteTransport ? network.fork() : http.Client();
  }

  @override
  void initState() {
    super.initState();
    incomingContactLink = widget.invitation;
    autoOpenContactLink = incomingContactLink != null;
    unawaited(restoreSession());
  }

  @override
  void didUpdateWidget(covariant ProbeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.invitation != oldWidget.invitation ||
        widget.invitationRevision != oldWidget.invitationRevision) {
      incomingContactLink = widget.invitation;
      autoOpenContactLink = incomingContactLink != null;
    }
  }

  Future<void> restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = readTabAccount() ?? prefs.getString('lastAccount');
      if (stored == null) return;
      final data = jsonDecode(stored) as Map<String, dynamic>;
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
      try {
        await login(resume: true);
      } catch (_) {
        status = 'Не удалось открыть сохранённый вход. Попробуйте снова.';
      }
    } catch (_) {
      status = 'Откройте свой аккаунт. Локальные данные сохранены.';
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
    });
    writeTabAccount(account);
    await prefs.setString('lastAccount', account);
    savedAccount = true;
  }

  VoiceCall? get call => calls?.active;
  bool busy = false;
  String status = '';

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      report(
        e is UserActionError
            ? e.message
            : 'Не удалось выполнить действие: ${e.runtimeType}. Проверьте подключение и ключ.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void report(String value) {
    if (!mounted) return;
    if (probe == null) {
      setState(() => status = value);
    } else if (value ==
            'Не удалось получить превью. Ссылку можно отправить без него.' ||
        value == 'Превью временно недоступно.') {
      showTransientNotice(context, value);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(value), duration: const Duration(seconds: 8)),
        );
    }
  }

  Future<void> login({bool resume = false}) async {
    if (!savedAccount) profile.text = newDeviceProfile();
    final accountPassword = password.text;
    final next = await MatrixProbe.open(profile.text.trim(), automatic: true);
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
    if (!linked && mounted) await linkDevice(accountPassword);
  }

  Future<void> connected(MatrixProbe next) async {
    password.clear();
    probe = next;
    linked = await deviceLinked(next.client);
    await refreshCurrentDeviceName(next.client);
    enableFirstContactTrust(next.client);
    historyRecovery = HistoryRecovery(next.client, () {
      if (mounted) {
        report(
          'Получен запрос ключей. Откройте «Настройки → Запросы истории».',
        );
      }
    });
    verifications = DeviceVerifications(next.client, () {
      if (!mounted) return;
      final owner = verifications;
      if (owner != null && owner.pending.isNotEmpty && owner.viewing == null) {
        unawaited(
          showDeviceVerification(
            context,
            owner,
            owner.pending.first,
            call: call,
          ),
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Получен запрос проверки устройства'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () {
              final owner = verifications;
              if (owner != null && owner.pending.isNotEmpty) {
                unawaited(
                  showDeviceVerification(
                    context,
                    owner,
                    owner.pending.first,
                    call: call,
                  ),
                );
              }
            },
          ),
        ),
      );
    });
    try {
      ownAvatar = (await next.client.fetchOwnProfile()).avatarUrl;
    } catch (_) {
      ownAvatar = null;
    }
    username.text = next.client.userID!;
    contacts = ContactService(next.client, tokenServer.text.trim());
    contacts!.addListener(() {
      if (mounted) setState(() {});
    });
    await contacts!.open();
    storagePolicy = StoragePolicy(next.client, () => selected?.id);
    await storagePolicy!.open();
    presenceTracker = PresenceTracker(next.client, () {
      if (mounted) setState(() {});
    });
    presenceTracker!.start();
    recordingActivity = RecordingActivity(next.client, () {
      if (mounted) setState(() {});
    })..start();
    if (MacOSNotifications.supported) {
      desktopNotifications = MacOSNotifications(next.client.userID!, (
        id,
      ) async {
        final room = next.client.getRoomById(id);
        if (mounted &&
            identical(probe, next) &&
            room?.membership == mx.Membership.join) {
          await select(room!);
        }
      });
      await desktopNotifications!.open();
    }
    sounds = AppSounds(next.client, onReceived: desktopNotifications?.message);
    await sounds!.open();
    actions = ChatActions(
      next.client,
      policyUrl: tokenServer.text.trim(),
      onSent: sounds!.sent,
      onDeleted: sounds!.deleted,
    );
    await actions!.open();
    await openP2p(next.client);
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
        desktopNotifications?.updateCalls(calls!);
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
    final pendingInvite = await contactLinks.pending();
    if (pendingInvite != null && incomingContactLink == null) {
      incomingContactLink = contactLinkUrl(
        contactLinks.origin,
        pendingInvite,
      ).toString();
      autoOpenContactLink = true;
    }
  }

  Future<void> registration({bool reset = false}) async {
    MatrixProbe? next;
    Future<mx.Client>? preparing;
    var adopted = false;
    String? registrationPassword;
    profile.text = newDeviceProfile();
    try {
      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => RegistrationScreen(
            resetPassword: reset,
            requireLocalPassphrase: false,
            onRegistered: (value) => registrationPassword = value,
            openClient: (passphrase) => preparing = () async {
              final opened = await MatrixProbe.open(
                profile.text.trim(),
                automatic: true,
              );
              try {
                if (opened.client.isLogged()) {
                  throw UserActionError(
                    'Не удалось создать новое хранилище. Повторите регистрацию.',
                  );
                }
                await opened.client.checkHomeserver(
                  secureEndpoint(server.text.trim()),
                  checkWellKnown: false,
                );
              } catch (_) {
                await opened.close();
                rethrow;
              }
              next = opened;
              return opened.client;
            }(),
          ),
        ),
      );
      if (completed == true && !reset && next != null) {
        await connected(next!);
        adopted = true;
        if (mounted) {
          await showAppDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              scrollable: true,
              title: const AppDialogTitle(
                child: Text('Добро пожаловать в VoiceChat!'),
              ),
              content: const Text(
                'Почта подтверждена, аккаунт создан, и вы уже вошли. Теперь сохраните ключ восстановления, чтобы не потерять доступ к переписке.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Продолжить'),
                ),
              ],
            ),
          );
        }
        if (mounted) await linkDevice(registrationPassword);
      }
      if (completed == true && reset) {
        report('Пароль изменён. Войдите снова и восстановите историю ключом.');
      }
    } finally {
      // Navigation can finish while the store is still opening.
      try {
        await preparing;
      } catch (_) {
        // The registration screen reports the opening error.
      }
      if (!adopted) await next?.close();
    }
  }

  Future<String?> askText(String title, {String initial = ''}) async {
    final input = TextEditingController(text: initial);
    final value = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => AlertDialog(
        title: AppDialogTitle(child: Text(title, textAlign: TextAlign.center)),
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
    if (group) {
      final draft = await showAppDialog<GroupDraft>(
        context: context,
        builder: (_) => PeoplePicker.group(
          client: probe!.client,
          allowedUsers: contacts!.acceptedUsers,
        ),
      );
      if (draft == null) return;
      final avatar = draft.avatar;
      final url = avatar == null
          ? null
          : await probe!.client.uploadContent(
              avatar.bytes,
              filename: avatar.name,
              contentType: avatar.mimeType,
            );
      final id = await probe!.createRoom(
        draft.users,
        name: draft.name,
        personal: draft.personal,
        avatar: url,
      );
      await select(await probe!.room(id));
      return;
    }
    final people = await showAppDialog<List<String>>(
      context: context,
      builder: (_) =>
          PeoplePicker(client: probe!.client, title: 'Найти человека'),
    );
    if (people == null || people.isEmpty) return;
    await connectContact(people.single);
  }

  Future<void> connectContact(String user) async {
    await contacts!.refresh();
    if (!contacts!.available) {
      throw UserActionError('Для нового контакта требуется связь с сервером.');
    }
    final existing = contacts!.requests
        .where((r) => r.peer(probe!.client.userID!) == user)
        .firstOrNull;
    if (existing != null) {
      if (existing.state == 'pending') {
        report('Запрос ожидает подтверждения. Его статус — в приглашениях.');
        return;
      }
      if (existing.state == 'declined') {
        report('Запрос отклонён.');
        return;
      }
      final room = probe!.client.getRoomById(existing.roomId);
      if (room?.membership == mx.Membership.join) {
        await select(room!);
        return;
      }
    }
    final id = await probe!.startDirectChat(user);
    final request = await contacts!.request(user, id);
    if (request.state == 'accepted') {
      await select(await probe!.room(request.roomId));
    } else {
      report(
        'Приглашение отправлено. После подтверждения собеседник появится в «Люди».',
      );
    }
  }

  Future<void> profileCard(String user) async {
    await presenceTracker?.refresh(user);
    if (!mounted) return;
    final result = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (_) => ProfileDialog(
        client: probe!.client,
        contacts: contacts!,
        userId: user,
        ownAvatar: ownAvatar,
      ),
    );
    if (result == 'contact') await connectContact(user);
    if (result == 'create-link') await contactLink(create: true);
    if (result == 'avatar') {
      await changeAvatar();
      if (mounted) await profileCard(user);
    }
  }

  Future<void> changeAvatar() async {
    final file = await editAvatar(context);
    if (file == null) return;
    final url = await probe!.client.uploadContent(
      file.bytes,
      filename: file.name,
      contentType: file.mimeType,
    );
    await probe!.client.setProfileField(probe!.client.userID!, 'avatar_url', {
      'avatar_url': url.toString(),
    });
    if (mounted) setState(() => ownAvatar = url);
  }

  Future<void> invitations() async {
    final service = contacts;
    if (service == null) return;
    await service.refresh();
    if (!mounted) return;
    final result = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (_) => InvitationsDialog(contacts: service),
    );
    if (result == 'create-link') await contactLink(create: true);
    if (result == 'accept-link') await contactLink();
    if (mounted) setState(() {});
  }

  void maybeOpenContactLink() {
    if (!autoOpenContactLink || contactLinkOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !autoOpenContactLink ||
          contactLinkOpen ||
          incomingContactLink == null ||
          restoringSession ||
          busy ||
          probe == null ||
          contacts == null ||
          !linked ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      autoOpenContactLink = false;
      unawaited(run(() => contactLink()));
    });
  }

  Future<void> contactLink({bool create = false}) async {
    if (contactLinkOpen) return;
    contactLinkOpen = true;
    final invitation = incomingContactLink;
    try {
      final room = await showAppDialog<mx.Room>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ContactLinkDialog(
          links: contactLinks,
          create: create,
          initialLink: create ? null : invitation,
        ),
      );
      if (room != null && mounted) {
        if (incomingContactLink == invitation) {
          setState(() => incomingContactLink = null);
        }
        await select(room);
      } else if (mounted) {
        final pending = await contactLinks.pending();
        if (pending != null && mounted && incomingContactLink == null) {
          setState(
            () => incomingContactLink = contactLinkUrl(
              contactLinks.origin,
              pending,
            ).toString(),
          );
        }
      }
    } finally {
      contactLinkOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> roomSettings([mx.Room? target, String? chosenAction]) async {
    final room = target ?? selected!;
    if (room.isDirectChat) {
      await profileCard(room.directChatMatrixID!);
      return;
    }
    var members = await room.requestParticipants();
    unawaited(presenceTracker?.refresh());
    if (!mounted) return;
    if (chosenAction == null) {
      var acting = false;
      await showAppDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, updateMembers) => RoomMembersDialog(
            room: room,
            members: members,
            onAction: (value) async {
              if (acting) return;
              acting = true;
              try {
                await roomSettings(room, value);
                if (!dialogContext.mounted) return;
                if (room.membership != mx.Membership.join) {
                  Navigator.pop(dialogContext);
                  return;
                }
                members = await room.requestParticipants();
              } catch (error) {
                report(
                  error is UserActionError
                      ? error.message
                      : 'Не удалось выполнить действие. Проверьте соединение.',
                );
              } finally {
                acting = false;
                if (dialogContext.mounted) updateMembers(() {});
              }
            },
          ),
        ),
      );
      return;
    }
    final action = chosenAction;
    if (action.startsWith('profile:') && mounted) {
      await profileCard(action.substring(8));
    } else if (action == 'invite' &&
        !room.isDirectChat &&
        !isPersonalRoom(room) &&
        mounted) {
      final users = await showAppDialog<List<String>>(
        context: context,
        animationStyle: appAnimationStyle(context),
        builder: (_) => PeoplePicker(
          client: room.client,
          multiple: true,
          allowedUsers: contacts!.acceptedUsers,
        ),
      );
      for (final user in users ?? <String>[]) {
        await ensureSharedGroupHistory(room);
        await room.invite(user);
      }
    } else if (action == 'avatar' && !room.isDirectChat) {
      if (!room.canChangeStateEvent(mx.EventTypes.RoomAvatar)) {
        throw UserActionError('Недостаточно прав для изменения аватара.');
      }
      if (!mounted) return;
      final file = await editAvatar(context);
      if (file != null) await room.setAvatar(file);
    } else if (action == 'rename' && !room.isDirectChat) {
      final name = await askText('Название', initial: roomDisplayName(room));
      if (name != null && name.isNotEmpty) await room.setName(name);
    } else if (!room.isDirectChat &&
        (action == 'leave' || action.startsWith('kick:'))) {
      final confirmed = await askText(
        action == 'leave'
            ? 'Введите ДА, чтобы покинуть чат'
            : 'Введите ДА, чтобы исключить участника',
      );
      if (confirmed != 'ДА') return;
      if (calls?.active?.chat.id == room.id) await calls?.end();
      if (action == 'leave') {
        await room.leave();
        if (selected?.id != room.id) return;
        timeline?.cancelSubscriptions();
        if (mounted) {
          setState(() {
            selected = null;
            timeline = null;
          });
        }
      } else {
        await room.kick(action.substring(5));
      }
    }
  }

  String? focusedEvent;
  bool completeHistory = false;
  Future<void> globalSearch() async {
    final result = await searchHistory(context, probe!.client);
    if (result != null) {
      await run(() => select(result.room, eventId: result.event));
    }
  }

  Future<void> select(mx.Room room, {String? eventId}) async {
    if (contacts?.hiddenRooms.contains(room.id) == true && room.isDirectChat) {
      throw UserActionError('Сначала дождитесь подтверждения контакта.');
    }
    unawaited(presenceTracker?.refresh(room.directChatMatrixID));
    if (room.membership == mx.Membership.invite) await room.join();
    await stopActiveCapture();
    final nextRoom = await probe!.room(room.id);
    final window = await historyWindow(nextRoom);
    final nextTimeline = await nextRoom.getTimeline(
      limit: eventId == null ? window.limit : mx.Room.defaultHistoryCount,
      eventContextId: eventId,
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
    if (!mounted) {
      nextTimeline.cancelSubscriptions();
      return;
    }
    timeline?.cancelSubscriptions();
    selected = nextRoom;
    timeline = nextTimeline;
    if (!nextRoom.isDirectChat &&
        nextRoom.historyVisibility == mx.HistoryVisibility.shared) {
      unawaited(
        requestMissingHistory(nextTimeline).catchError((Object _) => 0),
      );
    }
    focusedEvent = eventId;
    groupsTab = !nextRoom.isDirectChat;
    completeHistory = eventId == null && window.complete;
    await (await SharedPreferences.getInstance()).setString(
      'lastRoom:${profile.text.trim()}',
      room.id,
    );
  }

  Future<void> linkDevice(String? accountPassword) async {
    final client = probe!.client;
    final identity = await client.getCryptoIdentityState();
    if (!identity.initialized) {
      final devices = await client.getDevices();
      if (devices == null ||
          devices.any((d) => d.deviceId != client.deviceID)) {
        throw UserActionError(
          'На аккаунте ещё не настроено восстановление. Создайте ключ на первом устройстве.',
        );
      }
      final secret = accountPassword?.isNotEmpty == true
          ? accountPassword
          : await askPassword();
      if (secret == null) return;
      final key = await probe!.initializeRecovery(secret);
      await client.encryption!.keyManager.uploadInboundGroupSessions();
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RecoveryKeyDialog(recoveryKey: key),
      );
      await markDeviceLinked(client);
      if (mounted) setState(() => linked = true);
      return;
    }
    await client.updateUserDeviceKeys();
    final devices =
        client.userDeviceKeys[client.userID]?.deviceKeys.values
            .where(
              (d) => d.deviceId != client.deviceID && d.isValid && !d.blocked,
            )
            .toList() ??
        [];
    if (!mounted) return;
    final device = devices.length == 1
        ? devices.single
        : await showAppDialog<mx.DeviceKeys>(
            context: context,
            builder: (dialogContext) => SimpleDialog(
              title: const Text('Где подтвердить вход?'),
              children: [
                if (devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Других устройств нет. Используйте ключ восстановления.',
                    ),
                  ),
                for (final device in devices)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, device),
                    child: Text(
                      '${device.deviceDisplayName ?? 'VoiceChat'} · ${device.deviceId}',
                    ),
                  ),
              ],
            ),
          );
    if (device == null || !mounted) return;
    final owner = verifications!;
    final request = await owner.start(device);
    if (!mounted) return;
    final verified = await showDeviceVerification(
      context,
      owner,
      request,
      call: call,
    );
    if (!verified ||
        request.canceled ||
        request.state != crypto.KeyVerificationState.done ||
        !device.directVerified) {
      throw UserActionError('Подключение не подтверждено. Повторите сверку.');
    }
    report('Получаем ключи и восстанавливаем историю…');
    await receiveLinkedSecrets(client, device);
    if (mounted) setState(() => linked = true);
  }

  Future<void> setupRecovery() async {
    if ((await probe!.client.getCryptoIdentityState()).initialized) {
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: AppDialogTitle(child: const Text('Ключ восстановления')),
          content: const Text(
            'Ключ был показан при первом входе. Используйте сохранённую копию из менеджера паролей. Новые устройства можно подключить подтверждением на этом устройстве. Создание другого ключа не требуется.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
      return;
    }
    final secret = await askPassword();
    if (secret == null) return;
    final key = await probe!.initializeRecovery(secret);
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (_) => RecoveryKeyDialog(recoveryKey: key),
    );
    report('Ключи созданы. Резервную копию можно обновить после переписки.');
  }

  Future<void> restore() async {
    await probe!.requireHistoryBackup();
    if (!mounted) return;
    final input = TextEditingController();
    final value = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => AlertDialog(
        title: AppDialogTitle(child: const Text('Вернуть историю')),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: input,
            minLines: 3,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
            decoration: const InputDecoration(
              labelText: 'Ваш ключ восстановления',
              alignLabelWithHint: true,
            ),
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
    await markDeviceLinked(probe!.client);
    linked = true;
    report('Ключи восстановлены. Откройте чат для загрузки истории.');
  }

  Future<void> startCall({bool video = false}) async {
    if (selected == null) return;
    await stopActiveCapture();
    await calls!.start(selected!, video: video);
  }

  Future<void> audioOutput() async {
    if (kIsWeb) {
      final resumed = resumeBrowserAudio();
      final current = calls?.active;
      if (current is CallProbe) await current.media?.startAudio();
      report(
        await resumed
            ? 'Звук включён. Громкость и гарнитура — в настройках iPhone.'
            : 'Нажмите ещё раз, чтобы разрешить звук браузеру.',
      );
      return;
    }
    await lk.AudioManager.instance.setSpeakerOutputPreferred(
      !lk.AudioManager.instance.isSpeakerOutputPreferred,
    );
    report(
      'Переключён динамик/обычный аудиомаршрут. Гарнитурой управляет система.',
    );
  }

  Future<String?> askPassword() async {
    final input = TextEditingController();
    final value = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => AlertDialog(
        title: AppDialogTitle(
          child: const Text('Подтвердите паролем аккаунта'),
        ),
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
    MessageMediaCache.clear(probe!.client);
    probe!.client.httpClient
        .close(); // Abort network operations before closing local keys.
    try {
      await Future.wait([
        if (calls != null) calls!.close(),
        if (verifications != null) verifications!.close(),
        if (historyRecovery != null) historyRecovery!.close(),
        if (sounds != null) sounds!.close(),
        if (presenceTracker != null) presenceTracker!.close(),
        if (contacts != null) contacts!.close(),
        if (storagePolicy != null) storagePolicy!.close(),
        if (recordingActivity != null) recordingActivity!.close(),
        if (actions != null) actions!.close(),
      ]);
    } finally {
      await connectionStatus?.cancel();
      await sync?.cancel();
      timeline?.cancelSubscriptions();
      storagePolicy = null;
      try {
        await probe!.close();
      } finally {
        if (mounted) {
          setState(() {
            probe = null;
            selected = null;
            timeline = null;
            calls = null;
            verifications = null;
            historyRecovery = null;
            actions = null;
          });
        }
      }
    }
    report('Хранилище заблокировано. Для открытия введите локальную фразу.');
  }

  Future<void> verifyDevices({Object? choice}) async {
    final client = probe!.client;
    final users = selected == null
        ? <String>{client.userID!}
        : (await client.getJoinedMembersByRoom(selected!.id))!.keys.toSet();
    await refreshDevices(client, users);
    var devices = users
        .expand((user) => client.userDeviceKeys[user]!.deviceKeys.values)
        .toList();
    var independent = await independentlyVerifiedDevices(client, devices);
    if (!mounted) return;
    if (choice == null) {
      var acting = false;
      await showAppDialog<void>(
        context: context,
        animationStyle: appAnimationStyle(context),
        builder: (context) => StatefulBuilder(
          builder: (context, updateDevices) {
            Future<void> choose(Object value) async {
              if (acting) return;
              acting = true;
              try {
                await verifyDevices(choice: value);
                devices = users
                    .expand(
                      (user) => client.userDeviceKeys[user]!.deviceKeys.values,
                    )
                    .toList();
                independent = await independentlyVerifiedDevices(
                  client,
                  devices,
                );
              } catch (error) {
                report(
                  error is UserActionError
                      ? error.message
                      : 'Не удалось проверить устройство. Повторите попытку.',
                );
              } finally {
                acting = false;
                if (context.mounted) updateDevices(() {});
              }
            }

            return AlertDialog(
              title: AppDialogTitle(
                child: const Text('Проверка личности устройств'),
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IdentityField(label: 'Аккаунт', value: client.userID!),
                      IdentityField(
                        label: 'Это устройство',
                        value: client.deviceID!,
                      ),
                      if (client.fingerprintKey case final String fingerprint)
                        IdentityField(
                          label: 'Ваш отпечаток',
                          value: fingerprint,
                        ),
                      const SizedBox(height: 16),
                      const Text(
                        'Выберите устройство и сравните коды на обоих экранах лично или по независимому каналу. Автоматически закреплённый ключ ещё не означает независимую проверку.',
                      ),
                      for (final request in verifications!.pending)
                        ListTile(
                          title: Text('Продолжить проверку ${request.userId}'),
                          onTap: () => choose(request),
                        ),
                      ...devices.map(
                        (device) => Card.outlined(
                          margin: const EdgeInsets.only(top: 10),
                          child: ListTile(
                            title: Text(device.userId),
                            subtitle: Text(
                              '${device.deviceId}\n${device.userId == client.userID && device.deviceId == client.deviceID
                                  ? 'Это устройство'
                                  : independent.contains(device)
                                  ? 'Подтверждено независимой сверкой'
                                  : device.directVerified
                                  ? 'Ключ закреплён без отметки независимой сверки'
                                  : 'Не проверено'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  independent.contains(device)
                                      ? Icons.verified_user
                                      : device.directVerified
                                      ? Icons.lock_outline
                                      : Icons.help_outline,
                                ),
                                if (!device.blocked &&
                                    !(device.userId == client.userID &&
                                        device.deviceId == client.deviceID))
                                  PopupMenuButton<String>(
                                    popUpAnimationStyle: appAnimationStyle(
                                      context,
                                    ),
                                    tooltip: 'Способ проверки',
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'manual',
                                        child: Text('Сверить полный отпечаток'),
                                      ),
                                    ],
                                    onSelected: (_) =>
                                        choose((device: device, manual: true)),
                                  ),
                              ],
                            ),
                            onTap:
                                device.blocked ||
                                    device.userId == client.userID &&
                                        device.deviceId == client.deviceID
                                ? null
                                : () => choose(device),
                          ),
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
            );
          },
        ),
      );
      return;
    }
    final chosen = choice;
    if (!mounted) return;
    if (chosen case (device: final mx.DeviceKeys device, manual: true)) {
      await verifyFingerprint(device);
      return;
    }
    final owner = verifications!;
    final request = chosen is crypto.KeyVerification
        ? chosen
        : await owner.start(chosen as mx.DeviceKeys);
    if (mounted) {
      await showDeviceVerification(context, owner, request, call: call);
    }
  }

  Future<void> historyRequests() async {
    await showAppDialog<void>(
      context: context,
      animationStyle: appAnimationStyle(context),
      barrierDismissible: false,
      builder: (_) => HistoryRecoveryDialog(
        owner: historyRecovery!,
        verify: verifyFingerprint,
      ),
    );
  }

  Future<bool> verifyFingerprint(mx.DeviceKeys chosen) async {
    final client = probe!.client;
    final input = TextEditingController();
    final fingerprint = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => AlertDialog(
        title: AppDialogTitle(
          child: const Text('Введите отпечаток со второго устройства'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdentityField(label: 'Аккаунт', value: chosen.userId),
            IdentityField(label: 'Устройство', value: chosen.deviceId!),
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
    if (fingerprint == null) return false;
    await verifyDevice(client, chosen.userId, chosen.deviceId!, fingerprint);
    report('Отпечаток совпал. Устройство проверено локально.');
    return true;
  }

  Future<void> devices() async {
    final client = probe!.client;
    var items = await client.getDevices() ?? <mx.Device>[];
    String? feedback;
    bool revoking = false;
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) {
          Future<void> revoke(mx.Device device) async {
            if (revoking) return;
            update(() {
              revoking = true;
              feedback = null;
            });
            try {
              final secret = await askPassword();
              if (secret == null) return;
              await call?.close();
              await probe!.revokeDevice(device.deviceId, secret);
              items = await client.getDevices() ?? <mx.Device>[];
              feedback =
                  'Доступ устройства отозван. Старую скопированную историю это не удаляет.';
            } catch (error) {
              feedback = error is UserActionError
                  ? error.message
                  : 'Не удалось отозвать доступ. Проверьте соединение.';
            } finally {
              if (dialogContext.mounted) update(() => revoking = false);
            }
          }

          return AlertDialog(
            title: const AppDialogTitle(child: Text('Устройства аккаунта')),
            content: SizedBox(
              width: 480,
              height: (MediaQuery.sizeOf(dialogContext).height * .5).clamp(
                160,
                480,
              ),
              child: ListView(
                children: [
                  const Text(
                    'Отзыв завершает сеанс. Уже полученные сообщения могут остаться на устройстве.',
                  ),
                  const SizedBox(height: 8),
                  if (feedback != null)
                    Semantics(liveRegion: true, child: Text(feedback!)),
                  for (final device in items)
                    Card.outlined(
                      child: ListTile(
                        leading: const Icon(Icons.devices_outlined),
                        title: Text(accountDeviceName(device)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${device.deviceId}${device.deviceId == client.deviceID ? ' · Это устройство' : ''}',
                            ),
                            Text(
                              'Добавлено: ${deviceAddedAt(client, device.deviceId) == null ? 'дата не сохранена' : scheduledTime(deviceAddedAt(client, device.deviceId)!)}',
                            ),
                            if (device.lastSeenTs case final int timestamp)
                              Text(
                                'Последняя активность: ${scheduledTime(DateTime.fromMillisecondsSinceEpoch(timestamp))}',
                              ),
                          ],
                        ),
                        trailing: device.deviceId == client.deviceID
                            ? null
                            : IconButton(
                                tooltip: 'Отозвать доступ',
                                onPressed: revoking
                                    ? null
                                    : () => revoke(device),
                                icon: const Icon(Icons.no_accounts_outlined),
                              ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> openP2p(mx.Client client) async {
    final service = P2pService(client, contacts!, tokenServer.text.trim());
    service.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      await service.open();
      p2p = service;
    } catch (_) {
      await service.close();
      p2p = null;
      report(
        'Не удалось открыть P2P Share. Перезапустите приложение и повторите.',
      );
    }
  }

  Future<void> logout() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (context) => AlertDialog(
        title: AppDialogTitle(
          child: const Text('Выйти и удалить локальные ключи?'),
        ),
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
    await storagePolicy?.close();
    storagePolicy = null;
    try {
      if (kIsWeb) {
        await disablePushNotifications(
          tokenServer.text.trim(),
          probe!.client.accessToken!,
          createClient: _pushClient,
        );
      }
      await p2p?.close();
      p2p = null;
      await probe!.logout();
    } catch (_) {
      storagePolicy = StoragePolicy(probe!.client, () => selected?.id);
      await storagePolicy!.open();
      if (p2p == null) await openP2p(probe!.client);
      rethrow;
    }
    MessageMediaCache.clear(probe!.client);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastAccount');
    await prefs.remove('lastRoom:${profile.text.trim()}');
    writeTabAccount(null);
    savedAccount = false;
    await calls?.close();
    await verifications?.close();
    verifications = null;
    await desktopNotifications?.close();
    desktopNotifications = null;
    await sounds?.close();
    await historyRecovery?.close();
    await presenceTracker?.close();
    await contacts?.close();
    await recordingActivity?.close();
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
    if (probe != null) MessageMediaCache.clear(probe!.client);
    unawaited(sync?.cancel());
    timeline?.cancelSubscriptions();
    unawaited(calls?.close());
    unawaited(verifications?.close());
    unawaited(historyRecovery?.close());
    unawaited(desktopNotifications?.close());
    unawaited(sounds?.close());
    unawaited(presenceTracker?.close());
    unawaited(contacts?.close());
    unawaited(recordingActivity?.close());
    unawaited(actions?.close());
    unawaited(connectionStatus?.cancel());
    unawaited(() async {
      await p2p?.close();
      await storagePolicy?.close();
      await probe?.close();
    }());
    for (final c in [
      server,
      tokenServer,
      mediaServer,
      username,
      password,
      profile,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget paletteMenu() => PopupMenuButton<AppPalette>(
    popUpAnimationStyle: appAnimationStyle(context),
    tooltip: 'Цветовая схема',
    initialValue: widget.palette,
    onSelected: widget.onPalette,
    icon: const Icon(Icons.palette_outlined),
    itemBuilder: (_) => AppPalette.values
        .map((p) => PopupMenuItem(value: p, child: Text(p.label)))
        .toList(),
  );

  final loginForm = GlobalKey<FormState>();
  Future<void> submitLogin() async {
    if (!savedAccount && !(loginForm.currentState?.validate() ?? false)) return;
    await run(login);
  }

  Future<void> connectionSettings() => showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: AppDialogTitle(child: const Text('Параметры подключения')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (controller, label) in [
                (server, 'Matrix URL'),
                (tokenServer, 'Token API URL'),
                (mediaServer, 'LiveKit URL'),
              ])
                AuthField(
                  controller: controller,
                  label: label,
                  keyboardType: TextInputType.url,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Готово'),
        ),
      ],
    ),
  );

  Widget connection() => AuthPage(
    key: const ValueKey('halo-login'),
    title: savedAccount ? 'Ваши разговоры ждут' : 'Снова на связи',
    subtitle: savedAccount
        ? 'Откройте переписку на этом устройстве.'
        : 'Войдите в VoiceChat — и продолжите с того места, где остановились.',
    eyebrow: savedAccount ? 'СОХРАНЁННЫЙ АККАУНТ' : 'ВАШЕ ПРОСТРАНСТВО',
    icon: savedAccount ? Icons.forum_outlined : Icons.waving_hand_outlined,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'О приложении',
          onPressed: aboutApp,
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: 'Параметры подключения',
          onPressed: busy ? null : connectionSettings,
          icon: const Icon(Icons.tune_rounded),
        ),
        paletteMenu(),
      ],
    ),
    child: restoringSession
        ? const Column(
            children: [
              LinearProgressIndicator(),
              SizedBox(height: 16),
              Text('Открываем сохранённый вход…'),
            ],
          )
        : AutofillGroup(
            child: Form(
              key: loginForm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (savedAccount)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: AuthNotice(
                        username.text,
                        icon: Icons.account_circle_outlined,
                      ),
                    )
                  else ...[
                    AuthField(
                      controller: username,
                      label: 'Имя пользователя',
                      autofillHints: const [AutofillHints.username],
                      readOnly: busy,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Введите имя пользователя.'
                          : null,
                    ),
                    AuthField(
                      controller: password,
                      label: 'Пароль аккаунта',
                      secret: true,
                      autofillHints: const [AutofillHints.password],
                      readOnly: busy,
                      validator: (value) => value == null || value.isEmpty
                          ? 'Введите пароль аккаунта.'
                          : null,
                      onSubmitted: submitLogin,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() => registration(reset: true)),
                        child: const Text('Забыли пароль?'),
                      ),
                    ),
                  ],
                  SizedBox(
                    height: 3,
                    child: busy ? const LinearProgressIndicator() : null,
                  ),
                  const SizedBox(height: 1),
                  FilledButton.icon(
                    onPressed: busy ? null : submitLogin,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(savedAccount ? 'Открыть переписку' : 'Войти'),
                  ),
                  const SizedBox(height: 8),
                  const AuthNotice(
                    'Новое устройство: подтвердите вход на другом устройстве или ключом восстановления.',
                    icon: Icons.devices_outlined,
                  ),
                  const SizedBox(height: 8),
                  if (savedAccount)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              savedAccount = false;
                              profile.text = newDeviceProfile();
                            }),
                      child: const Text('Другой аккаунт'),
                    )
                  else ...[
                    OutlinedButton(
                      onPressed: busy ? null : () => run(() => registration()),
                      child: const Text('Создать аккаунт'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (status.isNotEmpty)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        status,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Локальная версия · проверка безопасности ещё не завершена',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
  );

  Future<void> aboutApp() async {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: !MacOSNotifications.supported,
      animationStyle: appAnimationStyle(context),
      builder: (_) => AppUpdateDialog(
        updateRoute: () {
          final network = probe?.client.httpClient;
          if (network is! RouteTransport ||
              network.origin != Uri.tryParse(updateOrigin)) {
            return null;
          }
          final selected = network.coordinator == null
              ? network.selected
              : network.coordinator!.route(RouteService.matrix)?.origin;
          if (selected == null) {
            throw const FormatException(
              'Нет доступного входа. Повторите проверку после восстановления связи.',
            );
          }
          return {
            'canonicalOrigin': updateOrigin,
            'selectedOrigin': selected.toString(),
          };
        },
        createClient: () {
          final network = probe?.client.httpClient;
          if (network is RouteTransport &&
              network.origin == Uri.tryParse(updateOrigin)) {
            return network.fork();
          }
          return http.Client();
        },
        prepareInstall: () async {
          if (busy ||
              restoringSession ||
              hasActiveCapture ||
              (call != null && !call!.isClosed) ||
              actions?.updateBusy == true ||
              p2p?.busy == true) {
            return 'Завершите звонок, запись или текущую отправку перед установкой.';
          }
          final reason = await checkUpdateGuards();
          if (reason != null) return reason;
          await actions?.prepareUpdate();
          return null;
        },
      ),
    );
  }

  Future<void> settings() async {
    Future<dynamic>? settingsClosed;
    var privacyBusy = false;
    String? privacyError;
    final choice = await showAppDialog<String>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateSettings) {
          Future<void> openSetting(String choice) async {
            await settingsAction(choice);
            if (!dialogContext.mounted) return;
            if (probe == null || !linked) {
              Navigator.pop(dialogContext);
            } else {
              updateSettings(() {});
            }
          }

          final compact = MediaQuery.sizeOf(dialogContext).width < 500;
          return AlertDialog(
            actionsPadding: compact
                ? const EdgeInsets.fromLTRB(16, 0, 16, 8)
                : null,
            buttonPadding: compact ? EdgeInsets.zero : null,
            contentPadding: compact
                ? const EdgeInsets.fromLTRB(24, 16, 24, 8)
                : null,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: AppDialogTitle(child: const Text('Настройки')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('О приложении'),
                      subtitle: const Text('Версия и обновления'),
                      onTap: aboutApp,
                    ),
                    ListTile(
                      leading: const Icon(Icons.network_check),
                      title: const Text('Диагностика соединения'),
                      subtitle: const Text(
                        'Маршрут и звонок без данных аккаунта',
                      ),
                      onTap: () => openSetting('diagnostics'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: PersonAvatar(
                        name: username.text.replaceFirst('@', ''),
                        client: probe!.client,
                        url: ownAvatar,
                        online: online,
                      ),
                      title: Text(probe!.client.userID!),
                      subtitle: Text('Устройство: ${probe!.client.deviceID}'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.account_circle_outlined),
                      title: const Text('Изменить аватар'),
                      onTap: () => openSetting('avatar'),
                    ),
                    if (contacts != null)
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: const Text('История приглашений'),
                        subtitle: const Text(
                          'Входящие, исходящие и завершённые',
                        ),
                        onTap: () => openSetting('invitations'),
                      ),
                    if (contacts != null)
                      StatefulBuilder(
                        builder: (context, update) => Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'Мне могут писать без подтверждения',
                              ),
                              subtitle: const Text(
                                'Если выключить, новые собеседники сначала отправляют запрос',
                              ),
                              value: contacts!.allowDirect,
                              onChanged: privacyBusy || !contacts!.available
                                  ? null
                                  : (value) async {
                                      update(() {
                                        privacyBusy = true;
                                        privacyError = null;
                                      });
                                      try {
                                        await contacts!.setAllowDirect(value);
                                      } catch (_) {
                                        privacyError =
                                            'Не удалось сохранить настройку. Проверьте соединение и повторите.';
                                      } finally {
                                        if (context.mounted) {
                                          update(() => privacyBusy = false);
                                        }
                                      }
                                    },
                            ),
                            if (privacyError != null) Text(privacyError!),
                          ],
                        ),
                      ),
                    const Divider(height: 28),
                    ListTile(
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('Локальное хранилище'),
                      subtitle: const Text(
                        'Объём, лимит и очистка старой локальной истории',
                      ),
                      onTap: () => openSetting('storage'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.zoom_in_outlined),
                      title: const Text('Масштаб'),
                      subtitle: const Text('Сообщения, люди и группы'),
                      onTap: () {
                        settingsClosed = ModalRoute.of(
                          dialogContext,
                        )?.completed;
                        Navigator.pop(dialogContext, 'scale');
                      },
                    ),
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
                      onTap: () => openSetting('sounds'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Устройства и безопасность',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (kIsWeb || MacOSNotifications.supported) ...[
                      ListTile(
                        leading: const Icon(
                          Icons.notifications_active_outlined,
                        ),
                        title: const Text('Включить уведомления'),
                        subtitle: Text(
                          MacOSNotifications.supported
                              ? 'Пока приложение работает, в том числе со скрытым окном.'
                              : 'На iPhone — из приложения на экране «Домой». iOS 16.4 и новее.',
                        ),
                        onTap: () => openSetting('push-enable'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.notifications_off_outlined),
                        title: const Text(
                          'Выключить уведомления на этом устройстве',
                        ),
                        onTap: () => openSetting('push-disable'),
                      ),
                    ],
                    ListTile(
                      leading: const Icon(Icons.devices_outlined),
                      title: const Text('Устройства'),
                      subtitle: const Text('Сеансы и отзыв доступа'),
                      onTap: () => openSetting('devices'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: const Text('Проверить устройства'),
                      subtitle: const Text(
                        'Независимая сверка устройств и ключей',
                      ),
                      onTap: () => openSetting('verify'),
                    ),
                    const Divider(height: 24),
                    Text(
                      'Доступ к истории',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: const Text('Ключ восстановления'),
                      onTap: () => openSetting('recovery'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.restore_rounded),
                      title: const Text('Восстановить'),
                      onTap: () => openSetting('restore'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.swap_horiz_rounded),
                      title: const Text('Запросы истории'),
                      subtitle: Text(
                        'Ожидают: ${historyRecovery?.pending.length ?? 0}',
                      ),
                      onTap: () => openSetting('historyRequests'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: const Text('Обновить backup'),
                      onTap: () => openSetting('backup'),
                    ),
                    const Divider(height: 24),
                    ListTile(
                      leading: const Icon(Icons.logout_rounded),
                      title: const Text('Выйти'),
                      subtitle: const Text(
                        'Завершить сеанс и удалить локальные ключи',
                      ),
                      onTap: () => openSetting('logout'),
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
          );
        },
      ),
    );
    if (choice == 'scale') {
      await settingsClosed;
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        clearBackdrop: true,
        builder: (_) => ChatScaleDialog(scale: ChatScaleScope.of(context)!),
      );
    }
  }

  Future<void> settingsAction(String chosen) async {
    if (!mounted) return;
    if (chosen == 'historyRequests') {
      await historyRequests();
      return;
    }
    await run(() async {
      switch (chosen) {
        case 'diagnostics':
          final snapshot = await connectionDiagnostics(
            probe?.routes,
            calls?.active,
          );
          if (mounted) {
            await showAppDialog<void>(
              context: context,
              animationStyle: appAnimationStyle(context),
              builder: (dialogContext) => AlertDialog(
                title: const AppDialogTitle(
                  child: Text('Диагностика соединения'),
                ),
                content: SingleChildScrollView(
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(snapshot),
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
          }
        case 'invitations':
          await invitations();
        case 'storage':
          await storagePolicy!.check();
          if (mounted) {
            await showAppDialog<void>(
              context: context,
              animationStyle: appAnimationStyle(context),
              builder: (_) => StorageDialog(policy: storagePolicy!),
            );
          }
        case 'sounds':
          if (kIsWeb) unawaited(resumeBrowserAudio());
          await sounds!.setEnabled(!sounds!.enabled);
          sounds!.updateCall(calls!);
        case 'push-enable':
          report(
            MacOSNotifications.supported
                ? await desktopNotifications!.setEnabled(true)
                : await enablePushNotifications(
                    tokenServer.text.trim(),
                    probe!.client.accessToken!,
                    createClient: _pushClient,
                  ),
          );
        case 'push-disable':
          report(
            MacOSNotifications.supported
                ? await desktopNotifications!.setEnabled(false)
                : await disablePushNotifications(
                    tokenServer.text.trim(),
                    probe!.client.accessToken!,
                    createClient: _pushClient,
                  ),
          );
        case 'avatar':
          await changeAvatar();
        case 'devices':
          await devices();
        case 'verify':
          await verifyDevices();
        case 'recovery':
          await setupRecovery();
        case 'restore':
          await restore();
        case 'backup':
          final backedUp = await probe!.backup();
          report(
            backedUp
                ? 'Резервная копия ключей обновлена.'
                : 'Резервное копирование не настроено на этом устройстве. Создайте ключ восстановления или откройте существующий ключ.',
          );
        case 'lock':
          await lock();
        case 'logout':
          await logout();
      }
    });
  }

  Widget rooms({bool compact = false}) => ConversationList(
    compact: compact,
    client: probe!.client,
    selected: selected,
    onSelect: (room) => run(() => select(room)),
    onNewPerson: () => run(() => newChat()),
    onNewGroup: () => run(() => newChat(group: true)),
    onSettings: settings,
    onP2p: p2p == null
        ? null
        : () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => P2pPanel(service: p2p!)),
          ),
    p2pIncoming: p2p?.incomingCount ?? 0,
    onInvitations: invitations,
    onSearch: globalSearch,
    ownAvatar: ownAvatar,
    ownOnline: online,
    onProfile: () => run(() => profileCard(probe!.client.userID!)),
    contactInvites: contacts?.incomingCount ?? 0,
    outgoingInvites:
        (contacts?.requests
                .where(
                  (r) =>
                      r.state == 'pending' && r.sender == probe!.client.userID,
                )
                .length ??
            0) +
        (contacts?.groups
                .where(
                  (g) =>
                      g.state == 'pending' &&
                      g.inviter == probe!.client.userID &&
                      g.userId != probe!.client.userID,
                )
                .length ??
            0),
    onChatMenu: (room, action) => run(() async {
      if (action == 'pin') {
        await room.setFavourite(!room.isFavourite);
        if (mounted) setState(() {});
      } else if (action == 'mute') {
        await room.setPushRuleState(
          room.pushRuleState == mx.PushRuleState.dontNotify
              ? mx.PushRuleState.notify
              : mx.PushRuleState.dontNotify,
        );
      } else if (action == 'info' && room.isDirectChat) {
        await profileCard(room.directChatMatrixID!);
      } else {
        await roomSettings(room, action == 'leave' ? 'leave' : null);
      }
    }),
    hiddenDirectRooms: contacts?.hiddenRooms ?? {},
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
      key: ValueKey(room.id),
      room: room,
      timeline: timeline!,
      actions: actions!,
      report: report,
      initialEventId: focusedEvent,
      onVoiceCall:
          isPersonalRoom(room) || busy || (call != null && !call!.isClosed)
          ? null
          : () => run(() => startCall()),
      onVideoCall:
          isPersonalRoom(room) || busy || (call != null && !call!.isClosed)
          ? null
          : () => run(() => startCall(video: true)),
      onRoomInfo: busy ? null : () => run(() => roomSettings()),
      completeHistory: completeHistory,
      onJump: (event) => run(() => select(room, eventId: event)),
      onForward: (target) async {
        await select(target);
        if (mounted) setState(() {});
      },
      header: ConversationHeader(
        room: room,
        lastSeenLabel: room.isDirectChat
            ? lastSeen(_roomPresenceSnapshot(room), DateTime.now())
            : '',
        onClose: () => run(() async {
          await stopActiveCapture();
          if (mounted) setState(() => selected = null);
        }),
        onProfile: room.isDirectChat
            ? () => run(() => profileCard(room.directChatMatrixID!))
            : () => run(() => roomSettings()),
        onInfo: busy ? null : () => run(() => roomSettings()),
        onVoiceCall:
            isPersonalRoom(room) || busy || (call != null && !call!.isClosed)
            ? null
            : () => run(() => startCall()),
        onVideoCall:
            isPersonalRoom(room) || busy || (call != null && !call!.isClosed)
            ? null
            : () => run(() => startCall(video: true)),
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
      await stopActiveCapture();
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        animationStyle: appAnimationStyle(context),
        barrierDismissible: false,
        builder: (_) => CallWindow(calls: calls!, audioOutput: audioOutput),
      );
    } catch (error) {
      presentedCall = null;
      report(
        error is UserActionError
            ? error.message
            : 'Не удалось освободить микрофон или камеру.',
      );
    } finally {
      callWindowOpen = false;
    }
  }

  Widget callBanner() {
    final remote = calls?.devices.remote.values.firstOrNull;
    if (remote != null && calls?.active?.isClosed != false) {
      return ActiveCallBanner(
        onPressed: showCallWindow,
        label:
            'Идёт звонок с ${roomDisplayName(remote.room)} на другом устройстве',
      );
    }
    final available =
        calls != null &&
        (calls!.starting ||
            calls!.dialError != null ||
            calls!.active?.isClosed == false ||
            calls!.directInvitations.isNotEmpty ||
            calls!.invitations.isNotEmpty);
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: available
          ? ActiveCallBanner(
              onPressed: showCallWindow,
              label: calls!.active?.isClosed == false
                  ? 'Идёт звонок · Вернуться к звонку'
                  : 'Открыть окно звонка',
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    maybeOpenContactLink();
    if (probe != null && !linked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Подключить устройство')),
        body: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Подтвердите вход на устройстве, где уже открыта переписка. Держите оба устройства рядом.',
                    ),
                    const SizedBox(height: 16),
                    if (busy)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Подключение и восстановление истории',
                      ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() => linkDevice(null)),
                      child: const Text('Подтвердить на другом устройстве'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await restore();
                              if (mounted) setState(() {});
                            }),
                      child: const Text('У меня есть ключ восстановления'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => run(lock),
                      child: const Text('Вернуться ко входу'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (probe == null) return connection();
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 2,
              child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
            ),
            callBanner(),
            if (incomingContactLink != null)
              ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: const Text('Приглашение в контакты'),
                subtitle: const Text(
                  'Откройте и подтвердите, чтобы добавить человека',
                ),
                onTap: busy ? null : () => run(() => contactLink()),
                trailing: IconButton(
                  tooltip: 'Скрыть приглашение',
                  onPressed: busy
                      ? null
                      : () => setState(() => incomingContactLink = null),
                  icon: const Icon(Icons.close),
                ),
              ),
            if (probe!.routes != null)
              RouteStatusBanner(coordinator: probe!.routes!, syncOnline: online)
            else if (!online)
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
                child: LayoutBuilder(
                  builder: (context, box) => AnimatedSwitcher(
                    duration: motionDuration(context),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: box.maxWidth >= 840
                        ? ResizableChatLayout(
                            key: const ValueKey('messenger-wide'),
                            sidebar: (compact) => rooms(compact: compact),
                            conversation: conversation(),
                          )
                        : selected == null
                        ? KeyedSubtree(
                            key: const ValueKey('contacts'),
                            child: rooms(),
                          )
                        : KeyedSubtree(
                            key: ValueKey('conversation-${selected?.id}'),
                            child: conversation(),
                          ),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .3),
                  ),
                ),
              ),
              child: Text(
                'Локальный стенд · сквозное шифрование',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurface.withValues(alpha: .55),
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
