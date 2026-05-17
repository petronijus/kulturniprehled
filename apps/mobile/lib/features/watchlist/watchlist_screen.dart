import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/core/widgets/blur_in_text.dart';
import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/watchlist/watchlist_replay_provider.dart';
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
  // Per-screen replay tick. Bumped when the global
  // [watchlistReplayProvider] fires (i.e. the user tabs back to
  // Watchlist) so the BlurInText title replays.
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
    super.dispose();
  }

  Future<void> _refresh() =>
      ref.read(syncControllerProvider.notifier).pullChanges();

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CachedWatchlistItemRow>> rows = ref.watch(
      watchlistProvider,
    );
    ref.listen<int>(watchlistReplayProvider, (int? previous, int next) {
      if (previous != next) _replayTick.value++;
    });

    final double topPad = MediaQuery.of(context).padding.top + 96;
    return Scaffold(
      backgroundColor: Colors.white,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: rows.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, _) => ListView(
            padding: EdgeInsets.only(top: topPad),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Chyba: $error', textAlign: TextAlign.center),
              ),
            ],
          ),
          data: (List<CachedWatchlistItemRow> items) => _WatchlistBody(
            items: items,
            topPad: topPad,
            replayTrigger: _replayTick,
          ),
        ),
      ),
    );
  }
}

class _WatchlistHeader extends StatelessWidget {
  const _WatchlistHeader({required this.onAdd, required this.replayTrigger});

  final VoidCallback onAdd;
  final Listenable replayTrigger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                BlurInText(
                  key: const ValueKey<String>('watchlist-title'),
                  text: 'Watchlist',
                  restartTrigger: replayTrigger,
                  style: const TextStyle(
                    fontFamily: 'Gloock',
                    fontSize: 50,
                    height: 1.0,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Filmy · Divadlo · Koncerty · Cokoliv',
                  style: TextStyle(
                    fontFamily: 'StackSansNotch',
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.48,
                    color: Colors.black.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          // Big plus button replaces the floating action button —
          // anchored at the top-right of the screen header per Figma.
          InkResponse(
            onTap: onAdd,
            radius: 64,
            child: const SizedBox(
              width: 120,
              height: 120,
              child: Icon(Icons.add, size: 110, color: Colors.black),
            ),
          ),
        ],
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
  const _WatchlistBody({
    required this.items,
    required this.topPad,
    required this.replayTrigger,
  });

  final List<CachedWatchlistItemRow> items;
  final double topPad;
  final Listenable replayTrigger;

  List<_WatchlistEntry> _layoutEntries() {
    final List<CachedWatchlistItemRow> roots =
        items.where((CachedWatchlistItemRow r) => r.parentId == null).toList()
          ..sort(
            (CachedWatchlistItemRow a, CachedWatchlistItemRow b) =>
                a.position.compareTo(b.position),
          );
    final Map<String, List<CachedWatchlistItemRow>> childrenByParent =
        <String, List<CachedWatchlistItemRow>>{};
    for (final CachedWatchlistItemRow row in items) {
      final String? pid = row.parentId;
      if (pid == null) continue;
      (childrenByParent[pid] ??= <CachedWatchlistItemRow>[]).add(row);
    }
    for (final List<CachedWatchlistItemRow> bucket in childrenByParent.values) {
      bucket.sort(
        (CachedWatchlistItemRow a, CachedWatchlistItemRow b) =>
            a.position.compareTo(b.position),
      );
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
    final Widget header = _WatchlistHeader(
      onAdd: () => _showAddDialog(context, ref, parentId: null),
      replayTrigger: replayTrigger,
    );
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: topPad),
          header,
          const SizedBox(height: 32),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Watchlist je prázdný — přidej první film, divadlo nebo koncert.',
              style: TextStyle(
                fontFamily: 'StackSansNotch',
                fontWeight: FontWeight.w400,
                fontSize: 13,
                color: Colors.black,
              ),
            ),
          ),
        ],
      );
    }

    final List<_WatchlistEntry> entries = _layoutEntries();

    // ReorderableListView's leading header slot is the cleanest way to
    // keep the title + plus-button sticky-at-top while the list scrolls
    // and stays reorderable.
    return ReorderableListView.builder(
      padding: EdgeInsets.only(top: topPad, bottom: 160),
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      header: Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: header,
      ),
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

  String _kindLabel(String kind) {
    switch (kind) {
      case 'film':
        return 'Film';
      case 'divadlo':
        return 'Divadlo';
      case 'koncert':
        return 'Koncert';
      default:
        return kind.isEmpty ? kind : kind[0].toUpperCase() + kind.substring(1);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CachedWatchlistItemRow row = entry.row;
    final double indent = entry.depth == 1 ? 32 : 0;
    return Dismissible(
      key: ValueKey<String>('dismiss-${row.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: const Color(0xFFE0E0E0),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete_outline, color: Colors.black),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(24 + indent, 10, 24, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _SquareCheckbox(
                    value: row.done,
                    onChanged: (bool next) async {
                      try {
                        await ref
                            .read(watchlistRepositoryProvider)
                            .setDone(
                              id: row.id,
                              version: row.version,
                              done: next,
                            );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Změna stavu selhala: $e')),
                          );
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          row.title,
                          style: TextStyle(
                            fontFamily: 'StackSansNotch',
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: row.done
                                ? Colors.black.withValues(alpha: 0.45)
                                : Colors.black,
                            decoration: row.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _kindLabel(row.kind),
                          style: TextStyle(
                            fontFamily: 'StackSansNotch',
                            fontWeight: FontWeight.w600,
                            fontSize: 10,
                            letterSpacing: 0.4,
                            color: Colors.black.withValues(alpha: 0.45),
                          ),
                        ),
                        if (row.note != null &&
                            row.note!.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            row.note!,
                            style: TextStyle(
                              fontFamily: 'StackSansNotch',
                              fontWeight: FontWeight.w400,
                              fontSize: 12,
                              color: Colors.black.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ReorderableDragStartListener(
                    index: index,
                    child: SizedBox(
                      width: 24,
                      height: 32,
                      child: Center(
                        child: Text(
                          '⋮⋮',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 18,
                            color: Colors.black.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Hairline divider between rows (skips the very last row
            // visually — handled by the parent's bottom padding).
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              height: 1,
              color: Colors.black.withValues(alpha: 0.06),
            ),
          ],
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

/// Square 20×20 checkbox with a 1.5 px border. Checked state is a
/// plain black fill — no inner glyph — to match the Figma's minimal
/// monochrome look. Replaces Material's Checkbox (which has a slight
/// corner radius and always renders a checkmark).
class _SquareCheckbox extends StatelessWidget {
  const _SquareCheckbox({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Padding(
        // Pad the tap target so it's comfortable to hit while the
        // visual is a tight 20×20.
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: value ? Colors.black : Colors.transparent,
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
        ),
      ),
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
