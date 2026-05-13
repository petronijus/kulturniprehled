import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/events_repository.dart';
import 'package:kp_mobile/features/outbox/outbox_controller.dart';

class EditEventScreen extends ConsumerStatefulWidget {
  const EditEventScreen({required this.eventId, super.key});

  final String eventId;

  @override
  ConsumerState<EditEventScreen> createState() => _EditEventScreenState();
}

class _EditEventScreenState extends ConsumerState<EditEventScreen> {
  CachedEventRow? _event;
  late TextEditingController _notesCtrl;
  String? _selectedStatus;
  bool _loading = true;

  static const List<String> _statuses = <String>[
    'planned',
    'attended',
    'cancelled',
    'missed',
  ];

  String _statusLabel(String status) {
    switch (status) {
      case 'planned':
        return 'Plánováno';
      case 'attended':
        return 'Bylo to';
      case 'cancelled':
        return 'Zrušeno';
      case 'missed':
        return 'Nestihli';
      default:
        return status;
    }
  }

  @override
  void initState() {
    super.initState();
    _notesCtrl = TextEditingController();
    Future<void>.microtask(_hydrate);
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _hydrate() async {
    final EventsRepository repo = ref.read(eventsRepositoryProvider);
    final CachedEventRow? row = await repo.getEvent(widget.eventId);
    if (!mounted) {
      return;
    }
    setState(() {
      _event = row;
      _notesCtrl.text = row?.notes ?? '';
      _selectedStatus = row?.status;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final CachedEventRow? event = _event;
    if (event == null) {
      return;
    }
    final Map<String, Object?> changes = <String, Object?>{};
    if (_selectedStatus != event.status) {
      changes['status'] = _selectedStatus;
    }
    final String newNotes = _notesCtrl.text;
    if (newNotes != (event.notes ?? '')) {
      changes['notes'] = newNotes.isEmpty ? null : newNotes;
    }
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final OutboxController outbox = ref.read(outboxControllerProvider.notifier);
    await outbox.queueEventUpdate(
      entityId: event.id,
      baseVersion: event.version,
      fields: changes,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Úprava zařazena do fronty.')));
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final CachedEventRow? event = _event;
    if (event == null) {
      return const Scaffold(body: Center(child: Text('Událost nenalezena.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upravit'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: 'Uložit',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(event.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Text('Stav', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final String s in _statuses)
                ChoiceChip(
                  label: Text(_statusLabel(s)),
                  selected: _selectedStatus == s,
                  onSelected: (_) => setState(() => _selectedStatus = s),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Poznámka', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            maxLines: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Program, dojem, fotky…',
            ),
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Uložit změnu'),
          ),
        ],
      ),
    );
  }
}
