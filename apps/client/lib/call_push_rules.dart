import 'package:matrix/matrix.dart';

/// Suppress encrypted signalling before the homeserver sends a visible push.
/// A worker cannot silently consume pushes on iOS without losing permission.
Future<void> installCallPushRule(Client client) => client.setPushRule(
  PushRuleKind.override,
  'dev.voicechat.silent',
  [],
  conditions: [
    PushCondition(
      kind: 'event_property_is',
      key: r'content.dev\.voicechat\.silent',
      value: true,
    ),
  ],
);
