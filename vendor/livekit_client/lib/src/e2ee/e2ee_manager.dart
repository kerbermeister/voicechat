// Copyright 2024 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/room.dart';
import '../events.dart';
import '../extensions.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../support/rtc_identity_native.dart'
    if (dart.library.js_interop) '../support/rtc_identity_web.dart'
    as rtc_identity;
import '../utils.dart';
import 'events.dart';
import 'key_provider.dart';
import 'options.dart';

class _ManagedFrameCryptor {
  final Future<FrameCryptor> ready;
  Future<void>? _closing;
  (String, FrameCryptorState)? _lastState;
  void Function(String, FrameCryptorState)? _listener;

  _ManagedFrameCryptor(this.ready);
  bool get isClosing => _closing != null;

  void stateChanged(String trackId, FrameCryptorState state) {
    _lastState = (trackId, state);
    _listener?.call(trackId, state);
  }

  void listen(void Function(String, FrameCryptorState) listener) {
    if (isClosing) return;
    _listener = listener;
    final last = _lastState;
    if (last != null) listener(last.$1, last.$2);
  }

  Future<void> close() => _closing ??= () async {
    _listener = null;
    FrameCryptor cryptor;
    try {
      cryptor = await ready;
    } catch (_) {
      // Initialization already reported its error to the publisher/subscriber.
      return;
    }
    await cryptor.dispose();
  }();
}

typedef _CryptorId = ({String identity, Object endpoint});

class E2EEManager {
  Room? _room;
  final _frameCryptors = <_CryptorId, _ManagedFrameCryptor>{};
  final BaseKeyProvider _keyProvider;
  final Algorithm _algorithm = Algorithm.kAesGcm;
  DataPacketCryptor? _dataPacketCryptor;
  bool _enabled = true;
  bool _encryptionEnabled = false;
  EventsListener<RoomEvent>? _listener;
  E2EEManager(this._keyProvider, {bool dcEncryptionEnabled = false}) {
    _encryptionEnabled = dcEncryptionEnabled;
  }

  Future<void> setup(Room room) async {
    if (_room != room) {
      await _cleanUp();
      _room = room;
      _listener = _room!.createListener();
      _listener!
        ..on<LocalTrackPublishedEvent>((event) async {
          if (room.isDisposed) return;
          if (event.publication.encryptionType == EncryptionType.kNone ||
              isAV1Codec(event.publication.track?.codec ?? '')) {
            // no need to setup frame cryptor
            return;
          }
          final binding = _addRtpSender(sender: event.publication.track!.sender!, identity: event.participant.identity);
          final frameCryptor = await binding.ready;
          if (binding.isClosing) return;
          if (kIsWeb && event.publication.track!.codec != null) {
            await frameCryptor.updateCodec(event.publication.track!.codec!);
          }
          binding.listen((trackId, state) {
            if (kDebugMode) {
              print('Sender::onFrameCryptorStateChanged: $state, trackId:  $trackId');
            }
            final participant = event.participant;
            [event.participant.events, participant.room.events].emit(
              TrackE2EEStateEvent(
                participant: participant,
                publication: event.publication,
                state: _e2eeStateFromFrameCryptoState(state),
              ),
            );
          });
        })
        ..on<LocalTrackUnpublishedEvent>((event) async {
          final sender = event.publication.track?.sender;
          if (sender != null) {
            await _removeCryptor(event.participant.identity, rtc_identity.senderIdentity(sender));
          }
        })
        ..on<TrackSubscribedEvent>((event) async {
          if (room.isDisposed) return;
          final codec = event.publication.mimeType.split('/')[1];
          if (event.publication.encryptionType == EncryptionType.kNone || isAV1Codec(codec)) {
            // no need to setup frame cryptor
            return;
          }
          final binding = _addRtpReceiver(receiver: event.track.receiver!, identity: event.participant.identity);
          final frameCryptor = await binding.ready;
          if (binding.isClosing) return;
          if (kIsWeb) {
            await frameCryptor.updateCodec(codec.toLowerCase());
          }
          binding.listen((trackId, state) {
            if (kDebugMode) {
              print('Receiver::onFrameCryptorStateChanged: $state, trackId: $trackId');
            }
            final participant = event.participant;
            [event.participant.events, participant.room.events].emit(
              TrackE2EEStateEvent(
                participant: participant,
                publication: event.publication,
                state: _e2eeStateFromFrameCryptoState(state),
              ),
            );
          });
        })
        ..on<TrackUnsubscribedEvent>((event) async {
          final receiver = event.track.receiver;
          if (receiver != null) {
            await _removeCryptor(event.participant.identity, rtc_identity.receiverIdentity(receiver));
          }
        });
      _dataPacketCryptor ??= await dataPacketCryptorFactory.createDataPacketCryptor(
        algorithm: _algorithm,
        keyProvider: _keyProvider.keyProvider,
      );
    }
  }

