import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';
import 'package:kp_mobile/features/auth/login_screen.dart';
import 'package:kp_mobile/features/calendar/calendar_screen.dart';
import 'package:kp_mobile/features/costs/cost_editor_screen.dart';
import 'package:kp_mobile/features/events/agenda_replay_provider.dart';
import 'package:kp_mobile/features/events/agenda_screen.dart';
import 'package:kp_mobile/features/events/edit_event_screen.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';
import 'package:kp_mobile/features/stats/stats_replay_provider.dart';
import 'package:kp_mobile/features/stats/stats_screen.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/tickets/ticket_viewer_screen.dart';
import 'package:kp_mobile/features/watchlist/watchlist_replay_provider.dart';
import 'package:kp_mobile/features/watchlist/watchlist_screen.dart';

final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((ref) {
  final Listenable refresh = ValueNotifier<AuthSession?>(
    ref.read(authControllerProvider).session,
  );
  ref.listen<AuthState>(authControllerProvider, (previous, next) {
    (refresh as ValueNotifier<AuthSession?>).value = next.session;
  });

  return GoRouter(
    initialLocation: '/agenda',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final bool signedIn = ref.read(authControllerProvider).session != null;
      final bool atLogin = state.matchedLocation == '/login';
      if (!signedIn && !atLogin) {
        return '/login';
      }
      if (signedIn && atLogin) {
        return '/agenda';
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _HomeShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/agenda',
                builder: (context, state) => const AgendaScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'events/:eventId',
                    builder: (context, state) => EventDetailScreen(
                      eventId: state.pathParameters['eventId']!,
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => EditEventScreen(
                          eventId: state.pathParameters['eventId']!,
                        ),
                      ),
                      GoRoute(
                        path: 'tickets/:ticketId',
                        builder: (context, state) => TicketViewerScreen(
                          ticketId: state.pathParameters['ticketId']!,
                        ),
                      ),
                      GoRoute(
                        path: 'costs/new',
                        builder: (context, state) => CostEditorScreen(
                          eventId: state.pathParameters['eventId']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/month',
                builder: (context, state) => const CalendarScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/watchlist',
                builder: (context, state) => const WatchlistScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/stats',
                builder: (context, state) => const StatsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class _HomeShell extends ConsumerStatefulWidget {
  const _HomeShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<_HomeShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const Duration _pollInterval = Duration(seconds: 10);
  static const Duration _slideDuration = Duration(milliseconds: 280);

  Timer? _pollTimer;

  // Drives the slide-in Transform on `widget.navigationShell`. Starts
  // at value 1.0 (rest, fully on-screen) so the first frame at app
  // launch doesn't animate; every subsequent tab tap fires `forward
  // (from: 0)` and the new branch slides in from `_slideFrom`.
  late final AnimationController _slideCtrl;
  // Sign of the slide offset: +1 means new tab is to the right of the
  // old one (slide-in from the right), −1 means it's to the left.
  double _slideFrom = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slideCtrl = AnimationController(
      vsync: this,
      duration: _slideDuration,
      value: 1.0,
    );
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _slideCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      ref.read(syncControllerProvider.notifier).pullChanges();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pull on every foregrounding so a switch to the other device picks
    // up its writes the moment the user returns. Also pause/resume the
    // poll so we don't bang the API while the app is backgrounded.
    if (state == AppLifecycleState.resumed) {
      ref.read(syncControllerProvider.notifier).pullChanges();
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pollTimer?.cancel();
    }
  }

  void _goBranch(int index) {
    final int previousIndex = widget.navigationShell.currentIndex;
    // Bottom-nav tap = always go to the branch root. So tapping Agenda
    // from inside the detail screen (or after switching tabs and
    // coming back) pops the stack to /agenda; tapping the other tabs
    // is unaffected because they don't have sub-routes.
    widget.navigationShell.goBranch(index, initialLocation: true);
    // Trigger the slide on every tab change. Direction follows the
    // nav order — taps to the right slide the new content in from
    // the right, taps to the left slide it in from the left. Tapping
    // the current tab (no index change) skips the animation.
    if (index != previousIndex) {
      _slideFrom = index > previousIndex ? 1.0 : -1.0;
      _slideCtrl.forward(from: 0);
    }
    // Pulling on every tab switch keeps each feature's cache fresh
    // without each screen having to know to sync in initState.
    ref.read(syncControllerProvider.notifier).pullChanges();
    // Entering a branch from another tab replays that branch's blur-in
    // headers — the screen widgets themselves stay in tree
    // (StatefulShellRoute keeps branch state), so initState won't fire
    // on its own.
    if (index == 0) {
      ref.read(agendaReplayProvider.notifier).state++;
    } else if (index == 2) {
      ref.read(watchlistReplayProvider.notifier).state++;
    } else if (index == 3) {
      ref.read(statsReplayProvider.notifier).state++;
    }
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Odhlásit?'),
        content: const Text('Odhlásí tě z účtu Kulturní Přehled.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Odhlásit'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authControllerProvider.notifier).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final int current = widget.navigationShell.currentIndex;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: <Widget>[
          // Slide the navigationShell on every tab switch via a
          // Transform on the same widget instance — no AnimatedSwitcher,
          // no KeyedSubtree, no remount. The IndexedStack inside keeps
          // every branch alive and offstage ones in TickerMode(disabled),
          // so BlurInText animations sit paused at 0 until their branch
          // becomes current and play naturally on first reveal.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _slideCtrl,
              builder: (BuildContext context, Widget? child) {
                final double dx =
                    _slideFrom *
                    MediaQuery.of(context).size.width *
                    (1 - Curves.easeOutCubic.transform(_slideCtrl.value));
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: widget.navigationShell,
            ),
          ),
          // Floating Kp logo (tap → logout confirm). Sits on every screen.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FloatingLogo(onTap: () => _confirmSignOut(context)),
          ),
          // Floating bottom nav.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _CulturalNav(selectedIndex: current, onTap: _goBranch),
          ),
        ],
      ),
    );
  }
}

