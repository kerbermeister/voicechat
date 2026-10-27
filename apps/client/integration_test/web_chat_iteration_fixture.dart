import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/chat_scale.dart';
import 'package:voicechat_probe/link_cards.dart';
import 'package:voicechat_probe/resizable_chat_layout.dart';
import 'package:voicechat_probe/theme.dart';
import 'audio_playback_fixture.dart';

// Standalone UI fixture: generated media only, no authentication or user storage.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  runApp(const Fixture());
}

class Fixture extends StatefulWidget {
  const Fixture({super.key});
  @override
  State<Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<Fixture> {
  final scale = ChatScale();
  late final room = mx.Room(
    id: '!ui-fixture:local',
    client: AudioFixtureClient(),
  );
  late final first = AudioFixtureEvent(room, 'first', milliseconds: 4000),
      second = AudioFixtureEvent(room, 'second', milliseconds: 6000);
  late final cover = base64Encode(
    img.encodePng(
      img.Image(width: 640, height: 360)..clear(img.ColorRgb8(30, 70, 125)),
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppPalette.halo.theme,
    builder: (_, child) => ChatScaleScope(scale: scale, child: child!),
    home: Scaffold(
      body: Builder(
        builder: (context) => ResizableChatLayout(
          sidebar: (compact) => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: ListenableBuilder(
              listenable: scale,
              builder: (_, _) => ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('VoiceChat · тестовый чат'),
                  ),
                  TextButton(
                    onPressed: () => showAppDialog<void>(
                      context: context,
                      clearBackdrop: true,
                      builder: (_) => ChatScaleDialog(scale: scale),
                    ),
                    child: const Text('Масштаб'),
                  ),
                  for (final name in ['Алексей', 'Семья', 'Моя комната'])
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: ChatScaled(
                        percent: scale.contacts,
                        child: ListTile(
                          leading: CircleAvatar(child: Text(name[0])),
                          title: Text(name),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          conversation: Column(
            children: [
              ListTile(
                title: const Text('Семья · тестовые данные'),
                trailing: IconButton(
                  tooltip: 'Информация о группе',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(
                      title: AppDialogTitle(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(radius: 48, child: Icon(Icons.groups)),
                            SizedBox(height: 12),
                            Text('Семья'),
                          ],
                        ),
                      ),
                      content: Text('Только синтетические данные'),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: scale,
                  builder: (_, _) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      ChatScaled(
                        percent: scale.messages,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AttachmentView(event: first, volume: 0),
                              const SizedBox(height: 12),
                              AttachmentView(event: second, volume: 0),
                              LinkCards(
                                text:
                                    'https://www.youtube.com/watch?v=abcdefghijk',
                                previews: [
                                  {
                                    'url':
                                        'https://www.youtube.com/watch?v=abcdefghijk',
                                    'title':
                                        'Проверка пропорций обложки и компактной подписи',
                                    'description': 'Синтетическая карточка',
                                    'image': cover,
                                  },
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
