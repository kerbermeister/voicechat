import 'dart:convert';

typedef ScreenDevice = ({String identity, String curve, String ed});

enum ScreenPhase {
  idle,
  selecting,
  preparing,
  connecting,
  viewing,
  sharing,
  reconnecting,
  error,
  closed,
}

class ScreenSnapshot {
  final String binding, state;
  final String? owner, generation;
  final int revision, rosterVersion;
  final List<ScreenDevice> roster;
  ScreenSnapshot._(
    this.binding,
    this.state,
    this.owner,
    this.generation,
    this.revision,
    this.rosterVersion,
    this.roster,
  );

  factory ScreenSnapshot.parse(Map<String, dynamic> json) {
    bool integer(Object? value) =>
        value is int && value >= 0 && value <= 9007199254740991;
    bool key(Object? value) {
      if (value is! String || value.length != 43) return false;
      try {
        return base64Decode('$value=').length == 32;
      } on FormatException {
        return false;
      }
    }

    final state = json['state'],
        owner = json['owner_identity'],
        generation = json['generation'];
    final roster = json['roster'];
    if (json['protocol_version'] is! int ||
        json['protocol_version'] != 1 ||
        json['binding_id'] is! String ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
        ).hasMatch(json['binding_id']) ||
        !integer(json['revision']) ||
        !integer(json['roster_version']) ||
        !{
          'idle',
          'switching',
          'active',
          'unavailable',
          'ended',
        }.contains(state) ||
        (owner != null && owner is! String) ||
        (generation != null &&
            (generation is! String ||
                !RegExp(r'^screen-[a-f0-9]{48}$').hasMatch(generation))) ||
        roster is! List ||
        roster.length > 10) {
      throw const FormatException('screen snapshot');
    }
    final identities = <String>{};
    final devices = <ScreenDevice>[];
    for (final entry in roster) {
      if (entry is! Map ||
          entry['identity'] is! String ||
          !RegExp(
            r'^@[^/\s]+:[^/\s]+/[^/\s]{1,255}$',
          ).hasMatch(entry['identity']) ||
          !identities.add(entry['identity']) ||
          !key(entry['curve']) ||
          !key(entry['ed'])) {
        throw const FormatException('screen roster');
      }
      devices.add((
        identity: entry['identity'],
        curve: entry['curve'],
        ed: entry['ed'],
      ));
    }
    if ((state == 'active' &&
            (owner == null ||
                generation == null ||
                !identities.contains(owner))) ||
        ({'idle', 'ended'}.contains(state) &&
            (owner != null || generation != null))) {
      throw const FormatException('screen owner');
    }
    return ScreenSnapshot._(
      json['binding_id'],
      state,
      owner,
      generation,
      json['revision'],
      json['roster_version'],
      List.unmodifiable(devices),
    );
  }
}
