import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';
import 'package:kp_mobile/features/auth/login_screen.dart';
import 'package:kp_mobile/features/events/agenda_screen.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';

final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((ref) {
  // Rebuild the router whenever auth state flips between signed-in and
  // signed-out so the redirect callback fires.
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
      GoRoute(
        path: '/agenda',
        builder: (context, state) => const AgendaScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'events/:eventId',
            builder: (context, state) =>
                EventDetailScreen(eventId: state.pathParameters['eventId']!),
          ),
        ],
      ),
    ],
  );
});
