import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';
import 'package:kp_mobile/features/auth/login_screen.dart';
import 'package:kp_mobile/features/calendar/calendar_screen.dart';
import 'package:kp_mobile/features/costs/cost_editor_screen.dart';
import 'package:kp_mobile/features/events/agenda_screen.dart';
import 'package:kp_mobile/features/events/edit_event_screen.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';
import 'package:kp_mobile/features/stats/stats_screen.dart';
import 'package:kp_mobile/features/sync/sync_controller.dart';
import 'package:kp_mobile/features/tickets/ticket_viewer_screen.dart';
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: widget.navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: _goBranch,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Agenda',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Měsíc',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: 'Watchlist',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Statistiky',
          ),
        ],
      ),
    );
  }
}
