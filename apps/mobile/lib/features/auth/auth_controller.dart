import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:kp_mobile/core/config.dart';
import 'package:kp_mobile/data/api_client/kp_client.dart';
import 'package:kp_mobile/data/storage/token_store.dart';
import 'package:kp_mobile/features/auth/auth_state.dart';

// Stable interface the tests can fake to avoid spinning up real Google.
abstract class GoogleSignInGateway {
  Future<String?> signIn();
  Future<void> signOut();
}

class _RealGoogleSignInGateway implements GoogleSignInGateway {
  _RealGoogleSignInGateway()
    : _signIn = GoogleSignIn(
        serverClientId: AppConfig.googleOauthServerClientId.isEmpty
            ? null
            : AppConfig.googleOauthServerClientId,
        scopes: const <String>['email', 'profile'],
      );

  final GoogleSignIn _signIn;

  @override
  Future<String?> signIn() async {
    final GoogleSignInAccount? account = await _signIn.signIn();
    if (account == null) {
      return null; // user cancelled
    }
    final GoogleSignInAuthentication auth = await account.authentication;
    return auth.idToken;
  }

  @override
  Future<void> signOut() => _signIn.signOut();
}

final Provider<GoogleSignInGateway> googleSignInGatewayProvider =
    Provider<GoogleSignInGateway>((ref) => _RealGoogleSignInGateway());

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    Future<void>.microtask(_hydrateFromStorage);
    return const AuthState();
  }

  Future<void> _hydrateFromStorage() async {
    final TokenStore store = ref.read(tokenStoreProvider);
    final TokenPair? pair = await store.read();
    if (pair == null) {
      return;
    }
    // We don't decode the JWT here — the API will tell us when it's stale
    // via 401 and the auth interceptor will refresh transparently. Keep
    // the session optimistic so the user lands on the agenda screen
    // immediately on app start.
    state = state.copyWith(
      session: const AuthSession(email: '', userId: ''),
    );
  }

  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final GoogleSignInGateway gateway = ref.read(googleSignInGatewayProvider);
      final String? idToken = await gateway.signIn();
      if (idToken == null) {
        state = state.copyWith(isLoading: false);
        return;
      }
      final KpClient client = ref.read(kpClientProvider);
      final Response<dynamic> response = await client.dio.post<dynamic>(
        '/v1/auth/google',
        data: <String, String>{'id_token': idToken},
      );
      final Map<String, dynamic> body = response.data! as Map<String, dynamic>;
      final TokenPair pair = TokenPair(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String,
        accessExpiresAt: DateTime.parse(body['access_expires_at'] as String),
        refreshExpiresAt: DateTime.parse(body['refresh_expires_at'] as String),
      );
      await ref.read(tokenStoreProvider).write(pair);
      state = state.copyWith(
        session: const AuthSession(email: '', userId: ''),
        isLoading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.response?.data?.toString() ?? e.message ?? 'login failed',
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> signOut() async {
    try {
      await ref.read(googleSignInGatewayProvider).signOut();
    } catch (_) {
      // Best-effort — even if Google sign-out fails we still drop our tokens.
    }
    await ref.read(tokenStoreProvider).clear();
    state = const AuthState();
  }

  void setSessionForTest(AuthSession? session) {
    state = state.copyWith(session: session, clearSession: session == null);
  }
}

final NotifierProvider<AuthController, AuthState> authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
