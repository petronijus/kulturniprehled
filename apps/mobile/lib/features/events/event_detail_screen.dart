import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({required this.eventId, super.key});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EventsRepository repo = ref.read(eventsRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Detail události')),
      body: FutureBuilder<CachedEventRow?>(
        future: repo.getEvent(eventId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final CachedEventRow? event = snapshot.data;
          if (event == null) {
            return const Center(child: Text('Událost nenalezena.'));
          }
          return FutureBuilder<List<CachedTicketRow>>(
            future: repo.ticketsForEvent(event.id),
            builder: (context, ticketSnapshot) {
              final List<CachedTicketRow> tickets =
                  ticketSnapshot.data ?? const <CachedTicketRow>[];
              return _EventDetailBody(event: event, tickets: tickets);
            },
          );
        },
      ),
    );
  }
}

class _EventDetailBody extends StatelessWidget {
  const _EventDetailBody({required this.event, required this.tickets});

  final CachedEventRow event;
  final List<CachedTicketRow> tickets;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('EEEE d. MMMM yyyy · HH:mm', 'cs');
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(event.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          fmt.format(event.startsAt.toLocal()),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (event.notes != null && event.notes!.isNotEmpty) ...<Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(event.notes!),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          'Lístky (${tickets.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (tickets.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Žádné lístky zatím nahrané.'),
          )
        else
          ...tickets.map(
            (ticket) => Card(
              child: ListTile(
                leading: const Icon(Icons.attach_file),
                title: Text(ticket.originalFilename ?? ticket.id),
                subtitle: Text(
                  '${ticket.mimeType} · '
                  '${ticket.sizeBytes != null ? '${(ticket.sizeBytes! / 1024).toStringAsFixed(1)} kB' : 'velikost neznámá'}',
                ),
              ),
            ),
          ),
      ],
    );
  }
}
