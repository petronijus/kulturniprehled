import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kp_mobile/core/replay_counter.dart';

/// Counter bumped whenever the stats screen should replay its blur-in
/// "Statistiky" header — fired from `_HomeShell._goBranch` when the
/// Stats tab becomes active.
final NotifierProvider<ReplayCounter, int> statsReplayProvider =
    NotifierProvider<ReplayCounter, int>(ReplayCounter.new);
