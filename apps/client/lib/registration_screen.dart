import 'dart:math';
import 'package:flutter/material.dart';
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

class _RegistrationScreenState extends State<RegistrationScreen> {
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
  String status = 'Подтвердите почту, затем завершите регистрацию.';

  Future<void> submit() async {
    if (busy) return;
    if (!email.text.contains('@') ||
        password.text.length < 12 ||
        password.text != confirmation.text ||
        (!widget.resetPassword &&
            !RegExp(r'^[a-z0-9._=-]{3,40}$').hasMatch(username.text))) {
      setState(
        () => status =
            'Нужны почта, username (3–40 латинских символов) и совпадающие пароли от 12 символов.',
      );
      return;
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
    setState(() => busy = true);
    try {
      client ??= await widget.openClient(
        widget.requireLocalPassphrase ? localPassphrase.text : null,
      );
      if (!mounted) return;
      if (sid == null) {
        final response = widget.resetPassword
            ? await client!.requestTokenToResetPasswordEmail(
                clientSecret,
                email.text.trim(),
                1,
              )
            : await client!.requestTokenToRegisterEmail(
                clientSecret,
                email.text.trim(),
                1,
              );
        sid = response.sid;
        if (mounted) {
          setState(
            () => status =
                'Письмо отправлено. Откройте ссылку подтверждения, затем вернитесь сюда. На локальном стенде почта: http://localhost:8025',
          );
        }
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
          await client!.register(
            username: username.text,
            password: password.text,
            initialDeviceDisplayName: 'VoiceChat',
            auth: auth,
          );
          await client!.firstSyncReceived;
          if (displayName.text.trim().isNotEmpty) {
            await client!.setProfileField(client!.userID!, 'displayname', {
              'displayname': displayName.text.trim(),
            });
          }
        }
        if (!widget.resetPassword) widget.onRegistered?.call(password.text);
        if (mounted) Navigator.pop(context, true);
      }
    } on UserActionError catch (error) {
      if (mounted) setState(() => status = error.message);
    } on mx.MatrixException catch (error) {
      session = error.session ?? session;
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
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              status = 'Не удалось связаться с сервером. Проверьте соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      readOnly: busy || sid != null,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
    appBar: AppBar(
      title: Text(
        widget.resetPassword ? 'Восстановить пароль' : 'Создать аккаунт',
      ),
    ),
    body: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (!widget.resetPassword)
                  field(username, 'Имя пользователя · латиницей'),
                if (!widget.resetPassword)
                  field(displayName, 'Отображаемое имя'),
                field(email, 'Электронная почта'),
                field(
                  password,
                  'Пароль аккаунта · от 12 символов',
                  secret: true,
                ),
                field(confirmation, 'Повторите пароль', secret: true),
                if (widget.requireLocalPassphrase) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: localPassphrase,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      readOnly: busy || client != null,
                      decoration: InputDecoration(
                        labelText: widget.resetPassword
                            ? 'Локальная фраза этого профиля'
                            : 'Локальная фраза · от 12 символов',
                        helperText: widget.resetPassword
                            ? 'Введите фразу, которой защищены данные этого браузера.'
                            : 'Защищает переписку в этом браузере. Придумайте отдельную фразу и сохраните её в менеджере паролей.',
                        helperMaxLines: 4,
                        errorText: localPassphraseError,
                        errorMaxLines: 3,
                      ),
                    ),
                  ),
                ],
                Text(status),
                const SizedBox(height: 16),
                if (widget.resetPassword)
                  const Text(
                    'Смена пароля отзовёт серверные сессии. Для истории по-прежнему нужен ключ восстановления; локальные ключи сохраняются.',
                  ),
                const SizedBox(height: 16),
                if (busy) const LinearProgressIndicator(),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(
                    sid == null
                        ? 'Отправить письмо'
                        : widget.resetPassword
                        ? 'Почта подтверждена · сменить пароль'
                        : 'Почта подтверждена · создать аккаунт',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  @override
  void dispose() {
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
