import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/participant_colors.dart';
import 'package:voicechat_probe/profile_dialog.dart';
import 'package:voicechat_probe/contact_service.dart';
import 'package:voicechat_probe/theme.dart';
import 'conversation_list_test.dart' show ListClient;
import 'rich_media_test.dart' show RichClient;

class ProfileClient extends RichClient {
  @override
  Future<mx.Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => mx.Profile(userId: userId, displayName: 'Александра Соколова');
}

class ProfileContacts extends ContactService {
  ProfileContacts(mx.Client client) : super(client, 'http://unused.test');
  @override
  Future<bool> policyFor(String user) async => true;
}

void main() {
  test(
    'Participant colors are stable, distinct and readable across message surfaces',
    () {
      final ids = List.generate(20, (i) => '@person$i:local');
      final slots = participantColorSlots(ids);
      expect(slots, participantColorSlots(ids.reversed));
      expect(slots.values.toSet().length, ids.length);
      for (final palette in AppPalette.values) {
        final theme = palette.theme;
        final messages = theme.extension<MessageColors>()!;
        for (final background in [
          theme.colorScheme.surfaceContainerLowest,
          theme.colorScheme.primaryContainer,
          messages.start,
          messages.end,
        ]) {
          final colors = slots.values
              .map((slot) => participantNameColor(slot, background))
              .toList();
          if (palette == AppPalette.halo) {
            expect(
              colors.toSet().length,
              ids.length,
              reason: 'Halo $background',
            );
          }
          for (final color in colors) {
            final a = color.computeLuminance(),
                b = background.computeLuminance();
            final contrast = a > b
                ? (a + .05) / (b + .05)
                : (b + .05) / (a + .05);
            expect(
              contrast,
              greaterThanOrEqualTo(4.5),
              reason: '${palette.name}, $background, $color',
            );
          }
        }
      }
    },
  );
  testWidgets(
    'Dialog blur animates both ways, blocks background and returns its result',
    (tester) async {
      String? result;
      var backgroundTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  backgroundTaps++;
                  result = await showAppDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) => AlertDialog(
                      title: const Text('Окно'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, 'done'),
                          child: const Text('Готово'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final halfway = tester
          .widget<BackdropFilter>(find.byType(BackdropFilter))
          .filter;
      expect(halfway, isNot(ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5)));
      await tester.pumpAndSettle();
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
        ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      );
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('Окно'), findsOneWidget);
      expect(backgroundTaps, 1);
      await tester.tap(find.text('Готово'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
        isNot(ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(result, 'done');
    },
  );
  testWidgets('Reduced motion keeps static blur without a transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (context) => const AlertDialog(title: Text('Окно')),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
    );
    expect(
      ModalRoute.of(tester.element(find.text('Окно')))!.transitionDuration,
      Duration.zero,
    );
  });
  testWidgets(
    'First person and group stay below search during tab transitions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = ListClient();
      var groups = false;
      for (var i = 0; i < 16; i++) {
        final room = mx.Room(id: '!room$i:local', client: client);
        room.states[mx.EventTypes.RoomName] = {
          '': mx.StrippedStateEvent(
            type: mx.EventTypes.RoomName,
            stateKey: '',
            senderId: client.userID,
            content: {'name': 'Чат $i'},
          ),
        };
        client.rooms.add(room);
        if (i.isEven) client.directChats['@person$i:local'] = [room.id];
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => ConversationList(
                client: client,
                groups: groups,
                onTabChanged: (value) => update(() => groups = value),
                onSelect: (_) {},
                onNewPerson: () {},
                onNewGroup: () {},
                onSettings: () {},
              ),
            ),
          ),
        ),
      );
      for (final tab in ['Люди', 'Группы', 'Люди']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        final searchBottom = tester.getBottomLeft(find.byType(TextField)).dy;
        for (final tile
            in find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(ListTile),
                )
                .evaluate()) {
          expect(
            tester.getTopLeft(find.byWidget(tile.widget)).dy,
            greaterThanOrEqualTo(searchBottom + 12),
          );
        }
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Profile retains own, contact, pending and declined actions on a narrow screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final state in ['own', 'accepted', 'pending', 'declined']) {
        final client = ProfileClient();
        final contacts = ProfileContacts(client)..available = true;
        final user = state == 'own' ? client.userID : '@friend:local';
        if (state != 'own') {
          contacts.requests = [
            ContactRequest.fromJson({
              'id': 'a' * 32,
              'sender': client.userID,
              'recipient': user,
              'room_id': '!dm:local',
              'state': state,
            }),
          ];
        }
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showAppDialog<String>(
                      context: context,
                      builder: (_) => ProfileDialog(
                        client: client,
                        contacts: contacts,
                        userId: user,
                      ),
                    );
                  },
                  child: const Text('Профиль'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Профиль'));
        await tester.pumpAndSettle();
        expect(find.text('Александра Соколова'), findsOneWidget);
        expect(find.text(user), findsOneWidget);
        final action = state == 'own'
            ? 'Изменить аватар'
            : state == 'accepted'
            ? 'Написать'
            : null;
        if (action != null) {
          await tester.ensureVisible(find.text(action));
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(result, state == 'own' ? 'avatar' : 'contact');
        } else {
          expect(
            find.text(
              state == 'pending'
                  ? 'Запрос ожидает подтверждения'
                  : 'Запрос отклонён',
            ),
            findsOneWidget,
          );
          expect(find.text('Написать'), findsNothing);
          await tester.tap(find.byTooltip('Закрыть'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        contacts.dispose();
      }
    },
  );
}
