import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/core/sensors/tilt_provider.dart';
import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/core/widgets/date_row.dart';
import 'package:kp_mobile/core/widgets/morphing_hero_cover.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/agenda_replay_provider.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/events/past_agenda_screen.dart' show PastHeader;
import 'package:kp_mobile/features/sync/sync_controller.dart';

const Color _ghostColor = Color(0xFFB1B1B1);
const double _ghostFontSize = 100;
const double _ghostBlur = 7.5;
const double _coverDiameter = 300;

// Delay between successive titles' blur-in start. Each card waits
// `index * _staggerMs` after agenda mount before it animates.
const int _staggerMs = 300;

class AgendaScreen extends ConsumerStatefulWidget {
  const AgendaScreen({super.key});

  @override
  ConsumerState<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends ConsumerState<AgendaScreen> {
  final ScrollController _scrollCtrl = ScrollController();
  // Per-frame replay signal — every notify causes BlurInText to reset
  // and play through. Bumped by agendaReplayProvider listener below.
  final ValueNotifier<int> _replayTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(syncControllerProvider.notifier).pullChanges(),
    );
  }

  @override
  void dispose() {
    _replayTick.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() =>
      ref.read(syncControllerProvider.notifier).pullChanges();

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    // Replay BlurInText titles every time something signals it
    // (returning from detail, tapping the agenda tab from another branch).
    ref.listen<int>(agendaReplayProvider, (previous, next) {
      if (previous != next) {
        _replayTick.value++;
      }
    });
    return Scaffold(
      backgroundColor: Colors.white,
      body: _ParallaxScope(
        scrollCtrl: _scrollCtrl,
        tilt: ref.read(tiltListenableProvider),
        child: _ReplayScope(
          tick: _replayTick,
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: agendaAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => _ErrorList(
                message: 'Načítání selhalo: $error',
                onRetry: _refresh,
              ),
              data: (rows) => _AgendaList(rows: rows, scrollCtrl: _scrollCtrl),
            ),
          ),
        ),
      ),
    );
  }
}

/// Carries the BlurInText replay signal down through the tree so each
/// event card can wire its title without prop-drilling.
class _ReplayScope extends InheritedWidget {
  const _ReplayScope({required this.tick, required super.child});

  final ValueListenable<int> tick;

  static ValueListenable<int> of(BuildContext context) {
    final _ReplayScope? scope = context
        .dependOnInheritedWidgetOfExactType<_ReplayScope>();
    assert(scope != null, '_ReplayScope missing from context');
    return scope!.tick;
  }

  @override
  bool updateShouldNotify(_ReplayScope old) => tick != old.tick;
}

/// Inherited carrier for the parallax inputs (scroll position + smoothed
/// device tilt). Wrapped widgets call `_ParallaxScope.of(context)` to grab
/// the listenables without prop-drilling them down through every layer.
class _ParallaxScope extends InheritedWidget {
  const _ParallaxScope({
    required this.scrollCtrl,
    required this.tilt,
    required super.child,
  });

  final ScrollController scrollCtrl;
  final ValueListenable<Offset> tilt;

  static _ParallaxScope of(BuildContext context) {
    final _ParallaxScope? scope = context
        .dependOnInheritedWidgetOfExactType<_ParallaxScope>();
    assert(scope != null, '_ParallaxScope missing from context');
    return scope!;
  }

  @override
  bool updateShouldNotify(_ParallaxScope old) =>
      scrollCtrl != old.scrollCtrl || tilt != old.tilt;
}

/// Wraps a layer with a Transform.translate driven by scroll position and
/// device tilt. Apply the same widget multiple times with different scale
/// factors to build a multi-layer parallax — background gets a small tilt
/// amplitude but a large scroll factor (it sticks), foreground gets the
/// opposite (it moves with the scroll, drifts more on tilt).
class _ParallaxLayer extends StatelessWidget {
  const _ParallaxLayer({
    required this.child,
    this.scrollFactor = 0,
    this.tiltAmplitude = Offset.zero,
  });

  final Widget child;

  /// Positive values translate the child *down* as the user scrolls down,
  /// which visually makes it lag behind the rest of the list (more "back").
  final double scrollFactor;

  /// Pixels of drift at full tilt (±1 on the normalised tilt input).
  final Offset tiltAmplitude;

  @override
  Widget build(BuildContext context) {
    final _ParallaxScope scope = _ParallaxScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[scope.scrollCtrl, scope.tilt]),
      builder: (context, _) {
        final double scroll = scope.scrollCtrl.hasClients
            ? scope.scrollCtrl.offset
            : 0.0;
        final Offset tilt = scope.tilt.value;
        final double dx = tilt.dx * tiltAmplitude.dx;
        final double dy = scroll * scrollFactor + tilt.dy * tiltAmplitude.dy;
        return Transform.translate(offset: Offset(dx, dy), child: child);
      },
    );
  }
}

class _AgendaList extends StatelessWidget {
  const _AgendaList({required this.rows, required this.scrollCtrl});

