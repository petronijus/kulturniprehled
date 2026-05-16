import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/core/widgets/morphing_hero_cover.dart';
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
    // Agenda passes the CachedEventRow as `extra` so we can render the
    // cover Hero on the first frame — required for the push-direction
    // Hero flight to find a destination endpoint.
    final CachedEventRow? initialEvent =
        GoRouterState.of(context).extra as CachedEventRow?;
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
        initialData: initialEvent,
        builder: (context, snapshot) {
          final CachedEventRow? event = snapshot.data;
          if (event == null) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
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
        if (event.coverImageUrl != null &&
            event.coverImageUrl!.isNotEmpty) ...<Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: MorphingHeroCover(
              tag: 'cover-${event.id}',
              imageUrl: event.coverImageUrl,
              borderRadius: BorderRadius.circular(12),
              fallback: Container(
                color: scheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        BlurInText(
          key: ValueKey<String>('detail-title-${event.id}'),
          text: event.title,
          style:
              Theme.of(context).textTheme.headlineSmall ??
              const TextStyle(fontSize: 24),
        ),
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
        if (event.venueAddress != null &&
            event.venueAddress!.isNotEmpty) ...<Widget>[
          _VenueSection(
            address: event.venueAddress!,
            imageUrl: event.venueImageUrl,
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

class _VenueSection extends StatelessWidget {
  const _VenueSection({required this.address, this.imageUrl});

  final String address;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (imageUrl != null && imageUrl!.isNotEmpty)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : Container(
                        color: scheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                errorBuilder: (context, _, _) => Container(
                  color: scheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Icon(Icons.place_outlined, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    address,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _openMaps(address),
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Mapa'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMaps(String address) async {
    // Universal Maps search URL — opens Google Maps on Android, Apple Maps
    // on iOS via the universal link, and the web fallback in a browser if
    // neither is installed.
    final Uri uri = Uri.https(
      'www.google.com',
      '/maps/search/',
      <String, String>{'api': '1', 'query': address},
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
