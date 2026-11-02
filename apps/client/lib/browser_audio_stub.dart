void prepareBrowserAudio() {}
Future<bool> playBrowserSound(String channel, String name, bool loop) async =>
    false;
void stopBrowserSound(String channel) {}
Future<bool> resumeBrowserAudio() async => true;
void closeBrowserAudio() {}

Future<Map<String, dynamic>> browserAudioOutputs() async => {
  'supported': false,
  'devices': [],
};
Future<void> selectBrowserAudioOutput(String id) async =>
    throw UnsupportedError('Browser audio only');
Future<void> chooseBrowserAudioOutput() async =>
    throw UnsupportedError('Browser audio only');
