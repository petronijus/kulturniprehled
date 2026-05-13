import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/outbox/conflict_dialog.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

class EventDetailScreen extends ConsumerStatefulWidget {
  const EventDetailScreen({required this.eventId, super.key});

  final String eventId;

  @override
  ConsumerState<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends ConsumerState<EventDetailScreen> {
  @override
  Widget build(BuildContext context) {
    // Surface outbox conflicts for this event (if one comes in while we're
    // looking at the detail screen, pop the resolution dialog right there).
    ref.listen<AsyncValue<OutboxConflict>>(outboxConflictStreamProvider, (
      previous,
      next,
    ) async {
      final OutboxConflict? conflict = next.value;
      if (conflict == null || conflict.entityId != widget.eventId) {
        return;
      }
      if (!mounted) {
        return;
      }
      final ConflictResolution? choice = await showConflictResolutionDialog(
        context: context,
        conflict: conflict,
      );
      if (!mounted || choice == null) {
        return;
      }
      final OutboxController outbox = ref.read(
        outboxControllerProvider.notifier,
      );
      if (choice == ConflictResolution.useServer) {
        await outbox.discardPending(conflict.opId);
      } else {
        await outbox.requeueWithFreshBaseVersion(
          opId: conflict.opId,
          baseVersion: conflict.currentVersion,
        );
      }
    });

    final EventsRepository repo = ref.read(eventsRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detail události'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Upravit',
            onPressed: () =>
                context.go('/agenda/events/${widget.eventId}/edit'),
          ),
        ],
      ),
      body: FutureBuilder<CachedEventRow?>(
        future: repo.getEvent(widget.eventId),
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

  String _statusLabel(String status) {
    switch (status) {
      case 'planned':
        return 'Plánováno';
      case 'attended':
        return 'Bylo to';
      case 'cancelled':
        return 'Zrušeno';
      case 'missed':
        return 'Nestihli';
      default:
        return status;
    }
  }

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
        const SizedBox(height: 8),
        Chip(label: Text(_statusLabel(event.status))),
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
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(
                  '/agenda/events/${event.id}/tickets/${ticket.id}',
                ),
              ),
            ),
          ),
      ],
    );
  }
}
