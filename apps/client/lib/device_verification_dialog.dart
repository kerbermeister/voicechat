import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'device_verification.dart';
import 'device_qr_scanner.dart';
import 'voice_call.dart';

Future<void> showDeviceVerification(
  BuildContext context,
  DeviceVerifications owner,
  KeyVerification request, {
  VoiceCall? call,
}) async {
  if (owner.viewing != null) return;
  owner.viewing = request;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _VerificationDialog(owner: owner, request: request, call: call),
    );
  } finally {
    if (!request.isDone) {
      try {
        await request.cancel('m.user').timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    owner.viewing = null;
    owner.forget(request);
  }
}

class _VerificationDialog extends StatefulWidget {
  final DeviceVerifications owner;
  final KeyVerification request;
  final VoiceCall? call;
  const _VerificationDialog({
    required this.owner,
    required this.request,
    this.call,
  });
  @override
  State<_VerificationDialog> createState() => _VerificationDialogState();
}

class _VerificationDialogState extends State<_VerificationDialog> {
  bool busy = false;
  String? error;
  Future<void> scan() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final bytes = await scanDeviceQr(
        context,
        widget.owner,
        widget.request,
        call: widget.call,
      );
      if (bytes == null) return;
      try {
        if (!widget.request.isDone) {
          await widget.request
              .continueVerification(
                EventTypes.Reciprocate,
                qrDataRawBytes: bytes,
              )
              .timeout(const Duration(seconds: 15));
        }
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось прочитать код. Повторите сканирование или сравните эмодзи.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action().timeout(const Duration(seconds: 15));
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось продолжить. Проверьте соединение или отмените запрос.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.owner,
    builder: (context, _) {
      final request = widget.request;
      final completed = widget.owner.completed.contains(request);
      return AlertDialog(
        title: Text(
          completed ? 'Устройство подтверждено' : 'Проверка устройства',
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${request.userId}\nУстройство: ${request.deviceId ?? 'ожидаем ответ'}',
                ),
                const SizedBox(height: 16),
                if (completed)
                  const Text(
                    'Ключ проверен независимо и сохранён на этом устройстве.',
                  )
                else if (request.canceled ||
                    request.state == KeyVerificationState.error)
                  Text(
                    request.canceledCode == 'm.timeout'
                        ? 'Время проверки истекло. Создайте новый запрос.'
                        : request.canceledCode == 'm.mismatched_sas'
                        ? 'Коды не совпали. Устройство не подтверждено.'
                        : request.canceledCode == 'm.invalid_key'
                        ? 'QR не соответствует этому запросу или ключам устройства. Начните проверку заново.'
                        : 'Проверка отменена. Новое доверие не подтверждено.',
                  )
                else if (request.state == KeyVerificationState.askAccept)
                  const Text(
                    'На другом устройстве запросили независимую сверку ключей. Принимайте запрос, только если вы начали проверку с этим человеком.',
                  )
                else if (request.state == KeyVerificationState.askSas) ...[
                  const Text(
                    'Сравните все семь эмодзи и три числа на обоих устройствах лично или по независимому доверенному каналу.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final emoji in request.sasEmojis)
                        Tooltip(
                          message: emoji.name,
                          child: Text(
                            emoji.emoji,
                            style: const TextStyle(fontSize: 34),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    request.sasNumbers.join('  '),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ] else if (request.state == KeyVerificationState.askChoice) ...[
                  const Text(
                    'Сравните эмодзи или сканируйте QR с другого устройства лично.',
                  ),
                  if (request.qrCode != null &&
                      request.possibleMethods.contains(EventTypes.QRShow))
                    Center(
                      child: QrImageView.withQr(
                        qr: QrCode.fromUint8List(
                          data: Uint8List.fromList(
                            request.qrCode!.qrDataRawBytes,
                          ),
                          errorCorrectLevel: QrErrorCorrectLevel.M,
                        ),
                        size: 240,
                        padding: const EdgeInsets.all(20),
                        backgroundColor: Colors.white,
                        semanticsLabel: 'QR для текущей проверки устройства',
                      ),
                    ),
                ] else if (request.state == KeyVerificationState.showQRSuccess)
                  const Text(
                    'QR совпал с ожидаемыми ключами. Покажите этот результат человеку рядом и дождитесь подтверждения на другом устройстве.',
                  )
                else if (request.state == KeyVerificationState.confirmQRScan)
                  const Text(
                    'Другое устройство сообщает об успешном сканировании. Подтверждайте только если вы видите успешный результат на нём лично.',
                  )
                else if (request.state == KeyVerificationState.askSSSS)
                  const Text(
                    'Можно подтвердить это устройство без восстановления всей истории. Доступ к старым сообщениям восстанавливается отдельно в настройках.',
                  )
                else
                  const Text(
                    'Ждём ответ и подтверждение на другом устройстве. Запрос действует не более 10 минут.',
                  ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (error ?? widget.owner.errors[request]
                    case final String failure)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      failure,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
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
            child: Text(request.isDone ? 'Закрыть' : 'Отмена'),
          ),
          if (!request.isDone &&
              request.state == KeyVerificationState.askAccept)
            FilledButton(
              onPressed: busy ? null : () => act(request.acceptVerification),
              child: const Text('Принять проверку'),
            ),
          if (!request.isDone &&
              request.state == KeyVerificationState.askChoice)
            FilledButton(
              onPressed: busy
                  ? null
                  : () =>
                        act(() => request.continueVerification(EventTypes.Sas)),
              child: const Text('Сравнить эмодзи'),
            ),
          if (!request.isDone &&
              request.state == KeyVerificationState.askChoice &&
              request.possibleMethods.contains(EventTypes.QRScan))
            OutlinedButton(
              onPressed: busy ? null : scan,
              child: const Text('Сканировать QR'),
            ),
          if (!request.isDone &&
              request.state == KeyVerificationState.confirmQRScan)
            FilledButton(
              onPressed: busy
                  ? null
                  : () => act(request.acceptQRScanConfirmation),
              child: const Text('Вижу успешное сканирование'),
            ),
          if (!request.isDone && request.state == KeyVerificationState.askSSSS)
            FilledButton(
              onPressed: busy
                  ? null
                  : () => act(() => request.openSSSS(skip: true)),
              child: const Text('Продолжить сверку устройства'),
            ),
          if (!request.isDone &&
              request.state == KeyVerificationState.askSas) ...[
            OutlinedButton(
              onPressed: busy ? null : () => act(request.rejectSas),
              child: const Text('Не совпадают'),
            ),
            FilledButton(
              onPressed: busy ? null : () => act(request.acceptSas),
              child: const Text('Совпадают'),
            ),
          ],
        ],
      );
    },
  );
}
