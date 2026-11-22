import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/tickets/ticket_code.dart';

/// One drawable code with the ticket it came from.
class TicketCodeEntry {
  const TicketCodeEntry({required this.ticket, required this.code});

  final CachedTicketRow ticket;
  final TicketCode code;
}

/// Every code of the event's tickets that has a verified redraw, in ticket
/// order. A code the server could not redraw is left out — its ticket
/// still opens as a PDF from the list below.
List<TicketCodeEntry> ticketCodeEntries(List<CachedTicketRow> tickets) {
  final List<TicketCodeEntry> entries = <TicketCodeEntry>[];
  for (final CachedTicketRow ticket in tickets) {
    final List<TicketCode> codes;
    try {
      codes = TicketCode.listFromJson(ticket.codesJson) ?? <TicketCode>[];
    } catch (e, st) {
      debugPrint('kp-tickets: codes of ${ticket.id} unreadable: $e');
      unawaited(Sentry.captureException(e, stackTrace: st));
      continue;
    }
    for (final TicketCode code in codes) {
      if (code.isDrawable) {
        entries.add(TicketCodeEntry(ticket: ticket, code: code));
      }
    }
  }
  return entries;
}

/// The codes, drawn inline in the event detail and swiped sideways when the
/// event has more than one. A tap opens them full screen at full brightness.
class TicketCodesCarousel extends StatefulWidget {
  const TicketCodesCarousel({
    required this.eventId,
    required this.entries,
    super.key,
  });

  final String eventId;
  final List<TicketCodeEntry> entries;

  @override
  State<TicketCodesCarousel> createState() => _TicketCodesCarouselState();
}

class _TicketCodesCarouselState extends State<TicketCodesCarousel> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<TicketCodeEntry> entries = widget.entries;
    return Column(
      children: <Widget>[
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: _controller,
            itemCount: entries.length,
            onPageChanged: (int i) => setState(() => _index = i),
            itemBuilder: (BuildContext context, int i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  context.go('/agenda/events/${widget.eventId}/codes?i=$i'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 34),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) =>
                      TicketCodeTile(
                        entry: entries[i],
                        maxWidth: box.maxWidth,
                        maxHeight: 240,
                      ),
                ),
              ),
            ),
          ),
        ),
        if (entries.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${_index + 1} / ${entries.length}',
              style: const TextStyle(
                fontFamily: 'StackSansHeadline',
                fontSize: 12,
                letterSpacing: 0.48,
                color: Colors.black54,
              ),
            ),
          ),
      ],
    );
  }
}

/// A single code on white with the ticket's file name under it.
///
/// The module bitmap is scaled by a whole number of physical pixels per
/// module with nearest-neighbour sampling, so every bar and cell keeps the
/// same width — a fractional scale would make some modules a pixel wider
/// than others, which is what makes a dense PDF417 unreadable.
class TicketCodeTile extends StatelessWidget {
  const TicketCodeTile({
    required this.entry,
    required this.maxWidth,
    required this.maxHeight,
    super.key,
  });

  final TicketCodeEntry entry;
  final double maxWidth;
  final double maxHeight;

  static const double _quietZone = 16;

  @override
  Widget build(BuildContext context) {
    final TicketCode code = entry.code;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double fitWidth = (maxWidth - 2 * _quietZone) * dpr;
    final double fitHeight = (maxHeight - 2 * _quietZone) * dpr;
    final int pixelsPerModule = math.max(
      1,
      math
          .min(fitWidth / code.modulesWidth, fitHeight / code.modulesHeight)
          .floor(),
    );
    final double width = code.modulesWidth * pixelsPerModule / dpr;
    final double height = code.modulesHeight * pixelsPerModule / dpr;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          color: Colors.white,
          // Quiet zone: scanners need white around the code.
          padding: const EdgeInsets.all(_quietZone),
          child: Image.memory(
            code.modulesPng!,
            width: width,
            height: height,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
          ),
        ),
        if (code.isLinear)
          Text(
            code.text,
            style: const TextStyle(
              fontSize: 14,
              letterSpacing: 2,
              color: Colors.black,
            ),
          ),
        const SizedBox(height: 12),
        Text(
          entry.ticket.originalFilename ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'StackSansHeadline',
            fontSize: 12,
            color: Colors.black,
          ),
        ),
      ],
    );
  }
}

/// The codes full screen, at full brightness while the screen is open, for
/// holding the phone under a scanner at the door.
class TicketCodesScreen extends ConsumerStatefulWidget {
  const TicketCodesScreen({
    required this.eventId,
    this.initialIndex = 0,
    super.key,
  });

  final String eventId;
  final int initialIndex;

  @override
  ConsumerState<TicketCodesScreen> createState() => _TicketCodesScreenState();
}

class _TicketCodesScreenState extends ConsumerState<TicketCodesScreen> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late final Future<List<TicketCodeEntry>> _entries = ref
      .read(kpDatabaseProvider)
      .ticketsForEvent(widget.eventId)
      .then(ticketCodeEntries);
  int? _index;

  @override
  void initState() {
    super.initState();
    unawaited(_setBrightness(full: true));
  }

  @override
  void dispose() {
    unawaited(_setBrightness(full: false));
    _controller.dispose();
    super.dispose();
  }

  Future<void> _setBrightness({required bool full}) async {
    try {
      if (full) {
        await ScreenBrightness.instance.setApplicationScreenBrightness(1);
      } else {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      }
    } catch (e, st) {
      debugPrint('kp-tickets: brightness (full: $full) failed: $e');
      await Sentry.captureException(e, stackTrace: st);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FutureBuilder<List<TicketCodeEntry>>(
          future: _entries,
          builder:
              (BuildContext context, AsyncSnapshot<List<TicketCodeEntry>> s) {
                final List<TicketCodeEntry> entries =
                    s.data ?? const <TicketCodeEntry>[];
                final int index = _index ?? widget.initialIndex;
                return Stack(
                  children: <Widget>[
                    LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) {
                        return PageView.builder(
                          controller: _controller,
                          itemCount: entries.length,
                          onPageChanged: (int i) => setState(() => _index = i),
                          itemBuilder: (BuildContext context, int i) => Center(
                            child: TicketCodeTile(
                              entry: entries[i],
                              maxWidth: box.maxWidth - 32,
                              // Room for the close button, the digits of a
                              // linear code, the file name and the counter.
                              maxHeight: box.maxHeight - 160,
                            ),
                          ),
                        );
                      },
                    ),
                    Positioned(
                      top: 4,
                      left: 4,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.black),
                        onPressed: () => context.pop(),
                      ),
                    ),
                    if (entries.length > 1)
                      Positioned(
                        bottom: 24,
                        left: 0,
                        right: 0,
                        child: Text(
                          '${index + 1} / ${entries.length}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'StackSansHeadline',
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                  ],
                );
              },
        ),
      ),
    );
  }
}
