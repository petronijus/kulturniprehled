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

class _NextEventBanner extends StatelessWidget {
  const _NextEventBanner({required this.event, required this.onTap});

  final CachedEventRow event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DateFormat fmt = DateFormat('EEEE d. MMMM · HH:mm', 'cs');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Icon(Icons.event_available, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Nejbližší',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        event.title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        fmt.format(event.startsAt.toLocal()),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSecondaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
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

  Widget? _eventDayCell(
    BuildContext context,
    DateTime day,
    Map<DateTime, List<CachedEventRow>> buckets, {
    required bool isToday,
  }) {
    final List<CachedEventRow> events =
        buckets[_dayKey(day)] ?? <CachedEventRow>[];
    if (events.isEmpty) {
      // Returning null lets table_calendar fall back to its default builder.
      return null;
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color bg = isToday
        ? scheme.primary.withValues(alpha: 0.25)
        : scheme.primaryContainer.withValues(alpha: 0.6);
    final Color fg = isToday ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: isToday ? Border.all(color: scheme.primary, width: 1.5) : null,
      ),
      alignment: Alignment.center,
      child: Text(
        '${day.day}',
        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  void _onNextTap(CachedEventRow event) {
    final DateTime eventDay = _dayKey(event.startsAt.toLocal());
    final bool alreadyFocused =
        _focused.year == eventDay.year && _focused.month == eventDay.month;
    final bool alreadySelected =
        _selected != null && isSameDay(_selected!, eventDay);
    if (alreadyFocused && alreadySelected) {
      // Second tap on the banner — go to the detail.
      context.go('/agenda/events/${event.id}');
      return;
    }
    setState(() {
      _focused = eventDay;
      _selected = eventDay;
    });
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
          final DateTime now = DateTime.now();
          final CachedEventRow? next = rows
              .where((e) => e.startsAt.toLocal().isAfter(now))
              .fold<CachedEventRow?>(null, (acc, e) {
                if (acc == null) return e;
                return e.startsAt.isBefore(acc.startsAt) ? e : acc;
              });
          return Column(
            children: <Widget>[
              if (next != null)
                _NextEventBanner(event: next, onTap: () => _onNextTap(next)),
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
                  // Days with events get a tinted background pill — far more
                  // visible than the 6 px dots at the bottom alone. Selected
                  // and today builders are left to defaults so we don't fight
                  // table_calendar's own highlight chain.
                  defaultBuilder: (context, day, focusedDay) =>
                      _eventDayCell(context, day, buckets, isToday: false),
                  todayBuilder: (context, day, focusedDay) =>
                      _eventDayCell(context, day, buckets, isToday: true),
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
