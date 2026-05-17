import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  // Months indexed as offset from this epoch — keeps the PageView controller
  // dealing with non-negative ints regardless of how far back / forward the
  // user paginates.
  static final DateTime _epoch = DateTime(2020);
  static int _indexFor(DateTime m) =>
      (m.year - _epoch.year) * 12 + (m.month - _epoch.month);
  static DateTime _monthFor(int i) => DateTime(_epoch.year, _epoch.month + i);

  late final PageController _pageCtrl;
  late int _focusedIndex;
  DateTime? _selected;
  final ValueNotifier<Offset> _tilt = ValueNotifier<Offset>(Offset.zero);
  StreamSubscription<AccelerometerEvent>? _accelSub;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _focusedIndex = _indexFor(DateTime(now.year, now.month));
    _selected = DateTime(now.year, now.month, now.day);
    _pageCtrl = PageController(initialPage: _focusedIndex);
    // Accelerometer drives a subtle parallax on the ghost year, the
    // banner, the title slider, and the grid. Smoothed exponentially
    // so the layers don't twitch on every micro hand movement.
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen((AccelerometerEvent event) {
          final Offset raw = Offset(
            (event.x / 3.0).clamp(-1.0, 1.0),
            ((event.y - 9.81) / 3.0).clamp(-1.0, 1.0),
          );
          const double alpha = 0.15;
          _tilt.value = _tilt.value * (1 - alpha) + raw * alpha;
        });
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _tilt.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

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

  CachedEventRow? _nextUpcoming(List<CachedEventRow> rows) {
    final DateTime now = DateTime.now();
    return rows
        .where((CachedEventRow e) => e.startsAt.toLocal().isAfter(now))
        .fold<CachedEventRow?>(null, (CachedEventRow? acc, CachedEventRow e) {
          if (acc == null) return e;
          return e.startsAt.isBefore(acc.startsAt) ? e : acc;
        });
  }

  void _focusEvent(CachedEventRow event) {
    final DateTime local = event.startsAt.toLocal();
    final DateTime day = _dayKey(local);
    final int idx = _indexFor(DateTime(local.year, local.month));
    final bool sameMonth = idx == _focusedIndex;
    final bool sameDay = _selected != null && _isSameDay(_selected!, day);
    if (sameMonth && sameDay) {
      context.go('/agenda/events/${event.id}', extra: event);
      return;
    }
    setState(() {
      _focusedIndex = idx;
      _selected = day;
    });
    if (!sameMonth) {
      _pageCtrl.animateToPage(
        idx,
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: agendaAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, _) => Center(child: Text('Chyba: $error')),
        data: (List<CachedEventRow> rows) {
          final Map<DateTime, List<CachedEventRow>> buckets = _bucket(rows);
          final CachedEventRow? next = _nextUpcoming(rows);
          final DateTime focused = _monthFor(_focusedIndex);
          final DateTime? sel = _selected;
          final List<CachedEventRow> selectedRows = sel == null
              ? const <CachedEventRow>[]
              : (buckets[_dayKey(sel)] ?? const <CachedEventRow>[]);
          final double topPad = MediaQuery.of(context).padding.top + 96;
          return _TiltScope(
            tilt: _tilt,
            child: Stack(
              children: <Widget>[
                // Ghost year — blurred grey number sitting behind the
                // month title (mirrors the agenda's ghost month label).
                // Lowest tilt amplitude — sits "deep" behind everything.
                Positioned(
                  left: -20,
                  top: topPad + 67,
                  child: IgnorePointer(
                    child: _TiltLayer(
                      amplitude: const Offset(4, 4),
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 7.5, sigmaY: 7.5),
                        child: Text(
                          '${focused.year}',
                          style: const TextStyle(
                            fontFamily: 'StackSansNotch',
                            fontWeight: FontWeight.w700,
                            fontSize: 100,
                            height: 1.0,
                            color: Color(0xFFB1B1B1),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Column(
                  children: <Widget>[
                    SizedBox(height: topPad),
                    if (next != null)
                      _TiltLayer(
                        amplitude: const Offset(10, 10),
                        child: _NextBanner(
                          event: next,
                          onTap: () => _focusEvent(next),
                        ),
                      ),
                    const SizedBox(height: 12),
                    // Title slider gets extra vertical room so the blur
                    // halo of the de-focused titles has space to render
                    // beyond the glyph baseline without being clipped.
                    SizedBox(
                      height: 80,
                      child: _TiltLayer(
                        amplitude: const Offset(8, 8),
                        child: _MonthTitleSlider(pageController: _pageCtrl),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const _DayOfWeekRow(),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 6 * 52.0,
                      child: _TiltLayer(
                        amplitude: const Offset(4, 4),
                        child: PageView.builder(
                          controller: _pageCtrl,
                          onPageChanged: (int i) {
                            setState(() => _focusedIndex = i);
                          },
                          itemBuilder: (BuildContext context, int index) {
                            final DateTime month = _monthFor(index);
                            return _MonthGrid(
                              month: month,
                              selected: _selected,
                              eventDays: buckets.keys
                                  .where(
                                    (DateTime d) =>
                                        d.year == month.year &&
                                        d.month == month.month,
                                  )
                                  .toSet(),
                              onDayTap: (DateTime d) =>
                                  setState(() => _selected = d),
                            );
                          },
                        ),
                      ),
                    ),
                    Container(
                      height: 1,
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                    Expanded(
                      child: _SelectedDayEvents(
                        selected: sel,
                        rows: selectedRows,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

const List<String> _monthNamesNominative = <String>[
  'Leden',
  'Únor',
  'Březen',
  'Duben',
  'Květen',
  'Červen',
  'Červenec',
  'Srpen',
  'Září',
  'Říjen',
  'Listopad',
  'Prosinec',
];

String _monthName(DateTime m) => _monthNamesNominative[m.month - 1];

class _NextBanner extends StatelessWidget {
  const _NextBanner({required this.event, required this.onTap});

  final CachedEventRow event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('EEEE d. MMMM · HH:mm', 'cs');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.arrow_forward, size: 72, color: Colors.black),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    fmt.format(event.startsAt.toLocal()),
                    style: TextStyle(
                      fontFamily: 'StackSansNotch',
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      letterSpacing: 0.48,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'StackSansNotch',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.black,
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

/// Two big Gloock month names that slide together when the user swipes
/// the calendar PageView underneath. At rest the next month peeks in
/// from the right edge as a visual hint that swiping advances months.
class _MonthTitleSlider extends StatelessWidget {
  const _MonthTitleSlider({required this.pageController});

  final PageController pageController;

  static const double _restLeft = 24.0;
  static const double _peekWidth = 70.0;
  // Max blur sigma at fully off-screen positions. 3× the previous
  // value to make the dissolve into the void really obvious.
  static const double _maxSigma = 42.0;
  // Padding around each title inside its ImageFiltered, so the blur
  // halo has room to render without being clipped to the glyph's tight
  // bounding box. Roughly 3 × max sigma covers the full Gaussian
  // falloff.
  static const double _blurHaloPad = 70.0;

  @override
  Widget build(BuildContext context) {
    // The slide distance per page change is anchored to the screen
    // width so that — regardless of how long a month's name is —
    // exactly [_peekWidth] px of the next title is always visible on
    // the right edge at rest.
    final double slideStep =
        MediaQuery.of(context).size.width - _peekWidth - _restLeft;
    return AnimatedBuilder(
      animation: pageController,
      builder: (BuildContext context, _) {
        final double page =
            pageController.hasClients &&
                pageController.position.hasContentDimensions
            ? (pageController.page ?? pageController.initialPage.toDouble())
            : pageController.initialPage.toDouble();
        final int base = page.floor();
        final double progress = page - base;
        // Render the four titles that can be visible at any moment of
        // a forward/backward swipe: base-1 (off-screen left), base
        // (current), base+1 (peek right), and base+2 (slides in from
        // the right as the user advances). Having base+2 already on
        // stage means the new peek doesn't pop into existence at
        // progress=1 — it slides into the right slot continuously.
        Widget titleAt(int offset) {
          final double x = _restLeft + slideStep * (offset - progress);
          final int index = base + offset;
          final DateTime month = _CalendarScreenState._monthFor(index);
          // Tap targets: tapping the current month goes one month back
          // (replaces the now-deleted left chevron); any other title
          // scrolls the PageView to itself.
          final int target = offset == 0 ? index - 1 : index;
          // Blur is asymmetric in slot-units (the signed
          // `offset - progress`):
          //   * Right side: sharp from 0 (centre) through 1 (the
          //     70-px peek rest position) — the peek lands crisply.
          //     Beyond 1 (further offscreen right) the blur ramps up,
          //     reaching full intensity at pos 2.
          //   * Left side: there is no rest peek, so blur ramps up
          //     immediately from 0 (centre, sharp) toward -1 (fully
          //     off-screen left, full blur) — the leaving title
          //     dissolves into the void.
          //
          // Keep the same widget tree across all sigma values so
          // Flutter updates the existing ImageFiltered's filter
          // property instead of recycling it as a Text↔ImageFiltered
          // identity flip per frame.
          final double pos = offset - progress;
          final double overshoot = pos >= 0
              ? (pos - 1.0).clamp(0.0, 1.0)
              : (-pos).clamp(0.0, 1.0);
          // Lower bound 0.01 keeps the ImageFiltered render object
          // active so Flutter actually calls markNeedsPaint when the
          // filter value changes back upward.
          final double sigma = (overshoot * _maxSigma).clamp(0.01, _maxSigma);
          return Positioned(
            // Compensate for the [_blurHaloPad] around the text so the
            // glyph itself still lands at the computed `x`/baseline.
            left: x - _blurHaloPad,
            top: -_blurHaloPad,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => pageController.animateToPage(
                target,
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
              ),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: sigma,
                  sigmaY: sigma,
                  tileMode: TileMode.decal,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(_blurHaloPad),
                  child: _MonthTitle(month: month),
                ),
              ),
            ),
          );
        }

        // Stack must not clip — the halo of off-centre titles bleeds
        // outside the slider's SizedBox height.
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[titleAt(-1), titleAt(0), titleAt(1), titleAt(2)],
        );
      },
    );
  }
}

class _MonthTitle extends StatelessWidget {
  const _MonthTitle({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    return Text(
      _monthName(month),
      style: const TextStyle(
        fontFamily: 'Gloock',
        fontSize: 50,
        height: 1.0,
        color: Colors.black,
      ),
    );
  }
}

class _DayOfWeekRow extends StatelessWidget {
  const _DayOfWeekRow();

  static const List<String> _names = <String>[
    'po',
    'út',
    'st',
    'čt',
    'pá',
    'so',
    'ne',
  ];

  @override
  Widget build(BuildContext context) {
    const TextStyle style = TextStyle(
      fontFamily: 'StackSansNotch',
      fontWeight: FontWeight.w600,
      fontSize: 11,
      letterSpacing: 0.4,
      color: Color(0x7F000000),
    );
    return Row(
      children: <Widget>[
        for (final String name in _names)
          Expanded(
            child: Center(child: Text(name, style: style)),
          ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.eventDays,
    required this.onDayTap,
  });

  final DateTime month;
  final DateTime? selected;
  final Set<DateTime> eventDays;
  final ValueChanged<DateTime> onDayTap;

  static List<DateTime> _layoutDays(DateTime month) {
    final DateTime first = DateTime(month.year, month.month);
    final int offset = first.weekday - DateTime.monday;
    final DateTime start = first.subtract(Duration(days: offset));
    return List<DateTime>.generate(42, (int i) => start.add(Duration(days: i)));
  }

  @override
  Widget build(BuildContext context) {
    final List<DateTime> cells = _layoutDays(month);
    return Column(
      children: <Widget>[
        for (int week = 0; week < 6; week++)
          Expanded(
            child: Row(
              children: <Widget>[
                for (int dow = 0; dow < 7; dow++)
                  Expanded(
                    child: _DayCell(
                      day: cells[week * 7 + dow],
                      isInMonth: cells[week * 7 + dow].month == month.month,
                      isSelected:
                          selected != null &&
                          _isSameDay(selected!, cells[week * 7 + dow]),
                      hasEvent: eventDays.contains(cells[week * 7 + dow]),
                      onTap: () => onDayTap(cells[week * 7 + dow]),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isInMonth,
    required this.isSelected,
    required this.hasEvent,
    required this.onTap,
  });

  final DateTime day;
  final bool isInMonth;
  final bool isSelected;
  final bool hasEvent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color textColor;
    if (isSelected) {
      textColor = Colors.white;
    } else if (!isInMonth) {
      textColor = Colors.black.withValues(alpha: 0.25);
    } else {
      textColor = Colors.black;
    }
    final Color? bg;
    if (isSelected) {
      bg = Colors.black;
    } else if (hasEvent && isInMonth) {
      bg = const Color(0xFFE8E8E8);
    } else {
      bg = null;
    }
    return InkResponse(
      onTap: onTap,
      radius: 24,
      child: Center(
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: bg == null
              ? null
              : BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontFamily: 'StackSansNotch',
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 14,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedDayEvents extends StatelessWidget {
  const _SelectedDayEvents({required this.selected, required this.rows});

  final DateTime? selected;
  final List<CachedEventRow> rows;

  @override
  Widget build(BuildContext context) {
    if (selected == null) {
      return const Center(child: Text('Vyber den v kalendáři.'));
    }
    if (rows.isEmpty) {
      return const Center(child: Text('Nic v ten den.'));
    }
    final DateFormat headerFmt = DateFormat('EEEE d.M.', 'cs');
    final String headerRaw = headerFmt.format(selected!);
    final String header = headerRaw.isEmpty
        ? headerRaw
        : headerRaw.toUpperCase();
    final DateFormat timeFmt = DateFormat('HH:mm', 'cs');
    return ListView(
      padding: const EdgeInsets.only(top: 18, bottom: 160),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            header,
            style: TextStyle(
              fontFamily: 'StackSansNotch',
              fontWeight: FontWeight.w600,
              fontSize: 11,
              letterSpacing: 0.4,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final CachedEventRow event in rows)
          _EventRow(
            event: event,
            time: timeFmt.format(event.startsAt.toLocal()),
          ),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.time});

  final CachedEventRow event;
  final String time;

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
    return InkWell(
      onTap: () => context.go('/agenda/events/${event.id}', extra: event),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontFamily: 'StackSansNotch',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$time · ${_categoryLabel(event.category)}',
                    style: TextStyle(
                      fontFamily: 'StackSansNotch',
                      fontWeight: FontWeight.w400,
                      fontSize: 12,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inherited carrier for the smoothed device-tilt notifier. Layers that
/// want to drift with the phone's tilt read it via [_TiltScope.of] and
/// scale it by their own per-layer amplitude (see [_TiltLayer]).
class _TiltScope extends InheritedWidget {
  const _TiltScope({required this.tilt, required super.child});

  final ValueListenable<Offset> tilt;

  static ValueListenable<Offset> of(BuildContext context) {
    final _TiltScope? scope = context
        .dependOnInheritedWidgetOfExactType<_TiltScope>();
    assert(scope != null, '_TiltScope missing from context');
    return scope!.tilt;
  }

  @override
  bool updateShouldNotify(_TiltScope old) => tilt != old.tilt;
}

/// Translates [child] by `tilt * amplitude` every accelerometer frame
/// without re-laying out the tree. Use a small amplitude for "deep"
/// background layers and a larger one for foreground content.
class _TiltLayer extends StatelessWidget {
  const _TiltLayer({required this.child, required this.amplitude});

  final Widget child;
  final Offset amplitude;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<Offset> tilt = _TiltScope.of(context);
    return ValueListenableBuilder<Offset>(
      valueListenable: tilt,
      builder: (BuildContext context, Offset value, Widget? c) =>
          Transform.translate(
            offset: Offset(value.dx * amplitude.dx, value.dy * amplitude.dy),
            child: c,
          ),
      child: child,
    );
  }
}
