String browserDeviceDescription(String agent, {int touchPoints = 0}) {
  final browser =
      agent.contains('Edg/') ||
          agent.contains('EdgiOS/') ||
          agent.contains('EdgA/')
      ? 'Edge'
      : agent.contains('OPR/')
      ? 'Opera'
      : agent.contains('Firefox/') || agent.contains('FxiOS/')
      ? 'Firefox'
      : agent.contains('Chrome/') || agent.contains('CriOS/')
      ? 'Chrome'
      : agent.contains('Safari/')
      ? 'Safari'
      : 'Браузер';
  String device;
  if (agent.contains('iPhone')) {
    device = 'iPhone';
  } else if (agent.contains('iPad') ||
      (agent.contains('Macintosh') && touchPoints > 1)) {
    device = 'iPad';
  } else if (agent.contains('Android')) {
    final model = RegExp(
      r'Android [^;\)]+;\s*(?:[a-z]{2}-[A-Z]{2};\s*)?([^\)]+)',
    ).firstMatch(agent)?.group(1)?.split(' Build/').first.trim();
    device = model == null || model == 'K' || model == 'wv' || model.isEmpty
        ? 'Android'
        : '$model · Android';
  } else if (agent.contains('Macintosh')) {
    device = 'Mac · macOS';
  } else if (agent.contains('Windows')) {
    device = 'Компьютер · Windows';
  } else if (agent.contains('Linux')) {
    device = 'Компьютер · Linux';
  } else {
    device = 'Веб-устройство';
  }
  return '$device · $browser';
}
