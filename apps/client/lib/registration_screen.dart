import 'dart:math';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;

/// Synapse handles email verification and UIA; the app never validates its own email token.
class RegistrationScreen extends StatefulWidget {
  final mx.Client client;
  final bool resetPassword;
  const RegistrationScreen({
    super.key,
    required this.client,
    this.resetPassword = false,
  });
  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
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
    setState(() => busy = true);
    try {
      if (sid == null) {
        final response = widget.resetPassword
            ? await widget.client.requestTokenToResetPasswordEmail(
                clientSecret,
                email.text.trim(),
                1,
              )
            : await widget.client.requestTokenToRegisterEmail(
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
          await widget.client.changePassword(
            password.text,
            auth: auth,
            logoutDevices: true,
          );
        } else {
          await widget.client.register(
            username: username.text,
            password: password.text,
            initialDeviceDisplayName: 'VoiceChat',
            auth: auth,
          );
          await widget.client.firstSyncReceived;
          if (displayName.text.trim().isNotEmpty) {
            await widget.client.setProfileField(
              widget.client.userID!,
              'displayname',
              {'displayname': displayName.text.trim()},
            );
          }
        }
        if (mounted) Navigator.pop(context, true);
      }
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
      readOnly: sid != null,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.resetPassword ? 'Восстановить пароль' : 'Создать аккаунт',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!widget.resetPassword)
              field(username, 'Имя пользователя · латиницей'),
            if (!widget.resetPassword) field(displayName, 'Отображаемое имя'),
            field(email, 'Электронная почта'),
            field(password, 'Пароль аккаунта · от 12 символов', secret: true),
            field(confirmation, 'Повторите пароль', secret: true),
            Text(status),
            const SizedBox(height: 16),
            if (widget.resetPassword)
              const Text(
                'Смена пароля отзовёт серверные сессии. Для истории по-прежнему нужен ключ восстановления; локальная фраза не меняется.',
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
  );
  @override
  void dispose() {
    for (final c in [username, displayName, email, password, confirmation]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }
}
