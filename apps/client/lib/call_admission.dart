/// Validate control metadata before it can replace an active media admission.
/// A heartbeat can reuse an existing JWT only for the exact same lease/generation.
Map<String, dynamic> parseCallAdmission(
  Object? value, {
  required String identity,
  bool heartbeat = false,
  Map<String, dynamic>? previous,
}) {
  if (value is! Map<String, dynamic> ||
      value['identity'] != identity ||
      value['lease_seconds'] != 30 ||
      value['generation'] is! String ||
      !RegExp(r'^vc-[a-f0-9]{48}$').hasMatch(value['generation']) ||
      value['lease_id'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['lease_id']) ||
      value['roster'] is! List ||
      (value['roster'] as List).isEmpty ||
      (value['roster'] as List).length > 10 ||
      value.containsKey('heartbeat_supported') &&
          value['heartbeat_supported'] is! bool) {
    throw const FormatException('Invalid call admission');
  }
  if (heartbeat &&
      (previous == null ||
          previous['identity'] != identity ||
          previous['lease_id'] != value['lease_id'])) {
    throw const FormatException('Heartbeat changed the call lease');
  }
  final token = value['token'];
  if (token != null) {
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid call token');
    }
    return value;
  }
  if (!heartbeat) throw const FormatException('Missing call token');
  if (previous!['generation'] != value['generation']) return value;
  final priorToken = previous['token'];
  if (priorToken is! String || priorToken.isEmpty) {
    throw const FormatException('Missing previous call token');
  }
  return {...value, 'token': priorToken};
}
