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
  - when you finish a turn with code changes, `just check-affected` runs
    (`just check` narrowed to the units changed since the last tree that
    passed; a shared file — the justfile, `tools/`, root config — runs the
    whole lane; pre-push still runs the whole `just check`); if it fails,
    you get the output and must fix it before stopping. It waits while
    background agents of the session are still working and runs in the turn
    the last of them reports back.
- **Rules** (`.claude/rules/`) load when you read files under
  `apps/mobile/lib`, `apps/mobile/android`, `apps/mobile/ios`, `apps/api`,
  `apps/api/web`, `skills` or `infra/claudebox`.

## Subagents — delegate to them

| Agent | Model / effort | When |
|---|---|---|
| `test-runner` | haiku / low | after code changes and before calling work done; read-only verdict; keeps Gradle, Docker and pytest logs out of the main context |
| `test-writer` | sonnet / high | when test-runner reports red, and to write tests; pass `model: "opus"` for a cross-layer, racy or flaky failure |
| `integrity-reviewer` | session / high | before committing anything under `apps/api/src`, `apps/api/alembic`, `apps/mobile/lib/features/{sync,outbox,auth,notifications}`, `apps/mobile/android`, `skills/kulturni-sezona` or `infra` |
| `docs-writer` | sonnet / medium | after a change to behaviour, commands, the API, the sync protocol, the toolchain or the release flow |

Each agent runs on the cheapest model that matches the session's result;
the reviewer keeps the session model. Escalate one call with the Agent
tool's `model` parameter rather than editing the frontmatter.

## Committing

When Petr asks to run the checks and commit a stretch of work, follow the
global `commit-in-background` skill: snapshot the finished tree, let a
background agent (haiku for a fully written plan, sonnet when it must split
hunks or write tests) make small commits and verify each one in its own
git worktree (`just ci` after the last), keep working meanwhile, then adopt
its commits with `git reset --mixed`. Small diffs are committed inline.
Never push without its own word.

## Skills

The skills in `skills/` are this project's own and are linked globally:
`/kulturni-prehled-ingest` (tickets → events), `/kulturni-prehled` (weekly
novelty watcher, the only one that e-mails), `/kulturni-sezona` (season
plan), `/program-links`, the domain experts (`/klasika-expert`,
`/elektronika-expert`, …) and the iOS releases (`/ios-release-vm`,
`/ios-release-macbook`). Deploys follow the global `/deploy` standard.
