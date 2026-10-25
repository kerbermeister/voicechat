// Mounted composers can prevent installation while their media is only in memory.
final updateGuards = <Future<String?> Function()>{};

Future<String?> checkUpdateGuards() async {
  for (final guard in updateGuards.toList()) {
    final reason = await guard();
    if (reason != null) return reason;
  }
  return null;
}
