import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/core/widgets/date_row.dart';
import 'package:kp_mobile/core/widgets/morphing_hero_cover.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/agenda_replay_provider.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/outbox/conflict_dialog.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

class EventDetailScreen extends ConsumerStatefulWidget {
  const EventDetailScreen({required this.eventId, super.key});

  final String eventId;

  @override
  ConsumerState<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends ConsumerState<EventDetailScreen> {
  @override
  void dispose() {
    // Tell the agenda to replay its blur-in titles when we go back. Read
    // a fresh reference so we don't capture a stale notifier — this runs
    // after the Scaffold is torn down.
    ref.read(agendaReplayProvider.notifier).state++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Surface outbox conflicts for this event (if one comes in while we're
    // looking at the detail screen, pop the resolution dialog right there).
    ref.listen<AsyncValue<OutboxConflict>>(outboxConflictStreamProvider, (
      previous,
      next,
    ) async {
      final OutboxConflict? conflict = next.value;
      if (conflict == null || conflict.entityId != widget.eventId) {
        return;
      }
      if (!mounted) {
        return;
      }
      final ConflictResolution? choice = await showConflictResolutionDialog(
        context: context,
        conflict: conflict,
      );
      if (!mounted || choice == null) {
        return;
      }
      final OutboxController outbox = ref.read(
        outboxControllerProvider.notifier,
      );
      if (choice == ConflictResolution.useServer) {
        await outbox.discardPending(conflict.opId);
      } else {
        await outbox.requeueWithFreshBaseVersion(
          opId: conflict.opId,
          baseVersion: conflict.currentVersion,
        );
      }
    });

    final EventsRepository repo = ref.read(eventsRepositoryProvider);
    // Agenda passes the CachedEventRow as `extra` so we can render the
    // cover Hero on the first frame — required for the push-direction
    // Hero flight to find a destination endpoint.
    final CachedEventRow? initialEvent =
        GoRouterState.of(context).extra as CachedEventRow?;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Cover image bleeds behind the status bar. Flip the system icons
      // to white so they stay visible on the typically dark photo.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: FutureBuilder<CachedEventRow?>(
          future: repo.getEvent(widget.eventId),
          initialData: initialEvent,
          builder: (context, snapshot) {
            final CachedEventRow? event = snapshot.data;
            if (event == null) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              return const Center(child: Text('Událost nenalezena.'));
            }
            return FutureBuilder<List<CachedTicketRow>>(
              future: repo.ticketsForEvent(event.id),
              builder: (context, ticketSnapshot) {
                final List<CachedTicketRow> tickets =
                    ticketSnapshot.data ?? const <CachedTicketRow>[];
                return _EventDetailBody(
                  event: event,
                  tickets: tickets,
                  onEdit: () =>
                      context.go('/agenda/events/${widget.eventId}/edit'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _EventDetailBody extends StatelessWidget {
  const _EventDetailBody({
    required this.event,
    required this.tickets,
    required this.onEdit,
  });

  final CachedEventRow event;
  final List<CachedTicketRow> tickets;
  final VoidCallback onEdit;

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

  IconData _categoryFallbackIcon(String category) {
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

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final DateTime local = event.startsAt.toLocal();
    final DateFormat dateFmt = DateFormat('EEEE d.M.', 'cs');
    final DateFormat timeFmt = DateFormat('HH:mm', 'cs');
    final String dateLabel = _capitalize(dateFmt.format(local));
    final String timeLabel = timeFmt.format(local);
    final String catLabel = _categoryLabel(event.category);

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            // Cover aspect ratio mirrors the Figma frame (402 × 305).
            final double imageHeight = constraints.maxWidth * (305 / 402);
            // Title overlaps the bottom of the cover by exactly half the
            // first line (Figma: 15 px on a 402-wide frame, matches a
            // single 30 px Gloock line / 2).
            const double overlap = 15;
            // Reserve enough room below the cover for the hanging title
            // before the next list item starts. Estimate: 4 lines of
            // Gloock 30 / 30 ≈ 120 px + a touch of breathing room.
            const double titleReserve = 130;
            return SizedBox(
              height: imageHeight + titleReserve - overlap,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      height: imageHeight,
                      child: MorphingHeroCover(
                        tag: 'cover-${event.id}',
                        imageUrl: event.coverImageUrl,
                        borderRadius: BorderRadius.zero,
                        fallback: Container(
                          color: const Color(0xFFEFEFEF),
                          alignment: Alignment.center,
                          child: Icon(
                            _categoryFallbackIcon(event.category),
                            size: 80,
                            color: Colors.black38,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      left: false,
                      child: _EditPill(onTap: onEdit),
                    ),
                  ),
                  Positioned(
                    top: imageHeight - overlap,
                    left: 34,
                    right: 34,
                    child: BlurInText(
                      key: ValueKey<String>('detail-title-${event.id}'),
                      text: event.title,
                      style: const TextStyle(
                        fontFamily: 'Gloock',
                        fontSize: 30,
                        height: 1.0,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
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
              const SizedBox(height: 32),
              if (event.notes != null && event.notes!.isNotEmpty)
                _NotesText(text: event.notes!),
            ],
          ),
        ),
        // Venue section: edge-to-edge image (symmetric with the top cover),
        // then padded address row with a Mapa launcher.
        if (event.venueAddress != null &&
            event.venueAddress!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 32),
          _VenueSection(
            address: event.venueAddress!,
            imageUrl: event.venueImageUrl,
          ),
        ],
        if (tickets.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 34),
            child: _TicketsSection(eventId: event.id, tickets: tickets),
          ),
        ],
        // Clearance for the bottom-nav gradient + safe-area inset.
        const SizedBox(height: 180),
      ],
    );
  }
}

/// Notes block. Plain styled text in StackSansNotch 12 / 16 / tracking 0.64.
/// "Word:" subheaders at the start of lines render in SemiBold to match the
/// Figma reference. No card chrome.
class _NotesText extends StatelessWidget {
  const _NotesText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    const TextStyle baseStyle = TextStyle(
      fontFamily: 'StackSansNotch',
      fontWeight: FontWeight.w400,
      fontSize: 12,
      height: 16 / 12,
      letterSpacing: 0.64,
      color: Colors.black,
    );
    final TextStyle boldStyle = baseStyle.copyWith(fontWeight: FontWeight.w600);
    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: _spans(text, baseStyle, boldStyle),
      ),
    );
  }

  static List<InlineSpan> _spans(String text, TextStyle base, TextStyle bold) {
    final List<InlineSpan> out = <InlineSpan>[];
    final List<String> lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      // Match a leading "Word:" subheader (single capitalised Czech word
      // followed by a colon, like "Místa:", "Program:", "Účinkují:").
      final RegExpMatch? match = RegExp(
        r'^([A-Za-zÁ-žá-ž]+:)(.*)$',
        unicode: true,
      ).firstMatch(line);
      if (match != null) {
        out.add(TextSpan(text: match.group(1), style: bold));
        out.add(TextSpan(text: match.group(2), style: base));
      } else {
        out.add(TextSpan(text: line, style: base));
      }
      if (i != lines.length - 1) {
        out.add(const TextSpan(text: '\n'));
      }
    }
    return out;
  }
}

class _TicketsSection extends StatelessWidget {
  const _TicketsSection({required this.eventId, required this.tickets});