  BaseKeyProvider get keyProvider => _keyProvider;

  Future<void> ratchetKey({String? participantId, int? keyIndex}) async {
    if (participantId != null) {
      await _keyProvider.ratchetKey(participantId, keyIndex);
    } else {
      await _keyProvider.ratchetSharedKey(keyIndex: keyIndex);
    }
  }

  Future<void> _cleanUp() async {
    _room = null;
    await _listener?.cancelAll();
    await _listener?.dispose();
    _listener = null;
    final bindings = _frameCryptors.values.toList();
    _frameCryptors.clear();
    final dataCryptor = _dataPacketCryptor;
    _dataPacketCryptor = null;
    await Future.wait<void>([
      for (final binding in bindings) binding.close(),
      if (dataCryptor != null) dataCryptor.dispose(),
    ]);
  }

  /// Called after the room's transports stop, before releasing its key provider.
  Future<void> dispose() => _cleanUp();

  Future<void> _removeCryptor(String identity, Object endpoint) async {
    final id = (identity: identity, endpoint: endpoint);
    final binding = _frameCryptors[id];
    if (binding == null) return;
    try {
      // The track is stopped before its unpublish/unsubscribe event. Keep the
      // binding visible until disposal completes so room cleanup can await it.
      await binding.close();
    } finally {
      if (identical(_frameCryptors[id], binding)) _frameCryptors.remove(id);
    }
  }

  _ManagedFrameCryptor _cryptorFor(String identity, Object endpoint, Future<FrameCryptor> Function() create) {
    if (_room == null || _room!.isDisposed) throw StateError('Encryption manager is closed');
    final id = (identity: identity, endpoint: endpoint);
    final existing = _frameCryptors[id];
    if (existing != null && !existing.isClosing) return existing;
    late final _ManagedFrameCryptor binding;
    Future<FrameCryptor> initialize() async {
      if (existing != null) await existing.close();
      final cryptor = await create();
      try {
        cryptor.onFrameCryptorStateChanged = binding.stateChanged;
        if (!await cryptor.setKeyIndex(_keyProvider.getLatestIndex(identity))) {
          throw StateError('Frame cryptor rejected its key index');
        }
        if (!await cryptor.setEnabled(_enabled)) {
          throw StateError('Frame cryptor rejected its enabled state');
        }
        return cryptor;
      } catch (error, stack) {
        try {
          await cryptor.dispose();
        } catch (cleanupError) {
          logger.warning('Unfinished cryptor disposal failed: ${cleanupError.runtimeType}');
        }
        Error.throwWithStackTrace(error, stack);
      }
    }

    binding = _ManagedFrameCryptor(
      initialize().catchError((Object error, StackTrace stack) {
        if (identical(_frameCryptors[id], binding)) _frameCryptors.remove(id);
        Error.throwWithStackTrace(error, stack);
      }),
    );
    _frameCryptors[id] = binding;
    return binding;
  }

  /// Install encryption before SDP negotiation can release the first RTP frame.
  Future<void> prepareLocalSender(RTCRtpSender sender, {String? codec}) async {
    if (isAV1Codec(codec ?? '')) return;
    final identity = _room?.localParticipant?.identity;
    if (identity == null) throw StateError('Local encryption identity is unavailable');
    final binding = _addRtpSender(sender: sender, identity: identity);
    final cryptor = await binding.ready;
    if (binding.isClosing || _room == null || _room!.isDisposed) {
      throw StateError('Encryption manager closed during sender preparation');
    }
    if (kIsWeb && codec != null) await cryptor.updateCodec(codec);
  }

