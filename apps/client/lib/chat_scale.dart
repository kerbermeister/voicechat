import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_motion.dart';

class ChatScale extends ChangeNotifier {
  static const baseline = 80.0, minimum = 60.0, maximum = 120.0;
  static const messageKey = 'chat_message_scale',
      contactKey = 'chat_contact_scale';
  double messages = baseline, contacts = baseline;
  Future<void> _saving = Future.value();
  bool _changed = false;

  static double valid(double? value) => value != null && value.isFinite
      ? value.clamp(minimum, maximum)
      : baseline;

  void load(SharedPreferences preferences) {
    if (_changed) return;
    final storedMessages = preferences.get(messageKey),
        storedContacts = preferences.get(contactKey);
    messages = valid(storedMessages is num ? storedMessages.toDouble() : null);
    contacts = valid(storedContacts is num ? storedContacts.toDouble() : null);
    notifyListeners();
  }

  Future<void> change({double? messages, double? contacts}) {
    _changed = true;
    this.messages = valid(messages ?? this.messages);
    this.contacts = valid(contacts ?? this.contacts);
    notifyListeners();
    final messageValue = this.messages, contactValue = this.contacts;
    final save = _saving.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setDouble(messageKey, messageValue) ||
          !await preferences.setDouble(contactKey, contactValue)) {
        throw StateError('Не удалось сохранить масштаб');
      }
    });
    _saving = save.catchError((Object _) {});
    return save;
  }
}

class ChatScaleScope extends InheritedNotifier<ChatScale> {
  const ChatScaleScope({
    super.key,
    required ChatScale scale,
    required super.child,
  }) : super(notifier: scale);
  static ChatScale? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatScaleScope>()?.notifier;
}

/// FittedBox lays out at the logical width before scaling both paint and hit tests.
/// The composer, navigation and system accessibility text scale remain independent.
class ChatScaled extends StatelessWidget {
  final double percent;
  final Widget child;
  const ChatScaled({super.key, required this.percent, required this.child});
  @override
  Widget build(BuildContext context) {
    final factor = ChatScale.valid(percent) / ChatScale.baseline;
    if (factor == 1) return child;
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.maxWidth,
        child: FittedBox(
          fit: BoxFit.fitWidth,
          alignment: Alignment.topCenter,
          child: SizedBox(width: constraints.maxWidth / factor, child: child),
        ),
      ),
    );
  }
}

class ChatScaleDialog extends StatelessWidget {
  final ChatScale scale;
  const ChatScaleDialog({super.key, required this.scale});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scale,
    builder: (context, _) {
      Widget slider(String label, double value, ValueChanged<double> change) =>
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label · ${value.round()}%'),
              Slider(
                value: value,
                min: ChatScale.minimum,
                max: ChatScale.maximum,
                divisions: 12,
                label: '${value.round()}%',
                semanticFormatterCallback: (value) =>
                    '$label: ${value.round()}%',
                onChanged: change,
              ),
            ],
          );
      void save({double? messages, double? contacts}) {
        scale.change(messages: messages, contacts: contacts).catchError((
          Object _,
        ) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Не удалось сохранить масштаб. Повторите настройку.',
                ),
              ),
            );
          }
        });
      }

      return AlertDialog(
        title: AppDialogTitle(child: const Text('Масштаб')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                slider(
                  'Сообщения',
                  scale.messages,
                  (value) => save(messages: value),
                ),
                slider(
                  'Люди и группы',
                  scale.contacts,
                  (value) => save(contacts: value),
                ),
                const Text(
                  '80% — исходный размер. Настройки сохраняются на этом устройстве.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => save(messages: 80, contacts: 80),
            child: const Text('Исходный размер'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      );
    },
  );
}
