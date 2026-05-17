import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Counter bumped whenever the watchlist should replay its blur-in
/// header animation — currently fired from `_HomeShell._goBranch` when
/// the Watchlist tab becomes active.
final StateProvider<int> watchlistReplayProvider = StateProvider<int>((_) => 0);
