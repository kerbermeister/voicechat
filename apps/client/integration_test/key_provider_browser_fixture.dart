// Local real-worker contract probe. No accounts, SFU, camera or microphone.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  if (!{'localhost', '127.0.0.1', '::1'}.contains(Uri.base.host)) {
    throw StateError('Loopback key-provider fixture required');
  }
  runApp(const MaterialApp(home: KeyProviderFixture()));
}

class KeyProviderFixture extends StatefulWidget {
  const KeyProviderFixture({super.key});
  @override
  State<KeyProviderFixture> createState() => _KeyProviderFixtureState();
}

class _KeyProviderFixtureState extends State<KeyProviderFixture> {
  var result = 'Готово: настоящий worker, без аккаунта и медиа';
  var running = false;

  Future<void> run() async {
    setState(() => running = true);
    try {
      final cases = <Map<String, Object>>[];
      for (final shared in [false, true]) {
        final provider = await lk.BaseKeyProvider.create(sharedKey: shared);
        final previous = Uint8List(32);
        final next = Uint8List.fromList(List.filled(32, 123));
        await provider.setRawKey(previous, participantId: 'alice');
        // The real worker must reject writes after this provider was removed.
        await provider.keyProvider.dispose();
        var rejected = false;
        try {
          await provider.setRawKey(next, participantId: 'alice', keyIndex: 1);
        } catch (_) {
          rejected = true;
        }
        final cachePreserved = shared
            ? provider.sharedKey?.every((value) => value == 0) == true
            : provider.getLatestIndex('alice') == 0;
        cases.add({
          'shared': shared,
          'worker_rejection_propagated': rejected,
          'confirmed_cache_preserved': cachePreserved,
        });
      }
      final fresh = await lk.BaseKeyProvider.create(sharedKey: false);
      try {
        await fresh.setRawKey(Uint8List(32), participantId: 'alice');
      } finally {
        await fresh.keyProvider.dispose();
      }
      result = jsonEncode({
        'passed': cases.every(
          (value) =>
              value['worker_rejection_propagated'] == true &&
              value['confirmed_cache_preserved'] == true,
        ),
        'cases': cases,
        'fresh_provider_succeeds': true,
        'media_opened': false,
      });
    } catch (error) {
      result = jsonEncode({'passed': false, 'failure': '${error.runtimeType}'});
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('QA: подтверждение установки медиаключей'),
    ),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: running ? null : run,
            child: Text(running ? 'Проверка…' : 'Проверить worker'),
          ),
          const SizedBox(height: 16),
          SelectableText(result),
        ],
      ),
    ),
  );
}
