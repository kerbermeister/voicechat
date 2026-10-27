import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import '../picked_file.dart';
import 'protocol.dart';

/// A single accepted live transfer. No reconnect or disk checkpoint protocol.
class P2pWire {
  final List<P2pFile> files;
  final List<PickedFile>? sources;
  final Future<void> Function(Map<String, dynamic>) signal;
  final Future<void> Function(int, int, Uint8List) store;
  final void Function(int, int, bool) progress;
  final void Function(P2pRoute) route;
  final void Function() complete;
  final void Function(String) failed;
  rtc.RTCPeerConnection? _pc;
  rtc.RTCDataChannel? _channel;
  final List<rtc.RTCIceCandidate> _candidates = [];
  bool _remoteSet = false, _closed = false, _finished = false, _pumping = false;
  Future<void> _receiving = Future.value(),
      _signals = Future.value(),
      _sending = Future.value();
  Timer? _timer;
  bool _readingStats = false;
  DateTime _activity = DateTime.now();
  int _queued = 0, _file = 0, _written = 0;
  final _block = BytesBuilder(copy: false);
  P2pHash _hash = P2pHash();
  Completer<void>? _ack;
  int _ackFile = -1, _ackBytes = 0;
  int _reportedBytes = 0;
  DateTime _progressAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ackVerified = false;

