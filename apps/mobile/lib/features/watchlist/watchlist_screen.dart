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
                    fontFamily: 'StackSansHeadline',
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
            child: Transform.translate(
              offset: const Offset(0, -10),
              child: const SizedBox(
                width: 120,
                height: 120,
                child: Icon(Icons.add, size: 110, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Render an alternating tree of roots and their children, plus a
/// non-interactive "Hotovo" divider that sits between the active and
/// completed root sections.
sealed class _WatchlistEntry {
  const _WatchlistEntry();
}

class _WatchlistItemEntry extends _WatchlistEntry {
  const _WatchlistItemEntry({
    required this.row,
    required this.depth,
    required this.scopeId,
  });

  final CachedWatchlistItemRow row;
  final int depth; // 0 = root, 1 = child
  final String? scopeId; // null = root scope, else the parent id
}

class _HotovoHeaderEntry extends _WatchlistEntry {
  const _HotovoHeaderEntry();
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
    // Split roots into active (top) and completed (under the Hotovo
    // divider). Active roots keep manual position order; completed
    // roots sort newest-checked first so the just-checked row pops to
    // the top of the Hotovo section.
    final List<CachedWatchlistItemRow> allRoots = items
        .where((CachedWatchlistItemRow r) => r.parentId == null)
        .toList();
    final List<CachedWatchlistItemRow> activeRoots =
        allRoots.where((CachedWatchlistItemRow r) => !r.done).toList()..sort(
          (CachedWatchlistItemRow a, CachedWatchlistItemRow b) =>
              a.position.compareTo(b.position),
        );
    final List<CachedWatchlistItemRow> doneRoots =
        allRoots.where((CachedWatchlistItemRow r) => r.done).toList()
          ..sort(_doneNewestFirst);

    final Map<String, List<CachedWatchlistItemRow>> childrenByParent =
        <String, List<CachedWatchlistItemRow>>{};
    for (final CachedWatchlistItemRow row in items) {
      final String? pid = row.parentId;
      if (pid == null) continue;
      (childrenByParent[pid] ??= <CachedWatchlistItemRow>[]).add(row);
    }

    Iterable<_WatchlistItemEntry> rootWithChildren(
      CachedWatchlistItemRow root,
    ) sync* {
      yield _WatchlistItemEntry(row: root, depth: 0, scopeId: null);
      final List<CachedWatchlistItemRow>? bucket = childrenByParent[root.id];
      if (bucket == null) return;
      // Children: active first (by position), completed at the end
      // (oldest-checked first → just-checked sits at the very bottom).
      final List<CachedWatchlistItemRow> activeKids =
          bucket.where((CachedWatchlistItemRow c) => !c.done).toList()..sort(
            (CachedWatchlistItemRow a, CachedWatchlistItemRow b) =>
                a.position.compareTo(b.position),
          );
      final List<CachedWatchlistItemRow> doneKids =
          bucket.where((CachedWatchlistItemRow c) => c.done).toList()
            ..sort(_doneOldestFirst);
      for (final CachedWatchlistItemRow c in activeKids) {
        yield _WatchlistItemEntry(row: c, depth: 1, scopeId: root.id);
      }
      for (final CachedWatchlistItemRow c in doneKids) {
        yield _WatchlistItemEntry(row: c, depth: 1, scopeId: root.id);
      }
    }

    final List<_WatchlistEntry> out = <_WatchlistEntry>[];
    for (final CachedWatchlistItemRow root in activeRoots) {
      out.addAll(rootWithChildren(root));
    }
    if (doneRoots.isNotEmpty) {
      out.add(const _HotovoHeaderEntry());
      for (final CachedWatchlistItemRow root in doneRoots) {
        out.addAll(rootWithChildren(root));
      }
    }
    return out;
  }

  static int _doneNewestFirst(
    CachedWatchlistItemRow a,
    CachedWatchlistItemRow b,
  ) {
    // Newest checked first. Rows without done_at (e.g. legacy data)
    // sink to the bottom of the section.
    final DateTime? ad = a.doneAt;
    final DateTime? bd = b.doneAt;
    if (ad == null && bd == null) return a.position.compareTo(b.position);
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  }

  static int _doneOldestFirst(
    CachedWatchlistItemRow a,
    CachedWatchlistItemRow b,
  ) {
    // Oldest checked first → just-checked sits at the very bottom of
    // the parent's children list, matching the "move to end" rule.
    final DateTime? ad = a.doneAt;
    final DateTime? bd = b.doneAt;
    if (ad == null && bd == null) return a.position.compareTo(b.position);
    if (ad == null) return -1;
    if (bd == null) return 1;
    return ad.compareTo(bd);
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
                fontFamily: 'StackSansHeadline',
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
        return switch (entry) {
          _WatchlistItemEntry() => _WatchlistRow(
            key: ValueKey<String>(entry.row.id),
            entry: entry,
            index: index,
          ),
          _HotovoHeaderEntry() => const _HotovoHeader(
            key: ValueKey<String>('hotovo-header'),
          ),
        };
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
    final _WatchlistEntry movingEntry = entries[oldIndex];
    final _WatchlistEntry targetEntry = entries[newIndex];
    // The Hotovo header has no drag handle so movingEntry can't be it,
    // but a drop *onto* the header position needs to be rejected.
    if (movingEntry is! _WatchlistItemEntry ||
        targetEntry is! _WatchlistItemEntry) {
      return;
    }
    if (movingEntry.scopeId != targetEntry.scopeId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Položky lze přeházet jen v rámci stejné úrovně. Použij dlouhý stisk pro přesun.',
          ),
        ),
      );
      return;
    }
    // Active and completed live in two visual sections; manual sort
    // doesn't make sense across them — the checkbox is the only way
    // to flip between sections.
    if (movingEntry.row.done != targetEntry.row.done) {
      return;
    }

    final WatchlistRepository repo = ref.read(watchlistRepositoryProvider);
    try {
      if (newIndex > oldIndex) {
        await repo.moveItem(
          id: movingEntry.row.id,
          version: movingEntry.row.version,
          afterId: targetEntry.row.id,
        );
      } else {
        await repo.moveItem(
          id: movingEntry.row.id,
          version: movingEntry.row.version,
          beforeId: targetEntry.row.id,
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

class _HotovoHeader extends StatelessWidget {
  const _HotovoHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              height: 1,
              color: Colors.black.withValues(alpha: 0.15),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'HOTOVO',
              style: TextStyle(
                fontFamily: 'StackSansHeadline',
                fontWeight: FontWeight.w600,
                fontSize: 10,
                letterSpacing: 0.5,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.black.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchlistRow extends ConsumerWidget {
  const _WatchlistRow({super.key, required this.entry, required this.index});

  final _WatchlistItemEntry entry;
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
                            fontFamily: 'StackSansHeadline',
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
                            fontFamily: 'StackSansHeadline',
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
                              fontFamily: 'StackSansHeadline',
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

void _showRowMenu(
  BuildContext context,
  WidgetRef ref,
  _WatchlistItemEntry entry,
) {
  showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext context) {
      final bool isRoot = entry.row.parentId == null;
      // Lift the sheet's last item ~120 px above the bottom edge so it
      // clears the floating _CulturalNav (130 px tall, sits over the
      // bottom of every screen).
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 120),
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
              if (!isRoot)
                ListTile(
                  leading: const Icon(Icons.arrow_back),
                  title: const Text('Vyndat na root'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    try {
                      await ref
                          .read(watchlistRepositoryProvider)
                          .moveItem(
                            id: entry.row.id,
                            version: entry.row.version,
                            setParent: true,
                            toEnd: true,
                          );
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Přesun selhal: $e')),
                        );
                      }
                    }
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
