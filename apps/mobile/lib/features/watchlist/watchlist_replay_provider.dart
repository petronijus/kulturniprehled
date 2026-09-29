import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kp_mobile/core/replay_counter.dart';

/// Counter bumped whenever the watchlist should replay its blur-in
/// header animation — currently fired from `_HomeShell._goBranch` when
/// the Watchlist tab becomes active.
final NotifierProvider<ReplayCounter, int> watchlistReplayProvider =
    NotifierProvider<ReplayCounter, int>(ReplayCounter.new);
