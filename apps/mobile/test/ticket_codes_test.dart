import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/event_dto.dart';
import 'package:kp_mobile/features/tickets/ticket_code.dart';
import 'package:kp_mobile/features/tickets/ticket_codes_view.dart';

import 'helpers/in_memory_db.dart';
import 'helpers/ticket_code_fixtures.dart';

final DateTime _base = DateTime.utc(2099);

CachedTicketRow _ticket(String id, List<Map<String, Object?>>? codes) {
  return CachedTicketRow(
    id: id,
    eventId: 'evt-1',
    workspaceId: 'ws-1',
    mimeType: 'application/pdf',
    originalFilename: '$id.pdf',
    codesJson: codes == null ? null : jsonEncode(codes),
    version: 2,
    updatedAt: _base,
    cachedAt: _base,
  );
}

Map<String, dynamic> _ticketPayload(Object? codes) => <String, dynamic>{
  'id': 't-1',
  'event_id': 'evt-1',
  'workspace_id': 'ws-1',
  'mime_type': 'application/pdf',
  'version': 2,
  'updated_at': '2099-01-01T00:00:00Z',
  'codes': codes,
};

Future<void> _pumpCarousel(
  WidgetTester tester,
  List<TicketCodeEntry> entries,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TicketCodesCarousel(eventId: 'evt-1', entries: entries),
      ),
    ),
  );
}

