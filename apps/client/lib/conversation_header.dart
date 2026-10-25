import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'conversation_list.dart';
import 'theme.dart';

/// The same controls remain visible on Android, mobile web and desktop.
class ConversationHeader extends StatelessWidget {
  final mx.Room room;
  final String lastSeenLabel;
  final VoidCallback onClose, onProfile;
  final VoidCallback? onInfo, onVoiceCall, onVideoCall;
  const ConversationHeader({
    super.key,
    required this.room,
    required this.onClose,
    required this.onProfile,
    this.lastSeenLabel = '',
    this.onInfo,
    this.onVoiceCall,
    this.onVideoCall,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final presence = roomPresence(room);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final avatarSize = constraints.maxWidth < 360
            ? 44.0
            : compact
            ? 48.0
            : 56.0;
        final buttonStyle = compact
            ? IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                maximumSize: const Size(44, 44),
                padding: const EdgeInsets.all(10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : null;
        return Material(
          color: colors.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Закрыть чат',
                  style: buttonStyle,
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onProfile,
                    child: Padding(
                      padding: EdgeInsets.zero,
                      child: Row(
                        children: [
                          PersonAvatar(
                            name: roomDisplayName(room),
                            client: room.client,
                            url: roomAvatar(room),
                            group: !room.isDirectChat,
                            online: presence == 'В сети',
                            size: avatarSize,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  roomDisplayName(room),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontSize: compact ? 18 : 20,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                Text(
                                  presence,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        fontSize: compact ? 12 : 13,
                                        color: presence == 'В сети'
                                            ? onlinePresenceColor(colors)
                                            : colors.onSurfaceVariant,
                                      ),
                                ),
                                if (lastSeenLabel.isNotEmpty)
                                  Text(
                                    lastSeenLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Участники и настройки чата',
                  style: buttonStyle,
                  onPressed: onInfo,
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
                IconButton.filledTonal(
                  tooltip: 'Голосовой звонок',
                  style: buttonStyle,
                  onPressed: onVoiceCall,
                  icon: const Icon(Icons.call_outlined),
                ),
                IconButton.filledTonal(
                  tooltip: 'Видеозвонок',
                  style: buttonStyle,
                  onPressed: onVideoCall,
                  icon: const Icon(Icons.videocam_outlined),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
