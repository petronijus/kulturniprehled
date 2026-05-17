import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/features/stats/stats_replay_provider.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  final int _year = DateTime.now().year;
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  // Per-screen replay tick driven by [statsReplayProvider] (bumped
  // from `_HomeShell._goBranch` when the Stats tab becomes active).
  final ValueNotifier<int> _replayTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    _replayTick.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final KpClient client = ref.read(kpClientProvider);
      final Response<dynamic> response = await client.dio.get<dynamic>(
        '/v1/stats',
        queryParameters: <String, dynamic>{'year': _year},
      );
      setState(() {
        _data = (response.data as Map<String, dynamic>?) ?? <String, dynamic>{};
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static const List<String> _monthShort = <String>[
    'led',
    'úno',
    'bře',
    'dub',
    'kvě',
    'čer',
    'čvc',
    'srp',
    'zář',
    'říj',
    'lis',
    'pro',
  ];

  String _categoryLabel(String category) {
    switch (category) {
      case 'concert':
        return 'Koncerty';
      case 'theatre':
        return 'Divadlo';
      case 'cinema':
        return 'Kino';
      default:
        return 'Jiné';
    }
  }

  /// Czech-style "18 540,-" formatting (thin space thousands, ",-"
  /// suffix). Cents are rounded into whole crowns.
  String _formatCzk(int cents) {
    final int crowns = (cents / 100).round();
    final NumberFormat fmt = NumberFormat.decimalPattern('cs_CZ');
    return '${fmt.format(crowns)},-';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(statsReplayProvider, (int? previous, int next) {
      if (previous != next) _replayTick.value++;
    });
    final double topPad = MediaQuery.of(context).padding.top + 96;
    return Scaffold(
      backgroundColor: Colors.white,
      body: RefreshIndicator(
        onRefresh: _load,
        child: Stack(
          children: <Widget>[
            // Ghost year (last two digits) — blurred grey behind the
            // header, same pattern as the calendar's year ghost.
            Positioned(
              left: 4,
              top: topPad + 32,
              child: IgnorePointer(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 7.5, sigmaY: 7.5),
                  child: Text(
                    (_year % 100).toString().padLeft(2, '0'),
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
            _build(topPad),
          ],
        ),
      ),
    );
  }

  Widget _build(double topPad) {
    if (_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: topPad),
          _StatsHeader(replayTrigger: _replayTick),
          const SizedBox(height: 96),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: topPad),
          _StatsHeader(replayTrigger: _replayTick),
          const SizedBox(height: 80),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: <Widget>[
                const Icon(Icons.cloud_off, size: 64),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _load,
                  child: const Text('Zkusit znovu'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final Map<String, dynamic>? data = _data;
    if (data == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: topPad),
          _StatsHeader(replayTrigger: _replayTick),
          const SizedBox(height: 80),
          const Center(child: Text('Žádná data.')),
        ],
      );
    }
    final int totalEvents = data['total_events'] as int? ?? 0;
    final int totalCostCents = data['total_cost_cents'] as int? ?? 0;
    final List<Map<String, dynamic>> byCategory =
        ((data['by_category'] as List<dynamic>?) ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();
    final List<Map<String, dynamic>> byMonth =
        ((data['by_month'] as List<dynamic>?) ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();

    final bool empty = totalEvents == 0 && totalCostCents == 0;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: topPad, bottom: 160),
      children: <Widget>[
        _StatsHeader(replayTrigger: _replayTick),
        const SizedBox(height: 24),
        if (empty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              children: <Widget>[
                Icon(Icons.bar_chart, size: 80),
                SizedBox(height: 16),
                Text(
                  'Pro tenhle rok zatím nic není.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else ...<Widget>[
          _HighlightBubble(
            events: totalEvents,
            spendCzk: _formatCzk(totalCostCents),
          ),
          const SizedBox(height: 48),
          _CategorySection(rows: byCategory, label: _categoryLabel),
          const SizedBox(height: 32),
          _MonthSection(rows: byMonth, monthNames: _monthShort),
        ],
      ],
    );
  }
}

class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.replayTrigger});

  final Listenable replayTrigger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: BlurInText(
        key: const ValueKey<String>('stats-title'),
        text: 'Statistiky',
        restartTrigger: replayTrigger,
        style: const TextStyle(
          fontFamily: 'Gloock',
          fontSize: 50,
          height: 1.0,
          color: Colors.black,
        ),
      ),
    );
  }
}

class _HighlightBubble extends StatelessWidget {
  const _HighlightBubble({required this.events, required this.spendCzk});

  final int events;
  final String spendCzk;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 60),
          decoration: const BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _BubbleStat(label: 'AKCÍ', value: '$events'),
                const SizedBox(height: 24),
                _BubbleStat(label: 'ÚTRATA', value: spendCzk),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleStat extends StatelessWidget {
  const _BubbleStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontFamily: 'StackSansNotch',
            fontWeight: FontWeight.w600,
            fontSize: 10,
            letterSpacing: 0.5,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'Gloock',
            fontSize: 40,
            height: 1.0,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({required this.rows, required this.label});

  final List<Map<String, dynamic>> rows;
  final String Function(String) label;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'PODLE KATEGORIE',
            style: TextStyle(
              fontFamily: 'StackSansNotch',
              fontWeight: FontWeight.w600,
              fontSize: 10,
              letterSpacing: 0.5,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          for (final Map<String, dynamic> row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label(row['category'] as String),
                      style: const TextStyle(
                        fontFamily: 'StackSansNotch',
                        fontWeight: FontWeight.w400,
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  Text(
                    '${row['count']}',
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
    );
  }
}

class _MonthSection extends StatelessWidget {
  const _MonthSection({required this.rows, required this.monthNames});

  final List<Map<String, dynamic>> rows;
  final List<String> monthNames;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Text('Žádné měsíce s daty.'),
      );
    }
    final int maxEvents = rows
        .map((Map<String, dynamic> r) => r['events'] as int)
        .fold<int>(0, (int a, int b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'PODLE MĚSÍCE',
            style: TextStyle(
              fontFamily: 'StackSansNotch',
              fontWeight: FontWeight.w600,
              fontSize: 10,
              letterSpacing: 0.5,
              color: Colors.black.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 12),
          for (final Map<String, dynamic> row in rows)
            _MonthBar(
              label: monthNames[(row['month'] as int) - 1],
              events: row['events'] as int,
              maxEvents: maxEvents,
            ),
        ],
      ),
    );
  }
}

class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.label,
    required this.events,
    required this.maxEvents,
  });

  final String label;
  final int events;
  final int maxEvents;

  @override
  Widget build(BuildContext context) {
    final double fraction = maxEvents == 0 ? 0 : events / maxEvents;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'StackSansNotch',
                fontWeight: FontWeight.w400,
                fontSize: 12,
                color: Colors.black.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return Stack(
                  children: <Widget>[
                    Container(
                      height: 16,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8E8E8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Container(
                      height: 16,
                      width: constraints.maxWidth * fraction,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 32,
            child: Text(
              '$events',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: 'StackSansNotch',
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