class _FloatingLogo extends StatelessWidget {
  const _FloatingLogo({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Image.asset(
                  'assets/brand/kp_logo.png',
                  height: 80,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CulturalNav extends StatelessWidget {
  const _CulturalNav({required this.selectedIndex, required this.onTap});

  final int selectedIndex;
  final ValueChanged<int> onTap;

  static const List<String> _labels = <String>[
    'Agenda',
    'Měsíc',
    'Watchlist',
    'Stats',
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 130 px (= original 110 + 20) raises the gradient's top edge so
      // there's more vertical room for the transparent → white fade
      // before the labels sit on solid white.
      height: 130,
      child: Stack(
        children: <Widget>[
          // Transparent→white gradient so the cards above fade out under
          // the nav. Reaches full white by 60 % (per Figma) so the labels
          // sit on a solid, opaque base.
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00FFFFFF), Color(0xFFFFFFFF)],
                  stops: <double>[0.0, 0.6049],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
          SafeArea(
            top: false,
            child: Transform.translate(
              // Shift labels 10 px down in their slot so the gradient
              // has more visual room above the row. Negative bottom
              // padding isn't a thing, so a translate is the simplest
              // way to shift in-place without changing the SizedBox
              // geometry.
              offset: const Offset(0, 10),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      for (int i = 0; i < _labels.length; i++)
                        _NavLabel(
                          label: _labels[i],
                          selected: i == selectedIndex,
                          onTap: () => onTap(i),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavLabel extends StatelessWidget {
  const _NavLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            fontFamily: 'StackSansHeadline',
            fontWeight: FontWeight.w600,
            fontSize: 12,
            letterSpacing: 0.48,
            color: selected
                ? Colors.black
                : Colors.black.withValues(alpha: 0.3),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}
