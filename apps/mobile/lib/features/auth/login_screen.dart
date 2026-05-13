import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:kp_mobile/features/auth/auth_controller.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authControllerProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Icon(
                Icons.theater_comedy_outlined,
                size: 96,
                color: scheme.primary,
                semanticLabel: 'Kulturní Přehled',
              ),
              const SizedBox(height: 24),
              Text(
                'Kulturní Přehled',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Sdílená agenda koncertů, divadla a kina.',
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              FilledButton.icon(
                key: const Key('google-login-button'),
                onPressed: auth.isLoading
                    ? null
                    : () => ref
                          .read(authControllerProvider.notifier)
                          .signInWithGoogle(),
                icon: const Icon(Icons.login),
                label: Text(
                  auth.isLoading ? 'Přihlašuji…' : 'Přihlásit přes Google',
                ),
              ),
              if (auth.error != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  auth.error!,
                  style: TextStyle(color: scheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
