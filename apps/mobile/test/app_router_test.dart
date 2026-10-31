import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
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

import 'helpers/in_memory_db.dart';

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
Future<void> _pumpApp(WidgetTester tester) async {
  final KpDatabase db = buildInMemoryDatabase();
  addTearDown(db.close);
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
}

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
}
