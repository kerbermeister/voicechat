// Test-only bridge from the existing synthetic A/V fixture to the actual SDK.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart'
    show Algorithm, FrameCryptor, KeyProvider, KeyProviderOptions;
// ignore: implementation_imports
import 'package:dart_webrtc/src/frame_cryptor_impl.dart';
// ignore: implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_receiver_impl.dart';
// ignore: implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_sender_impl.dart';
import 'package:web/web.dart' as web;

final factory = FrameCryptorFactoryImpl.instance;
final cryptors = <FrameCryptor>[];
final providers = <KeyProvider>[];
var invalidAudioFaultRejected = false, repeatedAudioFaultRejected = false;

void require(bool accepted) {
  if (!accepted) throw StateError('Marker encryption command rejected');
}

Future<Map> workerControl(
  Map<String, Object> command, {
  bool audio = false,
}) async {
  final protocol = audio ? 'fixture-av' : 'fixture-order';
  final msgId = 'marker-${DateTime.now().microsecondsSinceEpoch}';
  final reply = Completer<Map>();
  final listener = ((web.MessageEvent event) {
    final data = event.data.dartify();
    if (data is Map &&
        data['msgType'] == '$protocol-result' &&
        data['msgId'] == msgId &&
        !reply.isCompleted) {
      reply.complete(data['data'] as Map);
    }
  }).toJS;
  factory.worker.addEventListener('message', listener);
  try {
    factory.worker.postMessage(
      {'msgType': '$protocol-control', 'msgId': msgId, ...command}.jsify(),
    );
    final result = await reply.future.timeout(const Duration(seconds: 5));
    require(!result.containsKey('error'));
    return result;
  } finally {
    factory.worker.removeEventListener('message', listener);
  }
}

Future<void> initialize() async {
  require(providers.isEmpty && cryptors.isEmpty);
  await workerControl({
    'command': 'configure',
    'operation': 'none',
    'delayMs': 0,
  });
  try {
    await workerControl({
      'command': 'arm',
      'operation': 'unknown',
    }, audio: true);
  } on StateError {
    invalidAudioFaultRejected = true;
  }
  require(invalidAudioFaultRejected);
  final random = Random.secure();
  final key = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  for (var i = 0; i < 2; i++) {
    // Pinned SDK defaults; individual sender keys, and no plaintext fallback.
    final provider = await factory.createDefaultKeyProvider(
      KeyProviderOptions(
        sharedKey: false,
        ratchetSalt: Uint8List.fromList('LKFrameEncryptionKey'.codeUnits),
        uncryptedMagicBytes: Uint8List.fromList('LK-ROCKS'.codeUnits),
        ratchetWindowSize: 16,
        failureTolerance: -1,
        keyRingSize: 16,
        discardFrameWhenCryptorNotReady: true,
      ),
    );
    providers.add(provider);
    require(await provider.setKey(participantId: 'sender', index: 0, key: key));
  }
}

Future<void> activate(FrameCryptor cryptor, String kind) async {
  cryptors.add(cryptor);
  require(await cryptor.setKeyIndex(0));
  require(await cryptor.setEnabled(true));
  await cryptor.updateCodec(kind == 'video' ? 'vp8' : 'opus');
}

Future<void> prepareSender(web.RTCRtpSender sender) async {
  require(providers.length == 2 && sender.track != null);
  await activate(
    await factory.createFrameCryptorForRtpSender(
      participantId: 'sender',
      sender: RTCRtpSenderWeb.fromJsSender(sender),
      algorithm: Algorithm.kAesGcm,
      keyProvider: providers.first,
    ),
    sender.track!.kind,
  );
}

Future<void> prepareReceiver(web.RTCRtpReceiver receiver) async {
  require(providers.length == 2);
  await activate(
    await factory.createFrameCryptorForRtpReceiver(
      participantId: 'sender',
      receiver: RTCRtpReceiverWeb(receiver),
      algorithm: Algorithm.kAesGcm,
      keyProvider: providers.last,
    ),
    receiver.track.kind,
  );
}

Future<JSAny?> summary() async => {
  'cryptors': cryptors.length,
  'worker': await workerControl({'command': 'summary'}),
  'audio_fault': await workerControl({'command': 'summary'}, audio: true),
  'invalid_audio_fault_rejected': invalidAudioFaultRejected,
  'repeated_audio_fault_rejected': repeatedAudioFaultRejected,
}.jsify();

Future<void> armAudioFault(String operation) async {
  require({'encrypt', 'decrypt'}.contains(operation));
  final data = await workerControl({
    'command': 'arm',
    'operation': operation,
  }, audio: true);
  require(data['armed'] == true);
  try {
    await workerControl({
      'command': 'arm',
      'operation': operation,
    }, audio: true);
  } on StateError {
    repeatedAudioFaultRejected = true;
  }
  require(repeatedAudioFaultRejected);
}

Future<void> dispose() async {
  try {
    for (final cryptor in cryptors) {
      await cryptor.dispose();
    }
    for (final provider in providers) {
      await provider.dispose();
    }
  } finally {
    factory.worker.terminate();
    cryptors.clear();
    providers.clear();
  }
}

void main() {
  require(web.window.location.hostname == '127.0.0.1');
  web.window.setProperty(
    'VoiceChatMarkerE2EE'.toJS,
    {
      'initialize': (() => initialize().toJS).toJS,
      'prepareSender': ((web.RTCRtpSender sender) => prepareSender(
        sender,
      ).toJS).toJS,
      'prepareReceiver': ((web.RTCRtpReceiver receiver) => prepareReceiver(
        receiver,
      ).toJS).toJS,
      'summary': (() => summary().toJS).toJS,
      'armAudioFault': ((JSString operation) => armAudioFault(
        operation.toDart,
      ).toJS).toJS,
      'dispose': (() => dispose().toJS).toJS,
    }.jsify(),
  );
}
