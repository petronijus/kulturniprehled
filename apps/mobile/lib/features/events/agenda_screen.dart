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
            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length + (imminent.isEmpty ? 0 : 1),
              itemBuilder: (context, index) {
                if (imminent.isNotEmpty && index == 0) {
                  return _ImminentBanner(events: imminent);
                }
                final int rowIndex = imminent.isEmpty ? index : index - 1;
                return _AgendaTile(event: rows[rowIndex]);
              },
            );
          },
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

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('EEE d. M. yyyy · HH:mm', 'cs');
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Icon(_iconFor(event.category)),
        ),
        title: Text(event.title),
        subtitle: Text(fmt.format(event.startsAt.toLocal())),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/agenda/events/${event.id}'),
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
