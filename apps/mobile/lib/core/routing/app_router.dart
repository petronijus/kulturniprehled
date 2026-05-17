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
    with WidgetsBindingObserver {
  static const Duration _pollInterval = Duration(seconds: 10);

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
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
    }
  }

  int _previousIndex = 0;

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
    final bool forward = current >= _previousIndex;
    _previousIndex = current;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: <Widget>[
          // Branches with a horizontal slide between them. Right→left when
          // the user taps a tab to the right; left→right going back.
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final bool isIncoming = child.key == ValueKey<int>(current);
                final Offset begin = isIncoming
                    ? (forward ? const Offset(1, 0) : const Offset(-1, 0))
                    : (forward ? const Offset(-1, 0) : const Offset(1, 0));
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: begin,
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: KeyedSubtree(
                key: ValueKey<int>(current),
                child: widget.navigationShell,
              ),
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
      height: 110,
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
            fontFamily: 'StackSansNotch',
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
