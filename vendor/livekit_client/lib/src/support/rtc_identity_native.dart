// Copyright 2026 VoiceChat contributors.
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCRtpReceiver, RTCRtpSender;

Object senderIdentity(RTCRtpSender sender) => sender;
Object receiverIdentity(RTCRtpReceiver receiver) => receiver;
