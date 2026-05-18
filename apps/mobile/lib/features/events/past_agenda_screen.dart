import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

class PastAgendaScreen extends ConsumerWidget {
  const PastAgendaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: agendaAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Načítání selhalo: $error'),
            ),
          ),
          data: (rows) => _PastList(rows: _filterAndSortPast(rows)),
        ),
      ),
    );
  }

  static List<CachedEventRow> _filterAndSortPast(List<CachedEventRow> rows) {
    final DateTime now = DateTime.now();
    final List<CachedEventRow> past = rows
        .where((r) => r.startsAt.toLocal().isBefore(now))
        .toList();
    past.sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return past;
  }
}

class _PastList extends StatelessWidget {
  const _PastList({required this.rows});

  final List<CachedEventRow> rows;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black),
                  onPressed: () => context.go('/agenda'),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Minulé',
                  style: TextStyle(
                    fontFamily: 'Gloock',
                    fontSize: 60,
                    height: 1.0,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (rows.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(32, 64, 32, 32),
              child: Text(
                'Zatím nic neproběhlo.',
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _PastEventTile(event: rows[i]),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.of(context).size.height * 0.3),
        ),
      ],
    );
  }
}

class _PastEventTile extends StatelessWidget {
  const _PastEventTile({required this.event});

  final CachedEventRow event;

  String _categoryLabel(String category) {
    switch (category) {
      case 'concert':
        return 'Koncert';
      case 'theatre':
        return 'Divadlo';
      case 'cinema':
        return 'Film';
      case 'exhibition':
        return 'Výstava';
      default:
        return 'Událost';
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateTime local = event.startsAt.toLocal();
    final String dateLabel = DateFormat('d.M. yyyy', 'cs').format(local);
    final String catLabel = _categoryLabel(event.category);
    return InkWell(
      onTap: () => context.go('/agenda/events/${event.id}', extra: event),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Small thumbnail or category icon
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 56,
                height: 56,
                color: const Color(0xFFEFEFEF),
                child: _coverOrIcon(),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontFamily: 'StackSansHeadline',
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                      height: 1.2,
                      color: Colors.black,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$catLabel · $dateLabel',
                    style: const TextStyle(
                      fontFamily: 'StackSansHeadline',
                      fontWeight: FontWeight.w300,
                      fontSize: 13,
                      color: Colors.black54,
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

  Widget _coverOrIcon() {
    final String? url = event.coverImageUrl;
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, e, s) => _iconWidget(),
      );
    }
    return _iconWidget();
  }

  Widget _iconWidget() {
    IconData icon;
    switch (event.category) {
      case 'concert':
        icon = Icons.music_note;
        break;
      case 'theatre':
        icon = Icons.theater_comedy;
        break;
      case 'cinema':
        icon = Icons.local_movies;
        break;
      default:
        icon = Icons.event;
    }
    return Center(child: Icon(icon, size: 28, color: Colors.black38));
  }
}
