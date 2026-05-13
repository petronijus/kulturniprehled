import 'package:flutter/material.dart';

import 'package:kp_mobile/features/outbox/outbox_controller.dart';

// Minimal two-button conflict resolution.
//
// The server returned 409 with the current version while we tried to apply
// a stale edit. We don't try to merge text fields here (that would be M9+
// CRDT territory) — instead we let the user pick "Keep mine" (re-push with
// fresh base_version, possibly overwriting whatever changed server-side)
// or "Use server" (drop the local edit, let the next /v1/sync pull bring
// the real value down).

enum ConflictResolution { keepMine, useServer }

Future<ConflictResolution?> showConflictResolutionDialog({
  required BuildContext context,
  required OutboxConflict conflict,
}) {
  return showDialog<ConflictResolution>(
    context: context,
    builder: (context) {
      final Iterable<MapEntry<String, Object?>> entries =
          conflict.attemptedPayload.entries;
      return AlertDialog(
        title: const Text('Konflikt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Tahle událost se mezitím změnila i jinde. '
              'Ponechat tvoje změny, nebo přijmout aktuální stav serveru?',
            ),
            const SizedBox(height: 12),
            Text('Tvé pokusy:', style: Theme.of(context).textTheme.titleSmall),
            ...entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• ${e.key}: ${e.value}'),
              ),
            ),
            const SizedBox(height: 12),
            Text('Verze serveru: ${conflict.currentVersion}'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(ConflictResolution.useServer),
            child: const Text('Použít server'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(ConflictResolution.keepMine),
            child: const Text('Ponechat moje'),
          ),
        ],
      );
    },
  );
}