  _ManagedFrameCryptor _addRtpSender({required RTCRtpSender sender, required String identity}) => _cryptorFor(
    identity,
    rtc_identity.senderIdentity(sender),
    () => frameCryptorFactory.createFrameCryptorForRtpSender(
      participantId: identity,
      sender: sender,
      algorithm: _algorithm,
      keyProvider: _keyProvider.keyProvider,
    ),
  );

  _ManagedFrameCryptor _addRtpReceiver({required RTCRtpReceiver receiver, required String identity}) => _cryptorFor(
    identity,
    rtc_identity.receiverIdentity(receiver),
    () => frameCryptorFactory.createFrameCryptorForRtpReceiver(
      participantId: identity,
      receiver: receiver,
      algorithm: _algorithm,
      keyProvider: _keyProvider.keyProvider,
    ),
  );

  /// Enable/Disable frame crypto for the sender and receiver.
  /// @param enabled true to enable, false to disable
  /// if false, the frame cryptor will pass through frames and
  /// without encryption/decryption
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    for (var frameCryptor in _frameCryptors.entries.toList()) {
      if (!frameCryptor.value.isClosing) await (await frameCryptor.value.ready).setEnabled(enabled);
    }
  }

  /// Sets the key index for the encryptors of the participant.
  /// @param keyIndex the key index to set
  /// @param participantIdentity the identity of the participant,
  /// if null, use local participant.
  Future<void> setKeyIndex(int keyIndex, {String? participantIdentity}) async {
    participantIdentity ??= _room?.localParticipant?.identity;
    for (var item in _frameCryptors.entries.toList()) {
      if (item.key.identity == participantIdentity && !item.value.isClosing) {
        await (await item.value.ready).setKeyIndex(keyIndex);
      }
    }
  }

  /// Get the key index for the encryptors of the participant.
  /// @param identity the identity of the participant,
  /// if null, use local participant.
  /// @return the key index and -1 if not found
  Future<int> getKeyIndex(String? participantIdentity) async {
    participantIdentity ??= _room?.localParticipant?.identity;
    for (var item in _frameCryptors.entries.toList()) {
      if (item.key.identity == participantIdentity && !item.value.isClosing) {
        return await (await item.value.ready).keyIndex;
      }
    }
    return -1;
  }

  E2EEState _e2eeStateFromFrameCryptoState(FrameCryptorState state) {
    switch (state) {
      case FrameCryptorState.FrameCryptorStateNew:
        return E2EEState.kNew;
      case FrameCryptorState.FrameCryptorStateOk:
        return E2EEState.kOk;
      case FrameCryptorState.FrameCryptorStateMissingKey:
        return E2EEState.kMissingKey;
      case FrameCryptorState.FrameCryptorStateEncryptionFailed:
        return E2EEState.kEncryptionFailed;
      case FrameCryptorState.FrameCryptorStateDecryptionFailed:
        return E2EEState.kDecryptionFailed;
      case FrameCryptorState.FrameCryptorStateInternalError:
        return E2EEState.kInternalError;
      case FrameCryptorState.FrameCryptorStateKeyRatcheted:
        return E2EEState.kKeyRatcheted;
    }
  }

  bool get isDataChannelEncryptionEnabled => _enabled && _encryptionEnabled;

  Future<Uint8List?> handleEncryptedData({
    required Uint8List data,
    required Uint8List iv,
    required String participantIdentity,
    required int keyIndex,
  }) async {
    if (_dataPacketCryptor == null) {
      throw Exception('DataPacketCryptor is not initialized');
    }
    try {
      final decryptedData = await _dataPacketCryptor!.decrypt(
        participantId: participantIdentity,
        encryptedPacket: EncryptedPacket(data: data, keyIndex: keyIndex, iv: iv),
      );
      return decryptedData;
    } catch (e) {
      logger.warning('handleEncryptedData error: $e');
      return null;
    }
  }

  Future<EncryptedPacket> encryptData({required Uint8List data}) async {
    final participantId = _room?.localParticipant?.identity;
    if (participantId == null || _dataPacketCryptor == null) {
      throw Exception('DataPacketCryptor is not initialized');
    }
    return await _dataPacketCryptor!.encrypt(
      participantId: participantId,
      keyIndex: _keyProvider.getLatestIndex(participantId),
      data: data,
    );
  }
}
