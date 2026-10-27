import 'package:flutter/services.dart';

int p2pRequiredBytes(int bytes) => bytes * 2 + 64 * 1024 * 1024;

Future<int?> p2pAvailableBytes() =>
    const MethodChannel('voicechat/save').invokeMethod<int>('availableBytes');
