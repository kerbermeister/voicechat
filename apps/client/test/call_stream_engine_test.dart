// Exercise the SDK signaling handler, including repeated subscriber offers.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/core/signal_client.dart';
import 'package:livekit_client/src/core/transport.dart';
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as protocol;
import 'package:livekit_client/src/support/websocket.dart';
import 'package:voicechat_probe/call_stream_sync.dart';

class AnswerSocket extends LiveKitWebSocket {
  Completer<protocol.SessionDescription> answer = Completer();
  @override
  void send(List<int> data) {
    final request = protocol.SignalRequest.fromBuffer(data);
    if (request.hasAnswer()) answer.complete(request.answer);
  }
}

class AnswerPeer implements rtc.RTCPeerConnection {
  final locals = <rtc.RTCSessionDescription>[];
  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async =>
      rtc.RTCSignalingState.RTCSignalingStateStable;
  @override
  Future<rtc.RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => rtc.RTCSessionDescription('synthetic-answer', 'answer');
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription value) async {
    locals.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfferTransport implements Transport {
  @override
  final AnswerPeer pc = AnswerPeer();
  final remotes = <rtc.RTCSessionDescription>[];
  Completer<void> received = Completer();
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription value) async {
    remotes.add(value);
    received.complete();
  }

  @override
  Future<bool> dispose() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final nativeCall in [false, true]) {
    test(
      'subscriber policy=$nativeCall survives renegotiation; publisher stays intact',
      () async {
        final socket = AnswerSocket();
        late WebSocketEventHandlers incoming;
        final signal = SignalClient((
          uri, {
          options,
          headers,
          networkOptions,
        }) async {
          incoming = options!;
          return socket;
        });
        final engine = Engine(
          connectOptions: const lk.ConnectOptions(),
          roomOptions: const lk.RoomOptions(),
          signalClient: signal,
          subscriberDescriptionTransform: nativeCall
              ? synchronizeCallStreams
              : null,
        );
        addTearDown(engine.dispose);
        addTearDown(signal.dispose);
        final subscriber = OfferTransport();
        final publisher = OfferTransport();
        engine.subscriber = subscriber;
        engine.publisher = publisher;
        await signal.connect(
          'wss://synthetic.invalid',
          'test-token',
          connectOptions: const lk.ConnectOptions(),
          roomOptions: const lk.RoomOptions(),
        );
        for (final track in ['first', 'reconnected']) {
          socket.answer = Completer();
          subscriber.received = Completer();
          final offer = rtc.RTCSessionDescription(
            'a=msid:PA_a|TR_$track TR_$track\r\n',
            'offer',
          );
          incoming.onData!(
            protocol.SignalResponse(
              offer: protocol.SessionDescription(sdp: offer.sdp, type: 'offer'),
            ).writeToBuffer(),
          );
          final answer = await socket.answer.future.timeout(
            const Duration(seconds: 2),
          );
          expect(
            subscriber.remotes.last.sdp,
            nativeCall ? 'a=msid:PA_a|voicechat-call TR_$track\r\n' : offer.sdp,
          );
          expect(subscriber.pc.locals.last.sdp, answer.sdp);
          expect(subscriber.pc.locals.last.type, answer.type);
          expect(answer.sdp, 'synthetic-answer');
        }
        final answer = rtc.RTCSessionDescription('server-answer', 'answer');
        incoming.onData!(
          protocol.SignalResponse(
            answer: protocol.SessionDescription(
              sdp: answer.sdp,
              type: answer.type,
            ),
          ).writeToBuffer(),
        );
        await publisher.received.future.timeout(const Duration(seconds: 2));
        expect(publisher.remotes.single.sdp, answer.sdp);
        expect(publisher.remotes.single.type, answer.type);
      },
    );
  }
}
