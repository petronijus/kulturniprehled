import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/watchlist/watchlist_repository.dart';

// Shared watchlist screen.
//
// Items render in a flat order: roots in `position` order, followed by each
// root's children (indented) also in `position` order. Drag-to-reorder is
// allowed within a scope (root-only or among the siblings of one parent);
// moves across scopes are surfaced via a long-press menu instead.
//
// All writes go through `WatchlistRepository` which optimistically updates
// the local drift cache; the next /v1/sync pull reconciles.

class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  @override
  void initState() {
    super.initState();
    // Non-blocking sync on mount — same pattern as AgendaScreen. The list
    // renders from the local cache immediately; the pull tops it up with
    // anything the other device wrote since.
    Future<void>.microtask(
      () => ref.read(syncControllerProvider.notifier).pullChanges(),
    );
  }

  Future<void> _refresh() =>
      ref.read(syncControllerProvider.notifier).pullChanges();

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedWatchlistItemRow>> rows = ref.watch(
      watchlistProvider,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Watchlist')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: rows.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ListView(
            children: <Widget>[
              const SizedBox(height: 120),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Chyba: $error', textAlign: TextAlign.center),
              ),
            ],
          ),
          data: (items) => _WatchlistBody(items: items),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, ref, parentId: null),
        tooltip: 'Přidat',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Render an alternating tree of roots and their children. Each entry knows
/// its `scopeId` (== parent_id or `null` for root scope) so we can constrain
/// drag-reorders to one scope at a time.
class _WatchlistEntry {
  const _WatchlistEntry({
    required this.row,
    required this.depth,
    required this.scopeId,
  });

  final CachedWatchlistItemRow row;
  final int depth; // 0 = root, 1 = child
  final String? scopeId; // null = root scope, else the parent id
}

class _WatchlistBody extends ConsumerWidget {
  const _WatchlistBody({required this.items});

  final List<CachedWatchlistItemRow> items;

  List<_WatchlistEntry> _layoutEntries() {
    final List<CachedWatchlistItemRow> roots =
        items.where((r) => r.parentId == null).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final Map<String, List<CachedWatchlistItemRow>> childrenByParent =
        <String, List<CachedWatchlistItemRow>>{};
    for (final CachedWatchlistItemRow row in items) {
      final String? pid = row.parentId;
      if (pid == null) continue;
      (childrenByParent[pid] ??= <CachedWatchlistItemRow>[]).add(row);
    }
    for (final List<CachedWatchlistItemRow> bucket in childrenByParent.values) {
      bucket.sort((a, b) => a.position.compareTo(b.position));
    }

    final List<_WatchlistEntry> out = <_WatchlistEntry>[];
    for (final CachedWatchlistItemRow root in roots) {
      out.add(_WatchlistEntry(row: root, depth: 0, scopeId: null));
      final List<CachedWatchlistItemRow>? children = childrenByParent[root.id];
      if (children == null) continue;
      for (final CachedWatchlistItemRow child in children) {
        out.add(_WatchlistEntry(row: child, depth: 1, scopeId: root.id));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      // Use a scrollable ListView so the parent RefreshIndicator works
      // even when the list is empty (pull-down from the empty state).
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const <Widget>[
          SizedBox(height: 120),
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Watchlist je prázdný — přidej první film, divadlo nebo koncert.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    final List<_WatchlistEntry> entries = _layoutEntries();

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final _WatchlistEntry entry = entries[index];
        return _WatchlistRow(
          key: ValueKey<String>(entry.row.id),
          entry: entry,
          index: index,
        );
      },
      onReorder: (int oldIndex, int newIndex) async {
        await _reorder(context, ref, entries, oldIndex, newIndex);
      },
    );
  }

  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    List<_WatchlistEntry> entries,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final _WatchlistEntry moving = entries[oldIndex];
    final _WatchlistEntry target = entries[newIndex];
    if (moving.scopeId != target.scopeId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Položky lze přeházet jen v rámci stejné úrovně. Použij dlouhý stisk pro přesun.',
          ),
        ),
      );
      return;
    }

    final WatchlistRepository repo = ref.read(watchlistRepositoryProvider);
    try {
      // Land just after the target (or just before if dragging upward — same
      // result by symmetry: pinning to target.id is enough because the
      // server fills in the new midpoint position from the live state.
      if (newIndex > oldIndex) {
        await repo.moveItem(
          id: moving.row.id,
          version: moving.row.version,
          afterId: target.row.id,
        );
      } else {
        await repo.moveItem(
          id: moving.row.id,
          version: moving.row.version,
          beforeId: target.row.id,
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Přesun selhal: $e')));
      }
    }
  }
}

class _WatchlistRow extends ConsumerWidget {
  const _WatchlistRow({super.key, required this.entry, required this.index});

