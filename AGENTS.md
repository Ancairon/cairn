# record_reccomend

Open-source, album-first mobile music discovery app (Flutter/Dart). See an album, tap play (deep link into whatever streaming app is installed), rate it 1-5 stars, get the next album dynamically based on that rating.

## Goals

Bridge human curation with a fast, active, album-centric discovery loop on mobile — as an alternative to streaming algorithms that optimize for passive/repeat listening rather than full-album discovery. Success means: see an album, play it via deep link into whatever streaming app is installed, rate it, and get a genuinely relevant next album with no backend, no login, and no API keys required.

Locked-in architecture decisions:

- **No Spotify API integration** — no developer account, OAuth, or client secret anywhere in the app. A Spotify link may appear only as a deep-link *target*, and only if sourced from MusicBrainz's own public external-link data.
- **No Last.fm.** `album.getSimilar` doesn't exist in Last.fm's API (verified against Last.fm's docs), and MusicBrainz's own API already provides genre/tag data for free. Result: **zero API keys anywhere in this app.**
- **Data sources, all public and keyless:** MusicBrainz API (identity, genres, external links), Cover Art Archive (artwork), ListenBrainz Labs `similar-artists` (recommendation signal, real listening-session data), Odesli (cross-platform link resolution).
- **DB: `sqlite3` (pure-Dart FFI), not `sqflite`.** Works identically in a plain terminal Dart program and later inside the Flutter app (with `sqlite3_flutter_libs` on Android) — one DB package for the whole project's lifetime.
- **State management: plain `ChangeNotifier`.** No Riverpod/Bloc/Provider — deliberately minimal.
- **Recommendation algorithm: a single global "anchor" album**, not a branch/lineage tree. 4-5 stars sets the anchor; 3 is neutral; 1-2 pivots immediately to an unexplored decade/genre. No streak-counting.
- **Simplicity is a deliberate, explicit priority** — plain SQL over query builders, no codegen/build_runner steps, no premature abstraction. Code should be readable by a human, not just generated and trusted.
- **Build order:** terminal app (`bin/cli.dart`) + data layer first, fully headless on any Linux machine, no phone/Android SDK needed — then verified on a physical Android device over wireless ADB — then a Flutter UI on top of the same data layer.

Full schema, algorithm detail, and API integration notes live in `.agents/sow/specs/architecture.md`.

## SOW System

This project uses a local Statement of Work system.

The SOW system is self-contained in this repository. Normal SOW work must not depend on `~/.agents`, `~/.AGENTS.md`, global skills, global templates, or global scripts. Use this `AGENTS.md`, project-local SOW files, project-local specs, project-local skills, and the active SOW.

**The `.agents/sow/` directory is intentionally excluded from git (see `.gitignore`) — it is a local planning/tracking aid, not published as part of this open-source repo.** This is a deliberate user decision, not an oversight; do not propose removing it from `.gitignore` without being asked.

### Roles

- **User responsibilities:** purpose, scope decisions, design forks, risk acceptance, destructive approvals, and final product judgment.
- **Assistant responsibilities:** investigation, evidence, implementation, tests or equivalent validation, reviews, documentation, memory updates, and concise reporting.

### Required First Checks

Before non-trivial work:

1. Read pending/current SOWs for overlap, contradictions, and existing decisions.
2. Read relevant specs under `.agents/sow/specs/`.
3. Inspect `.agents/skills/project-*/SKILL.md` and load every runtime project skill whose trigger matches the work.
4. Inspect code/docs/data as ground truth.
5. Ask the user only for irreducible product/design/risk decisions.

### Git Worktrees

Assistants must not create git worktrees on their own. Create a git worktree only when the user explicitly asks for it or approves it.

### Sensitive Data In Durable Artifacts

SOWs, specs, documentation, project skills, agent instructions, and code comments are commit-ready artifacts. Treat them as public unless a repository-specific policy explicitly says otherwise.

CRITICAL: Never write raw sensitive data to durable artifacts. This includes passwords, API keys, bearer tokens, SNMP communities, private keys, connection strings with embedded credentials, session cookies, community member names, customer names, customer identifiers, personal data, non-private IP addresses that can identify customers, private endpoints, account IDs, and proprietary incident details.

Write only sanitized evidence:

- use placeholders such as `[REDACTED_SECRET]`, `[CUSTOMER]`, `[ACCOUNT]`, `[PRIVATE_ENDPOINT]`;
- use stable aliases such as `customer-a` only when the real mapping is not stored in the repository;
- cite file paths, line numbers, command names, schema fields, or error classes instead of copying sensitive values;
- summarize logs and traces; include only minimal redacted snippets.

If sensitive data is required to continue, stop and ask the user for a secure handling path. If sensitive data is found in a durable artifact, sanitize it before any commit. If sensitive data was already committed, tell the user and do not rewrite history without explicit approval.

(This project has no API keys or secrets at all by design — see Goals — but this rule still applies to any future credentials, tokens, or personal data that might appear in logs/fixtures.)

### Open-Source Reference Evidence

When a SOW uses external open-source repositories as evidence, record the upstream repository identity and checked commit, not the workstation mirror path.

For local mirrored or cloned open-source repositories, cite evidence in this form:

```text
owner/repo @ commit
relative/path/inside/repo:line
```

Rules:

- Never use workstation absolute paths for external open-source evidence in SOWs.
- Resolve `owner/repo` from the repository remote, not only from the local directory name.
- Record the commit with `git -C <repo> rev-parse --short=12 HEAD` or the full hash when precision matters.
- Use paths relative to the upstream repository root after the `owner/repo @ commit` line.
- If multiple repositories were checked, list each repository and commit separately.

### Pre-Implementation Gate

Implementation must not begin until the active SOW contains a concrete `## Pre-Implementation Gate` section. Before moving a SOW from `pending/open` to `current/in-progress`, or before continuing implementation in an existing current SOW that lacks this section, fill the gate.

The gate must record: problem/root-cause model, evidence reviewed, affected contracts and surfaces, existing patterns to reuse, risk and blast radius, sensitive data handling plan, implementation plan, validation plan, artifact impact plan, open-source reference evidence, and open decisions.

Generic placeholders such as `TBD`, `N/A`, or "to be checked later" are invalid unless the SOW explains why the item truly does not apply. If the gate exposes an unknown that cannot be resolved by investigation, stop and ask the user before implementation.

### When A SOW Is Required

Create or reuse a SOW for non-trivial work: feature work, bug fixes with behavioral impact, refactors, migrations, documentation/content changes with product impact, process changes, regressions, spec hygiene, project skill changes, or any work with unclear risk.

Trivial work does not need a SOW: typo fixes, formatting-only changes, mechanical renames with no behavior change, simple low-risk search/replace.

When unsure, treat the work as non-trivial.

### SOW Locations

- Pending: `.agents/sow/pending/`
- Current: `.agents/sow/current/`
- Done: `.agents/sow/done/`
- Specs: `.agents/sow/specs/`
- Template for new SOWs: `.agents/sow/SOW.template.md`
- Local audit: `.agents/sow/audit.sh`

Create new SOW files from `.agents/sow/SOW.template.md`. The template is project-local and may be customized for this repository.

Empty SOW directories must contain `.gitkeep` so the layout survives clone/checkout (even though `.agents/sow/` itself is gitignored here, per the decision above — the placeholders keep the local structure consistent).

Filename: `SOW-NNNN-YYYYMMDD-{slug}.md`

Status and directory must agree: `open` in `pending/`, `in-progress`/`paused` in `current/`, `completed`/`closed` in `done/`.

### SOW Completion And Commit

The successful terminal SOW status is `completed`. `done` is a directory name, not a status value. Never write `Status: done` or `Status: complete`.

When a SOW's work is ready to close: finish implementation/docs/specs/skills/validation/follow-up mapping, update the SOW to `Status: completed`, move it to `.agents/sow/done/`, and commit the code changes together (the SOW itself is gitignored, so its move doesn't need a code commit — but keep the code commit scoped to the same completed unit of work).