  P2pWire({
    required this.files,
    this.sources,
    required this.signal,
    required this.store,
    required this.progress,
    required this.route,
    required this.complete,
    required this.failed,
  });

  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    bool relayOnly = false,
  }) async {
    final pc = await rtc.createPeerConnection({
      'iceServers': iceServers,
      'iceTransportPolicy': relayOnly ? 'relay' : 'all',
    });
    if (_closed) {
      await pc.close();
      await pc.dispose();
      return;
    }
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (!_closed && candidate.candidate?.isNotEmpty == true) {
        _sendSignal({'kind': 'ice', 'candidate': candidate.toMap()});
      }
    };
    pc.onConnectionState = (state) {
      if (!_closed &&
          !_finished &&
          state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail('Соединение оборвалось. Отправьте файлы заново.');
      }
    };
    pc.onDataChannel = (channel) {
      if (sources != null ||
          _channel != null ||
          channel.label != 'voicechat.p2p.v1') {
        unawaited(channel.close());
        return;
      }
      _bind(channel);
    };
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_finished && DateTime.now().difference(_activity).inSeconds > 60) {
        _fail('Нет ответа от устройства. Отправьте файлы заново.');
      }
      unawaited(_stats());
    });
    if (sources != null) {
      _bind(
        await pc.createDataChannel(
          'voicechat.p2p.v1',
          rtc.RTCDataChannelInit()..ordered = true,
        ),
      );
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendSignal({'kind': 'sdp', 'type': 'offer', 'sdp': offer.sdp});
    }
  }

  void _sendSignal(Map<String, dynamic> message) {
    _signals = _signals
        .then((_) async {
          if (!_closed) await signal(message);
        })
        .catchError((Object e) {
          _fail('Не удалось согласовать соединение.');
        });
  }

  Future<void> receiveSignal(Map<String, dynamic> data) async {
    if (_closed || _pc == null) return;
    if (data['kind'] == 'sdp') {
      final type = data['type'], sdp = data['sdp'];
      if (type != (sources == null ? 'offer' : 'answer') ||
          sdp is! String ||
          sdp.length > 65536 ||
          _remoteSet) {
        throw const FormatException('Invalid SDP');
      }
      await _pc!.setRemoteDescription(
        rtc.RTCSessionDescription(sdp, type as String),
      );
      _remoteSet = true;
      for (final candidate in _candidates) {
        await _pc!.addCandidate(candidate);
      }
      _candidates.clear();
      if (sources == null) {
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        _sendSignal({'kind': 'sdp', 'type': 'answer', 'sdp': answer.sdp});
      }
    } else if (data['kind'] == 'ice') {
      final raw = data['candidate'];
      if (raw is! Map ||
          raw['candidate'] is! String ||
          (raw['candidate'] as String).length > 4096 ||
          (raw['sdpMid'] != null && raw['sdpMid'] is! String) ||
          (raw['sdpMLineIndex'] != null && raw['sdpMLineIndex'] is! int)) {
        throw const FormatException('Invalid ICE');
      }
      final candidate = rtc.RTCIceCandidate(
        raw['candidate'] as String,
        raw['sdpMid'] as String?,
        raw['sdpMLineIndex'] as int?,
      );
      if (_remoteSet) {
        await _pc!.addCandidate(candidate);
      } else {
        if (_candidates.length >= 64) {
          throw const FormatException('Too many candidates');
        }
        _candidates.add(candidate);
      }
    } else {
      throw const FormatException('Invalid signaling');
    }
  }

  void _bind(rtc.RTCDataChannel channel) {
    _channel = channel;
    channel.onMessage = (message) {
      if (_closed) return;
      final size = message.isBinary
          ? message.binary.length
          : message.text.length;
      _queued += size;
      if (_queued > p2pBlockBytes + 65536 ||
          (!message.isBinary && size > 4096)) {
        _fail('Получены недопустимые данные.');
        return;
      }
      _receiving = _receiving
          .then((_) async {
            if (!_closed) await _receive(message);
          })
          .catchError((Object _) {
            _fail('Передача повреждена или не хватает места.');
          })
          .whenComplete(() {
            _queued -= size;
          });
    };
    channel.onDataChannelState = (state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        _startSending();
      }
      if (state == rtc.RTCDataChannelState.RTCDataChannelClosed && !_closed) {
        if (_finished) {
          unawaited(close());
        } else {
          _fail('Передача прервана. Отправьте файлы заново.');
        }
      }
    };
    if (channel.state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
      _startSending();
    }
  }

  void _startSending() {
    _activity = DateTime.now();
    unawaited(_stats());
    if (sources == null || _pumping || _closed) return;
    _pumping = true;
    unawaited(
      _sending = _sendFiles().catchError((Object _) {
        if (!_closed) _fail('Файл недоступен или передача прервана.');
      }),
    );
  }

  Future<void> _stats() async {
    if (_pc == null || _closed || _readingStats) return;
    _readingStats = true;
    try {
      final reports = await _pc!.getStats();
      if (!_closed) {
        route(
          p2pRouteFromStats([
            for (final report in reports)
              {'id': report.id, 'type': report.type, ...report.values},
          ]),
        );
      }
    } catch (_) {
      /* Unknown is preferable to claiming a direct path. */
    } finally {
      _readingStats = false;
    }
  }

  Future<void> _send(rtc.RTCDataChannelMessage message) async {
    if (_closed ||
        _channel?.state != rtc.RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Closed channel');
    }
    while (await _channel!.getBufferedAmount() > 256 * 1024) {
      if (_closed) throw StateError('Closed channel');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_closed) throw StateError('Closed channel');
    await _channel!.send(message);
    _activity = DateTime.now();
  }

  Future<void> _sendFiles() async {
    for (var file = 0; file < files.length; file++) {
      final meta = files[file], source = sources![file];
      _reportedBytes = 0;
      for (
        var offset = 0;
        offset < meta.size || (offset == 0 && meta.size == 0);
      ) {
        if (_closed) return;
        final end = (offset + p2pBlockBytes).clamp(0, meta.size);
        _ackFile = file;
        _ackBytes = end;
        _ackVerified = end == meta.size;
        final ack = _ack = Completer<void>();
        // Attach the error handler before a cancel can race a pending source read.
        final acknowledged = ack.future;
        unawaited(acknowledged.catchError((Object _) {}));
        if (meta.size == 0) {
          await _send(rtc.RTCDataChannelMessage(jsonEncode({'empty': file})));
        } else {
          final bytes = await source
              .read(offset, end)
              .timeout(const Duration(seconds: 60));
          if (bytes.length != end - offset) throw StateError('Source changed');
          for (var start = 0; start < bytes.length;) {
            final next = (start + p2pFrameBytes - p2pHeaderBytes).clamp(
              0,
              bytes.length,
            );
            await _send(
              rtc.RTCDataChannelMessage.fromBinary(
                p2pFrame(
                  file,
                  offset + start,
                  Uint8List.sublistView(bytes, start, next),
                ),
              ),
            );
            start = next;
          }
        }
        await acknowledged.timeout(const Duration(seconds: 60));
        if (_closed) return;
        offset = end;
        if (meta.size == 0) break;
      }
    }
    _finished = true;
    await _stats();
    complete();
    await close();
  }

  Future<void> _receive(rtc.RTCDataChannelMessage message) async {
    if (sources != null) {
      if (message.isBinary) {
        throw const FormatException('Unexpected binary reply');
      }
      final data = jsonDecode(message.text);
      if (data is! Map || data['file'] is! int || data['bytes'] is! int) {
        throw const FormatException('Invalid ACK');
      }
      final file = data['file'] as int, bytes = data['bytes'] as int;
      boundedInt(file, 0, files.length - 1);
      boundedInt(bytes, 0, files[file].size);
      if (data['progress'] == true) {
        if (file < _ackFile || (file == _ackFile && bytes <= _reportedBytes)) {
          return;
        }
        if (file != _ackFile ||
            bytes > _ackBytes ||
            bytes == files[file].size) {
          throw const FormatException('Unexpected progress');
        }
        _reportedBytes = bytes;
        _activity = DateTime.now();
        progress(file, bytes, false);
        return;
      }
      if (data['verified'] is! bool) throw const FormatException('Invalid ACK');
      if (file < _ackFile || (file == _ackFile && bytes < _ackBytes)) return;
      if (file != _ackFile ||
          bytes != _ackBytes ||
          data['verified'] != _ackVerified) {
        throw const FormatException('Unexpected ACK');
      }
      _activity = DateTime.now();
      _reportedBytes = bytes;
      progress(file, bytes, data['verified'] == true);
      if (_ack?.isCompleted == false) _ack!.complete();
      return;
    }
    if (_finished || _file >= files.length) {
      throw const FormatException('Unexpected file');
    }
    final meta = files[_file];
    if (!message.isBinary) {
      final data = jsonDecode(message.text);
      if (data is! Map || data['empty'] != _file || meta.size != 0) {
        throw const FormatException('Invalid empty file');
      }
      await _flush();
      return;
    }
    final frame = parseP2pFrame(message.binary);
    if (frame.file != _file ||
        frame.offset != _written + _block.length ||
        frame.offset + frame.bytes.length > meta.size ||
        _block.length + frame.bytes.length > p2pBlockBytes) {
      throw const FormatException('Invalid file offset');
    }
    _activity = DateTime.now();
    _block.add(frame.bytes);
    _hash.input.add(frame.bytes);
    if (_block.length == p2pBlockBytes ||
        _written + _block.length == meta.size) {
      await _flush();
    } else if (DateTime.now().difference(_progressAt).inMilliseconds >= 250) {
      // Live progress must remain useful on links that need minutes for a disk block.
      // This receipt never releases the sender's block; only the stored ACK does.
      _progressAt = DateTime.now();
      final received = _written + _block.length;
      progress(_file, received, false);
      await _send(
        rtc.RTCDataChannelMessage(
          jsonEncode({'progress': true, 'file': _file, 'bytes': received}),
        ),
      );
    }
  }

  Future<void> _flush() async {
    final meta = files[_file];
    final bytes = _block.takeBytes();
    if (bytes.isNotEmpty) await store(_file, _written ~/ p2pBlockBytes, bytes);
    if (_closed) return;
    _written += bytes.length;
    final verified = _written == meta.size;
    if (verified && _hash.finish() != meta.hash) {
      throw const FormatException('File checksum mismatch');
    }
    progress(_file, _written, verified);
    await _send(
      rtc.RTCDataChannelMessage(
        jsonEncode({'file': _file, 'bytes': _written, 'verified': verified}),
      ),
    );
    if (verified) {
      _file++;
      _written = 0;
      _hash = P2pHash();
      if (_file == files.length) {
        _finished = true;
        complete();
      }
    }
  }

  void _fail(String reason) {
    if (_closed) return;
    failed(reason);
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (_ack?.isCompleted == false) {
      _ack!.completeError(StateError('Transfer closed'));
    }
    try {
      await _channel?.close();
    } catch (_) {
      /* Already closed by WebRTC. */
    }
    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {
      /* Peer may already be gone. */
    }
  }

  Future<void> drain() async {
    await close();
    await _receiving;
    await _sending;
  }
}
