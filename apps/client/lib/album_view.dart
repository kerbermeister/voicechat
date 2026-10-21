import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'photo_viewer.dart';

List<mx.Event> albumPhotos(mx.Event event) {
  final images = event.content['images'];
  if (images is! List || images.isEmpty || images.length > 64) {
    throw const FormatException('Invalid album');
  }
  return [
    for (var i = 0; i < images.length; i++)
      mx.Event.fromJson({
        'event_id': '${event.eventId}/$i',
        'type': mx.EventTypes.Message,
        'sender': event.senderId,
        'origin_server_ts': event.originServerTs.millisecondsSinceEpoch,
        'content': Map<String, dynamic>.from(images[i] as Map),
      }, event.room),
  ];
}

Future<Uint8List> loadPhoto(mx.Event event) async {
  final size = event.infoMap['size'];
  if (event.messageType != mx.MessageTypes.Image ||
      !event.isAttachmentEncrypted ||
      size is! int ||
      size <= 0 ||
      size > 10485760) {
    throw const FormatException('Invalid encrypted photo');
  }
  final file = await event.downloadAndDecryptAttachment();
  if (file.bytes.length != size) {
    throw const FormatException('Photo size mismatch');
  }
  return file.bytes;
}

class AlbumView extends StatefulWidget {
  final mx.Event event;
  const AlbumView({super.key, required this.event});
  @override
  State<AlbumView> createState() => _AlbumViewState();
}

class _AlbumViewState extends State<AlbumView> {
  List<mx.Event> photos = [];
  final loaded = <int, Future<Uint8List>>{};
  @override
  void initState() {
    super.initState();
    try {
      photos = albumPhotos(widget.event);
    } catch (_) {
      photos = [];
    }
  }

  Widget tile(int i) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => showPhotos(context, [
          for (var j = 0; j < photos.length; j++)
            () => loaded.putIfAbsent(j, () => loadPhoto(photos[j])),
        ], i),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: loaded.putIfAbsent(i, () => loadPhoto(photos[i])),
              builder: (_, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Icon(Icons.broken_image_outlined));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Image.memory(
                  snapshot.data!,
                  cacheWidth: 600,
                  fit: BoxFit.cover,
                  semanticLabel: 'Фото ${i + 1} из ${photos.length}',
                );
              },
            ),
            if (i == 5 && photos.length > 6)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text(
                  '+${photos.length - 6}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const Text('Повреждённый альбом');
    final visible = photos.length.clamp(1, 6);
    final caption = widget.event.content['caption'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 420,
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: visible == 1 ? 1 : 2,
              crossAxisSpacing: 5,
              mainAxisSpacing: 5,
              childAspectRatio: visible == 1 ? 1.4 : 1.1,
            ),
            itemCount: visible,
            itemBuilder: (_, i) => tile(i),
          ),
        ),
        if (caption is String && caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectableText(caption, semanticsLabel: caption),
          ),
      ],
    );
  }
}
