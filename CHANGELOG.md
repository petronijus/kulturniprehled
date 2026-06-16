# Changelog

All notable changes to Kulturní Přehled. Format follows
[Keep a Changelog](https://keepachangelog.com/), versioning follows
[SemVer](https://semver.org/). The mobile app version (`apps/mobile/pubspec.yaml`)
drives the `vX.Y.Z` tags; per-release detail is on the
[GitHub Releases](../../releases) page.

## [Unreleased]

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