void main() {
  test('sync payload codes land in the cached row', () {
    final TicketDto dto = TicketDto.fromMap(_ticketPayload(<Object?>[qrSeat1]));

    final TicketCode code = TicketCode.listFromJson(dto.codesJson)!.single;
    expect(code.text, 'SEAT-1');
    expect(code.isDrawable, isTrue);
    expect(code.isLinear, isFalse);
    expect((code.modulesWidth, code.modulesHeight), (21, 21));
    // A real PNG, not just any base64.
    expect(code.modulesPng!.sublist(1, 4), utf8.encode('PNG'));
  });

  test('an unscanned ticket keeps null codes, not an empty list', () {
    final TicketDto dto = TicketDto.fromMap(_ticketPayload(null));

    expect(dto.codesJson, isNull);
    expect(TicketCode.listFromJson(dto.codesJson), isNull);
  });

  test('entries keep ticket order and skip codes without a redraw', () {
    final List<TicketCodeEntry> entries = ticketCodeEntries(<CachedTicketRow>[
      _ticket('a', <Map<String, Object?>>[qrSeat1, notRedrawn]),
      _ticket('b', null),
      _ticket('c', <Map<String, Object?>>[code128Ticket]),
    ]);

    expect(
      entries.map((TicketCodeEntry e) => (e.ticket.id, e.code.text)),
      <(String, String)>[('a', 'SEAT-1'), ('c', '1234567890128')],
    );
  });

  test('a corrupt codes column hides the codes instead of crashing', () {
    final CachedTicketRow broken = _ticket(
      'a',
      null,
    ).copyWith(codesJson: const drift.Value<String?>('{not json'));

    expect(ticketCodeEntries(<CachedTicketRow>[broken]), isEmpty);
  });

  testWidgets('carousel draws the codes and swipes between tickets', (
    WidgetTester tester,
  ) async {
    await _pumpCarousel(
      tester,
      ticketCodeEntries(<CachedTicketRow>[
        _ticket('first', <Map<String, Object?>>[qrSeat1]),
        _ticket('second', <Map<String, Object?>>[qrSeat2]),
      ]),
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('first.pdf'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('second.pdf'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('a single code shows no page indicator', (
    WidgetTester tester,
  ) async {
    await _pumpCarousel(
      tester,
      ticketCodeEntries(<CachedTicketRow>[
        _ticket('only', <Map<String, Object?>>[pdf417Ticket]),
      ]),
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining(' / '), findsNothing);
  });

  testWidgets('modules are scaled by whole device pixels', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _pumpCarousel(
      tester,
      ticketCodeEntries(<CachedTicketRow>[
        _ticket('only', <Map<String, Object?>>[pdf417Ticket]),
      ]),
    );

    final Image image = tester.widget<Image>(find.byType(Image));
    expect(image.filterQuality, FilterQuality.none);
    final double modulePixels = image.width! * 2.75 / 120;
    expect(modulePixels, closeTo(modulePixels.roundToDouble(), 1e-9));
    expect(modulePixels, greaterThanOrEqualTo(2));
    expect(image.height! * 2.75 / 21, closeTo(modulePixels, 1e-9));
  });

  testWidgets('the seat of the ticket sits above its code', (
    WidgetTester tester,
  ) async {
    await _pumpCarousel(
      tester,
      ticketCodeEntries(<CachedTicketRow>[
        _ticket('seated', <Map<String, Object?>>[
          <String, Object?>{
            ...qrSeat1,
            'seat': 'Přízemí vpravo · Řada 10 · Místo 19',
          },
        ]),
        _ticket('standing', <Map<String, Object?>>[qrSeat2]),
      ]),
    );

    final Offset seat = tester.getCenter(
      find.text('Přízemí vpravo · Řada 10 · Místo 19'),
    );
    expect(seat.dy, lessThan(tester.getTopLeft(find.byType(Image)).dy));

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('standing.pdf'), findsOneWidget);
    expect(find.textContaining('Řada'), findsNothing);
  });

  testWidgets('linear codes print their digits under the bars', (
    WidgetTester tester,
  ) async {
    await _pumpCarousel(
      tester,
      ticketCodeEntries(<CachedTicketRow>[
        _ticket('only', <Map<String, Object?>>[code128Ticket]),
      ]),
    );

    expect(find.text('1234567890128'), findsOneWidget);
  });

  group('filling codes read over REST', () {
    late KpDatabase db;
    setUp(() => db = buildInMemoryDatabase());
    tearDown(() => db.close());

    CachedTicketsCompanion fetched({int version = 2}) => TicketDto.fromMap(
      _ticketPayload(<Object?>[qrSeat1])..['version'] = version,
    ).toCompanion();

    Future<void> seed({
      int version = 2,
      DateTime? deletedAt,
      String? codesJson,
    }) => db.upsertTicket(
      TicketDto.fromMap(
        _ticketPayload(null)..['version'] = version,
      ).toCompanion().copyWith(
        deletedAt: drift.Value<DateTime?>(deletedAt),
        codesJson: drift.Value<String?>(codesJson),
      ),
    );

    test('fills a row an older app synced without codes', () async {
      await seed();

      expect(await db.fillMissingTicketCodes(fetched()), isTrue);
      expect((await db.findTicket('t-1'))!.codesJson, isNotNull);
    });

    test('never brings back a ticket deleted meanwhile', () async {
      await seed(version: 3, deletedAt: _base);

      expect(await db.fillMissingTicketCodes(fetched()), isFalse);
      final CachedTicketRow row = (await db.findTicket('t-1'))!;
      expect(row.deletedAt, isNotNull);
      expect(row.version, 3);
    });

    test('never overwrites a newer synced row', () async {
      await seed(version: 4);

      expect(await db.fillMissingTicketCodes(fetched(version: 3)), isFalse);
      expect((await db.findTicket('t-1'))!.version, 4);
    });

    test('leaves rows that already have codes alone', () async {
      await seed(codesJson: '[]');

      expect(await db.fillMissingTicketCodes(fetched(version: 5)), isFalse);
      expect((await db.findTicket('t-1'))!.codesJson, '[]');
    });

    test('does not invent a ticket the device has not synced', () async {
      expect(await db.fillMissingTicketCodes(fetched()), isFalse);
      expect(await db.findTicket('t-1'), isNull);
    });
  });
}
