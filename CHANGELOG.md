# Changelog

All notable changes to Kulturní Přehled. Format follows
[Keep a Changelog](https://keepachangelog.com/), versioning follows
[SemVer](https://semver.org/). The mobile app version (`apps/mobile/pubspec.yaml`)
drives the `vX.Y.Z` tags; per-release detail is on the
[GitHub Releases](../../releases) page.

## [Unreleased]

## [1.2.0] - 2026-09-30

The season planner arrives, and the Android app moves to Google Play.

### Added
- **Season planner** — a web app served by the API at `/app`, reachable only
  from the home network: a season calendar, a candidate pool with filters by
  area, ensemble and venue, scenario previews, plan conflicts (two events a
  week, two days between them, no work twice, blocked days), the shared
  household calendar and public holidays in the grid, and a player that plays
  a concert's programme piece by piece on Spotify.
- **Seat watch** — watch a sold-out hall from the planner and get an e-mail
  when seats next to each other come free.
- **Season skills** — domain experts (classical, electronic) that scrape
  Prague programmes, a season orchestrator with a constraint validator, a
  weekly novelty watcher that e-mails only newly announced events, and
  programme links to recordings. The weekly and season runs moved to a home
  server.
- Ensemble and festival logos in the planner and the weekly e-mail.

### Changed
- **Android ships through Google Play internal testing** instead of a
  sideloaded APK. Uninstall the old app once and install from the Play
  testers' link.
- The planner's interface is in English, and public holidays carry English
  names.
- Every dependency is on its latest release, among them Riverpod 3,
  go_router 18, google_sign_in 7, flutter_local_notifications 22, Vite 8,
  TypeScript 7, SQLAlchemy 2.1 and FastAPI 0.142.
- On Android, the first start after the update asks you to sign in again: the
  new secure storage cannot read the tokens the old version kept.
- iOS now needs iOS 15 or later.

### Fixed
- Scrapers that read only the first page of an ensemble's listing, dated
  every PKF concert with the next one's date, or kept only the first evening
  of a multi-night run.
- A pool update no longer wipes the programme and scores gathered earlier; a
  concert whose web address changed stays the same concert.
- A bought concert no longer collides with itself in the plan.
- The programme player plays what was picked, and Spotify's player is no
  longer blocked by the planner's content policy.
- Deploying no longer starts a second API container next to the running one.

## [1.1.0]

Current public baseline. Self-hosted cultural-event tracker for two users, with
Flutter apps (Android + iOS) and a Python/FastAPI backend.

### Features
- Shared agenda of cultural events (concerts, theatre, cinema): chronological
  list, monthly calendar, past-events view, per-event detail with cover art,
  venue photos, ticket PDFs, costs and notes.
- Shared, 2-level-nested watchlist with drag-to-reorder and 10-second polling.
- Year-in-review statistics (spend, visits by category, top venues, monthly).
- LLM-powered ticket ingestion via a Claude Code skill (`skills/ticket-parser`).
- Google OAuth login with an email allowlist; independent REST API key for the
  ingestion skill / automation.

Earlier tags (v0.0.1 – v1.0.x) tracked the pre-1.0 build-out; see the Releases
page for their notes.
