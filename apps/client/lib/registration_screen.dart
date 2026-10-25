import 'device_added.dart';
import 'device_name.dart';
import 'dart:async';
import 'dart:math';
import 'auth_layout.dart';
import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'user_action_error.dart';
import 'package:matrix/matrix.dart' as mx;

/// Synapse handles email verification and UIA; the app never validates its own email token.
class RegistrationScreen extends StatefulWidget {
  final Future<mx.Client> Function(String? passphrase) openClient;
  final bool requireLocalPassphrase;
  final bool resetPassword;
  final void Function(String password)? onRegistered;
  const RegistrationScreen({
    super.key,
    required this.openClient,
    this.requireLocalPassphrase = false,
    this.onRegistered,
    this.resetPassword = false,
  });
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen>
    with WidgetsBindingObserver {
  final localPassphrase = TextEditingController();
  mx.Client? client;
  String? localPassphraseError;
  final username = TextEditingController();
  final displayName = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  final clientSecret = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  String? sid;
  String? session;
  bool busy = false;
  String? status;
  final formKey = GlobalKey<FormState>();
  int sendAttempt = 0;
  Timer? verificationTimer;
  bool completed = false;
  bool verificationStopped = false;
  Duration retryDelay = const Duration(seconds: 3);
  DateTime? retryAfter;
  late final registrationDeviceId =
      'voicechat-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void scheduleVerification({Duration? delay}) {
    verificationTimer?.cancel();
    if (!mounted ||
        widget.resetPassword ||
        sid == null ||
        completed ||
        verificationStopped ||
        busy) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    var wait = delay ?? retryDelay;
    final remaining = retryAfter?.difference(DateTime.now());
    if (remaining != null && remaining > wait) wait = remaining;
    verificationTimer = Timer(wait, () => unawaited(submit(automatic: true)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleVerification(delay: Duration.zero);
    } else {
      verificationTimer?.cancel();
    }
  }

  Future<void> submit({bool automatic = false}) async {
    if (busy || completed) return;
    verificationTimer?.cancel();
    if (sid == null) {
      final invalid = formKey.currentState!.validateGranularly();
      if (invalid.isNotEmpty) {
        await Scrollable.ensureVisible(
          invalid.first.context,
          alignment: .2,
          duration: motionDuration(context),
        );
        return;
      }
    }
    if (widget.requireLocalPassphrase && client == null) {
      final phrase = localPassphrase.text;
      final error = phrase.length < 12 || phrase.length > 1024
          ? 'Введите локальную фразу от 12 до 1024 символов.'
          : !widget.resetPassword && phrase == password.text
          ? 'Придумайте фразу, отличную от пароля аккаунта.'
          : null;
      setState(() => localPassphraseError = error);
      if (error != null) return;
    }
    setState(() {
      busy = true;
      status = null;
      verificationStopped = false;
    });
    try {
      client ??= await widget.openClient(
        widget.requireLocalPassphrase ? localPassphrase.text : null,
      );
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (sid == null) {
        sendAttempt++;
        final response = widget.resetPassword
            ? await client!.requestTokenToResetPasswordEmail(
                clientSecret,
                email.text.trim(),
                sendAttempt,
              )
            : await client!.requestTokenToRegisterEmail(
                clientSecret,
                email.text.trim(),
                sendAttempt,
              );
        sid = response.sid;
        if (mounted) setState(() => status = null);
      } else {
        final auth = mx.AuthenticationThreePidCreds(
          session: session,
          type: mx.AuthenticationTypes.emailIdentity,
          threepidCreds: mx.ThreepidCreds(
            sid: sid!,
            clientSecret: clientSecret,
          ),
        );
        if (widget.resetPassword) {
          await client!.changePassword(
            password.text,
            auth: auth,
            logoutDevices: true,
          );
        } else {
          // A completed SDK login must not be registered again if a later sync/profile request fails.
          if (!client!.isLogged()) {
            await client!.register(
              username: username.text,
              password: password.text,
              deviceId: registrationDeviceId,
              initialDeviceDisplayName: await currentDeviceName(),
              auth: auth,
            );
          }
          if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
          final addedAt = DateTime.now();
          await client!.firstSyncReceived;
          await recordDeviceAdded(client!, addedAt);
          if (displayName.text.trim().isNotEmpty) {
            await client!.setProfileField(client!.userID!, 'displayname', {
              'displayname': displayName.text.trim(),
            });
          }
        }
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        completed = true;
        if (!widget.resetPassword) widget.onRegistered?.call(password.text);
        Navigator.pop(context, true);
      }
    } on UserActionError catch (error) {
      verificationStopped = true;
      if (mounted) setState(() => status = error.message);
    } on mx.MatrixException catch (error) {
      session = error.session ?? session;
      final pendingEmail =
          [
            'M_THREEPID_AUTH_FAILED',
            'M_UNAUTHORIZED',
          ].contains(error.errcode) ||
          (error.requireAdditionalAuthentication &&
              error.authenticationFlows?.any(
                    (flow) => flow.stages.contains(
                      mx.AuthenticationTypes.emailIdentity,
                    ),
                  ) ==
                  true);
      if (automatic && pendingEmail) {
        retryDelay = const Duration(seconds: 3);
      } else if (error.errcode == 'M_LIMIT_EXCEEDED') {
        retryAfter = DateTime.now().add(
          Duration(milliseconds: max(3000, error.retryAfterMs ?? 3000)),
        );
        if (mounted) {
          setState(
            () => status = widget.resetPassword
                ? 'Сервер просит подождать. Повторите смену пароля позже.'
                : 'Сервер просит подождать. Проверка продолжится автоматически.',
          );
        }
      } else if (error.errcode == 'M_UNKNOWN' ||
          (error.response?.statusCode ?? 0) >= 500) {
        retryDelay = Duration(seconds: min(30, retryDelay.inSeconds * 2));
        if (mounted) {
          setState(
            () => status = widget.resetPassword
                ? 'Сервер временно недоступен. Повторите смену пароля позже.'
                : 'Сервер временно недоступен. Проверка продолжится автоматически.',
          );
        }
      } else {
        verificationStopped = !widget.resetPassword && !pendingEmail;
        if (mounted) {
          setState(
            () => status = switch (error.errcode) {
              'M_USER_IN_USE' =>
                'Это имя уже занято. Вернитесь и выберите другое.',
              'M_THREEPID_IN_USE' =>
                'Эта почта уже зарегистрирована. Используйте вход или восстановление пароля.',
              'M_THREEPID_AUTH_FAILED' =>
                'Сначала подтвердите адрес по ссылке из письма.',
              _ =>
                'Сервер не завершил подтверждение. Проверьте письмо и повторите. Код: ${error.errcode}',
            },
          );
        }
      }
    } catch (_) {
      retryDelay = Duration(seconds: min(30, retryDelay.inSeconds * 2));
      if (mounted) {
        setState(
          () => status = sid != null && !widget.resetPassword
              ? 'Нет связи с сервером. Проверка продолжится автоматически после восстановления соединения.'
              : 'Не удалось связаться с сервером. Проверьте соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
      scheduleVerification();
    }
  }

  String? validate(TextEditingController controller, String? value) {
    final text = value ?? '';
    if (controller == username &&
        !RegExp(r'^[a-z0-9._=-]{3,40}$').hasMatch(text)) {
      return 'От 3 до 40 символов: строчные латинские буквы, цифры, . _ = -';
    }
    if (controller == email && !text.contains('@')) {
      return 'Введите адрес электронной почты.';
    }
    if (controller == password && text.length < 12) {
      return 'Используйте не менее 12 символов.';
    }
    if (controller == confirmation && text != password.text) {
      return 'Пароли не совпадают.';
    }
    return null;
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    String? helper,
    Iterable<String>? autofillHints,
  }) => AuthField(
    controller: controller,
    label: label,
    secret: secret,
    helper: helper,
    readOnly: busy || sid != null,
    keyboardType: controller == email ? TextInputType.emailAddress : null,
    inputFormatters: controller == username
        ? [
            TextInputFormatter.withFunction(
              (_, value) => value.copyWith(text: value.text.toLowerCase()),
            ),
          ]
        : null,
    autofillHints: autofillHints,
    validator: (value) => validate(controller, value),
    onSubmitted: controller == confirmation ? submit : null,
  );

  Widget pair(Widget first, Widget second) =>
      !widget.resetPassword &&
          MediaQuery.sizeOf(context).width >= 900 &&
          MediaQuery.textScalerOf(context).scale(16) <= 20
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: 16),
            Expanded(child: second),
          ],
        )
      : Column(children: [first, second]);

  @override
  Widget build(BuildContext context) {
    final reset = widget.resetPassword;
    final sent = sid != null;
    final short = compactAuthHeight(context);
    final colors = Theme.of(context).colorScheme;
    return AuthPage(
      maxWidth: reset ? 520 : 760,
      onBack: () => Navigator.maybePop(context),
      eyebrow: sent
          ? '02 / ПОДТВЕРЖДЕНИЕ'
          : reset
          ? 'ВОССТАНОВЛЕНИЕ ДОСТУПА'
          : '01 / НОВЫЙ АККАУНТ',
      icon: sent
          ? Icons.mark_email_unread_outlined
          : reset
          ? Icons.key_outlined
          : Icons.person_add_outlined,
      title: sent
          ? 'Проверьте вашу почту'
          : reset
          ? 'Восстановить пароль'
          : 'Начнём знакомство',
      subtitle: sent
          ? reset
                ? 'Откройте ссылку из письма. Затем вернитесь сюда, чтобы сохранить новый пароль.'
                : 'Откройте ссылку из письма. Здесь регистрация завершится автоматически — даже если письмо открыто на другом устройстве. Оставьте эту вкладку открытой.'
          : reset
          ? 'Укажите почту аккаунта и придумайте новый пароль. Мы отправим ссылку для подтверждения.'
          : 'Выберите имя, по которому вас найдут, и настройте доступ к вашим разговорам.',
      child: AutofillGroup(
        child: Form(
          key: formKey,
          child: AuthStage(
            child: Column(
              key: ValueKey(sent ? 'verify-email' : 'account-details'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sent) ...[
                  AuthNotice(email.text.trim(), icon: Icons.alternate_email),
                  const SizedBox(height: 12),
                  const Text(
                    'Не нашли письмо?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Проверьте папку «Спам» и правильность адреса.',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  if (!reset) ...[
                    if (!short)
                      Text(
                        'ПРОФИЛЬ',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    SizedBox(height: short ? 0 : 8),
                    pair(
                      field(
                        username,
                        'Логин · строчные a–z',
                        helper: short
                            ? null
                            : '3–40 символов: строчные a–z, цифры, . _ = -',
                        autofillHints: const [AutofillHints.newUsername],
                      ),
                      field(
                        displayName,
                        'Отображаемое имя (необязательно)',
                        autofillHints: const [AutofillHints.name],
                      ),
                    ),
                    if (!short) const Divider(height: 16),
                    if (!short)
                      Text(
                        'ДОСТУП',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    SizedBox(height: short ? 0 : 8),
                  ],
                  field(
                    email,
                    'Электронная почта',
                    autofillHints: const [AutofillHints.email],
                  ),
                  pair(
                    field(
                      password,
                      'Пароль аккаунта · от 12 символов',
                      secret: true,
                      autofillHints: const [AutofillHints.newPassword],
                    ),
                    field(
                      confirmation,
                      'Повторите пароль',
                      secret: true,
                      autofillHints: const [AutofillHints.newPassword],
                    ),
                  ),
                  if (widget.requireLocalPassphrase)
                    AuthField(
                      controller: localPassphrase,
                      label: reset
                          ? 'Локальная фраза этого профиля'
                          : 'Локальная фраза · от 12 символов',
                      secret: true,
                      readOnly: busy || client != null,
                      error: localPassphraseError,
                      helper: reset
                          ? 'Введите фразу, которой защищены данные этого браузера.'
                          : 'Защищает переписку в этом браузере. Придумайте отдельную фразу и сохраните её в менеджере паролей.',
                    ),
                ],
                if (reset) ...[
                  const AuthNotice(
                    'Смена пароля завершит серверные сессии на устройствах. Для восстановления истории нужен ключ восстановления; локальные ключи сохраняются.',
                    icon: Icons.devices_outlined,
                  ),
                  SizedBox(height: short ? 4 : 12),
                ],
                if (status != null) ...[
                  AuthNotice(status!, error: true),
                  const SizedBox(height: 16),
                ],
                SizedBox(
                  height: 3,
                  child: busy ? const LinearProgressIndicator() : null,
                ),
                const SizedBox(height: 9),
                if (sent && !reset && !verificationStopped)
                  const Text(
                    'Ожидаем подтверждения почты. Вход произойдёт автоматически.',
                    textAlign: TextAlign.center,
                  ),
                if (!sent || reset || verificationStopped)
                  FilledButton.icon(
                    onPressed: busy ? null : submit,
                    icon: Icon(
                      sent ? Icons.check_rounded : Icons.arrow_forward_rounded,
                    ),
                    label: Text(
                      !sent
                          ? 'Отправить письмо'
                          : reset
                          ? 'Почта подтверждена · сменить пароль'
                          : 'Повторить проверку',
                    ),
                  ),
                const SizedBox(height: 4),
                if (sent)
                  TextButton(
                    onPressed: busy || (!reset && client?.isLogged() == true)
                        ? null
                        : () {
                            verificationTimer?.cancel();
                            setState(() {
                              sid = null;
                              session = null;
                              status = null;
                              verificationStopped = false;
                              retryAfter = null;
                              retryDelay = const Duration(seconds: 3);
                            });
                          },
                    child: const Text('Изменить данные'),
                  )
                else
                  TextButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: Text(
                      reset ? 'Вернуться ко входу' : 'Уже есть аккаунт? Войти',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    verificationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in [
      username,
      displayName,
      email,
      password,
      confirmation,
      localPassphrase,
    ]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }
}