  final String eventId;
  final List<CachedTicketRow> tickets;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Lístky (${tickets.length})',
          style: const TextStyle(
            fontFamily: 'StackSansNotch',
            fontWeight: FontWeight.w600,
            fontSize: 12,
            letterSpacing: 0.48,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 8),
        for (final CachedTicketRow ticket in tickets)
          _TicketRow(eventId: eventId, ticket: ticket),
      ],
    );
  }
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.eventId, required this.ticket});

  final String eventId;
  final CachedTicketRow ticket;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go('/agenda/events/$eventId/tickets/${ticket.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.attach_file, size: 18, color: Colors.black),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ticket.originalFilename ?? ticket.id,
                style: const TextStyle(
                  fontFamily: 'StackSansNotch',
                  fontSize: 13,
                  color: Colors.black,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}

class _VenueSection extends StatelessWidget {
  const _VenueSection({required this.address, this.imageUrl});

  final String address;
  final String? imageUrl;

  Future<void> _openMaps() async {
    final Uri uri = Uri.https(
      'www.google.com',
      '/maps/search/',
      <String, String>{'api': '1', 'query': address},
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (imageUrl != null && imageUrl!.isNotEmpty)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
              errorBuilder: (context, _, _) => Container(
                color: const Color(0xFFEFEFEF),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.black38,
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(34, 20, 34, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.place_outlined, size: 18, color: Colors.black),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  address,
                  style: const TextStyle(
                    fontFamily: 'StackSansNotch',
                    fontWeight: FontWeight.w400,
                    fontSize: 12,
                    height: 16 / 12,
                    letterSpacing: 0.64,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _openMaps,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    'Mapa',
                    style: TextStyle(
                      fontFamily: 'StackSansNotch',
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      letterSpacing: 0.48,
                      color: Colors.black,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EditPill extends StatelessWidget {
  const _EditPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Icon(
            Icons.edit_outlined,
            color: Colors.white,
            size: 22,
            shadows: <Shadow>[
              Shadow(
                color: Color(0x80000000),
                offset: Offset(0, 1),
                blurRadius: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
