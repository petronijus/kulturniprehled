import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/core/widgets/morphing_hero_cover.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';

const Color _ghostColor = Color(0xFFB1B1B1);
const double _ghostFontSize = 100;
const double _ghostBlur = 7.5;
const double _coverDiameter = 300;

class AgendaScreen extends ConsumerStatefulWidget {
  const AgendaScreen({super.key});

  @override
  ConsumerState<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends ConsumerState<AgendaScreen> {
  @override
  void initState() {
    super.initState();
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: agendaAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => _ErrorList(
            message: 'Načítání selhalo: $error',
            onRetry: _refresh,
          ),
          data: _AgendaList.new,
        ),
      ),
    );
  }
}

class _AgendaList extends StatelessWidget {
  const _AgendaList(this.rows);

  final List<CachedEventRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          32,
          MediaQuery.of(context).padding.top + 120,
          32,
          120,
        ),
        children: const <Widget>[
          Text(
            'Žádné události',
            style: TextStyle(
              fontFamily: 'Gloock',
              fontSize: 40,
              height: 1.0,
              color: Colors.black,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Přidej první lístek nebo počkej na sync.',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
        ],
      );
    }

    final List<_MonthGroup> months = _groupByMonth(rows);

    // Top padding clears the floating Kp logo overlay (logo lives in the
    // home shell now, not in this screen). Bottom padding is ~half the
    // screen height so the last card can be scrolled up into the middle
    // of the viewport — gives the bottom item the same breathing room as
    // any other.
    final MediaQueryData mq = MediaQuery.of(context);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: mq.padding.top + 64,
        bottom: mq.size.height * 0.5,
      ),
      itemCount: months.length,
      itemBuilder: (context, index) => _MonthSection(group: months[index]),
    );
  }

  static List<_MonthGroup> _groupByMonth(List<CachedEventRow> rows) {
    final List<_MonthGroup> out = <_MonthGroup>[];
    int? lastYear;
    int? lastMonth;
    for (final CachedEventRow e in rows) {
      final DateTime local = e.startsAt.toLocal();
      if (local.year != lastYear || local.month != lastMonth) {
        out.add(_MonthGroup(year: local.year, month: local.month, events: []));
        lastYear = local.year;
        lastMonth = local.month;
      }
      out.last.events.add(e);
    }
    return out;
  }
}

class _MonthGroup {
  _MonthGroup({required this.year, required this.month, required this.events});

  final int year;
  final int month;
  final List<CachedEventRow> events;
}

class _MonthSection extends StatelessWidget {
  const _MonthSection({required this.group});

  final _MonthGroup group;

  @override
  Widget build(BuildContext context) {
    // Czech month name, first letter uppercase.
    final String raw = DateFormat(
      'LLLL',
      'cs',
    ).format(DateTime(group.year, group.month));
    final String label = raw.isEmpty
        ? raw
        : raw[0].toUpperCase() + raw.substring(1);

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Giant blurred month label sitting behind the first card.
        Positioned(
          left: -20,
          top: 24,
          right: 0,
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: _ghostBlur,
                sigmaY: _ghostBlur,
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'StackSansNotch',
                  fontWeight: FontWeight.w700,
                  fontSize: _ghostFontSize,
                  color: _ghostColor,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Reserve vertical space so the giant ghost lives mostly behind
            // the first card without pushing layout.
            const SizedBox(height: 80),
            for (final CachedEventRow e in group.events) _EventCard(event: e),
            const SizedBox(height: 16),
          ],
        ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

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
    final DateFormat dateFmt = DateFormat('EEEE d.M.', 'cs');
    final DateFormat timeFmt = DateFormat('HH:mm', 'cs');
    final String dateLabel = _capitalize(dateFmt.format(local));
    final String timeLabel = timeFmt.format(local);
    final String catLabel = _categoryLabel(event.category);

    return InkWell(
      // Pass the cached row as extra so the detail screen can render the
      // cover Hero on the very first frame — without it, Hero push has no
      // destination registered and falls back to a plain fade.
      onTap: () => context.go('/agenda/events/${event.id}', extra: event),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 0, 24),
        // SizedBox locks the tile height to the cover diameter so taps on
        // the lower half of the cover hit *this* card's InkWell instead of
        // leaking through to the next list item.
        child: SizedBox(
          height: _coverDiameter,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // Circular cover, slight bleed past the right edge per Figma.
              Positioned(
                right: -16,
                top: 0,
                child: SizedBox(
                  width: _coverDiameter,
                  height: _coverDiameter,
                  child: MorphingHeroCover(
                    tag: 'cover-${event.id}',
                    imageUrl: event.coverImageUrl,
                    borderRadius: BorderRadius.circular(_coverDiameter / 2),
                    fallback: Container(
                      color: const Color(0xFFEFEFEF),
                      alignment: Alignment.center,
                      child: Icon(
                        _iconFor(event.category),
                        size: 64,
                        color: Colors.black38,
                      ),
                    ),
                  ),
                ),
              ),
              // Title + date row, sitting on top of the cover.
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: 240,
                      child: BlurInText(
                        key: ValueKey<String>('title-${event.id}'),
                        text: event.title,
                        style: const TextStyle(
                          fontFamily: 'Gloock',
                          fontSize: 50,
                          height: 1.0,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _DateRow(
                      leading: catLabel,
                      center: dateLabel,
                      trailing: timeLabel,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.leading,
    required this.center,
    required this.trailing,
  });

  final String leading;
  final String center;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    const TextStyle style = TextStyle(
      fontFamily: 'StackSansNotch',
      fontWeight: FontWeight.w600,
      fontSize: 12,
      color: Colors.black,
      letterSpacing: 0.48,
      height: 1.2,
    );
    return Row(
      children: <Widget>[
        Text(leading, style: style),
        const SizedBox(width: 8),
        const Expanded(child: _Hairline()),
        const SizedBox(width: 8),
        Text(center, style: style),
        const SizedBox(width: 8),
        const Expanded(child: _Hairline()),
        const SizedBox(width: 8),
        Text(trailing, style: style),
      ],
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: Colors.black);
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
        const Icon(Icons.cloud_off, size: 80, color: Colors.black38),
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
