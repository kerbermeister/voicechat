// Copyright 2026 VoiceChat contributors.
// SPDX-License-Identifier: Apache-2.0
// ignore_for_file: implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_receiver_impl.dart' show RTCRtpReceiverWeb;
import 'package:dart_webrtc/src/rtc_rtp_sender_impl.dart' show RTCRtpSenderWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCRtpReceiver, RTCRtpSender;

// Transceiver getters create fresh Dart wrappers around the same JS endpoint.
Object senderIdentity(RTCRtpSender sender) => (sender as RTCRtpSenderWeb).jsRtpSender;
Object receiverIdentity(RTCRtpReceiver receiver) => (receiver as RTCRtpReceiverWeb).jsRtpReceiver;