  final List<CachedEventRow> rows;
  final ScrollController scrollCtrl;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ListView(
        controller: scrollCtrl,
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

    final DateTime now = DateTime.now();
    final List<CachedEventRow> future = <CachedEventRow>[];
    final List<CachedEventRow> past = <CachedEventRow>[];
    for (final CachedEventRow row in rows) {
      if (row.startsAt.toLocal().isBefore(now)) {
        past.add(row);
      } else {
        future.add(row);
      }
    }

    final List<_MonthGroup> months = _groupByMonth(future);
    // Cumulative event count before each month — lets each card know
    // its global index for the blur-in stagger (each card adds another
    // _staggerMs of delay so titles cascade rather than blur in
    // together).
    final List<int> startEventIndices = <int>[];
    int running = 0;
    for (final _MonthGroup g in months) {
      startEventIndices.add(running);
      running += g.events.length;
    }
    final bool showPastTile = past.isNotEmpty;
    final int itemCount = months.length + (showPastTile ? 1 : 0);

    final MediaQueryData mq = MediaQuery.of(context);
    return ListView.builder(
      controller: scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: mq.padding.top + 64,
        // Cap scroll so the last item (Minulé tile) ends up in the bottom
        // third of the viewport at max scroll instead of being pullable
        // all the way to the middle of the screen.
        bottom: mq.size.height * 0.2,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < months.length) {
          return _MonthSection(
            group: months[index],
            startEventIndex: startEventIndices[index],
          );
        }
        return _PastTile(count: past.length);
      },
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
  const _MonthSection({required this.group, required this.startEventIndex});

  final _MonthGroup group;
  // Global position of this month's first event across the whole
  // agenda — drives the blur-in stagger so card N starts blurring in
  // N × _staggerMs after the cards above it.
  final int startEventIndex;

  @override
  Widget build(BuildContext context) {
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
        // Giant blurred month label — slowest scroll layer, smallest tilt
        // drift. Sits behind the first card.
        Positioned(
          left: -20,
          top: 24,
          right: 0,
          child: IgnorePointer(
            child: _ParallaxLayer(
              scrollFactor: 0.12,
              tiltAmplitude: const Offset(2, 2),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: _ghostBlur,
                  sigmaY: _ghostBlur,
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'StackSansHeadline',
                    fontWeight: FontWeight.w700,
                    fontSize: _ghostFontSize,
                    color: _ghostColor,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 80),
            for (int i = 0; i < group.events.length; i++)
              _EventCard(event: group.events[i], index: startEventIndex + i),
            const SizedBox(height: 16),
          ],
        ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.index});

  final CachedEventRow event;

  /// Global position of this card in the agenda. Drives the per-card
  /// blur-in stagger so titles cascade rather than blur in together.
  final int index;

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
      onTap: () => context.go('/agenda/events/${event.id}', extra: event),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 0, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _coverDiameter),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // Mid-depth: cover image. Mild scroll lag — both cover and
              // title carry a scrollFactor so they lag together; the small
              // delta between them keeps the depth illusion without
              // throwing the title off the cover on later cards.
              Positioned(
                right: -16,
                top: 0,
                child: _ParallaxLayer(
                  scrollFactor: 0.10,
                  tiltAmplitude: const Offset(3, 3),
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
              ),
              // Foreground: title + date row. Modest tilt drift — title
              // shouldn't fly around vs cover. Top inset pushes the title
              // below the cover's visual centre.
              _ParallaxLayer(
                scrollFactor: -0.02,
                tiltAmplitude: const Offset(6, 6),
                child: Padding(
                  padding: const EdgeInsets.only(top: 80, right: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(
                        width: 240,
                        child: BlurInText(
                          key: ValueKey<String>('title-${event.id}'),
                          text: event.title,
                          restartTrigger: _ReplayScope.of(context),
                          startDelay: Duration(
                            milliseconds: index * _staggerMs,
                          ),
                          style: const TextStyle(
                            fontFamily: 'Gloock',
                            fontSize: 50,
                            height: 1.0,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Hero(
                        tag: 'daterow-${event.id}',
                        child: Material(
                          type: MaterialType.transparency,
                          child: DateRow(
                            leading: catLabel,
                            center: dateLabel,
                            trailing: timeLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
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

/// Slim divider tile that ends the agenda — small "Minulé" label followed
/// by a thin rule and a right-pointing chevron at the end. Whole row is
/// the tap target into /agenda/past.
class _PastTile extends StatelessWidget {
  const _PastTile({required this.count});

  // Kept for future surfacing (e.g. badge); intentionally unused in the
  // current Figma 2040:37 style which doesn't show a count.
  final int count;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go('/agenda/past'),
      child: const Padding(
        // Match the event card's DateRow horizontal bounds: outer card
        // padding 24-left/0-right combined with the foreground's 24-right
        // inner padding gives 24/24 — so "Minulé" sits under "Koncert"
        // and the arrow sits under the event time.
        padding: EdgeInsets.fromLTRB(24, 82, 24, 64),
        child: PastHeader(label: 'Minulé'),
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
