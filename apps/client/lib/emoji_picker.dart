import 'app_motion.dart';
import 'package:flutter/material.dart';

// Unicode characters, rendered by the device; no remote image requests from chats.
const emojiCategories = <String, String>{
  'Смайлики':
      '👍 ❤️ 🎉 🙏 😀 😃 😄 😁 😆 😅 😂 🤣 😊 🙂 🙃 😉 😍 🥰 😘 😗 😙 😚 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🫢 🫣 🤫 🤔 🫡 🤐 🤨 😐 😑 😶 🫥 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 🥸 😎 🤓 🧐 😕 🫤 😟 🙁 ☹️ 😮 😯 😲 😳 🥺 🥹 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 ☠️ 💩 🤡 👻 👽 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾',
  'Жесты':
      '👋 🤚 🖐️ ✋ 🖖 🫱 🫲 🫳 🫴 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 🫵 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 🤝 🙏 💪 🦾 ✍️ 💅 🤳 🦵 🦶 👂 👃 🧠 👀 👁️ 👅 👄',
  'Любовь':
      '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 🩷 🩵 🩶 💔 ❤️‍🔥 ❤️‍🩹 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 💌 💋 💯 💢 💥 💫 💦 💨 🕳️ 💬 🗨️ 🗯️ 💭 💤 ✨ 🌟 ⭐ 🔥 🎉 🎊 🎈 🎁 🎀 🥂 💐 🌹',
  'Природа':
      '🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦋 🐝 🐞 🐢 🐍 🦎 🦖 🐙 🐠 🐟 🐬 🐳 🦈 🐘 🦒 🦓 🦔 🐾 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🍁 🍂 🍃 🌸 🌼 🌻 🌺 🌷 🌍 🌎 🌏 🌙 ☀️ 🌤️ 🌧️ ⛈️ 🌈 ❄️ ☃️ 🌊',
  'Еда':
      '🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🥦 🥒 🥕 🌽 🥔 🍞 🥐 🥨 🧀 🥚 🍳 🥞 🥓 🥩 🍗 🍔 🍟 🍕 🌮 🌯 🥙 🥗 🍝 🍜 🍣 🍱 🥟 🍦 🍨 🍩 🍪 🎂 🍰 🧁 🍫 🍬 🍭 🍯 🥛 ☕ 🍵 🧃 🥤 🧋 🍺 🍷 🥂',
  'Дела':
      '🏠 🏡 🏢 🏥 🏫 🏖️ ⛰️ 🏕️ 🌅 🌇 🌉 🚗 🚕 🚌 🚎 🚲 🛵 🏍️ 🚆 🚇 🚀 ✈️ 🚁 🚢 ⛵ ⚽ 🏀 🏈 ⚾ 🎾 🏐 🏓 🏸 🥊 🏊 🏃 🚶 🧘 🏆 🥇 🎮 🎲 🎯 🎨 🎭 🎤 🎧 🎼 🎹 🎸 🎺 🥁 📱 💻 🖥️ ⌨️ 📷 🎥 📚 📖 📝 ✏️ 📌 📎 📅 ⏰ ✅ ☑️ ❌ ❎ ❓ ❗ ⚠️ ⛔ 🚫 💡 🔑 🔒 🔓 🛠️ ⚙️ ❤️ 👍',
};

Future<String?> pickEmoji(BuildContext context) => showAppDialog<String>(
  context: context,
  animationStyle: appAnimationStyle(context),
  builder: (_) => const _EmojiPicker(),
);

class _EmojiPicker extends StatefulWidget {
  const _EmojiPicker();
  @override
  State<_EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<_EmojiPicker> {
  String category = emojiCategories.keys.first;
  @override
  Widget build(BuildContext context) {
    final emoji = emojiCategories[category]!.split(' ');
    return AlertDialog(
      title: AppDialogTitle(child: const Text('Эмодзи')),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final name in emojiCategories.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: name == category,
                        onSelected: (_) => setState(() => category = name),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 52,
                  mainAxisExtent: 48,
                ),
                itemCount: emoji.length,
                itemBuilder: (_, i) => IconButton(
                  tooltip: emoji[i],
                  onPressed: () => Navigator.pop(context, emoji[i]),
                  icon: ExcludeSemantics(
                    child: Text(emoji[i], style: const TextStyle(fontSize: 25)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