### One SOW At A Time

Never execute multiple SOWs as one batch. If work overlaps, merge/consolidate before implementation, or split into separate SOWs and complete one before starting the next. Progress reports are not stop points — once a SOW is in progress, continue until delivered, failed with evidence, blocked on a real user decision, or superseded by newer instructions.

### User Decisions

When user decisions are needed: present concrete evidence with files/lines or sources, provide numbered options, explain pros/cons/implications/risks, recommend one option with reasoning, and record the user's decision in the SOW before implementation.

### Followup Discipline

"Deferred" is not a terminal outcome. Before a SOW can close, every valid deferred item must be implemented, explicitly rejected with evidence, or represented by a real pending/current SOW file.

### Regressions

A regression is discovered after a SOW was considered completed/closed and later testing/use finds broken behavior. Reopen the original SOW (move `done/` → `current/`, mark `in-progress`), and append a dated `## Regression - YYYY-MM-DD` section at the end of the file, after the original outcome/lessons/follow-up. Never prepend regression content above the original narrative. Do not create a new SOW for a true regression.

### Validation Gate

A SOW cannot be completed until Validation records: acceptance criteria evidence, tests or equivalent validation, real-use evidence when a runnable path exists, reviewer findings and handling, same-failure search results, the sensitive data gate, the artifact maintenance gate, SOW status/directory consistency, spec/skill/docs update-or-reason, lessons extracted, and follow-up mapping. Generic "N/A" is invalid.

### Artifact Maintenance Gate

Every SOW close must record whether each of these was updated or why not needed: `AGENTS.md`, runtime project skills (`.agents/skills/project-*/SKILL.md`), specs (`.agents/sow/specs/`), end-user/operator docs (README etc.), end-user/operator skills, SOW lifecycle.

### Specs

Specs are memory of WHAT this project does — product behavior, public contracts, data formats, UX rules, business logic, operational guarantees, known edge cases. They describe current reality, not aspiration. If specs and code disagree, record the discrepancy in the active SOW.

### Project Skills

Project skills are memory of HOW to work here, under `.agents/skills/project-*/SKILL.md`. Before non-trivial work, inspect matching skill descriptions and load them. Do not create generic `project-*` skills just to look complete — a missing skill is better than a useless one.

### Project Skills Index

None yet. This is a fresh bootstrap on an empty project with zero code written — there is no concrete reusable workflow knowledge to capture into a hook-based checklist yet. This decision is recorded in `SOW-0001` rather than left as an unstated gap. Revisit once Milestone 1 (the CLI + data layer) produces real lessons worth codifying (e.g. a MusicBrainz rate-limiting gotcha, a recurring test-fixture pattern).

Legacy runtime skills: none.

Output/reference skills: none.

### Project-specific commands

- `dart pub get` — install dependencies.
- `dart run bin/cli.dart` — run the terminal app (Milestone 1).
- `dart test` — run pure-logic tests (recommendation scoring/dedup, export formatting) against fixture JSON, no live API calls.
- `flutter test` / `flutter analyze` — once the project is wired up as a Flutter project (Milestone 3 onward).

### Project-specific overrides

None yet.

### Preservation Notes

Fresh bootstrap on a genuinely empty project (confirmed via `bootstrap-repo` audit — no pre-existing `AGENTS.md` or other agent files). Nothing to preserve from a prior state; this file and `SOW-0001` are the first record of the architecture decisions made during planning.

Project SOW status: initialized
