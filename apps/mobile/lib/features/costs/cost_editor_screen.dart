import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:kp_mobile/data/api_client/kp_client.dart';

// Add a cost to an event. Online-only (POST /v1/events/{id}/costs) — adding
// a cost while offline is rare enough that we skip the outbox round-trip;
// the change_log pull on the next sync will land it on every device.

const List<String> _kinds = <String>['ticket', 'transport', 'food', 'other'];
const List<String> _currencies = <String>['CZK', 'EUR', 'USD'];

class CostEditorScreen extends ConsumerStatefulWidget {
  const CostEditorScreen({required this.eventId, super.key});

  final String eventId;

  @override
  ConsumerState<CostEditorScreen> createState() => _CostEditorScreenState();
}

class _CostEditorScreenState extends ConsumerState<CostEditorScreen> {
  final TextEditingController _amount = TextEditingController(text: '0');
  final TextEditingController _note = TextEditingController();
  String _currency = 'CZK';
  String _kind = 'ticket';
  DateTime _paidAt = DateTime.now();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int? _amountCents() {
    final String raw = _amount.text.replaceAll(',', '.').trim();
    if (raw.isEmpty) {
      return null;
    }
    final double? value = double.tryParse(raw);
    if (value == null || value < 0) {
      return null;
    }
    return (value * 100).round();
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _paidAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030, 12, 31),
    );
    if (picked != null) {
      setState(() => _paidAt = picked);
    }
  }

  Future<void> _submit() async {
    final int? cents = _amountCents();
    if (cents == null) {
      setState(() => _error = 'Zadej platnou částku.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final KpClient client = ref.read(kpClientProvider);
      await client.dio.post<dynamic>(
        '/v1/events/${widget.eventId}/costs',
        data: <String, Object?>{
          'amount_cents': cents,
          'currency': _currency,
          'kind': _kind,
          'paid_at':
              '${_paidAt.year.toString().padLeft(4, '0')}-'
              '${_paidAt.month.toString().padLeft(2, '0')}-'
              '${_paidAt.day.toString().padLeft(2, '0')}',
          if (_note.text.isNotEmpty) 'note': _note.text,
        },
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Náklad uložen.')));
      context.pop();
    } on DioException catch (e) {
      setState(() {
        _error = e.response?.data?.toString() ?? e.message ?? 'Selhalo.';
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('d. M. yyyy', 'cs');
    return Scaffold(
      appBar: AppBar(title: const Text('Náklad')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Částka',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _currency,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Měna',
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final String c in _currencies)
                      DropdownMenuItem<String>(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _currency = v ?? 'CZK'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Druh',
            ),
            items: <DropdownMenuItem<String>>[
              for (final String k in _kinds)
                DropdownMenuItem<String>(value: k, child: Text(_kindLabel(k))),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'ticket'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text('Zaplaceno: ${fmt.format(_paidAt)}'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Poznámka',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: const Icon(Icons.save),
            label: Text(_submitting ? 'Ukládám…' : 'Uložit'),
          ),
        ],
      ),
    );
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'ticket':
        return 'Lístek';
      case 'transport':
        return 'Doprava';
      case 'food':
        return 'Jídlo';
      case 'other':
        return 'Jiné';
      default:
        return kind;
    }
  }
}
