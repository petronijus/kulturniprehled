import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/event_dto.dart';

// Offline-first repository. The UI watches the drift cache and never blocks
// on the network; a background sync replenishes the cache on demand.

class EventsRepository {
  EventsRepository(this._db);

  final KpDatabase _db;

  Stream<List<CachedEventRow>> watchAgenda() => _db.watchAgenda();

  Future<CachedEventRow?> getEvent(String id) => _db.findEvent(id);

  Future<List<CachedTicketRow>> ticketsForEvent(String eventId) =>
      _db.ticketsForEvent(eventId);

  Future<void> upsertEvent(EventDto event) =>
      _db.upsertEvent(event.toCompanion());

  Future<void> upsertTicket(TicketDto ticket) =>
      _db.upsertTicket(ticket.toCompanion());
}

final Provider<EventsRepository> eventsRepositoryProvider =
    Provider<EventsRepository>(
      (ref) => EventsRepository(ref.read(kpDatabaseProvider)),
    );

final StreamProvider<List<CachedEventRow>> agendaProvider =
    StreamProvider<List<CachedEventRow>>(
      (ref) => ref.read(eventsRepositoryProvider).watchAgenda(),
    );
