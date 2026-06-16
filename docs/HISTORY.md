# Development history

This repository was re-published with a cleaned git history (private
infrastructure details and personal data removed). The granular commit history
is preserved; this file is a high-level orientation map of the merged
pull-requests that built the app, for when the commit log alone isn't enough.

| PR | Date | Change |
|----|------|--------|
| #1 | 2026-05-14 | fix(api,mobile): accept multiple OAuth audiences so iOS sign-in works |
| #2 | 2026-05-14 | fix(infra): make compose.prod.yml overlay opt-in in upgrade.sh |
| #3 | 2026-05-14 | feat(api): watchlist — shared todo list with 2-level nesting |
| #5 | 2026-05-14 | feat(mobile): watchlist UI — list, add/edit, reorder, 3rd nav tab |
| #6 | 2026-05-14 | docs: 2026-05-14 watchlist + mobile-build session handover |
| #7 | 2026-05-14 | feat: watchlist outbox — offline-first mutations end-to-end |
| #8 | 2026-05-14 | feat: cover_image_url on Event (backend + mobile render) |
| #9 | 2026-05-14 | feat: venue card + maps, rich agenda tile, month-view highlight |
| #10 | 2026-05-15 | fix: stats by event month + event detail reorder |
| #11 | 2026-05-15 | feat(mobile): next-event banner in month view |
| #12 | 2026-05-15 | feat(mobile): month section headers in Agenda |
| #13 | 2026-05-15 | ci(android): signed release APK in GitHub Releases |
| #14 | 2026-05-15 | chore: drop GitHub Actions CI, document manual release flow |
| #15 | 2026-05-31 | feat: scoped PATs + server-side digest context for cloud weekly routine |
| #16 | 2026-06-03 | feat: Spotify concert playlists from ticket ingest |
| #17 | 2026-06-05 | fix: scheduled notifications silently dropped + silent logout (refresh reuse) |
| #18 | 2026-06-08 | fix: stats screen no longer pins a stale load error |
| #19 | 2026-06-08 | fix: superseded token rotation no longer logs the device out |
| #20 | 2026-06-10 | feat(api): serve Discogs taste map from /v1/digest/context |
| #21 | 2026-06-10 | feat(api): relay digest email over SMTP via POST /v1/digest/send |
| #22 | 2026-06-14 | feat(mobile): per-card agenda parallax + difference-blend titles & date row |

_Generated from merged PR metadata; see `git log` for full detail and
[CHANGELOG.md](../CHANGELOG.md) for released versions._
