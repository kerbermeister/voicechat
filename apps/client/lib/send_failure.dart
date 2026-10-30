import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'user_action_error.dart';

/// Only authored descriptions and known protocol codes reach the UI/local outbox.
/// Never persist exception strings: URLs, headers and server bodies may contain secrets.
({String reason, String recommendation, String? code}) describeSendFailure(
  Object error, {
  bool temporary = false,
}) {
  if (error is UserActionError) {
    return (
      reason: error.message,
      recommendation:
          'Устраните указанную причину и повторите отправку через меню этого сообщения. Если нужно изменить содержимое, отмените отправку и создайте исправленное сообщение.',
      code: null,
    );
  }
  if (error is MatrixException) {
    final code = error.error.name;
    if ([
      MatrixError.M_UNKNOWN_TOKEN,
      MatrixError.M_UNAUTHORIZED,
      MatrixError.M_USER_DEACTIVATED,
    ].contains(error.error)) {
      return (
        reason: 'Сервер не подтвердил доступ к аккаунту.',
        recommendation:
            'Проверьте состояние подключения аккаунта. Не очищайте данные приложения: сообщение сохранено в очереди. После восстановления доступа повторите отправку.',
        code: code,
      );
    }
    if (error.error == MatrixError.M_FORBIDDEN) {
      return (
        reason: temporary
            ? 'Сервер запретил отправку сообщения с таймером.'
            : 'Сервер запретил отправку в этот чат.',
        recommendation:
            'Проверьте членство в чате, права на отправку и принятие приглашения собеседником. Для сообщения с таймером также должна быть доступна серверная функция удаления.',
        code: code,
      );
    }
    if (error.error == MatrixError.M_TOO_LARGE) {
      return (
        reason: 'Сервер отклонил слишком большое сообщение или вложение.',
        recommendation:
            'Отмените отправку через меню сообщения, уменьшите файл или подпись либо разделите вложения и отправьте заново.',
        code: code,
      );
    }
    if (error.error == MatrixError.M_LIMIT_EXCEEDED) {
      return (
        reason: 'Сервер временно ограничил частоту отправки.',
        recommendation:
            'Подождите немного: приложение повторит отправку автоматически. Не создавайте вторую копию сообщения.',
        code: code,
      );
    }
    return (
      reason: 'Сервер вернул ошибку отправки.',
      recommendation:
          'Повторите отправку позже. Если ошибка сохраняется, сообщите администратору код ниже. Сообщение остаётся в очереди.',
      code: code,
    );
  }
  if (error is TimeoutException || error is http.ClientException) {
    return (
      reason: error is TimeoutException
          ? 'Истекло время ожидания подтверждения сервера.'
          : 'Не удалось установить соединение с сервером.',
      recommendation:
          'Проверьте интернет и доступность сервиса. В течение минуты приложение повторяет отправку автоматически, затем ждёт ручного повтора; можно нажать «Повторить сейчас». Повтор использует то же сообщение и не создаёт вторую копию.',
      code: null,
    );
  }
  return (
    reason: 'Отправка не подтверждена; точная причина недоступна.',
    recommendation:
        'Проверьте соединение и состояние аккаунта, затем повторите отправку. Не очищайте данные приложения: сообщение сохранено. Если ошибка повторяется, обратитесь к администратору.',
    code: null,
  );
}
