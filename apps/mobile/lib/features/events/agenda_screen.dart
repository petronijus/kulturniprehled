import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/system/server_status.dart';

class AgendaScreen extends ConsumerStatefulWidget {
  const AgendaScreen({super.key});

  @override
  ConsumerState<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends ConsumerState<AgendaScreen> {
  @override
  void initState() {
    super.initState();
    // Fire a non-blocking sync the moment the screen mounts. The agenda
    // renders from cache immediately so the user is never staring at a
    // spinner.
    Future<void>.microtask(
      () => ref.read(syncControllerProvider.notifier).pullChanges(),
    );
  }

  Future<void> _refresh() =>
      ref.read(syncControllerProvider.notifier).pullChanges();

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    final ServerHealth health = ref.watch(serverStatusProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kulturní přehled'),
        actions: <Widget>[
          if (health == ServerHealth.unreachable)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Tooltip(
                message: 'Server nedostupný — pracuju z cache.',
                child: Icon(Icons.cloud_off, size: 20),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Odhlásit',
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: agendaAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => _ErrorList(
            message: 'Načítání selhalo: $error',
            onRetry: _refresh,
          ),
          data: (rows) {
            if (rows.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(32),
                children: const <Widget>[
                  SizedBox(height: 80),
                  Icon(Icons.event_busy, size: 80),
                  SizedBox(height: 16),
                  Text(
                    'Žádné události — přidej první lístek nebo počkej na sync.',
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }
            final DateTime now = DateTime.now();
            final DateTime cutoff = now.add(const Duration(hours: 24));
            final List<CachedEventRow> imminent = rows
                .where(
                  (e) =>
                      e.startsAt.toLocal().isAfter(now) &&
                      e.startsAt.toLocal().isBefore(cutoff),
                )
                .toList();
            // Flatten the agenda into a stream of widgets: optional imminent
            // banner, then month-header / tile / tile / month-header / ...
            // Months with zero events emit nothing — the header lives next
            // to its first tile.
            final List<Widget> items = <Widget>[];
            if (imminent.isNotEmpty) {
              items.add(_ImminentBanner(events: imminent));
            }
            int? lastYear;
            int? lastMonth;
            for (final CachedEventRow e in rows) {
              final DateTime local = e.startsAt.toLocal();
              if (local.year != lastYear || local.month != lastMonth) {
                items.add(_MonthHeader(year: local.year, month: local.month));
                lastYear = local.year;
                lastMonth = local.month;
              }
              items.add(_AgendaTile(event: e));
            }
            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              itemBuilder: (context, index) => items[index],
            );
          },
        ),
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.year, required this.month});

  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    // Format as e.g. "Červen 2026" — DateFormat lowercases the month name
    // in cs locale, so we uppercase the first letter for a header look.
    final String raw = DateFormat(
      'LLLL yyyy',
      'cs',
    ).format(DateTime(year, month));
    final String label = raw.isEmpty
        ? raw
        : raw[0].toUpperCase() + raw.substring(1);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _AgendaTile extends StatelessWidget {
  const _AgendaTile({required this.event});

  final CachedEventRow event;

  IconData _iconFor(String category) {
    switch (category) {
      case 'concert':
        return Icons.music_note;
      case 'theatre':
        return Icons.theater_comedy;
      case 'cinema':
        return Icons.local_movies;
      default:
        return Icons.event;
    }
  }

  /// Pulls a short program/teaser line out of `notes`. The skill writes a
  /// stable format starting with the program/season blurb on line one; we
  /// strip empty lines and seat-info / transit-info lines so the tile shows
  /// the headline, not logistics.
  String? _previewFromNotes(String? notes) {
    if (notes == null) {
      return null;
    }
    for (final String raw in notes.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('Místa:')) continue;
      if (line.startsWith('Místo:')) continue;
      if (line.startsWith('🚌')) continue;
      if (line.startsWith('Vstupenky')) continue;
      if (line.startsWith('•')) continue;
      return line;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('EEE d. M. yyyy · HH:mm', 'cs');
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? preview = _previewFromNotes(event.notes);
    final bool hasCover =
        event.coverImageUrl != null && event.coverImageUrl!.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/agenda/events/${event.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (hasCover)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  event.coverImageUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : Container(color: scheme.surfaceContainerHighest),
                  errorBuilder: (context, _, _) => Container(
                    color: scheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                      _iconFor(event.category),
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (!hasCover)
                    Padding(
                      padding: const EdgeInsets.only(right: 12, top: 4),
                      child: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        child: Icon(_iconFor(event.category)),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          event.title,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          fmt.format(event.startsAt.toLocal()),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        if (preview != null) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            preview,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImminentBanner extends StatelessWidget {
  const _ImminentBanner({required this.events});

  final List<CachedEventRow> events;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('HH:mm', 'cs');
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.notifications_active_outlined,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                'V nejbližších 24 h',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final CachedEventRow e in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${fmt.format(e.startsAt.toLocal())} · ${e.title}',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorList extends StatelessWidget {
  const _ErrorList({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 80),
        const Icon(Icons.cloud_off, size: 80),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async => onRetry(),
          child: const Text('Zkusit znovu'),
        ),
      ],
    );
  }
}
