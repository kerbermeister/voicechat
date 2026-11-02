import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'call_controller.dart';
import 'call_window.dart';

/// Keeps chat routes mounted but inaccessible while answering over the keyguard.
class AndroidCallScreen extends ChangeNotifier {
  static final instance = AndroidCallScreen();
  static const channel = MethodChannel('voicechat/call_screen');
  bool active = false;
  CallController? calls;

  Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'show') {
        active = call.arguments == true;
        notifyListeners();
      }
    });
    active = await channel.invokeMethod<bool>('state') ?? false;
  }

  void attach(CallController? value) {
    calls = value;
    notifyListeners();
  }

  Future<void> hide() => channel.invokeMethod<void>('hide');
}

class AndroidCallScreenGate extends StatelessWidget {
  final Widget child;
  final Future<void> Function() audioOutput;
  const AndroidCallScreenGate({
    super.key,
    required this.child,
    required this.audioOutput,
  });

  @override
  Widget build(BuildContext context) {
    final screen = AndroidCallScreen.instance;
    return AnimatedBuilder(
      animation: screen,
      builder: (context, _) {
        if (screen.active) {
          // The native curtain stays above Flutter until this frame hides chats.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (screen.active) {
              AndroidCallScreen.channel.invokeMethod<void>('ready');
            }
          });
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(offstage: screen.active, child: child),
            if (screen.active)
              HeroControllerScope.none(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => ListenableBuilder(
                      listenable: screen,
                      builder: (context, _) => screen.calls == null
                          ? const Scaffold(
                              body: Center(child: CircularProgressIndicator()),
                            )
                          : CallWindow(
                              calls: screen.calls!,
                              audioOutput: audioOutput,
                              onMinimize: screen.hide,
                            ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
