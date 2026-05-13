import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _focused = DateTime.now();
  DateTime? _selected = DateTime.now();

  // Local-date key so events spanning multiple days don't collide with
  // each other in the marker map.
  DateTime _dayKey(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  Map<DateTime, List<CachedEventRow>> _bucket(List<CachedEventRow> rows) {
    final Map<DateTime, List<CachedEventRow>> map =
        <DateTime, List<CachedEventRow>>{};
    for (final CachedEventRow row in rows) {
      final DateTime key = _dayKey(row.startsAt.toLocal());
      map.putIfAbsent(key, () => <CachedEventRow>[]).add(row);
    }
    return map;
  }

  Color _markerColor(BuildContext context, String category) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    switch (category) {
      case 'concert':
        return scheme.primary;
      case 'theatre':
        return scheme.tertiary;
      case 'cinema':
        return scheme.secondary;
      default:
        return scheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Kalendář')),
      body: agendaAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('Chyba: $error')),
        data: (rows) {
          final Map<DateTime, List<CachedEventRow>> buckets = _bucket(rows);
          final DateTime? selected = _selected;
          final List<CachedEventRow> selectedRows = selected == null
              ? <CachedEventRow>[]
              : (buckets[_dayKey(selected)] ?? <CachedEventRow>[]);
          return Column(
            children: <Widget>[
              TableCalendar<CachedEventRow>(
                locale: 'cs_CZ',
                firstDay: DateTime.utc(2020),
                lastDay: DateTime.utc(2030, 12, 31),
                focusedDay: _focused,
                selectedDayPredicate: (day) =>
                    selected != null && isSameDay(day, selected),
                eventLoader: (day) =>
                    buckets[_dayKey(day)] ?? <CachedEventRow>[],
                startingDayOfWeek: StartingDayOfWeek.monday,
                availableCalendarFormats: const <CalendarFormat, String>{
                  CalendarFormat.month: 'Měsíc',
                },
                calendarStyle: CalendarStyle(
                  markerSize: 6,
                  markerDecoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                onDaySelected: (selectedDay, focusedDay) {
                  setState(() {
                    _selected = selectedDay;
                    _focused = focusedDay;
                  });
                },
                onPageChanged: (focused) => _focused = focused,
                calendarBuilders: CalendarBuilders<CachedEventRow>(
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      bottom: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final CachedEventRow e in events.take(3))
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _markerColor(context, e.category),
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: selectedRows.isEmpty
                    ? Center(
                        child: Text(
                          selected == null
                              ? 'Vyber den v kalendáři.'
                              : 'Nic v ten den.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: selectedRows.length,
                        itemBuilder: (context, index) {
                          final CachedEventRow event = selectedRows[index];
                          final DateFormat fmt = DateFormat('HH:mm', 'cs');
                          return ListTile(
                            title: Text(event.title),
                            subtitle: Text(
                              '${fmt.format(event.startsAt.toLocal())} · '
                              '${event.category}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                context.go('/agenda/events/${event.id}'),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
