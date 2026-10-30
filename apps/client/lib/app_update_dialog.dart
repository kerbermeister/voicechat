import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'app_version.dart';
import 'macos_update_dialog.dart';
import 'app_update.dart';
import 'update_platform.dart';

const updateChannel = MethodChannel('voicechat/update');

class AppUpdateDialog extends StatefulWidget {
  final Future<String?> Function() prepareInstall;
  final String origin;
  final http.Client Function()? createClient;
  final Map<String, String>? Function()? updateRoute;
  const AppUpdateDialog({
    super.key,
    required this.prepareInstall,
    this.origin = updateOrigin,
    this.createClient,
    this.updateRoute,
  });
  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog>
    with WidgetsBindingObserver {
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Map<String, dynamic>? installed;
  AppUpdate? update;
  http.Client? client;
  String? path;
  String message = '';
  bool busy = false, waitingPermission = false, installing = false;
  int bytes = 0, generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (android) {
      updateChannel.setMethodCallHandler((call) async {
        if (call.method == 'stateChanged') await readInstalled();
      });
      unawaited(readInstalled());
    }
  }

  Future<void> readInstalled() async {
    try {
      final info = await updateChannel.invokeMapMethod<String, dynamic>('info');
      if (!mounted) return;
      setState(() {
        if (installing && info?['pending'] != true) {
          path = null;
          update = null;
          bytes = 0;
          waitingPermission = false;
        }
        installed = info;
        installing = info?['pending'] == true;
        if ((info?['status'] as String? ?? '').isNotEmpty) {
          message = info!['status'] as String;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Не удалось прочитать версию приложения.');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && client != null) cancel();
    if (state == AppLifecycleState.resumed && android && !busy) {
      unawaited(readInstalled());
    }
  }

  void cancel() {
    generation++;
    client?.close();
    client = null;
    if (mounted) {
      setState(() {
        busy = false;
        message = 'Проверка или загрузка отменена.';
      });
    }
  }

  Future<void> check() async {
    if (busy || installed == null || installing) return;
    final current = ++generation;
    final network = widget.createClient?.call() ?? http.Client();
    client = network;
    setState(() {
      busy = true;
      update = null;
      path = null;
      message = 'Проверяем обновления…';
    });
    try {
      final next = await checkAppUpdate(
        network,
        widget.origin,
        installed!['applicationId'] as String,
      );
      if (!mounted || current != generation) return;
      setState(() {
        if (next.versionCode <= (installed!['versionCode'] as int)) {
          message = 'Обновлений нет.';
        } else if (next.minSdk > (installed!['sdk'] as int)) {
          message = 'Новая версия не поддерживает эту версию Android.';
        } else {
          update = next;
          message = 'Доступно обновление.';
        }
      });
    } catch (error) {
      showError(error, current);
    } finally {
      network.close();
      if (current == generation) {
        client = null;
        if (mounted) setState(() => busy = false);
      }
    }
  }

  void showError(Object error, int current) {
    if (!mounted || current != generation) return;
    setState(
      () => message = switch (error) {
        FormatException e => e.message,
        PlatformException e => e.message ?? 'Android отклонил установку.',
        _ => 'Не удалось выполнить действие. Проверьте соединение и повторите.',
      },
    );
  }

  Future<void> download() async {
    if (busy || update == null) return;
    final current = ++generation;
    final selectedUpdate = update!;
    final network = widget.createClient?.call() ?? http.Client();
    String? target;
    var verified = false;
    client = network;
    setState(() {
      busy = true;
      bytes = 0;
      message = 'Загружаем обновление…';
    });
    try {
      target = (await updateChannel.invokeMethod<String>('prepare'))!;
      if (current != generation || !mounted) return;
      await downloadUpdate(network, widget.origin, selectedUpdate, target, (
        value,
      ) {
        if (mounted && current == generation) setState(() => bytes = value);
      }, () => current != generation || !mounted);
      if (!mounted || current != generation) return;
      await updateChannel.invokeMethod<void>('verify', {
        ...selectedUpdate.installArguments,
        'path': target,
      });
      if (!mounted || current != generation) return;
      path = target;
      verified = true;
    } catch (error) {
      if (current == generation) path = null;
      showError(error, current);
    } finally {
      network.close();
      if (!verified && target != null) {
        await updateChannel
            .invokeMethod<void>('discard', {'path': target})
            .catchError((Object _) {});
      }
      if (current == generation) {
        client = null;
        if (mounted) setState(() => busy = false);
      }
    }
    if (mounted && current == generation && path != null) await install();
  }

  Future<void> install() async {
    if (busy || path == null || update == null) return;
    final current = generation;
    setState(() => busy = true);
    try {
      final reason = await widget.prepareInstall();
      if (!mounted || current != generation) return;
      if (reason != null) {
        setState(() => message = reason);
        return;
      }
      final allowed =
          await updateChannel.invokeMethod<bool>('allowed') ?? false;
      if (!mounted) return;
      if (!allowed) {
        setState(() {
          waitingPermission = true;
          message =
              'Разрешите VoiceChat устанавливать обновления в настройках Android. Затем нажмите «Продолжить установку».';
        });
        return;
      }
      final finalReason = await widget.prepareInstall();
      if (!mounted || current != generation) return;
      if (finalReason != null) {
        setState(() => message = finalReason);
        return;
      }
      await updateChannel.invokeMethod<void>('install', {
        ...update!.installArguments,
        'path': path!,
      });
      if (mounted) {
        setState(() {
          installing = true;
          waitingPermission = false;
          message =
              'Подтвердите установку в окне Android. После обновления откройте VoiceChat.';
        });
      }
    } catch (error) {
      showError(error, current);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      return MacOSUpdateDialog(
        prepareInstall: widget.prepareInstall,
        updateRoute: widget.updateRoute,
      );
    }
    final version = installed?['versionName'] ?? appVersion;
    final build = installed?['versionCode'] ?? appBuild;
    return PopScope(
      canPop: !(busy && client == null),
      child: AlertDialog(
        title: const Text('О приложении'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('VoiceChat $version (сборка $build)'),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(liveRegion: true, child: Text(message)),
                  ),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(
                      value: bytes > 0 && update != null
                          ? bytes / update!.sizeBytes
                          : null,
                    ),
                  ),
                if (bytes > 0 && update != null)
                  Text(
                    '${(bytes / 1048576).toStringAsFixed(1)} / ${(update!.sizeBytes / 1048576).toStringAsFixed(1)} МБ',
                  ),
                if (update != null && !installing) ...[
                  const SizedBox(height: 16),
                  Text(
                    '${update!.versionName} (сборка ${update!.versionCode}) · ${(update!.sizeBytes / 1048576).toStringAsFixed(1)} МБ',
                  ),
                  const SizedBox(height: 8),
                  Text(update!.notes),
                  const SizedBox(height: 8),
                  const Text(
                    'При установке приложение закроется. Аккаунт и локальные данные сохраняются при совместимом обновлении.',
                  ),
                ],
                if (android && !busy && !installing) ...[
                  const SizedBox(height: 16),
                  if (waitingPermission)
                    TextButton(
                      onPressed: () async {
                        try {
                          await updateChannel.invokeMethod<void>('settings');
                        } catch (error) {
                          showError(error, generation);
                        }
                      },
                      child: const Text('Открыть настройки Android'),
                    ),
                  if (update != null)
                    FilledButton(
                      onPressed: path == null ? download : install,
                      child: Text(
                        path == null
                            ? 'Скачать и установить'
                            : 'Продолжить установку',
                      ),
                    )
                  else
                    FilledButton(
                      onPressed: installed == null ? null : check,
                      child: const Text('Проверить обновления'),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (busy && client != null)
            TextButton(onPressed: cancel, child: const Text('Отменить')),
          TextButton(
            onPressed: busy && client == null
                ? null
                : () => Navigator.pop(context),
            child: Text(
              update != null && path == null ? 'Не сейчас' : 'Закрыть',
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    generation++;
    client?.close();
    if (path != null) {
      unawaited(
        updateChannel
            .invokeMethod<void>('discard', {'path': path!})
            .catchError((Object _) {}),
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    if (android) updateChannel.setMethodCallHandler(null);
    super.dispose();
  }
}
