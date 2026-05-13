// Runtime configuration read from --dart-define values at build time.
//
// In dev: `flutter run --dart-define=KP_API_BASE=http://10.0.2.2:18000`
// In prod: bake the public URL into the release flavour. `10.0.2.2` is the
// Android emulator alias for the host machine; physical devices need the
// host's LAN IP or the public tunnel URL.

class AppConfig {
  const AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'KP_API_BASE',
    defaultValue: 'http://10.0.2.2:18000',
  );

  static const String googleOauthClientIdAndroid = String.fromEnvironment(
    'KP_GOOGLE_OAUTH_CLIENT_ID_ANDROID',
  );

  static const String googleOauthClientIdIos = String.fromEnvironment(
    'KP_GOOGLE_OAUTH_CLIENT_ID_IOS',
  );

  // The web client id is what the **backend** verifies the ID token against.
  // On Android+iOS the user signs in with the platform-specific client id,
  // but Google issues an ID token whose `aud` is the linked web client id —
  // and that's what we send to /v1/auth/google.
  static const String googleOauthServerClientId = String.fromEnvironment(
    'KP_GOOGLE_OAUTH_SERVER_CLIENT_ID',
  );

  // Sentry / GlitchTip DSN. Leave empty in dev; the SDK skips init.
  static const String sentryDsn = String.fromEnvironment('KP_SENTRY_DSN');
  static const String sentryEnvironment = String.fromEnvironment(
    'KP_SENTRY_ENVIRONMENT',
    defaultValue: 'dev',
  );
}
