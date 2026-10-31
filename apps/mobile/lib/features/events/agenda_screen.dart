import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/core/sensors/tilt_provider.dart';
import 'package:kp_mobile/core/widgets/blend_mask.dart';
import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/core/widgets/date_row.dart';
import 'package:kp_mobile/core/widgets/morphing_hero_cover.dart';
import 'package:kp_mobile/core/widgets/parallax_layer.dart';
import 'package:kp_mobile/core/widgets/prerendered_blur_text.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/agenda_replay_provider.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/events/past_agenda_screen.dart'
    show PastHeader;
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

/// [ParallaxLayer] wired to the agenda's scroll position and device tilt.
class _AgendaParallax extends StatelessWidget {
  const _AgendaParallax({
    required this.scrollFactor,
    required this.tiltAmplitude,
    required this.child,
  });

  final double scrollFactor;
  final Offset tiltAmplitude;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _ParallaxScope scope = _ParallaxScope.of(context);
    return ParallaxLayer(
      scroll: scope.scrollCtrl,
      tilt: scope.tilt,
      scrollFactor: scrollFactor,
      tiltAmplitude: tiltAmplitude,
      child: child,
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

    final List<_AgendaEntry> entries = _entriesFor(future);
    final bool showPastTile = past.isNotEmpty;
    final int itemCount = entries.length + (showPastTile ? 1 : 0);

    final MediaQueryData mq = MediaQuery.of(context);
    return ScrollConfiguration(
      behavior: const _WhiteBackdropScrollBehavior(),
      child: ListView.builder(
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
        itemBuilder: (context, index) => index < entries.length
            ? _AgendaCardItem(entry: entries[index])
            : _PastTile(count: past.length),
      ),
    );
  }

  /// One list item per event, so the list builds, lays out and paints only
  /// the cards near the viewport. The first card of each month carries that
  /// month's ghost label; spacing reproduces the per-month layout (80 above a
  /// month, 20 between its cards, 16 after it).
  static List<_AgendaEntry> _entriesFor(List<CachedEventRow> rows) {
    final List<_AgendaEntry> out = <_AgendaEntry>[];
    for (int i = 0; i < rows.length; i++) {
      final DateTime local = rows[i].startsAt.toLocal();
      final DateTime? previous = i > 0 ? rows[i - 1].startsAt.toLocal() : null;
      final DateTime? next = i + 1 < rows.length
          ? rows[i + 1].startsAt.toLocal()
          : null;
      out.add(
        _AgendaEntry(
          event: rows[i],
          // Global position across the agenda — drives the blur-in stagger
          // so card N starts N × _staggerMs after the first.
          index: i,
          monthLabel: previous == null || !_sameMonth(previous, local)
              ? _monthLabel(local)
              : null,
          endsMonth: next == null || !_sameMonth(local, next),
        ),
      );
    }
    return out;
  }

  static bool _sameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  static String _monthLabel(DateTime local) {
    final String raw = DateFormat(
      'LLLL',
      'cs',
    ).format(DateTime(local.year, local.month));
    return raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);
  }
}

/// Paints opaque white under the whole list *inside* the scroll content, so
/// it rides into Android's stretch-overscroll layer with the cards (behind
/// the ghost month, which still shows through). That layer isolates its
/// content, and the date/title difference-blend needs a backdrop in it —
/// without one the black-on-white text drops out on the end-bounce, leaving
/// only text over the photos. One backdrop for the whole list rather than one
/// per card: a per-card fill would cut off the cover above it where its
/// parallax drift spills over the card boundary.
class _WhiteBackdropScrollBehavior extends MaterialScrollBehavior {
  const _WhiteBackdropScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => super.buildOverscrollIndicator(
    context,
    ColoredBox(color: Colors.white, child: child),
    details,
  );
}

class _AgendaEntry {
  const _AgendaEntry({
    required this.event,
    required this.index,
    required this.monthLabel,
    required this.endsMonth,
  });

  final CachedEventRow event;
  final int index;

  /// Set on the first card of a month: the ghost label drawn behind it.
  final String? monthLabel;
  final bool endsMonth;
}

class _AgendaCardItem extends StatelessWidget {
  const _AgendaCardItem({required this.entry});

  final _AgendaEntry entry;

  @override
  Widget build(BuildContext context) {
    final String? monthLabel = entry.monthLabel;
    final Widget card = Padding(
      padding: EdgeInsets.only(
        top: monthLabel != null ? 80 : 20,
        bottom: entry.endsMonth ? 16 : 0,
      ),
      child: _EventCard(event: entry.event, index: entry.index),
    );
    if (monthLabel == null) {
      return card;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Giant blurred month label — slowest scroll layer, smallest tilt
        // drift. Sits behind the month's first card.
        Positioned(
          left: -20,
          top: 24,
          right: 0,
          child: IgnorePointer(
            child: _AgendaParallax(
              scrollFactor: 0.12,
              tiltAmplitude: const Offset(2, 2),
              child: PrerenderedBlurText(
                monthLabel,
                sigma: _ghostBlur,
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
        card,
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
                child: _AgendaParallax(
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
              _AgendaParallax(
                scrollFactor: -0.02,
                tiltAmplitude: const Offset(6, 6),
                child: Padding(
                  padding: const EdgeInsets.only(top: 80, right: 24),
                  // White + difference blend inverts whatever is behind the
                  // title and date row, so both stay legible where they cross
                  // the dark cover circle (and read black on the plain
                  // background). One blend layer for the pair: each
                  // difference layer makes the GPU read back the backdrop,
                  // and that readback is the bulk of a scroll frame's cost.
                  child: BlendMask(
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
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Hero(
                          tag: 'daterow-${event.id}',
                          flightShuttleBuilder: _dateRowShuttle,
                          child: Material(
                            type: MaterialType.transparency,
                            child: DateRow(
                              leading: catLabel,
                              center: dateLabel,
                              trailing: timeLabel,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The white date row only reads through the card's blend layer, which
  /// stays behind when the row flies. Landing back on the agenda (pop), the
  /// shuttle is this white row, so it carries its own blend; flying to the
  /// detail screen it is the detail's plain black row.
  static Widget _dateRowShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final Widget child = (toHeroContext.widget as Hero).child;
    return direction == HeroFlightDirection.pop
        ? BlendMask(child: child)
        : child;
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
