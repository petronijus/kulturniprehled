import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Monotonic counter bumped whenever something wants the agenda screen to
/// replay its entrance animations (BlurInText titles, etc).
///
/// Sources that bump it:
///   * `EventDetailScreen.dispose()` — user backed out of an event detail.
///   * `_HomeShell._goBranch(0)` — user tapped the Agenda tab from
///     another branch.
///
/// The agenda screen listens to this provider and forwards the change
/// through an InheritedWidget to every BlurInText in the list.
final StateProvider<int> agendaReplayProvider = StateProvider<int>((_) => 0);
