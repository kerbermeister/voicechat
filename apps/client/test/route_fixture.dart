import 'dart:convert';
import 'dart:io';

/// Browser runner embeds the same infra examples; native tests read them directly.
/// Keep one source of truth without making test fixtures production web assets.
String routeFixture(String name) {
  const embedded = String.fromEnvironment('ROUTE_TEST_FIXTURES');
  if (embedded.isNotEmpty) {
    return jsonEncode((jsonDecode(embedded) as Map<String, dynamic>)[name]);
  }
  return File('../../infra/$name').readAsStringSync();
}
