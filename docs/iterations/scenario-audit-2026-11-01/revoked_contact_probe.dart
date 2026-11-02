// UA-27: cached accepted contacts outlive the Matrix session after remote revoke.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/contact_service.dart';

import '../../../apps/client/test/call_window_test.dart' show WindowDatabase;

void main() {
  test(
    'UA-27.C08 cached contacts must tolerate a cleared userID after revocation',
    () async {
      final client = Client('logged-out-qa', database: WindowDatabase());
      final contacts = ContactService(client, 'http://localhost:18090');
      contacts.requests = [
        ContactRequest.fromJson({
          'id': 'a' * 32,
          'sender': '@qa_alice:local',
          'recipient': '@qa_bob:local',
          'room_id': '!qa:local',
          'state': 'accepted',
        }),
      ];
      addTearDown(client.dispose);
      expect(client.userID, isNull);
      expect(
        () => contacts.acceptedUsers,
        returnsNormally,
        reason: 'Presence and UI refresh continue after the SDK clears a revoked session',
      );
      expect(contacts.acceptedUsers, isEmpty);
    },
  );
}
