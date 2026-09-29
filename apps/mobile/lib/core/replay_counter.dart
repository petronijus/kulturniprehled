import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A monotonic counter a screen listens to so it can replay its entrance
/// animations. Only ever goes up; [replay] bumps it.
class ReplayCounter extends Notifier<int> {
  @override
  int build() => 0;

  void replay() => state++;
}
