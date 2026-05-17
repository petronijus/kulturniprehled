import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  int _year = DateTime.now().year;
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
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

  String _formatCzk(int cents) {
    final double value = cents / 100.0;
    return NumberFormat.currency(locale: 'cs_CZ', symbol: 'Kč').format(value);
  }

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

  static const List<String> _monthNames = <String>[
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: RefreshIndicator(
        onRefresh: _load,
        child: Column(
          children: <Widget>[
            SizedBox(height: MediaQuery.of(context).padding.top + 96),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    tooltip: 'Předchozí rok',
                    onPressed: () {
                      setState(() => _year -= 1);
                      unawaitedLoad();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '$_year',
                      style: const TextStyle(
                        fontFamily: 'StackSansNotch',
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: 'Další rok',
                    onPressed: () {
                      setState(() => _year += 1);
                      unawaitedLoad();
                    },
                  ),
                ],
              ),
            ),
            Expanded(child: _build()),
          ],
        ),
      ),
    );
  }

  void unawaitedLoad() {
    Future<void>.microtask(_load);
  }

  Widget _build() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 64),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Zkusit znovu')),
            ],
          ),
        ),
      );
    }
    final Map<String, dynamic>? data = _data;
    if (data == null) {
      return const Center(child: Text('Žádná data.'));
    }
    final int totalEvents = data['total_events'] as int? ?? 0;
    final int attended = data['attended'] as int? ?? 0;
    final int totalCostCents = data['total_cost_cents'] as int? ?? 0;
    final List<dynamic> byCategory =
        (data['by_category'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> byMonth =
        (data['by_month'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> topVenues =
        (data['top_venues'] as List<dynamic>?) ?? const <dynamic>[];

    if (totalEvents == 0 && totalCostCents == 0) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: const <Widget>[
          SizedBox(height: 80),
          Icon(Icons.bar_chart, size: 80),
          SizedBox(height: 16),
          Text('Pro tenhle rok zatím nic není.', textAlign: TextAlign.center),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _KpiCard(label: 'Celkem akcí', value: '$totalEvents'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _KpiCard(label: 'Zúčastnili jsme se', value: '$attended'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _KpiCard(label: 'Útrata', value: _formatCzk(totalCostCents)),
        const SizedBox(height: 24),
        Text('Podle kategorie', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final dynamic row in byCategory)
          ListTile(
            dense: true,
            title: Text(
              _categoryLabel(
                (row as Map<String, dynamic>)['category'] as String,
              ),
            ),
            trailing: Text('${row['count']}'),
          ),
        const SizedBox(height: 16),
        Text('Podle měsíce', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _MonthBars(
          rows: byMonth.cast<Map<String, dynamic>>(),
          monthNames: _monthNames,
          formatCzk: _formatCzk,
        ),
        if (topVenues.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            'Nejčastější místa',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final dynamic row in topVenues)
            ListTile(
              dense: true,
              title: Text((row as Map<String, dynamic>)['name'] as String),
              trailing: Text('${row['count']}'),
            ),
        ],
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}

class _MonthBars extends StatelessWidget {
  const _MonthBars({
    required this.rows,
    required this.monthNames,
    required this.formatCzk,
  });

  final List<Map<String, dynamic>> rows;
  final List<String> monthNames;
  final String Function(int cents) formatCzk;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Žádné měsíce s daty.'),
      );
    }
    final int maxEvents = rows
        .map((r) => r['events'] as int)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        for (final Map<String, dynamic> row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 36,
                  child: Text(monthNames[(row['month'] as int) - 1]),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double fraction = maxEvents == 0
                          ? 0
                          : (row['events'] as int) / maxEvents;
                      return Stack(
                        children: <Widget>[
                          Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          Container(
                            height: 18,
                            width: constraints.maxWidth * fraction,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 36,
                  child: Text('${row['events']}', textAlign: TextAlign.right),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: Text(
                    formatCzk(row['total_cost_cents'] as int),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