  final _WatchlistEntry entry;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CachedWatchlistItemRow row = entry.row;
    final TextStyle? titleStyle = row.done
        ? TextStyle(
            decoration: TextDecoration.lineThrough,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.5),
          )
        : null;

    return Dismissible(
      key: ValueKey<String>('dismiss-${row.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) async => _confirmDelete(context),
      onDismissed: (_) async {
        try {
          await ref.read(watchlistRepositoryProvider).deleteItem(row.id);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Smazání selhalo: $e')));
          }
        }
      },
      child: InkWell(
        onLongPress: () => _showRowMenu(context, ref, entry),
        child: Padding(
          padding: EdgeInsets.only(left: entry.depth == 1 ? 32 : 0),
          child: ListTile(
            leading: Checkbox(
              value: row.done,
              onChanged: (bool? next) async {
                if (next == null) return;
                try {
                  await ref
                      .read(watchlistRepositoryProvider)
                      .setDone(id: row.id, version: row.version, done: next);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Změna stavu selhala: $e')),
                    );
                  }
                }
              },
            ),
            title: Text(row.title, style: titleStyle),
            subtitle: row.note == null || row.note!.isEmpty
                ? _KindBadge(kind: row.kind)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _KindBadge(kind: row.kind),
                      const SizedBox(height: 4),
                      Text(row.note!),
                    ],
                  ),
            trailing: ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Smazat položku?'),
          content: Text(
            entry.depth == 0 && entry.row.parentId == null
                ? 'Pokud má položka podpoložky, smažou se s ní.'
                : 'Tato akce je vratná jen ze serveru.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Smazat'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final String kind;

  static const Map<String, ({String label, IconData icon})> _styles =
      <String, ({String label, IconData icon})>{
        'film': (label: 'Film', icon: Icons.movie_outlined),
        'divadlo': (label: 'Divadlo', icon: Icons.theater_comedy_outlined),
        'koncert': (label: 'Koncert', icon: Icons.music_note_outlined),
      };

  @override
  Widget build(BuildContext context) {
    final ({String label, IconData icon}) style =
        _styles[kind] ?? (label: kind, icon: Icons.label_outline);
    final Color fg = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(style.icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Text(style.label, style: TextStyle(fontSize: 12, color: fg)),
      ],
    );
  }
}

void _showRowMenu(BuildContext context, WidgetRef ref, _WatchlistEntry entry) {
  showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext context) {
      final bool isRoot = entry.row.parentId == null;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Upravit'),
              onTap: () {
                Navigator.of(context).pop();
                _showEditDialog(context, ref, entry.row);
              },
            ),
            if (isRoot)
              ListTile(
                leading: const Icon(Icons.add_outlined),
                title: const Text('Přidat podpoložku'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showAddDialog(context, ref, parentId: entry.row.id);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Smazat'),
              onTap: () async {
                Navigator.of(context).pop();
                final bool? confirmed = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('Smazat položku?'),
                      content: Text(
                        isRoot
                            ? 'Pokud má položka podpoložky, smažou se s ní.'
                            : 'Položka bude smazána.',
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Zrušit'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Smazat'),
                        ),
                      ],
                    );
                  },
                );
                if (confirmed != true) return;
                try {
                  await ref
                      .read(watchlistRepositoryProvider)
                      .deleteItem(entry.row.id);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Smazání selhalo: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

void _showAddDialog(
  BuildContext context,
  WidgetRef ref, {
  required String? parentId,
}) {
  final TextEditingController titleController = TextEditingController();
  final TextEditingController noteController = TextEditingController();
  String kind = 'film';

  showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder:
            (BuildContext context, void Function(void Function()) setState) {
              return AlertDialog(
                title: Text(
                  parentId == null ? 'Nová položka' : 'Nová podpoložka',
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: titleController,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Název'),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<String>(
                        segments: const <ButtonSegment<String>>[
                          ButtonSegment<String>(
                            value: 'film',
                            label: Text('Film'),
                          ),
                          ButtonSegment<String>(
                            value: 'divadlo',
                            label: Text('Divadlo'),
                          ),
                          ButtonSegment<String>(
                            value: 'koncert',
                            label: Text('Koncert'),
                          ),
                        ],
                        selected: <String>{kind},
                        onSelectionChanged: (Set<String> next) =>
                            setState(() => kind = next.first),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: noteController,
                        decoration: const InputDecoration(
                          labelText: 'Poznámka (volitelné)',
                        ),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Zrušit'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final String title = titleController.text.trim();
                      if (title.isEmpty) return;
                      Navigator.of(context).pop();
                      try {
                        await ref
                            .read(watchlistRepositoryProvider)
                            .createItem(
                              title: title,
                              kind: kind,
                              parentId: parentId,
                              note: noteController.text.trim().isEmpty
                                  ? null
                                  : noteController.text.trim(),
                            );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Přidání selhalo: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('Přidat'),
                  ),
                ],
              );
            },
      );
    },
  );
}

void _showEditDialog(
  BuildContext context,
  WidgetRef ref,
  CachedWatchlistItemRow row,
) {
  final TextEditingController titleController = TextEditingController(
    text: row.title,
  );
  final TextEditingController noteController = TextEditingController(
    text: row.note ?? '',
  );
  String kind = row.kind;

  showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder:
            (BuildContext context, void Function(void Function()) setState) {
              return AlertDialog(
                title: const Text('Upravit položku'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: titleController,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Název'),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<String>(
                        segments: const <ButtonSegment<String>>[
                          ButtonSegment<String>(
                            value: 'film',
                            label: Text('Film'),
                          ),
                          ButtonSegment<String>(
                            value: 'divadlo',
                            label: Text('Divadlo'),
                          ),
                          ButtonSegment<String>(
                            value: 'koncert',
                            label: Text('Koncert'),
                          ),
                        ],
                        selected: <String>{kind},
                        onSelectionChanged: (Set<String> next) =>
                            setState(() => kind = next.first),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: noteController,
                        decoration: const InputDecoration(
                          labelText: 'Poznámka (volitelné)',
                        ),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Zrušit'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final String title = titleController.text.trim();
                      if (title.isEmpty) return;
                      Navigator.of(context).pop();
                      try {
                        await ref
                            .read(watchlistRepositoryProvider)
                            .updateItem(
                              id: row.id,
                              version: row.version,
                              title: title,
                              kind: kind,
                              note: noteController.text.trim().isEmpty
                                  ? null
                                  : noteController.text.trim(),
                            );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Úprava selhala: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('Uložit'),
                  ),
                ],
              );
            },
      );
    },
  );
}
