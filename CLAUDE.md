@AGENTS.md

## Claude Code in this repo

Project configuration lives in `.claude/` (committed). What it does for you:

- **Hooks** (`.claude/settings.json`):
  - every file you write — with the edit tools or from the shell (`sed -i`,
    `>`, heredocs) — is formatted with `tools/dev/format.sh`; a complaint it
    cannot fix (ruff, shellcheck, Biome) comes back to you. Unused imports
    are left alone mid-edit; `just check` catches the ones that stay;
  - writing key material, SOPS files, the brand masters, drift's
    `*.g.dart`, lockfiles and build output is refused, from the shell too,
    and so is a shell command that prints key material — also when wrapped
    (`sudo -u x cat …`) or reached by a recursive search (`grep -r`; use `rg` or
    `git grep`, which skip gitignored files); a call the guard cannot parse
    is denied; `project.pbxproj` asks first;
  - when you finish a turn with code changes, `just check` runs; if it
    fails, you get the output and must fix it before stopping.
- **Rules** (`.claude/rules/`) load when you read files under
  `apps/mobile/lib`, `apps/mobile/android`, `apps/mobile/ios`, `apps/api`,
  `apps/api/web`, `skills` or `infra/claudebox`.

## Subagents — delegate to them

| Agent | When |
|---|---|
| `test-runner` | after code changes, on any failing test or build, and to write tests; keeps Gradle, Docker and pytest logs out of the main context |
| `integrity-reviewer` | before committing anything under `apps/api/src`, `apps/api/alembic`, `apps/mobile/lib/features/{sync,outbox,auth,notifications}`, `apps/mobile/android`, `skills/kulturni-sezona` or `infra` |
| `docs-writer` | after a change to behaviour, commands, the API, the sync protocol, the toolchain or the release flow |

## Skills

The skills in `skills/` are this project's own and are linked globally:
`/kulturni-prehled-ingest` (tickets → events), `/kulturni-prehled` (weekly
novelty watcher, the only one that e-mails), `/kulturni-sezona` (season
plan), `/program-links`, the domain experts (`/klasika-expert`,
`/elektronika-expert`, …) and the iOS releases (`/ios-release-vm`,
`/ios-release-macbook`). Deploys follow the global `/deploy` standard.
