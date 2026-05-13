// Auth session value held by Riverpod. Immutable so the router redirect
// callback can compare by identity / equality cheaply.

class AuthSession {
  const AuthSession({required this.email, required this.userId});
  final String email;
  final String userId;
}

class AuthState {
  const AuthState({this.session, this.isLoading = false, this.error});

  final AuthSession? session;
  final bool isLoading;
  final String? error;

  AuthState copyWith({
    AuthSession? session,
    bool? isLoading,
    String? error,
    bool clearSession = false,
    bool clearError = false,
  }) {
    return AuthState(
      session: clearSession ? null : (session ?? this.session),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
