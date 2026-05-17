import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Counter bumped whenever the stats screen should replay its blur-in
/// "Statistiky" header — fired from `_HomeShell._goBranch` when the
/// Stats tab becomes active.
final StateProvider<int> statsReplayProvider = StateProvider<int>((_) => 0);
