import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:kp_mobile/core/routing/app_router.dart';
import 'package:kp_mobile/core/widgets/date_row.dart';
import 'package:kp_mobile/core/widgets/local_first_image.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/tickets/ticket_codes_view.dart';

import 'helpers/in_memory_db.dart';
import 'helpers/ticket_code_fixtures.dart';

final CachedEventRow _event = CachedEventRow(
  id: 'evt-1',
  workspaceId: 'ws-1',
  title: 'Sokolov',
  category: 'concert',
  startsAt: DateTime.utc(2099, 3, 4, 18),
  venueTimezone: 'Europe/Prague',
  status: 'planned',
  source: 'manual',
  coverImageUrl: 'https://images.example.com/sokolov.jpg',
  version: 1,
  updatedAt: DateTime.utc(2099),
  cachedAt: DateTime.utc(2099),
);

class _SignedIn extends AuthController {
  @override
  AuthState build() => const AuthState(
    session: AuthSession(email: 'petr@example.com', userId: 'u-1'),
  );
}

class _IdleSyncController extends SyncController {
  @override
  SyncState build() => const SyncState();

  @override
  Future<void> pullChanges({int batchSize = 500}) async {}
}

class _StubEventsRepository extends EventsRepository {
  _StubEventsRepository(super.db);

  @override
  Future<CachedEventRow?> getEvent(String id) =>
      Future<CachedEventRow?>.value(id == _event.id ? _event : null);

  @override
  Future<List<CachedTicketRow>> ticketsForEvent(String eventId) =>
      Future<List<CachedTicketRow>>.value(<CachedTicketRow>[]);
}

/// Widgets of [type] under no [Hero]: in this tree only a hero flight's
/// shuttle, which lives in the navigator's overlay, fits that.
Finder _inFlight(Type type) => find.byElementPredicate((Element element) {
  if (element.widget.runtimeType != type) {
    return false;
  }
  bool underHero = false;
  element.visitAncestorElements((Element ancestor) {
    underHero = ancestor.widget is Hero;
    return !underHero;
  });
  return !underHero;
}, description: '$type in a hero flight');

/// The app through its own router, signed in, with one agenda event.
Future<GoRouter> _pumpApp(
  WidgetTester tester, {
  List<CachedTicketRow> tickets = const <CachedTicketRow>[],
}) async {
  final KpDatabase db = buildInMemoryDatabase();
  addTearDown(db.close);
  for (final CachedTicketRow ticket in tickets) {
    await db.upsertTicket(ticket.toCompanion(false));
  }
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      authControllerProvider.overrideWith(_SignedIn.new),
      kpDatabaseProvider.overrideWith((ref) => db),
      agendaProvider.overrideWith(
        (ref) => Stream<List<CachedEventRow>>.value(<CachedEventRow>[_event]),
      ),
      syncControllerProvider.overrideWith(_IdleSyncController.new),
      eventsRepositoryProvider.overrideWith((ref) => _StubEventsRepository(db)),
      outboxConflictStreamProvider.overrideWith(
        (ref) => const Stream<OutboxConflict>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: container.read(appRouterProvider),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container.read(appRouterProvider);
}

CachedTicketRow _ticket(String id, Map<String, Object?> code) =>
    CachedTicketRow(
      id: id,
      eventId: 'evt-1',
      workspaceId: 'ws-1',
      mimeType: 'application/pdf',
      originalFilename: '$id.pdf',
      codesJson: jsonEncode(<Object?>[code]),
      version: 2,
      updatedAt: DateTime.utc(2099),
      cachedAt: DateTime.utc(2099),
    );

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  // Through the app's own router: go_router 18 silently gave every route a
  // NoTransitionPage, so the cover and date row stopped flying.
  testWidgets('cover and date row fly from the agenda to the detail', (
    tester,
  ) async {
    await _pumpApp(tester);

    await tester.tap(find.text('Sokolov'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // Mid-transition both heroes are shuttles in the overlay.
    expect(_inFlight(LocalFirstImage), findsOneWidget);
    expect(_inFlight(DateRow), findsOneWidget);

    await tester.pumpAndSettle();
    expect(_inFlight(LocalFirstImage), findsNothing);
    expect(find.byType(EventDetailScreen), findsOneWidget);
  });

  testWidgets('the logo menu shows the installed version and build', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Kulturní Přehled',
      packageName: 'com.kulturniprehled.kp_mobile',
      version: '1.3.2',
      buildNumber: '25',
      buildSignature: '',
    );
    await _pumpApp(tester);

    await tester.tap(find.image(const AssetImage('assets/brand/kp_logo.png')));
    await tester.pumpAndSettle();

    expect(find.text('Kulturní Přehled 1.3.2 (25)'), findsOneWidget);
  });

  // On the phone the second ticket opened as the first, and the bottom bar
  // and logo covered the full-screen code.
  testWidgets('full-screen codes open on the tapped ticket above the shell', (
    tester,
  ) async {
    final GoRouter router = await _pumpApp(
      tester,
      tickets: <CachedTicketRow>[
        _ticket('first', qrSeat1),
        _ticket('second', qrSeat2),
      ],
    );

    router.go('/agenda/events/evt-1/codes?i=1');
    await tester.pumpAndSettle();

    expect(find.byType(TicketCodesScreen), findsOneWidget);
    expect(find.text('second.pdf'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Agenda'), findsNothing);
    expect(
      find.image(const AssetImage('assets/brand/kp_logo.png')),
      findsNothing,
    );
  });
}
