import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';

class PastAgendaScreen extends ConsumerStatefulWidget {
  const PastAgendaScreen({super.key});

  @override
  ConsumerState<PastAgendaScreen> createState() => _PastAgendaScreenState();
}

class _PastAgendaScreenState extends ConsumerState<PastAgendaScreen> {
  // Fresh tick each mount so the BlurInText title plays through once
  // when the user opens the Minulé screen.
  final ValueNotifier<int> _replayTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _replayTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedEventRow>> agendaAsync = ref.watch(
      agendaProvider,
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: <Widget>[
          agendaAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Načítání selhalo: $error'),
              ),
            ),
            data: (rows) => _PastList(
              rows: _filterAndSortPast(rows),
              replayTrigger: _replayTick,
            ),
          ),
          // Floating back button above the list. Tap → bottom-nav Agenda root.
          Positioned(
            left: 4,
            top: MediaQuery.of(context).padding.top + 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.black),
              onPressed: () => context.go('/agenda'),
            ),
          ),
        ],
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

/// Figma 2040:37 — small label + thin horizontal rule + tiny right arrow.
/// Used as the agenda's "tap to see past" tile (agenda_screen) and as the
/// section header inside the past list itself.
class PastHeader extends StatelessWidget {
  const PastHeader({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'StackSansHeadline',
            fontWeight: FontWeight.w600,
            fontSize: 12,
            height: 1.0,
            letterSpacing: 0.48,
            color: Colors.black,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(child: SizedBox(height: 12, child: _ArrowRule())),
      ],
    );
  }
}

class _ArrowRule extends StatelessWidget {
  const _ArrowRule();

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _ArrowRulePainter(),
        size: Size.infinite,
      );
}

class _ArrowRulePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final double y = size.height / 2;
    const double headLen = 5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    canvas.drawLine(
      Offset(size.width, y),
      Offset(size.width - headLen, y - headLen),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, y),
      Offset(size.width - headLen, y + headLen),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _PastList extends StatelessWidget {
  const _PastList({required this.rows, required this.replayTrigger});

  final List<CachedEventRow> rows;
  final Listenable replayTrigger;

  @override
  Widget build(BuildContext context) {
    // Mirrors the WatchlistScreen header geometry so the two parent screens
    // sit at the same vertical rhythm: status-bar inset + 96 px.
    final double topPad = MediaQuery.of(context).padding.top + 96;
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, topPad, 24, 24),
            child: BlurInText(
              key: const ValueKey<String>('minule-title'),
              text: 'Minulé',
              restartTrigger: replayTrigger,
              style: const TextStyle(
                fontFamily: 'Gloock',
                fontSize: 50,
                height: 1.0,
                color: Colors.black,
              ),
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
