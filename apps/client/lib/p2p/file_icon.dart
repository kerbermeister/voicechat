import 'package:flutter/material.dart';

({String label, IconData icon, Color color}) p2pFileAppearance(
  String name,
  String mime,
) {
  final type = mime.toLowerCase().split(';').first.trim();
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (type.startsWith('image/') ||
      {
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'avif',
        'svg',
        'bmp',
      }.contains(ext)) {
    return (
      label: 'Изображение',
      icon: Icons.image_rounded,
      color: const Color(0xff007f78),
    );
  }
  if (type.startsWith('video/') ||
      {'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'}.contains(ext)) {
    return (
      label: 'Видео',
      icon: Icons.movie_rounded,
      color: const Color(0xff7251b5),
    );
  }
  if (type.startsWith('audio/') ||
      {'mp3', 'wav', 'm4a', 'flac', 'ogg', 'aac'}.contains(ext)) {
    return (
      label: 'Аудио',
      icon: Icons.music_note_rounded,
      color: const Color(0xffb13979),
    );
  }
  if (type == 'application/pdf' || ext == 'pdf') {
    return (
      label: 'PDF',
      icon: Icons.picture_as_pdf_rounded,
      color: const Color(0xffbe493f),
    );
  }
  if ({'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'}.contains(ext) ||
      type.contains('zip') ||
      type.contains('compressed') ||
      type == 'application/x-tar') {
    return (
      label: 'Архив',
      icon: Icons.folder_zip_rounded,
      color: const Color(0xff996417),
    );
  }
  if ({'xls', 'xlsx', 'ods', 'csv'}.contains(ext) ||
      type.contains('spreadsheet') ||
      type == 'text/csv') {
    return (
      label: 'Таблица',
      icon: Icons.table_chart_rounded,
      color: const Color(0xff32734a),
    );
  }
  if ({
        'dart',
        'js',
        'ts',
        'py',
        'java',
        'rs',
        'json',
        'html',
        'css',
        'xml',
        'sh',
        'yaml',
        'yml',
      }.contains(ext) ||
      type.contains('json')) {
    return (
      label: 'Код',
      icon: Icons.code_rounded,
      color: const Color(0xff3267b1),
    );
  }
  if (type.startsWith('text/') ||
      {
        'doc',
        'docx',
        'odt',
        'rtf',
        'pages',
        'ppt',
        'pptx',
        'key',
      }.contains(ext) ||
      type.contains('document') ||
      type.contains('presentation')) {
    return (
      label: 'Документ',
      icon: Icons.description_rounded,
      color: const Color(0xff527092),
    );
  }
  return (
    label: 'Файл',
    icon: Icons.insert_drive_file_rounded,
    color: const Color(0xff6b7082),
  );
}

class P2pFileIcon extends StatelessWidget {
  final String name, mime;
  final bool verified;
  const P2pFileIcon({
    super.key,
    required this.name,
    required this.mime,
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final appearance = p2pFileAppearance(name, mime);
    return Semantics(
      label: appearance.label,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 38,
          child: Stack(
            children: [
              Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      appearance.color,
                      Color.lerp(appearance.color, Colors.black, .25)!,
                    ],
                  ),
                ),
                child: Icon(appearance.icon, color: Colors.white, size: 24),
              ),
              if (verified)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_circle,
                      size: 15,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
