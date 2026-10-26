import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_version.dart';

class MacOSUpdateDialog extends StatefulWidget {
  static const channel = MethodChannel('voicechat/macos_update');
  final Future<String?> Function() prepareInstall;
  const MacOSUpdateDialog({super.key, required this.prepareInstall});
  @override
  State<MacOSUpdateDialog> createState() => _MacOSUpdateDialogState();
}

class _MacOSUpdateDialogState extends State<MacOSUpdateDialog> {
  Map<String, dynamic> state = {'phase': 'idle'};
  String version = appVersion, buildNumber = '$appBuild';
  bool commanding = false;
  bool closing = false;
  String get phase => state['phase'] as String? ?? 'idle';
  bool get locked => phase == 'extracting' || phase == 'installing';

  @override
  void initState() {
    super.initState();
    MacOSUpdateDialog.channel.setMethodCallHandler((call) async {
      if (!mounted || closing) return 'Окно обновления закрыто.';
      if (call.method == 'prepareInstall') return widget.prepareInstall();
      if (call.method == 'state') {
        setState(
          () => state = Map<String, dynamic>.from(call.arguments as Map),
        );
      }
      return null;
    });
    readInfo();
  }

  Future<void> readInfo() async {
    try {
      final info = await MacOSUpdateDialog.channel
          .invokeMapMethod<String, dynamic>('info');
      if (mounted && info != null) {
        setState(() {
          version = info['version'] as String;
          buildNumber = info['build'] as String;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(
          () => state['message'] = 'Не удалось прочитать версию приложения.',
        );
      }
    }
  }

  Future<void> command(String method) async {
    if (commanding || closing) return;
    setState(() => commanding = true);
    try {
      if (method == 'download' || method == 'install') {
        final reason = await widget.prepareInstall();
        if (!mounted || closing) return;
        if (reason != null) {
          setState(() => state['message'] = reason);
          return;
        }
      }
      await MacOSUpdateDialog.channel.invokeMethod<void>(method);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => state['message'] =
              error.message ??
              'Не удалось обновить приложение. Повторите попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => commanding = false);
    }
  }

  Future<void> close() async {
    if (locked || commanding || closing) return;
    closing = true;
    try {
      await MacOSUpdateDialog.channel.invokeMethod<void>('cancel');
      if (mounted) Navigator.pop(context);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          closing = false;
          state['message'] = error.message ?? 'Не удалось отменить обновление.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = (state['size'] as num?)?.toDouble() ?? 0;
    final received = (state['received'] as num?)?.toDouble() ?? 0;
    final busy = phase == 'checking' || phase == 'downloading' || locked;
    return PopScope(
      canPop: !locked && !commanding,
      child: AlertDialog(
        title: const Text('О приложении'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('VoiceChat $version (сборка $buildNumber)'),
                if ((state['message'] as String? ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(state['message'] as String),
                    ),
                  ),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(
                      value: phase == 'downloading' && size > 0
                          ? (received / size).clamp(0, 1)
                          : null,
                    ),
                  ),
                if (state['version'] != null && phase != 'idle') ...[
                  const SizedBox(height: 16),
                  Text(
                    '${state['version']} (сборка ${state['build']}) · ${(size / 1048576).toStringAsFixed(1)} МБ',
                  ),
                  Text('macOS ${state['minimumOS']} и новее'),
                  const SizedBox(height: 8),
                  Text(state['notes'] as String? ?? ''),
                  const SizedBox(height: 8),
                  const Text(
                    'При установке приложение закроется и запустится снова. Аккаунт и локальные данные сохраняются.',
                  ),
                ],
                if (!busy) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: commanding
                        ? null
                        : () => command(
                            phase == 'available'
                                ? 'download'
                                : phase == 'ready'
                                ? 'install'
                                : 'check',
                          ),
                    child: Text(
                      phase == 'available'
                          ? 'Скачать и установить'
                          : phase == 'ready'
                          ? 'Продолжить установку'
                          : 'Проверить обновления',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (phase == 'checking' || phase == 'downloading')
            TextButton(
              onPressed: commanding ? null : () => command('cancel'),
              child: const Text('Отменить'),
            ),
          TextButton(
            onPressed: locked || commanding ? null : close,
            child: Text(phase == 'available' ? 'Не сейчас' : 'Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    closing = true;
    MacOSUpdateDialog.channel
        .invokeMethod<void>('cancel')
        .catchError((Object _) {});
    MacOSUpdateDialog.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
