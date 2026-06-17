# Self-hosting

This app authenticates users with **Google OAuth** (an email allowlist). It is
wired to use **your own Google Cloud project** — none of the credentials below
are baked into the repo, so you bring your own. (The one value committed, the
iOS client id in `Info.plist`, ships as a `YOUR_IOS_CLIENT_ID` placeholder.)

## 1. Create a Google Cloud project

In the [Google Cloud Console](https://console.cloud.google.com/):

1. New project → configure the **OAuth consent screen** (External, add your
   login emails as test users).
2. Create **OAuth client IDs** under *Credentials*:
   - **Web application** — used by the backend to verify ID tokens. Note its
     client id **and secret**. Add your API origin to the authorized origins.
   - **Android** — package name `com.kulturniprehled.kpMobile` + your signing
     SHA-1.
   - **iOS** — bundle id `com.kulturniprehled.kpMobile`.

## 2. Backend (`apps/api`)

Set in `.env` (see `.env.example`):

```
GOOGLE_OAUTH_CLIENT_ID=<web client id>          # the audience tokens are checked against
GOOGLE_OAUTH_CLIENT_SECRET=<web client secret>
ALLOWED_EMAILS=you@example.com,partner@example.com
```

## 3. Mobile app (`apps/mobile`)

Pass your client ids at build time via `--dart-define` (see `lib/core/config.dart`):

```
flutter build apk --release \
  --dart-define=KP_API_BASE=https://your-api.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID=<web client id> \
  --dart-define=KP_GOOGLE_OAUTH_CLIENT_ID_ANDROID=<android client id>
```

> On iOS the OAuth client id can't come from `--dart-define`; it must be static
> in `ios/Runner/Info.plist`, which ships a `YOUR_IOS_CLIENT_ID` placeholder.
> Either edit it by hand, or:
>
> ```
> export KP_IOS_GOOGLE_CLIENT_ID=<your bare iOS client id>   # before .apps.googleusercontent.com
> ./scripts/ios-inject-client-id.sh        # placeholder -> your id
> # build, then:
> ./scripts/ios-inject-client-id.sh --restore
> ```
>
> The maintainer's iOS release scripts (`infra/ios/release-*.sh`) do this
> inject/restore automatically.

## 4. Run

Backend + storage come up with `docker compose` from `infra/`; see
[`docs/deployment.md`](deployment.md).
